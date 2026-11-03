import Foundation
import Observation

/// What a paired phone sees and can do. Reads and calls `AppModel`'s public surface and nothing else: what the UI can't
/// do, the phone can't either. See ShiftProtocol/Wire.swift for the messages.
@MainActor
@Observable
public final class RemoteServer {
    /// Paired phones, and ones still being shown their code.
    public private(set) var devices: [RemoteDevice]
    /// Where it listens on loopback, and on the tailnet once shared.
    public private(set) var port: Int?

    /// How often a subscribed log is checked for more (tests shorten it).
    /// ponytail: polling, cheap while a phone is looking; a store callback if phones ever watch many logs.
    @ObservationIgnored var logPoll: Duration = .milliseconds(400)

    private static let logChunk = 256 << 10

    @ObservationIgnored private weak var model: AppModel?
    @ObservationIgnored private let listener: RemoteListener
    @ObservationIgnored private var connections: Set<RemoteConnection> = []
    @ObservationIgnored private var sent = RemoteSnapshot()
    @ObservationIgnored private var pumps: [RemoteConnection: [AgentLog: Task<Void, Never>]] = [:]
    @ObservationIgnored let keepAwake = KeepAwake()
    @ObservationIgnored private var tailnetShared = false

    init(model: AppModel, listener: RemoteListener) {
        self.model = model
        self.listener = listener
        devices = listener.auth.devices
    }

    func start() async {
        // The listener calls these on its queue. Hopping in order keeps a connection's messages in order.
        let (events, input) = AsyncStream<@MainActor () async -> Void>.makeStream()
        Task { @MainActor in
            for await event in events { await event() }
        }
        port = await listener.start(.init(
            opened: { [weak self] connection in input.yield { self?.opened(connection) } },
            received: { [weak self] connection, data in input.yield { self?.received(data, from: connection) } },
            closed: { [weak self] connection in input.yield { self?.closed(connection) } }))
        observe()
        guard !devices.isEmpty else { return }
        // Tailscale may not be up yet at login.
        Task { [weak self] in
            while let self, !self.devices.isEmpty {
                if await self.shareOnTailnet() != nil { return }
                try? await Task.sleep(for: .seconds(60))
            }
        }
    }

    func stop() {
        listener.stop()
        keepAwake.set(false)
    }

    // MARK: Pairing

    public enum PairingError: LocalizedError {
        case notListening, noTailnet

        public var errorDescription: String? {
            switch self {
            case .notListening: "Shift could not start listening for your phone. Quit and reopen it."
            case .noTailnet: "Your phone reaches this Mac over Tailscale, with HTTPS certificates on. Start Tailscale, check that in its admin console, and try again."
            }
        }
    }

    /// A new device and what its code carries, valid until it's revoked.
    func pair() async throws -> (device: RemoteDevice, pairing: Pairing) {
        guard let port else { throw PairingError.notListening }
        guard let host = await shareOnTailnet() else { throw PairingError.noTailnet }
        let (device, token) = listener.auth.add()
        devices = listener.auth.devices
        return (device, Pairing(host: host, port: port, token: token))
    }

    /// Forgets the device and drops its connection. With none left, the Mac stops being reachable on the tailnet.
    func revoke(_ id: RemoteDevice.ID) {
        listener.auth.remove(id)
        devices = listener.auth.devices
        for connection in connections where connection.caller == .device(id) { connection.close() }
        if devices.isEmpty, tailnetShared, let port {
            tailnetShared = false
            Task { await model?.stopSharingOnTailnet(port: port) }
        }
    }

    /// Serves the port on the tailnet and learns who may reach it. The host name, nil if that failed.
    private func shareOnTailnet() async -> String? {
        guard let port, let shared = await model?.shareOnTailnet(port: port) else { return nil }
        listener.auth.setOwner(shared.owner)
        tailnetShared = true
        return shared.host
    }

    // MARK: State

