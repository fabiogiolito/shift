import Foundation

public enum AgentKind: String, Codable, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex

    public var id: String { rawValue }
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    public var executableName: String { self == .claudeCode ? "claude" : "codex" }
}

public struct AgentInstallation: Codable, Hashable, Sendable {
    public var path: String
    public var version: String?

    public init(path: String, version: String? = nil) {
        self.path = path
        self.version = version
    }
}

/// The whole status vocabulary. Do not add cases without a product decision.
public enum TaskStatus: String, Codable, Sendable {
    case working, needsInput, blocked, completed, conflict, merged

    /// Statuses where the user is the one who has to act.
    public var needsAttention: Bool { self == .needsInput || self == .blocked || self == .conflict }
}

/// What a project's agents may do. Every task inherits it from its project.
/// Mirrors the agents' own permission modes. Set per project, inherited by every task.
public enum AgentPermissions: String, Codable, CaseIterable, Identifiable, Sendable {
    /// Never asks: any command, network, package installs.
    case bypass
    /// The agent's own automatic review approves routine actions and blocks risky ones.
    case auto
    /// The agent asks before commands and edits; the task waits for the user to allow or deny.
    case manual

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .bypass: "Bypass permissions"
        case .auto: "Auto"
        case .manual: "Manual"
        }
    }

    public var symbol: String {
        switch self {
        case .bypass: "exclamationmark.shield"
        case .auto: "checkmark.shield"
        case .manual: "hand.raised"
        }
    }

    public var summary: String {
        switch self {
        case .bypass: "The agent runs any command, uses the network and installs packages without asking."
        case .auto: "The agent's automatic review approves routine actions and blocks risky ones."
        case .manual: "The agent asks before running commands or changing files. The task waits for your answer."
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        switch raw {
        case "fullAccess": self = .bypass // saved by earlier builds
        case "sandboxed": self = .auto
        default: self = AgentPermissions(rawValue: raw) ?? .bypass
        }
    }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var repoPath: String
    public var baseBranch: String
    public var defaultAgent: AgentKind
    /// Shell command that starts the dev server, e.g. `pnpm dev`. Empty = no server.
    /// Run with `PORT=<port>` in the environment; `$PORT` in the command is expanded by the shell.
    public var serverCommand: String
    /// Shell command run once in each new task's worktree before the server and agent start,
    /// e.g. `pnpm install && cp "$SHIFT_REPO/.env" .`. Empty = nothing to prepare.
    /// Run with `SHIFT_REPO`, `SHIFT_WORKTREE` and `PORT` in the environment.
    public var setupCommand: String
    /// Shell command that builds the app, for app projects (they have no dev server). Empty = a web project.
    /// If the last line of its output is the path of a `.app`, Shift opens it. Run with `SHIFT_REPO`,
    /// `SHIFT_WORKTREE` and `SHIFT_TASK` in the environment.
    public var buildCommand: String
    public var permissions: AgentPermissions

    public init(id: UUID = UUID(), name: String, repoPath: String, baseBranch: String,
                defaultAgent: AgentKind = .claudeCode, serverCommand: String = "", setupCommand: String = "",
                buildCommand: String = "", permissions: AgentPermissions = .bypass) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.baseBranch = baseBranch
        self.defaultAgent = defaultAgent
        self.serverCommand = serverCommand
        self.setupCommand = setupCommand
        self.buildCommand = buildCommand
        self.permissions = permissions
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        name = try values.decode(String.self, forKey: .name)
        repoPath = try values.decode(String.self, forKey: .repoPath)
        baseBranch = try values.decode(String.self, forKey: .baseBranch)
        defaultAgent = try values.decode(AgentKind.self, forKey: .defaultAgent)
        serverCommand = try values.decode(String.self, forKey: .serverCommand)
        // Absent in state saved before these existed.
        setupCommand = try values.decodeIfPresent(String.self, forKey: .setupCommand) ?? ""
        buildCommand = try values.decodeIfPresent(String.self, forKey: .buildCommand) ?? ""
        permissions = try values.decodeIfPresent(AgentPermissions.self, forKey: .permissions) ?? .bypass
    }

    public var repoURL: URL { URL(fileURLWithPath: repoPath) }
    /// An app is tested by building it, not on a dev server: its tasks get no server and no port.
    public var isApp: Bool { !buildCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

public struct Prompt: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var text: String
    public var date: Date
    /// Sent while the agent was working and not yet handed to it. Stop drops pending prompts.
    public var isPending: Bool
    /// Paths of files and images dropped on the prompt field. The agent gets them as a list of paths
    /// after the text, and reads them itself.
    public var attachments: [String]

    public init(id: UUID = UUID(), text: String, date: Date = Date(), isPending: Bool = false,
                attachments: [String] = []) {
        self.id = id
        self.text = text
        self.date = date
        self.isPending = isPending
        self.attachments = attachments
    }

    /// What the agent is sent: the text, then the attached paths.
    public var agentText: String {
        guard !attachments.isEmpty else { return text }
        let list = "Attached files:\n" + attachments.map { "- \($0)" }.joined(separator: "\n")
        return text.isEmpty ? list : text + "\n\n" + list
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        text = try values.decode(String.self, forKey: .text)
        date = try values.decode(Date.self, forKey: .date)
        isPending = try values.decodeIfPresent(Bool.self, forKey: .isPending) ?? false
        attachments = try values.decodeIfPresent([String].self, forKey: .attachments) ?? []
    }
}

