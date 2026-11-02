import Foundation

public enum AgentKind: String, Codable, CodingKeyRepresentable, CaseIterable, Sendable, Identifiable {
    case claudeCode, codex

    public var id: String { rawValue }
    public var displayName: String { self == .claudeCode ? "Claude Code" : "Codex" }
    public var executableName: String { self == .claudeCode ? "claude" : "codex" }
}

/// A model an agent can run, e.g. `opus` / "Opus".
public struct AgentModel: Hashable, Identifiable, Sendable {
    /// What the agent's CLI takes as its model.
    public var id: String
    public var name: String

    public init(id: String, name: String) {
        self.id = id
        self.name = name
    }
}

/// How much of the user's agent subscription is used, per limit window (5 hours, a week…).
public struct AgentUsage: Codable, Equatable, Sendable {
    public struct Window: Codable, Equatable, Sendable {
        /// "5-hour", "Weekly".
        public var name: String
        public var usedPercent: Double
        public var resetsAt: Date?

        public init(name: String, usedPercent: Double, resetsAt: Date?) {
            self.name = name
            self.usedPercent = usedPercent
            self.resetsAt = resetsAt
        }

        /// 0...100. A window past its reset time has started over.
        public func percentLeft(at date: Date = .now) -> Double {
            if let resetsAt, resetsAt <= date { return 100 }
            return min(100, max(0, 100 - usedPercent))
        }
    }

    public var windows: [Window]

    public init(windows: [Window]) { self.windows = windows }

    /// The window closest to its limit: the one that will pause the agent first.
    public var tightest: Window? { windows.min { $0.percentLeft() < $1.percentLeft() } }

    /// When the agent can run again after using up a window: the latest reset of the used-up ones.
    /// nil if none is used up. May be in the past when this reading is from before the reset.
    public var limitResetsAt: Date? { windows.filter { $0.usedPercent >= 100 }.compactMap(\.resetsAt).max() }
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

/// What a project is: picks the commands suggested for it and how its tasks are tested.
public enum ProjectType: String, Codable, CaseIterable, Identifiable, Sendable {
    case staticWebsite, dynamicWebsite, nativeApp, electronApp, other

    public var id: Self { self }
    public var displayName: String {
        switch self {
        case .staticWebsite: "Static website"
        case .dynamicWebsite: "Dynamic website"
        case .nativeApp: "Native app"
        case .electronApp: "Electron app"
        case .other: "Other"
        }
    }
}

/// One thing a project can build or run from a task's worktree, e.g. its Mac app or its iOS app.
public struct BuildTarget: Codable, Identifiable, Hashable, Sendable {
    /// Stored by name, so another case (say a physical iOS device) can join later.
    public enum Kind: String, Codable, CaseIterable, Identifiable, Sendable {
        /// Builds, then opens the .app it printed last, if it printed one.
        case macApp
        /// Builds, then runs the .app it printed last on a simulator.
        case iOSSimulator
        /// Keeps running while the app is open, so it is started and stopped, not awaited.
        case run
        /// Runs the command and shows its log.
        case script

        public var id: Self { self }
        public var displayName: String {
            switch self {
            case .macApp: "Mac app"
            case .iOSSimulator: "iOS Simulator"
            case .run: "Run"
            case .script: "Script"
            }
        }
    }

    public var id: UUID
    public var name: String
    /// Shell command run in the task's worktree, with `SHIFT_REPO`, `SHIFT_WORKTREE`, `SHIFT_TASK` and
    /// `SHIFT_TARGET` in the environment.
    public var command: String
    public var kind: Kind
    /// Path prefixes such as `App/`. The target whose paths match most of a task's changes is suggested for it.
    public var paths: [String]

    public init(id: UUID = UUID(), name: String, command: String, kind: Kind = .macApp, paths: [String] = []) {
        self.id = id
        self.name = name
        self.command = command
        self.kind = kind
        self.paths = paths
    }

    /// Only the name and command are required, so the project chat's agent can write a target by hand.
    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try values.decode(String.self, forKey: .name)
        command = try values.decode(String.self, forKey: .command)
        kind = try values.decodeIfPresent(Kind.self, forKey: .kind) ?? .macApp
        paths = try values.decodeIfPresent([String].self, forKey: .paths) ?? []
    }

    /// A native app with no command of its own: what to build is guessed from the task's files when it builds.
    package static let detected = BuildTarget(id: UUID(uuidString: "5B1F7A52-0000-4000-8000-000000000000")!, name: "App", command: "")

