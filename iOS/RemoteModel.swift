import Foundation
import Observation
import Security
import ShiftProtocol
import UIKit
import UserNotifications

/// The Mac's live state as far as the phone knows, and its methods sent to the Mac as commands. A copy of the parts of
/// `AppModel` the views read: nothing is stored, and with the Mac away nothing can be done.
@MainActor
@Observable
final class RemoteModel {
    enum Link: Equatable {
        case connecting, online, offline
        /// The Mac said no: this phone was revoked, or the Mac doesn't know yet who owns it.
        case refused
    }

    private(set) var state = RemoteSnapshot()
    private(set) var link = Link.connecting
    /// A snapshot arrived at least once since pairing, so `state` means something.
    private(set) var hasState = false
    private(set) var pairing: Pairing?
    /// A link opened from the Mac's QR code, until the user agrees to it.
    var proposedPairing: Pairing?
    var lastError: String?
    /// Each project's icon, once asked for. nil inside: it has none.
    private(set) var projectIcons: [UUID: UIImage?] = [:]

    @ObservationIgnored private var run: Task<Void, Never>?
    @ObservationIgnored private var socket: URLSessionWebSocketTask?
    @ObservationIgnored private var nextID = 1
    @ObservationIgnored private var waiting: [Int: CheckedContinuation<(RemoteResult?, String?), Never>] = [:]
    @ObservationIgnored private var streams: [AgentLog: LogStream] = [:]
    /// A screenshot never changes once taken.
    @ObservationIgnored private var screenshots: [UUID: UIImage] = [:]

    init() {
        #if DEBUG
        // scripts/build.sh launches a simulator build at its own Mac build, with no pairing.
        if let server = ProcessInfo.processInfo.environment["SHIFT_SERVER"], let direct = Pairing(shiftServer: server) {
            pairing = direct
            connect()
            return
        }
        #endif
        pairing = Keychain.load()
        if pairing != nil { connect() }
    }

    /// Set on launch: asks for permission once, and shows banners with the app open too, as the Mac does.
    @ObservationIgnored private let notifier = Notifier()

    // MARK: Pairing

    func open(link url: URL) {
        if let pairing = Pairing(link: url) { proposedPairing = pairing } else { lastError = "That isn't a pairing code from Shift." }
    }

    func pair(_ new: Pairing) {
        Keychain.save(new)
        reset(to: new)
        connect()
    }

    func forget() {
        Keychain.delete()
        reset(to: nil)
    }

    private func reset(to new: Pairing?) {
        run?.cancel()
        socket?.cancel()
        pairing = new
        state = RemoteSnapshot()
        hasState = false
        streams = [:]
        link = .connecting
    }

    // MARK: Connection

    /// Coming back to the foreground: don't wait out the delay before the next try.
    func reconnectNow() {
        if pairing != nil, link != .online { connect() }
    }

    private func connect() {
        run?.cancel()
        socket?.cancel()
        run = Task { [weak self] in
            var delay = 1.0
            while !Task.isCancelled, let self, let pairing = self.pairing {
                if await self.session(pairing) { delay = 1 }
                guard !Task.isCancelled else { return }
                try? await Task.sleep(for: .seconds(delay))
                delay = min(delay * 2, 15)
            }
        }
    }

