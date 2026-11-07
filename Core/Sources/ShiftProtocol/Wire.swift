import Foundation

// What the phone and the Mac say to each other: JSON text over a WebSocket. Every message is a synthesized
// Codable enum, `{"task": {"_0": {…}}}`, which gives the tolerance old and new peers need for free: unknown
// fields are skipped, and a message of an unknown type doesn't decode, so `Wire.decode` returns nil and the
// reader moves on. When adding a field to a message or to `RemoteSnapshot`, make it optional: older peers won't send it.

public enum Wire {
    /// Say what you speak; never refuse a peer over it. Bump it when a peer may want to adapt to the difference.
    /// 2: knows the `archived` task status. A Mac sends a peer that hasn't said so archived tasks as merged.
    public static let version = 2
    public static let socketPath = "/ws"
    /// POST an image's bytes here, `?name=photo.jpg`. The reply is `AttachmentUploaded`.
    /// GET one back, `?name=` the last component of its path.
    public static let attachmentsPath = "/attachments"
    /// GET a task's screenshot, `?name=` the last component of its `path`.
    public static let screenshotsPath = "/screenshots"
    /// More than a WebSocket message may carry, for whoever reads them: a snapshot can be large.
    public static let maxMessage = 64 << 20

    public static func encode<T: Encodable>(_ value: T) -> Data {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        do { return try encoder.encode(value) } catch { preconditionFailure("Wire types encode: \(error)") }
    }

    /// nil: not something this version knows, to be ignored.
    public static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(type, from: data)
    }
}

// MARK: - Phone to Mac

public enum ClientMessage: Codable, Equatable, Sendable {
    case hello(version: Int, device: String)
    /// Answered by a `.reply` with the same `id`. `command` is nil if this version doesn't know it.
    case command(CommandRequest)
    /// Sends what the log has from `offset`, and what gets appended, as `.log`.
    case subscribe(log: AgentLog, from: UInt64)
    case unsubscribe(log: AgentLog)
}

public struct CommandRequest: Codable, Equatable, Sendable {
    public var id: Int
    public var command: RemoteCommand?

    public init(id: Int, command: RemoteCommand?) {
        self.id = id
        self.command = command
    }

    private enum CodingKeys: String, CodingKey { case id, command }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(Int.self, forKey: .id)
        command = try? values.decode(RemoteCommand.self, forKey: .command)
    }
}

/// `AppModel`'s public methods, one to one. Project settings and adding projects aren't here: those stay on the Mac.
public enum RemoteCommand: Codable, Equatable, Sendable {
    /// `baseBranch` nil means the project's. A Mac from before it starts from the project's.
    case createTask(projectID: UUID, prompt: String, attachments: [String], agent: AgentKind?, baseBranch: String? = nil)
    case sendPrompt(taskID: Int, text: String, attachments: [String])
    case answerApproval(taskID: Int, allow: Bool)
    case stop(taskID: Int)
    case resume(taskID: Int)
    case rename(taskID: Int, title: String)
    case merge(taskID: Int)
    case delete(taskID: Int)
    /// A Mac from before the phone's context menu doesn't know these three.
    case archive(taskID: Int)
    /// Comma-separated, as `AppModel.addTags`.
    case addTags(taskID: Int, tags: String)
    case removeTag(taskID: Int, tag: String)
    case resolveConflict(taskID: Int)
    case conflictedFiles(taskID: Int)
    case pushBranch(taskID: Int)
    case pullRequestURL(taskID: Int)
    case loadChanges(taskID: Int)
    case loadDiff(taskID: Int)
    case restartServer(taskID: Int)
    case serverLog(taskID: Int)
    case build(taskID: Int, target: UUID)
    case buildLog(taskID: Int, target: UUID)
    case sendChat(projectID: UUID, text: String, attachments: [String])
    case answerChatApproval(projectID: UUID, allow: Bool)
    case stopChat(projectID: UUID)
    case newChat(projectID: UUID)
    /// The base server's address on the Mac, started and shared with the phone first. Its port is what the phone wants.
    case baseServerURL(projectID: UUID)
    /// The branches a task in the project could merge into.
    case branches(projectID: UUID)
    case changeBase(taskID: Int, to: String)
    /// The project's icon as a PNG, as the Mac's sidebar shows it. `.data(nil)` if it has none.
    case projectIcon(projectID: UUID)
    /// Answered with `.taskID` of the run's task. A Mac from before schedules doesn't know these.
    case runScheduleNow(scheduleID: UUID)
    case setSchedulePaused(scheduleID: UUID, paused: Bool)
    /// Saves the open draft (`RemoteSnapshot.scheduleDraft`), if it's still this one, as the Mac's form would.
    case saveScheduleDraft(scheduleID: UUID)
    case discardScheduleDraft(scheduleID: UUID)
}

