import Foundation

// Contracts between the orchestrator (AppModel) and the machinery.
// Implementations live in Git/, Agents/, Server/, System/, Store/.

// MARK: - Git

public enum MergeResult: Equatable, Sendable {
    case merged
    case conflict
}

public protocol GitServicing: Sendable {
    func isRepository(_ url: URL) async -> Bool
    func branches(repo: URL) async throws -> [String]
    func currentBranch(repo: URL) async throws -> String

    /// Creates `branch` from the current tip of `base` and checks it out in a new worktree at `path`.
    func createWorktree(repo: URL, branch: String, base: String, at path: URL) async throws
    /// Checks out the existing `branch` in a new worktree at `path`, after pruning worktrees whose
    /// folder is gone (such as the one that used to be at `path`).
    func addWorktree(repo: URL, branch: String, at path: URL) async throws
    /// Removes the worktree (forced) and, if given, deletes the branch. Must not throw if already gone.
    func removeWorktree(repo: URL, path: URL, deleteBranch: String?) async throws

    /// Stages and commits everything in the worktree. Returns false if there was nothing to commit.
    @discardableResult
    func commitAll(worktree: URL, message: String) async throws -> Bool
    /// Makes git ignore everything that is untracked in the worktree right now (what the project's
    /// setup command created), so it is never committed or shown as a change. Entries go into the
    /// repository's `info/exclude`, which the main checkout and all worktrees share.
    func excludeUntracked(worktree: URL) async throws

    /// Everything the task changed relative to the merge base with `base`, including uncommitted work.
    func changes(worktree: URL, base: String) async throws -> DiffSummary
    func diff(worktree: URL, base: String) async throws -> [FileDiff]

    /// True if `branch` would merge into `base` without conflicts. Must not touch any working tree.
    func canMergeCleanly(repo: URL, branch: String, base: String) async throws -> Bool
    /// Integrates `branch` into `base`. Must leave the repo untouched when returning `.conflict`.
    func merge(repo: URL, branch: String, into base: String, message: String) async throws -> MergeResult
    /// True if `path` (relative to the repo root) is tracked by git.
    func isTracked(repo: URL, path: String) async -> Bool
    /// True if `branch` has commits of its own and every one of them is already contained in `base`.
    func isMerged(repo: URL, branch: String, base: String) async throws -> Bool
    func branchExists(repo: URL, branch: String) async -> Bool

    /// Where `branch` gets pushed: its upstream remote, else `origin`, else the first remote. nil if none.
    func remote(repo: URL, branch: String) async -> String?
    /// Commits on `branch` that are not on `<remote>/<branch>` as last fetched (no network). All of
    /// the branch's commits if the remote does not have it yet.
    func unpushedCount(repo: URL, branch: String, remote: String) async throws -> Int
    /// `git push <remote> <branch>`, never forced, publishing the branch (`-u`) if the remote lacks it.
    /// Never waits for a password and gives up after a timeout. Throws a plain-language message.
    func push(repo: URL, branch: String, remote: String) async throws
}

// MARK: - Agents

public enum AgentOutcome: Equatable, Sendable {
    case completed(summary: String)
    /// `options`: up to 4 short suggested replies the agent offered, most likely first.
    case needsInput(question: String, options: [String] = [])
    case blocked(reason: String, options: [String] = [])
}

public enum AgentEvent: Equatable, Sendable {
    /// The agent's own session id, to persist and pass back in on the next run.
    case sessionStarted(id: String)
    /// One short human line, e.g. "Running tests…". Not a transcript.
    case activity(String)
    /// The agent's own words for what the task will accomplish. Either may be missing.
    case described(title: String?, description: String?)
    /// Raw output for the debugging view only.
    case rawOutput(String)
    /// Manual permissions: the agent waits to be allowed to do `summary`, one short human line such as
    /// "Run `pnpm install`". Answer through `AgentRequest.approvals`; the run goes on either way.
    case approvalRequested(id: String, summary: String)
    /// Always the last event of a run.
    case finished(AgentOutcome)
}

/// Carries the user's answers to `.approvalRequested`, and follow-up instructions, into the agent
/// while it runs. The orchestrator answers and sends; the adapter running the request handles them.
public final class ApprovalChannel: @unchecked Sendable {
    public typealias Handler = @Sendable (_ id: String, _ allow: Bool, _ message: String?) -> Bool
    public typealias MessageHandler = @Sendable (_ text: String) -> Bool

    private let lock = NSLock()
    private var handler: Handler?
    private var messageHandler: MessageHandler?

    public init() {}

    /// `message`: on a denial, what the user wants instead. Returns true if the agent received it;
    /// false if it could not take one (or the run is over), so the caller must deliver it another way.
    @discardableResult
    public func answer(id: String, allow: Bool, message: String? = nil) -> Bool {
        lock.withLock { handler }?(id, allow, message) ?? false
    }

    /// For adapters: `handler` receives every answer until it is replaced or set to nil.
    public func onAnswer(_ handler: Handler?) {
        lock.withLock { self.handler = handler }
    }