    /// One connection, until it's over. True if it got as far as hearing from the Mac.
    private func session(_ pairing: Pairing) async -> Bool {
        var request = URLRequest(url: pairing.url(path: Wire.socketPath))
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request)
        socket.maximumMessageSize = Wire.maxMessage
        socket.resume()
        self.socket = socket
        let watchdog = Task { [weak socket] in await Self.watch(socket) }
        defer {
            watchdog.cancel()
            socket.cancel()
            waiting.values.forEach { $0.resume(returning: (nil, "Lost the connection to your Mac.")) }
            waiting = [:]
        }
        var heard = false
        while true {
            do {
                let received = try await socket.receive()
                if !heard {
                    heard = true
                    link = .online
                    send(.hello(version: Wire.version, device: UIDevice.current.name))
                    for (log, stream) in streams where stream.isOpen { send(.subscribe(log: log, from: stream.offset)) }
                }
                let data = switch received {
                case .string(let text): Data(text.utf8)
                case .data(let data): data
                @unknown default: Data()
                }
                // Whatever this version doesn't know is skipped.
                if let message = Wire.decode(ServerMessage.self, from: data) { await handle(message) }
            } catch {
                guard self.socket === socket else { return heard } // Replaced by a newer one.
                link = (socket.response as? HTTPURLResponse)?.statusCode == 401 ? .refused : .offline
                return heard
            }
        }
    }

    /// A phone on a train can lose the Mac without anything saying so.
    private static func watch(_ socket: URLSessionWebSocketTask?) async {
        let answered = Flag()
        while (try? await Task.sleep(for: .seconds(15))) != nil, let socket {
            guard answered.take() else { return socket.cancel(with: .goingAway, reason: nil) }
            socket.sendPing { error in if error == nil { answered.set() } }
        }
    }

    private final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var value = true
        func set() { lock.withLock { value = true } }
        func take() -> Bool { lock.withLock { defer { value = false }; return value } }
    }

    private func handle(_ message: ServerMessage) async {
        switch message {
        case .hello: break
        case .reply(let id, let result, let error):
            waiting.removeValue(forKey: id)?.resume(returning: (result, error))
        case .log(let log, let offset, let data):
            await streams[log]?.received(data, at: offset)
        case .snapshot:
            state.apply(message)
            hasState = true
        case .task(let task):
            let old = self.task(task.id)?.status
            state.apply(message)
            // ponytail: only while the app runs; iOS suspends it soon after it leaves the screen. Push needs APNs.
            if let old, task.status.notifies(from: old) {
                let project = state.projects.first { $0.id == task.projectID }?.name ?? ""
                notifier.notify(title: project, body: "\(task.title) \(task.status.needsAttention ? "needs your attention" : "is ready for review").", taskID: task.id)
            }
        default:
            state.apply(message)
        }
    }

    private func send(_ message: ClientMessage) {
        socket?.send(.string(String(decoding: Wire.encode(message), as: UTF8.self))) { _ in }
    }

    // MARK: Commands

    /// Sends the command and shows what went wrong, if anything.
    @discardableResult
    /// `quietly`: a failure isn't shown, for things the user didn't ask for.
    private func perform(_ command: RemoteCommand, quietly: Bool = false) async -> RemoteResult? {
        guard link == .online else {
            if !quietly { lastError = "Your Mac is offline." }
            return nil
        }
        let id = nextID
        nextID += 1
        let (result, error) = await withCheckedContinuation { continuation in
            waiting[id] = continuation
            send(.command(CommandRequest(id: id, command: command)))
        }
        if let error, !quietly { lastError = error }
        return result
    }

    /// The new task, with the project's default agent. nil if it couldn't be started, having said why.
    func createTask(projectID: UUID, prompt: String, attachments: [String]) async -> Int? {
        guard case .taskID(let id)? = await perform(.createTask(projectID: projectID, prompt: prompt, attachments: attachments, agent: nil)) else { return nil }
        if id == nil { lastError = "Your Mac couldn't start this task." }
        return id
    }

    /// False if it didn't get through.
    @discardableResult
    func sendPrompt(taskID: Int, text: String, attachments: [String] = []) async -> Bool {
        await perform(.sendPrompt(taskID: taskID, text: text, attachments: attachments)) != nil
    }

    func answerApproval(taskID: Int, allow: Bool) async { await perform(.answerApproval(taskID: taskID, allow: allow)) }
    func stop(taskID: Int) async { await perform(.stop(taskID: taskID)) }
    func resume(taskID: Int) async { await perform(.resume(taskID: taskID)) }

    /// False if it didn't get through.
    @discardableResult
    func sendChat(projectID: UUID, text: String, attachments: [String] = []) async -> Bool {
        await perform(.sendChat(projectID: projectID, text: text, attachments: attachments)) != nil
    }

    func answerChatApproval(projectID: UUID, allow: Bool) async { await perform(.answerChatApproval(projectID: projectID, allow: allow)) }
    func stopChat(projectID: UUID) async { await perform(.stopChat(projectID: projectID)) }
    func newChat(projectID: UUID) async { await perform(.newChat(projectID: projectID)) }

    /// The project's base branch as this phone reaches it, once its server answers on the Mac.
    func baseURL(projectID: UUID) async -> URL? {
        guard case .url(let url?)? = await perform(.baseServerURL(projectID: projectID)), let port = url.port else { return nil }
        return pairing?.preview(port: port)
    }

    func merge(taskID: Int) async { await perform(.merge(taskID: taskID)) }
    func push(taskID: Int) async { await perform(.pushBranch(taskID: taskID)) }
    func resolveConflict(taskID: Int) async { await perform(.resolveConflict(taskID: taskID)) }
    func changeBase(taskID: Int, to base: String) async { await perform(.changeBase(taskID: taskID, to: base)) }

    /// The page to open it on, with the branch pushed.
    func pullRequestURL(taskID: Int) async -> URL? {
        guard case .url(let url)? = await perform(.pullRequestURL(taskID: taskID)) else { return nil }
        return url
    }

    /// Nothing to say if it fails, as from a Mac too old to know the command: the picker offers just the current base.
    func branches(projectID: UUID) async -> [String] {
        let earlier = lastError
        defer { lastError = earlier }
        guard case .files(let branches)? = await perform(.branches(projectID: projectID)) else { return [] }
        return branches
    }

    func changes(taskID: Int) async -> DiffSummary? {
        guard case .changes(let changes)? = await perform(.loadChanges(taskID: taskID)) else { return nil }
        return changes
    }

    func diff(taskID: Int) async -> [FileDiff]? {
        guard case .diff(let files)? = await perform(.loadDiff(taskID: taskID)) else { return nil }
        return files
    }

    /// Saves an image on the Mac. Its path there goes in a prompt's `attachments`.
    func upload(_ data: Data, name: String) async throws -> String {
        guard let pairing else { throw URLError(.notConnectedToInternet) }
        var request = URLRequest(url: pairing.url(path: Wire.attachmentsPath, query: [.init(name: "name", value: name)]))
        request.httpMethod = "POST"
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        let (body, response) = try await URLSession.shared.upload(for: request, from: data)
        guard (response as? HTTPURLResponse)?.statusCode == 200, let uploaded = Wire.decode(AttachmentUploaded.self, from: body) else {
            throw URLError(.badServerResponse)
        }
        return uploaded.path
    }

    /// Fetches the project's icon from the Mac, once. A Mac too old to send it leaves the folder.
    func loadIcon(projectID: UUID) async {
        guard projectIcons[projectID] == nil, case .data(let data)? = await perform(.projectIcon(projectID: projectID), quietly: true) else { return }
        projectIcons[projectID] = data.flatMap { UIImage(data: $0, scale: 2) }
    }

    /// A task's screenshot, fetched from the Mac once. nil if it can't be had.
    func image(_ shot: TaskScreenshot) async -> UIImage? {
        if let image = screenshots[shot.id] { return image }
        guard let pairing else { return nil }
        let name = (shot.path as NSString).lastPathComponent
        var request = URLRequest(url: pairing.url(path: Wire.screenshotsPath, query: [.init(name: "name", value: name)]))
        request.setValue("Bearer \(pairing.token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, let image = UIImage(data: data) else { return nil }
        screenshots[shot.id] = image
        return image
    }

    // MARK: Queries

    func tasks(in projectID: UUID) -> [TaskItem] { state.tasks.filter { $0.projectID == projectID } }
    func task(_ id: Int) -> TaskItem? { state.tasks.first { $0.id == id } }
    func chat(projectID: UUID) -> ProjectChat? { state.chats.first { $0.projectID == projectID } }

    /// The task's dev server, while it runs.
    func previewURL(_ task: TaskItem) -> URL? {
        guard let port = task.port, task.serverPID != nil else { return nil }
        return pairing?.preview(port: port)
    }

    // MARK: Transcripts

    /// Starts following the log, from where the phone last got to. Kept for next time: the parser holds the conversation.
    func openLog(_ log: AgentLog, agent: AgentKind) -> LogStream {
        let stream = streams[log] ?? LogStream(agent: agent)
        streams[log] = stream
        stream.isOpen = true
        if link == .online { send(.subscribe(log: log, from: stream.offset)) }
        return stream
    }

    func closeLog(_ log: AgentLog) {
        streams[log]?.isOpen = false
        if link == .online { send(.unsubscribe(log: log)) }
    }
}