    package var hasCommand: Bool { !command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    /// Whether `path`, relative to the repo, is covered by `paths`.
    package func matches(path: String) -> Bool {
        paths.contains { raw in
            // With or without its slash: project.yml's sources can be single files too.
            var prefix = raw.trimmingCharacters(in: .whitespaces)
            if prefix.hasSuffix("/") { prefix.removeLast() }
            guard !prefix.isEmpty else { return false }
            return path == prefix || path.hasPrefix(prefix + "/")
        }
    }

    /// The target whose paths match the most of `changed` (the first of them on a tie), else the last one
    /// built, else the first.
    package static func suggested(among targets: [BuildTarget], changed: [String], lastBuilt: BuildTarget.ID?) -> BuildTarget? {
        var best: (target: BuildTarget, matches: Int)?
        for target in targets {
            let matches = changed.filter(target.matches(path:)).count
            if matches > (best?.matches ?? 0) { best = (target, matches) }
        }
        return best?.target ?? targets.first { $0.id == lastBuilt } ?? targets.first
    }
}

public struct Project: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var repoPath: String
    public var baseBranch: String
    public var type: ProjectType
    public var defaultAgent: AgentKind
    /// Shell command that starts the dev server, e.g. `pnpm dev`. Empty = no server.
    /// Run with `PORT=<port>` in the environment; `$PORT` in the command is expanded by the shell.
    public var serverCommand: String
    /// Shell command run once in each new task's worktree before the server and agent start,
    /// e.g. `pnpm install && cp "$SHIFT_REPO/.env" .`. Empty = nothing to prepare.
    /// Run with `SHIFT_REPO`, `SHIFT_WORKTREE` and `PORT` in the environment.
    public var setupCommand: String
    /// What builds or runs the app, for app projects (they have no dev server). Empty = a web project,
    /// except a native app, whose command is then guessed from the task's files when it builds.
    /// Read `targets` for what can actually be built.
    public var buildTargets: [BuildTarget]
    public var permissions: AgentPermissions
    /// The model each agent runs, by `AgentModel.id`. No entry: the agent's own default.
    public var models: [AgentKind: String]
    /// Push each task's branch to the remote when the task completes.
    public var pushTaskBranches: Bool
    /// Keep screenshots of what each prompt changes. Not for apps: they have no page to load.
    public var takesScreenshots: Bool
    /// A finished task's main button opens a pull request, and merging moves to its dropdown.
    public var opensPullRequests: Bool

    public init(id: UUID = UUID(), name: String, repoPath: String, baseBranch: String, type: ProjectType = .other,
                defaultAgent: AgentKind = .claudeCode, serverCommand: String = "", setupCommand: String = "",
                buildTargets: [BuildTarget] = [], permissions: AgentPermissions = .bypass, models: [AgentKind: String] = [:],
                pushTaskBranches: Bool = false, opensPullRequests: Bool = false, takesScreenshots: Bool = false) {
        self.id = id
        self.name = name
        self.repoPath = repoPath
        self.baseBranch = baseBranch
        self.type = type
        self.defaultAgent = defaultAgent
        self.serverCommand = serverCommand
        self.setupCommand = setupCommand
        self.buildTargets = buildTargets
        self.permissions = permissions
        self.models = models
        self.pushTaskBranches = pushTaskBranches
        self.takesScreenshots = takesScreenshots
        self.opensPullRequests = opensPullRequests
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
        // State saved before there were targets has a single command.
        let legacyCommand = try decoder.container(keyedBy: LegacyKeys.self)
            .decodeIfPresent(String.self, forKey: .buildCommand) ?? ""
        permissions = try values.decodeIfPresent(AgentPermissions.self, forKey: .permissions) ?? .bypass
        models = try values.decodeIfPresent([AgentKind: String].self, forKey: .models) ?? [:]
        pushTaskBranches = try values.decodeIfPresent(Bool.self, forKey: .pushTaskBranches) ?? false
        takesScreenshots = try values.decodeIfPresent(Bool.self, forKey: .takesScreenshots) ?? false
        opensPullRequests = try values.decodeIfPresent(Bool.self, forKey: .opensPullRequests) ?? false
        type = try values.decodeIfPresent(ProjectType.self, forKey: .type)
            ?? (!legacyCommand.isEmpty ? .nativeApp : !serverCommand.isEmpty ? .dynamicWebsite
                : setupCommand.isEmpty ? .staticWebsite : .other)
        let migrated = BuildTarget(name: "App", command: legacyCommand, kind: type == .electronApp ? .run : .macApp)
        buildTargets = try values.decodeIfPresent([BuildTarget].self, forKey: .buildTargets)
            ?? (migrated.hasCommand ? [migrated] : [])
    }

    private enum LegacyKeys: String, CodingKey { case buildCommand }

    public var repoURL: URL { URL(fileURLWithPath: repoPath) }
    /// An app is tested by building it, not on a dev server: its tasks get no server and no port.
    public var isApp: Bool { type == .nativeApp || buildTargets.contains(where: \.hasCommand) }
    /// Whether one of its targets keeps running while the app is open, or would once an Electron app has its command.
    public var runsApp: Bool { type == .electronApp || targets.contains { $0.kind == .run } }
    /// What a task can build or run. A native app without a command still has something to build:
    /// whatever its worktree turns out to contain.
    public var targets: [BuildTarget] {
        let targets = buildTargets.filter(\.hasCommand)
        return targets.isEmpty && type == .nativeApp ? [.detected] : targets
    }

    /// The kind a target gets when all the user gave is a command.
    public var defaultTargetKind: BuildTarget.Kind { type == .electronApp ? .run : .macApp }