    /// Hands the user's follow-up instructions to the running agent session. Returns true once the
    /// agent has them (it will act on them in this run); false if it cannot take them right now.
    @discardableResult
    public func send(_ text: String) -> Bool {
        lock.withLock { messageHandler }?(text) ?? false
    }

    /// For adapters: `handler` receives every `send` until it is replaced or set to nil.
    public func onMessage(_ handler: MessageHandler?) {
        lock.withLock { messageHandler = handler }
    }
}

public struct AgentRequest: Sendable {
    public var prompt: String
    /// nil starts a new session; otherwise resumes that session.
    public var sessionID: String?
    public var worktree: URL
    public var environment: [String: String]
    /// The project's setting at the time of this run.
    public var permissions: AgentPermissions
    /// The task has no agent-written title and description yet, so the agent must provide them.
    public var needsDescription: Bool
    /// Manual permissions: where the answers to `.approvalRequested` come from.
    public var approvals: ApprovalChannel

    public init(prompt: String, sessionID: String? = nil, worktree: URL, environment: [String: String] = [:],
                permissions: AgentPermissions = .bypass, needsDescription: Bool? = nil,
                approvals: ApprovalChannel = ApprovalChannel()) {
        self.prompt = prompt
        self.sessionID = sessionID
        self.worktree = worktree
        self.environment = environment
        self.permissions = permissions
        self.needsDescription = needsDescription ?? (sessionID == nil)
        self.approvals = approvals
    }
}

public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// nil if the agent's CLI isn't installed.
    func detect() async -> AgentInstallation?
    /// Runs one agent turn. The stream always ends with `.finished`.
    /// Cancelling the consuming Swift task must terminate the agent process.
    func run(_ request: AgentRequest) -> AsyncStream<AgentEvent>
}

// MARK: - Dev server and setup

public struct CommandResult: Equatable, Sendable {
    /// 128 + signal number if the command was killed by a signal.
    public var exitCode: Int32
    /// stdout and stderr, interleaved.
    public var output: String

    public init(exitCode: Int32, output: String = "") {
        self.exitCode = exitCode
        self.output = output
    }
}

public protocol ServerManaging: Sendable {
    /// Runs `command` to completion through the user's login shell with cwd = `directory`, outside
    /// any sandbox. Throws only if it could not be started. Cancelling the calling Swift task must
    /// kill the command and its children.
    func run(command: String, directory: URL, environment: [String: String]) async throws -> CommandResult

    /// Starts `command` in `directory` with PORT set. Replaces any server already running for the task.
    /// Returns the pid of the process group leader.
    func start(taskID: Int, command: String, directory: URL, port: Int) async throws -> Int32
    /// Kills the server and its children. Must not throw if nothing is running.
    func stop(taskID: Int) async
    /// Kills a server left over from a previous app launch.
    func stopOrphan(pid: Int32) async
    func isRunning(taskID: Int) async -> Bool
    /// The last `lines` lines of the server's output, from this and earlier launches.
    func log(taskID: Int, lines: Int) async -> String
    func stopAll() async
}

public protocol PortAllocating: Sendable {
    /// Returns `preferred` if it is free and not in `reserved`, otherwise the next free port above it.
    func allocate(preferred: Int, reserved: Set<Int>) async -> Int
}

// MARK: - System

public protocol Notifying: Sendable {
    func requestAuthorization() async
    func notify(title: String, body: String, taskID: Int) async
    func setBadge(count: Int) async
}

// MARK: - Persistence

public struct AppState: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [TaskItem]
    public var nextTaskID: Int

    public init(projects: [Project] = [], tasks: [TaskItem] = [], nextTaskID: Int = 3001) {
        self.projects = projects
        self.tasks = tasks
        self.nextTaskID = nextTaskID
    }
}

public protocol StateStoring: Sendable {
    func load() async -> AppState
    func save(_ state: AppState) async
    func appendLog(taskID: Int, text: String) async
    func readLog(taskID: Int) async -> String
    func deleteLog(taskID: Int) async
}

public struct Services: Sendable {
    public var git: GitServicing
    public var agents: [AgentKind: AgentAdapter]
    public var servers: ServerManaging
    public var ports: PortAllocating
    public var notifier: Notifying
    public var store: StateStoring

    public init(git: GitServicing, agents: [AgentKind: AgentAdapter], servers: ServerManaging,
                ports: PortAllocating, notifier: Notifying, store: StateStoring) {
        self.git = git
        self.agents = agents
        self.servers = servers
        self.ports = ports
        self.notifier = notifier
        self.store = store
    }
}

public enum ShiftPaths {
    /// No spaces in this path on purpose: dev tooling breaks on "Application Support".
    public static let root = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".shift")
    public static let state = root.appendingPathComponent("state.json")
    public static let logs = root.appendingPathComponent("logs")
    public static let worktrees = root.appendingPathComponent("worktrees")

    public static func worktree(project: Project, taskID: Int, root: URL = worktrees) -> URL {
        let slug = project.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return root.appendingPathComponent(String(slug)).appendingPathComponent(String(taskID))
    }
}