/// A log coming in from the Mac, read as a conversation with the same parser the Mac uses.
@MainActor
@Observable
final class LogStream {
    private(set) var turns: [TranscriptTurn] = []
    @ObservationIgnored fileprivate var isOpen = false
    @ObservationIgnored fileprivate private(set) var offset: UInt64 = 0
    @ObservationIgnored private let parser: Parser

    /// Off the main thread: a long log is a lot of JSON.
    private actor Parser {
        private var parser: TranscriptParser
        init(agent: AgentKind) { parser = TranscriptParser(agent: agent) }
        func feed(_ data: Data) -> [TranscriptTurn]? { parser.feed(data) ? parser.turns : nil }
    }

    fileprivate init(agent: AgentKind) { parser = Parser(agent: agent) }

    fileprivate func received(_ data: Data, at start: UInt64) async {
        // Left over from before a reconnect, or already seen.
        guard start == offset else { return }
        offset += UInt64(data.count)
        if let new = await parser.feed(data) { turns = new.filter { !$0.blocks.isEmpty || !$0.promptIDs.isEmpty || $0.text != nil } }
    }
}

/// The pairing is a password: it stays on this device, and is readable once the phone was unlocked.
private enum Keychain {
    private static let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                               kSecAttrService as String: "com.fabiogiolito.shift.pairing"]

    static func load() -> Pairing? {
        var result: CFTypeRef?
        let search = query.merging([kSecReturnData as String: true, kSecMatchLimit as String: kSecMatchLimitOne]) { $1 }
        guard SecItemCopyMatching(search as CFDictionary, &result) == errSecSuccess, let data = result as? Data else { return nil }
        return Wire.decode(Pairing.self, from: data)
    }

    static func save(_ pairing: Pairing) {
        delete()
        let item = query.merging([kSecValueData as String: Wire.encode(pairing),
                                  kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly]) { $1 }
        SecItemAdd(item as CFDictionary, nil)
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}

/// Local notifications for task changes heard over the socket.
private final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    override init() {
        super.init()
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    /// One per task: a newer one replaces the older.
    func notify(title: String, body: String, taskID: Int) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let id = "task-\(taskID)"
        let center = UNUserNotificationCenter.current()
        center.removeDeliveredNotifications(withIdentifiers: [id])
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }
}