    private func observe() {
        guard let model else { return }
        withObservationTracking {
            sync(model)
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in self?.observe() }
        }
    }

    private func sync(_ model: AppModel) {
        let now = Self.snapshot(of: model)
        let messages = now.changes(since: sent)
        sent = now
        for connection in connections { messages.forEach(connection.post) }
        keepAwake.set(model.tasks.contains { $0.status == .working })
    }

    static func snapshot(of model: AppModel) -> RemoteSnapshot {
        var snapshot = RemoteSnapshot()
        snapshot.projects = model.projects
        snapshot.tasks = model.tasks
        snapshot.chats = model.chats
        snapshot.pullRequests = model.pullRequests
        snapshot.builds = model.builds
        snapshot.usage = model.usage
        for project in model.projects {
            if let request = model.chatApprovalRequest(projectID: project.id) { snapshot.chatApprovals[project.id] = request }
        }
        snapshot.replyingChats = model.replyingChats
        return snapshot
    }

    // MARK: Connections

    private func opened(_ connection: RemoteConnection) {
        connections.insert(connection)
        seen(connection)
        connection.post(.hello(version: Wire.version))
        // Together with `connections`, on the main actor: nothing can change between this and the next sync.
        connection.post(.snapshot(sent))
    }

    private func closed(_ connection: RemoteConnection) {
        connections.remove(connection)
        pumps.removeValue(forKey: connection)?.values.forEach { $0.cancel() }
    }

    private func seen(_ connection: RemoteConnection, name: String? = nil) {
        guard case .device(let id) = connection.caller else { return }
        listener.auth.seen(id, name: name)
        devices = listener.auth.devices
    }

    private func received(_ data: Data, from connection: RemoteConnection) {
        // A message this version doesn't know is ignored, so that a newer phone can keep talking.
        guard connections.contains(connection), let message = Wire.decode(ClientMessage.self, from: data) else { return }
        switch message {
        case .hello(_, let device):
            seen(connection, name: device)
        case .command(let request):
            Task { @MainActor in
                // Unlike a message, a command has someone waiting for its reply.
                let (result, error) = if let command = request.command { await perform(command) }
                    else { (RemoteResult?.none, String?.some("This Mac's Shift doesn't know this command. Update it.")) }
                connection.post(.reply(id: request.id, result: result, error: error))
            }
        case .subscribe(let log, let offset):
            pumps[connection]?[log]?.cancel()
            pumps[connection, default: [:]][log] = Task { @MainActor [weak self] in await self?.pump(log, from: offset, to: connection) }
        case .unsubscribe(let log):
            pumps[connection]?.removeValue(forKey: log)?.cancel()
        }
    }

    /// Sends the log from `offset`, and then whatever gets appended, until cancelled.
    private func pump(_ log: AgentLog, from offset: UInt64, to connection: RemoteConnection) async {
        var offset = offset
        while !Task.isCancelled {
            guard let data = await model?.logBytes(log, from: offset, length: Self.logChunk) else { return }
            if data.isEmpty {
                try? await Task.sleep(for: logPoll)
            } else {
                await connection.send(.log(log, offset: offset, data: data))
                offset += UInt64(data.count)
            }
        }
    }

    // MARK: Commands

    /// Runs the command. What it failed with is what the model would show the user as an alert. Which also still does.
    func perform(_ command: RemoteCommand) async -> (RemoteResult?, String?) {
        guard let model else { return (nil, "Shift is quitting.") }
        let earlier = model.lastError
        model.lastError = nil
        let result: Result<RemoteResult, Error> = await run(command, on: model)
        let failure = model.lastError
        if failure == nil { model.lastError = earlier }
        switch result {
        case .success(let result): return failure.map { (nil, $0) } ?? (result, nil)
        case .failure(let error): return (nil, error.localizedDescription)
        }
    }

    private func run(_ command: RemoteCommand, on model: AppModel) async -> Result<RemoteResult, Error> {
        switch command {
        case .createTask(let projectID, let prompt, let attachments, let agent):
            return .success(.taskID(model.createTask(projectID: projectID, prompt: prompt, attachments: attachments, agent: agent)))
        case .sendPrompt(let id, let text, let attachments): model.sendPrompt(taskID: id, text: text, attachments: attachments)
        case .answerApproval(let id, let allow): model.answerApproval(taskID: id, allow: allow)
        case .stop(let id): model.stop(taskID: id)
        case .resume(let id): model.resume(taskID: id)
        case .rename(let id, let title): model.rename(taskID: id, to: title)
        case .merge(let id): await model.merge(taskID: id)
        case .branches(let projectID): return .success(.files(await model.branches(for: projectID)))
        case .changeBase(let id, let base): await model.changeBase(taskID: id, to: base)
        case .delete(let id): await model.delete(taskID: id)
        case .resolveConflict(let id): model.resolveConflict(taskID: id)
        case .conflictedFiles(let id): return .success(.files(await model.conflictedFiles(taskID: id)))
        case .pushBranch(let id): await model.pushBranch(taskID: id)
        case .pullRequestURL(let id): return .success(.url(await model.pullRequestURL(taskID: id)))
        case .loadChanges(let id): return await model.loadChanges(taskID: id).map(RemoteResult.changes)
        case .loadDiff(let id): return await model.loadDiff(taskID: id).map(RemoteResult.diff)
        case .restartServer(let id): await model.restartServer(taskID: id)
        case .serverLog(let id): return .success(.text(await model.serverLog(taskID: id)))
        case .build(let id, let target): _ = await model.build(taskID: id, target: target)
        case .buildLog(let id, let target): return .success(.text(model.buildLog(taskID: id, target: target)))
        case .sendChat(let id, let text, let attachments): model.sendChat(projectID: id, text: text, attachments: attachments)
        case .answerChatApproval(let id, let allow): model.answerChatApproval(projectID: id, allow: allow)
        case .stopChat(let id): model.stopChat(projectID: id)
        case .newChat(let id): await model.newChat(projectID: id)
        case .projectIcon(let id):
            guard let project = model.projects.first(where: { $0.id == id }) else { return .success(.data(nil)) }
            return .success(.data(await ProjectIconFinder.png(in: URL(fileURLWithPath: project.repoPath))))
        case .baseServerURL(let id):
            let url = await model.baseServerURL(projectID: id)
            // ponytail: stays shared until Tailscale's serve config is reset; it only points at a port on this Mac,
            // for this tailnet. Unserve it when the base server stops if that ever matters.
            if let port = url?.port { _ = await model.shareOnTailnet(port: port) }
            return .success(.url(url))
        }
        return .success(.done)
    }
}

// MARK: - For the UI and the server

extension AppModel {
    /// Phones paired with this Mac, and ones still being shown their code.
    public var remoteDevices: [RemoteDevice] { remote?.devices ?? [] }

    /// A new device, and what its QR code shows.
    public func pairDevice() async throws -> (device: RemoteDevice, pairing: Pairing) {
        guard let remote else { throw RemoteServer.PairingError.notListening }
        return try await remote.pair()
    }

    public func revokeDevice(_ id: RemoteDevice.ID) { remote?.revoke(id) }

    /// Up to `length` bytes of the log from `offset`. Empty past its end or if there is no log.
    public func logBytes(_ log: AgentLog, from offset: UInt64, length: Int) async -> Data {
        await store?.logBytes(log, from: offset, length: length) ?? Data()
    }
}