public enum RemoteResult: Codable, Equatable, Sendable {
    case done
    case taskID(Int?)
    case text(String)
    case files([String])
    case url(URL?)
    case changes(DiffSummary)
    case diff([FileDiff])
    case data(Data?)
}

public struct AttachmentUploaded: Codable, Equatable, Sendable {
    /// On the Mac: what goes in a prompt's `attachments`.
    public var path: String

    public init(path: String) { self.path = path }
}

// MARK: - Mac to phone

public enum ServerMessage: Codable, Equatable, Sendable {
    case hello(version: Int)
    case snapshot(RemoteSnapshot)
    // Whole entities that changed. See `RemoteSnapshot.changes(since:)`.
    case projects([Project])
    case task(TaskItem)
    case taskRemoved(Int)
    case chat(ProjectChat)
    case chatRemoved(UUID)
    case pullRequest(taskID: Int, PullRequest?)
    case build(BuildKey, BuildState?)
    case usage(AgentKind, AgentUsage?)
    case chatApproval(projectID: UUID, String?)
    case replyingChats(Set<UUID>)
    case offline(Bool)
    /// All of them, whenever any changes. An older phone doesn't know this message and skips it.
    case schedules([Schedule])
    case scheduleDraft(Schedule?)
    /// One reply per `.command`: a result, or why there is none.
    case reply(id: Int, result: RemoteResult?, error: String?)
    /// Bytes of a subscribed log, from `offset`.
    case log(AgentLog, offset: UInt64, data: Data)
}

/// What the Mac knows that the phone shows. A task's pending approval is its `approvalRequest`.
public struct RemoteSnapshot: Codable, Equatable, Sendable {
    public var projects: [Project] = []
    public var tasks: [TaskItem] = []
    public var chats: [ProjectChat] = []
    public var pullRequests: [Int: PullRequest] = [:]
    public var builds: [BuildKey: BuildState] = [:]
    public var usage: [AgentKind: AgentUsage] = [:]
    /// What each project's chat agent is waiting to be allowed to do.
    public var chatApprovals: [UUID: String] = [:]
    public var replyingChats: Set<UUID> = []
    /// The Mac can't reach the internet while an agent runs. Nil: an older Mac, which doesn't say.
    public var isOffline: Bool?
    /// With their runs. Nil: an older Mac, from before schedules.
    public var schedules: [Schedule]?
    /// The schedule form open on the Mac, filled in (by the chat, `/schedule`…), not saved yet. Nil: none, or an older Mac.
    public var scheduleDraft: Schedule?

    public init() {}