/// A piece of delegated work. Outlives any single agent invocation.
/// Named TaskItem to avoid clashing with Swift's `Task`.
public struct TaskItem: Codable, Identifiable, Hashable, Sendable {
    /// Display number, e.g. 3001. Unique across all projects.
    public var id: Int
    public var projectID: Project.ID
    public var title: String
    public var status: TaskStatus
    public var agent: AgentKind
    public var branch: String
    public var worktreePath: String
    /// Agent's own session identifier, used to resume the same conversation.
    public var sessionID: String?
    /// Usually equal to `id`, but may differ if that port was taken.
    public var port: Int?
    public var serverPID: Int32?
    public var prompts: [Prompt]
    /// What the agent is trying to accomplish, in its own words. Not the prompt.
    public var description: String?
    /// Handoff note shown when completed.
    public var summary: String?
    /// Shown when status is needsInput.
    public var question: String?
    /// Manual permissions: what the agent is asking to do, e.g. "Run `pnpm install`". Status is needsInput.
    public var approvalRequest: String?
    /// Short suggested replies the agent offered with a question or a block, shown as buttons.
    /// Optional so state saved by earlier builds still decodes.
    public var options: [String]?
    /// Shown when status is blocked.
    public var blockedReason: String?
    /// One short line describing what the agent is doing right now.
    public var activity: String?
    /// True while the agent is resolving a merge conflict (status is working).
    public var isResolvingConflict: Bool
    public var createdAt: Date
    public var workingSince: Date?
    public var mergedAt: Date?

    public init(id: Int, projectID: Project.ID, title: String, status: TaskStatus = .working,
                agent: AgentKind, branch: String, worktreePath: String, sessionID: String? = nil,
                port: Int? = nil, serverPID: Int32? = nil, prompts: [Prompt] = [],
                description: String? = nil,
                summary: String? = nil, question: String? = nil, blockedReason: String? = nil,
                activity: String? = nil, isResolvingConflict: Bool = false,
                createdAt: Date = Date(), workingSince: Date? = nil, mergedAt: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.status = status
        self.agent = agent
        self.branch = branch
        self.worktreePath = worktreePath
        self.sessionID = sessionID
        self.port = port
        self.serverPID = serverPID
        self.prompts = prompts
        self.description = description
        self.summary = summary
        self.question = question
        self.blockedReason = blockedReason
        self.activity = activity
        self.isResolvingConflict = isResolvingConflict
        self.createdAt = createdAt
        self.workingSince = workingSince
        self.mergedAt = mergedAt
    }

    public static let interruptedReason = "Interrupted when Shift quit."
    /// Saved by earlier builds; still resumable.
    static let legacyInterruptedReason = "Interrupted when Shift quit. Send a prompt to continue."
    public static let stoppedReason = "Stopped"

    /// Blocked because it was stopped or interrupted, so `AppModel.resume(taskID:)` can carry on.
    public var canResume: Bool {
        status == .blocked && [Self.interruptedReason, Self.legacyInterruptedReason, Self.stoppedReason].contains(blockedReason)
    }

    public var worktreeURL: URL { URL(fileURLWithPath: worktreePath) }
    public var serverURL: URL? { port.flatMap { URL(string: "http://localhost:\($0)") } }
}

// MARK: - Diff

public enum ChangeKind: String, Codable, Sendable { case added, modified, deleted, renamed }

public struct FileChange: Codable, Identifiable, Hashable, Sendable {
    public var path: String
    public var oldPath: String?
    public var kind: ChangeKind
    public var additions: Int
    public var deletions: Int
    public var isBinary: Bool

    public var id: String { path }

    public init(path: String, oldPath: String? = nil, kind: ChangeKind, additions: Int = 0,
                deletions: Int = 0, isBinary: Bool = false) {
        self.path = path
        self.oldPath = oldPath
        self.kind = kind
        self.additions = additions
        self.deletions = deletions
        self.isBinary = isBinary
    }
}

public struct DiffSummary: Codable, Hashable, Sendable {
    public var files: [FileChange]

    public init(files: [FileChange] = []) { self.files = files }

    public var additions: Int { files.reduce(0) { $0 + $1.additions } }
    public var deletions: Int { files.reduce(0) { $0 + $1.deletions } }
}

public struct DiffLine: Codable, Hashable, Sendable {
    public enum Kind: String, Codable, Sendable { case context, added, removed }

    public var kind: Kind
    public var text: String
    public var oldNumber: Int?
    public var newNumber: Int?

    public init(kind: Kind, text: String, oldNumber: Int? = nil, newNumber: Int? = nil) {
        self.kind = kind
        self.text = text
        self.oldNumber = oldNumber
        self.newNumber = newNumber
    }
}

public struct DiffHunk: Codable, Hashable, Sendable {
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) {
        self.header = header
        self.lines = lines
    }
}

public struct FileDiff: Codable, Identifiable, Hashable, Sendable {
    public var change: FileChange
    public var hunks: [DiffHunk]

    public var id: String { change.path }

    public init(change: FileChange, hunks: [DiffHunk]) {
        self.change = change
        self.hunks = hunks
    }
}