    /// The command of the first target: what editing a project with a single command reads and writes.
    /// Writing to a project with no target creates one; emptying the only one removes it.
    public var buildCommand: String {
        get { buildTargets.first?.command ?? "" }
        set {
            let isBlank = newValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            if buildTargets.isEmpty {
                if !isBlank { buildTargets = [BuildTarget(name: "App", command: newValue, kind: defaultTargetKind)] }
            } else if isBlank && buildTargets.count == 1 {
                buildTargets = []
            } else {
                buildTargets[0].command = newValue
            }
        }
    }
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

/// A picture of the task's server, taken before its first change or after a prompt changed something.
public struct TaskScreenshot: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var path: String
    public var isBefore: Bool
    /// The page it shows, e.g. `/pricing`.
    public var page: String
    public var date: Date

    public init(id: UUID = UUID(), path: String, isBefore: Bool, page: String, date: Date = Date()) {
        self.id = id
        self.path = path
        self.isBefore = isBefore
        self.page = page
        self.date = date
    }

    public var url: URL { URL(fileURLWithPath: path) }
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
    /// The branch the task started from and merges into. Set when the task is created; only
    /// `AppModel.changeBase` changes it. nil in state saved before tasks had their own base.
    public var baseBranch: String?
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
    /// The project chat that started or follows this task, and hears how it goes. Not one that replaced it.
    public var chatID: ProjectChat.ID?
    /// Oldest first. Optional so state saved by earlier builds still decodes.
    public var screenshots: [TaskScreenshot]?
    /// The target last built or run. Optional so state saved by earlier builds still decodes.
    public var lastBuiltTargetID: BuildTarget.ID?

    public init(id: Int, projectID: Project.ID, title: String, status: TaskStatus = .working,
                agent: AgentKind, branch: String, baseBranch: String? = nil, worktreePath: String, sessionID: String? = nil,
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
        self.baseBranch = baseBranch
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
    package static let legacyInterruptedReason = "Interrupted when Shift quit. Send a prompt to continue."
    public static let stoppedReason = "Stopped"

    /// Blocked because it was stopped or interrupted, so `AppModel.resume(taskID:)` can carry on.
    public var canResume: Bool {
        status == .blocked && [Self.interruptedReason, Self.legacyInterruptedReason, Self.stoppedReason].contains(blockedReason)
            || isUsageLimited
    }

    /// Blocked because the agent's subscription limit was reached ("You've hit your usage limit…").
    // ponytail: matched on the agent's wording; an agent-written reason with these words also counts.
    public var isUsageLimited: Bool {
        status == .blocked && blockedReason?.range(of: "usage limit|hit your limit|limit reached",
                                                   options: [.regularExpression, .caseInsensitive]) != nil
    }

    /// What a task is called until the agent or the user names it.
    package static func localTitle(id: Int, prompt: String, attachments: [String]) -> String {
        let title = Self.title(for: prompt.isEmpty ? attachments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" : prompt)
        return title.isEmpty ? "Task \(id)" : title
    }

    /// Nobody has named it yet, so the agent still may.
    package var hasLocalTitle: Bool {
        guard let first = prompts.first else { return false }
        return title == Self.localTitle(id: id, prompt: first.text, attachments: first.attachments)
    }

    /// The title until the agent or the user gives one (see `hasLocalTitle`), and the fallback if neither does.
    package static func title(for prompt: String) -> String {
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        var sentence = ""
        for (index, character) in zip(text.indices, text) {
            if character.isNewline { break }
            if ".!?".contains(character) {
                let next = text.index(after: index)
                if next == text.endIndex || text[next].isWhitespace { break }
            }
            sentence.append(character)
        }
        if sentence.count > 50 {
            let cut = sentence.prefix(50)
            sentence = String(cut.lastIndex(of: " ").map { cut[..<$0] } ?? cut)
        }
        return sentence.trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    /// The branch this task merges into: its own, else (state from before tasks had one) the project's.
    public func base(in project: Project) -> String { baseBranch ?? project.baseBranch }
    public var worktreeURL: URL { URL(fileURLWithPath: worktreePath) }
    public var serverURL: URL? { port.flatMap { URL(string: "http://localhost:\($0)") } }
}

/// A project's one conversation with its agent, for questions, plans and whatever the user asks it to do.
/// Not a task: no worktree, branch, server, merge or status. It runs in the project's own folder, with the
/// project's permissions.
public struct ProjectChat: Codable, Identifiable, Hashable, Sendable {
    /// Names its log. New Chat makes a new one.
    public var id: UUID
    public var projectID: Project.ID
    /// The agent `sessionID` belongs to.
    public var agent: AgentKind?
    public var sessionID: String?
    public var prompts: [Prompt]

    public init(id: UUID = UUID(), projectID: Project.ID, agent: AgentKind? = nil, sessionID: String? = nil, prompts: [Prompt] = []) {
        self.id = id
        self.projectID = projectID
        self.agent = agent
        self.sessionID = sessionID
        self.prompts = prompts
    }
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