    /// What turns `old` into this.
    public func changes(since old: RemoteSnapshot) -> [ServerMessage] {
        var messages: [ServerMessage] = []
        if projects != old.projects { messages.append(.projects(projects)) }
        let oldTasks = Dictionary(old.tasks.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        messages += tasks.filter { oldTasks[$0.id] != $0 }.map(ServerMessage.task)
        messages += Set(oldTasks.keys).subtracting(tasks.map(\.id)).map(ServerMessage.taskRemoved)
        let oldChats = Dictionary(old.chats.map { ($0.id, $0) }, uniquingKeysWith: { $1 })
        messages += chats.filter { oldChats[$0.id] != $0 }.map(ServerMessage.chat)
        messages += Set(oldChats.keys).subtracting(chats.map(\.id)).map(ServerMessage.chatRemoved)
        for id in Set(pullRequests.keys).union(old.pullRequests.keys) where pullRequests[id] != old.pullRequests[id] {
            messages.append(.pullRequest(taskID: id, pullRequests[id]))
        }
        for key in Set(builds.keys).union(old.builds.keys) where builds[key] != old.builds[key] {
            messages.append(.build(key, builds[key]))
        }
        for kind in Set(usage.keys).union(old.usage.keys) where usage[kind] != old.usage[kind] {
            messages.append(.usage(kind, usage[kind]))
        }
        for id in Set(chatApprovals.keys).union(old.chatApprovals.keys) where chatApprovals[id] != old.chatApprovals[id] {
            messages.append(.chatApproval(projectID: id, chatApprovals[id]))
        }
        if replyingChats != old.replyingChats { messages.append(.replyingChats(replyingChats)) }
        if isOffline != old.isOffline { messages.append(.offline(isOffline ?? false)) }
        if schedules != old.schedules { messages.append(.schedules(schedules ?? [])) }
        if scheduleDraft != old.scheduleDraft { messages.append(.scheduleDraft(scheduleDraft)) }
        return messages
    }

    /// Applies a message from `changes(since:)`. Any other message changes nothing.
    public mutating func apply(_ message: ServerMessage) {
        switch message {
        case .snapshot(let snapshot): self = snapshot
        case .projects(let projects): self.projects = projects
        case .task(let task):
            if let index = tasks.firstIndex(where: { $0.id == task.id }) { tasks[index] = task } else { tasks.append(task) }
        case .taskRemoved(let id): tasks.removeAll { $0.id == id }
        case .chat(let chat):
            if let index = chats.firstIndex(where: { $0.id == chat.id }) { chats[index] = chat } else { chats.append(chat) }
        case .chatRemoved(let id): chats.removeAll { $0.id == id }
        case .pullRequest(let id, let pullRequest): pullRequests[id] = pullRequest
        case .build(let key, let build): builds[key] = build
        case .usage(let kind, let usage): self.usage[kind] = usage
        case .chatApproval(let id, let request): chatApprovals[id] = request
        case .replyingChats(let ids): replyingChats = ids
        case .offline(let offline): isOffline = offline
        case .schedules(let schedules): self.schedules = schedules
        case .scheduleDraft(let draft): scheduleDraft = draft
        case .hello, .reply, .log: break
        }
    }
}

// MARK: - Pairing

/// Where a phone reaches a Mac and what it proves itself with.
public struct Pairing: Codable, Equatable, Sendable {
    public var server: URL
    public var token: String

    public init(server: URL, token: String) {
        self.server = server
        self.token = token
    }

    public init(host: String, port: Int, token: String) {
        self.init(server: URL(string: "https://\(host):\(port)")!, token: token)
    }

    /// What the Mac's QR code holds: `shift-remote://pair?host=…&port=…&token=…`. The Camera app opens it in the phone's app.
    public var link: URL {
        var components = URLComponents()
        components.scheme = "shift-remote"
        components.host = "pair"
        components.queryItems = [.init(name: "host", value: server.host ?? ""), .init(name: "port", value: String(server.port ?? 443)),
                                 .init(name: "token", value: token)]
        return components.url!
    }

    public init?(link: URL) {
        let items = URLComponents(url: link, resolvingAgainstBaseURL: false)?.queryItems ?? []
        func value(_ name: String) -> String? { items.first { $0.name == name }?.value }
        guard link.scheme == "shift-remote", link.host == "pair", let host = value("host"), !host.isEmpty,
              let port = value("port").flatMap(Int.init), let token = value("token"), !token.isEmpty,
              URL(string: "https://\(host):\(port)") != nil else { return nil }
        self.init(host: host, port: port, token: token)
    }

    /// Debug builds: SHIFT_SERVER, `http://127.0.0.1:port?token=…`. scripts/build.sh sets it.
    public init?(shiftServer value: String) {
        guard var components = URLComponents(string: value), components.host != nil,
              let token = components.queryItems?.first(where: { $0.name == "token" })?.value else { return nil }
        components.query = nil
        guard let server = components.url else { return nil }
        self.init(server: server, token: token)
    }

    /// The same URL scheme, host and auth, for another path.
    public func url(path: String, query: [URLQueryItem] = []) -> URL {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)!
        components.path = path
        if !query.isEmpty { components.queryItems = query }
        return components.url!
    }

    /// The task's dev server: where the Mac shares it for this kind of connection.
    public func preview(port: Int) -> URL? {
        var components = URLComponents(url: server, resolvingAgainstBaseURL: false)
        components?.port = port
        components?.path = ""
        return components?.url
    }
}
