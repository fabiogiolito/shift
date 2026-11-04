import Foundation

// Contracts between the orchestrator (AppModel) and the machinery.
// Implementations live in Git/, Agents/, Server/, System/, Store/.

// MARK: - Git

public protocol GitServicing: Sendable {
    func isRepository(_ url: URL) async -> Bool
    /// Makes the folder a repository and commits everything in it: tasks branch off a commit.
    func initRepository(_ url: URL) async throws
    func branches(repo: URL) async throws -> [String]
    func currentBranch(repo: URL) async throws -> String

    /// Creates `branch` at the tip of `source`, checking nothing out. Throws a plain message for an
    /// invalid or taken name.
    func createBranch(repo: URL, name: String, from source: String) async throws
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
    /// The contents of `path` at the merge base with `base`: the "before" side of the diff.
    func baseContents(worktree: URL, base: String, path: String) async throws -> Data

    /// True if `branch` would merge into `base` without conflicts. Must not touch any working tree.
    func canMergeCleanly(repo: URL, branch: String, base: String) async throws -> Bool
    /// Paths (relative to the repo root) that conflict when merging `branch` into `base`; empty if it
    /// merges cleanly. Must not touch any working tree.
    func conflictedFiles(repo: URL, branch: String, base: String) async throws -> [String]
    /// Integrates `branch` into `base`. Must leave the repo untouched when returning `.conflict`.
    func merge(repo: URL, branch: String, into base: String, message: String) async throws -> MergeResult
    /// True if `path` (relative to the repo root) is tracked by git.
    func isTracked(repo: URL, path: String) async -> Bool
    /// True if `branch` has commits of its own and every one of them is already contained in `base`.
    func isMerged(repo: URL, branch: String, base: String) async throws -> Bool
    /// True if everything on `branch` is contained in `base` (also when it has no commits of its own).
    func isContained(repo: URL, branch: String, in base: String) async throws -> Bool
    /// Moves the worktree's own commits (those not on `oldBase`) onto `newBase`. With `oldBase` gone,
    /// everything not on `newBase` moves. On a conflict the rebase is aborted, the worktree is left as it
    /// was and false is returned.
    func rebase(worktree: URL, from oldBase: String, onto newBase: String) async throws -> Bool
    /// Merges `base` into the worktree's branch, bringing its newer commits in. On a conflict the merge is
    /// aborted, the worktree is left as it was and false is returned.
    func mergeBase(worktree: URL, base: String) async throws -> Bool
    func branchExists(repo: URL, branch: String) async -> Bool

    /// Where `branch` gets pushed: its upstream remote, else `origin`, else the first remote. nil if none.
    func remote(repo: URL, branch: String) async -> String?
    /// The remote's fetch URL as configured, e.g. `git@github.com:owner/repo.git`. nil if unknown.
    func remoteURL(repo: URL, remote: String) async -> String?
    /// Commits on `branch` that are not on `<remote>/<branch>` as last fetched (no network). All of
    /// the branch's commits if the remote does not have it yet.
    func unpushedCount(repo: URL, branch: String, remote: String) async throws -> Int
    /// `git push <remote> <branch>`, never forced, publishing the branch (`-u`) if the remote lacks it.
    /// If the remote has commits the branch lacks, merges them in and pushes again; on a conflict the
    /// branch is left as it was and it throws.
    /// Never waits for a password and gives up after a timeout. Throws a plain-language message.
    func push(repo: URL, branch: String, remote: String) async throws

    /// The repo's pull requests by head branch, the newest for each, from the GitHub CLI. `github` is
    /// "owner/repo". Throws if `gh` is missing, signed out or offline. Never asks for anything.
    func pullRequests(repo: URL, github: String) async throws -> [String: PullRequest]
    /// Brings a pull request's head commit into the repo, also when its branch is gone from the remote.
    func fetchPullRequest(repo: URL, number: Int, remote: String) async throws
    /// Moves `branch` up to what the remote has, if that is a fast-forward; otherwise leaves it alone.
    /// Where it is checked out, keeps uncommitted changes or leaves it alone.
    func fastForward(repo: URL, branch: String, remote: String) async throws
}

// MARK: - Agents

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

/// Who takes this turn's screenshots.
public enum ScreenshotRequest: Sendable, Equatable {
    /// Shift does, of the page the agent names.
    case page
    /// An app has no page to load, so the agent does and names the image. `wantsBefore`: nothing has changed yet.
    case app(wantsBefore: Bool)
}

public struct AgentRequest: Sendable {
    public var prompt: String
    /// nil starts a new session; otherwise resumes that session.
    public var sessionID: String?
    public var worktree: URL
    public var environment: [String: String]
    /// The project's setting at the time of this run.
    public var permissions: AgentPermissions
    /// The project's model for this agent. nil: the agent's own default.
    public var model: String?
    /// The task has no agent-written title and description yet, so the agent must provide them.
    public var needsDescription: Bool
    /// The task's current description, which the agent extends as the task grows.
    public var description: String?
    /// Manual permissions: where the answers to `.approvalRequested` come from.
    public var approvals: ApprovalChannel
    /// The project chat: it gets the chat's instructions instead of the task ones, and its reply as it's written.
    public var chat: Bool
    /// The project chat: what it's told about the project's tasks right now, after its instructions.
    public var chatContext: String
    /// The agent must say what shows this turn's change (`.screenshots`).
    public var screenshots: ScreenshotRequest?

    public init(prompt: String, sessionID: String? = nil, worktree: URL, environment: [String: String] = [:],
                permissions: AgentPermissions = .bypass, model: String? = nil, needsDescription: Bool? = nil,
                description: String? = nil, approvals: ApprovalChannel = ApprovalChannel(), chat: Bool = false,
                chatContext: String = "", screenshots: ScreenshotRequest? = nil) {
        self.prompt = prompt
        self.sessionID = sessionID
        self.worktree = worktree
        self.environment = environment
        self.permissions = permissions
        self.model = model
        self.needsDescription = needsDescription ?? (sessionID == nil)
        self.description = description
        self.approvals = approvals
        self.chat = chat
        self.chatContext = chatContext
        self.screenshots = screenshots
    }
}

public protocol AgentAdapter: Sendable {
    var kind: AgentKind { get }
    /// nil if the agent's CLI isn't installed.
    func detect() async -> AgentInstallation?
    /// Runs one agent turn. The stream always ends with `.finished`.
    /// Cancelling the consuming Swift task must terminate the agent process.
    func run(_ request: AgentRequest) -> AsyncStream<AgentEvent>
    /// The user's current subscription limits. nil if unknown (not signed in, offline, API key).
    func usage() async -> AgentUsage?
    /// The models the user can pick from, besides the agent's own default.
    func models() async -> [AgentModel]
}

extension AgentAdapter {
    public func usage() async -> AgentUsage? { nil }
    public func models() async -> [AgentModel] { [] }
}

// MARK: - Dev server and setup

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
    /// Whether something accepts connections on the port on loopback.
    func isListening(_ port: Int) async -> Bool
    /// Whether a process outside the process group `group` (the server's own) has a connection open to the port:
    /// a browser tab's live-reload socket, for one.
    func hasClients(_ port: Int, besides group: Int32) async -> Bool
}

// MARK: - System

public protocol Notifying: Sendable {
    func requestAuthorization() async
    func notify(title: String, body: String, taskID: Int) async
    func setBadge(count: Int) async
}

public protocol Screenshotting: Sendable {
    /// Saves a PNG of the page at `url` to `file`, making its folder if needed, after running `script` in the
    /// loaded page. False if the page did not load or the script failed: the picture wouldn't show what was asked.
    func capture(url: URL, script: String?, to file: URL) async -> Bool
    /// Saves the image at `source`, which an agent named, as a PNG to `file`. False if it isn't an image file.
    func copyImage(at source: URL, to file: URL) async -> Bool
}

// MARK: - Persistence

/// Puts a built iOS app on a simulator.
public protocol SimulatorRunning: Sendable {
    /// Installs `app` on the booted simulator (else boots the newest available iPhone), launches it in place of
    /// the copy already running, and brings Simulator.app forward. `environment` holds the variables for
    /// `simctl`: its `SIMCTL_CHILD_` ones reach the app.
    func run(app: URL, environment: [String: String]) async throws
}

public protocol StateStoring: Sendable {
    func load() async -> AppState
    func save(_ state: AppState) async
    func appendLog(taskID: Int, text: String) async
    /// The end of the log, starting at a whole line.
    func readLog(taskID: Int) async -> String
    func deleteLog(taskID: Int) async
    func appendChatLog(chatID: UUID, text: String) async
    func deleteChatLog(chatID: UUID) async
    /// Up to `length` bytes of the log from `offset`. Empty past its end or if there is no log.
    func logBytes(_ log: AgentLog, from offset: UInt64, length: Int) async -> Data
}

public struct Services: Sendable {
    public var git: GitServicing
    public var agents: [AgentKind: AgentAdapter]
    public var servers: ServerManaging
    public var ports: PortAllocating
    public var notifier: Notifying
    public var store: StateStoring
    /// Shares task servers on the tailnet. Nil: not shared (tests, or nothing to share with).
    public var tailscale: Tailscale?
    /// Lets the project chat's agent run Shift through `shiftctl`. Nil: it can't (tests).
    public var control: ControlServer?
    /// Nil: no screenshots, whatever the project says.
    public var screenshots: Screenshotting?
    /// Lets a paired phone follow and steer tasks. Nil: it can't (tests).
    public var remote: RemoteListener?
    /// Nil: iOS builds can't be run.
    public var simulators: SimulatorRunning?

    public init(git: GitServicing, agents: [AgentKind: AgentAdapter], servers: ServerManaging,
                ports: PortAllocating, notifier: Notifying, store: StateStoring, tailscale: Tailscale? = nil,
                screenshots: Screenshotting? = nil, control: ControlServer? = nil, simulators: SimulatorRunning? = nil,
                remote: RemoteListener? = nil) {
        self.git = git
        self.agents = agents
        self.servers = servers
        self.ports = ports
        self.notifier = notifier
        self.store = store
        self.tailscale = tailscale
        self.control = control
        self.screenshots = screenshots
        self.remote = remote
        self.simulators = simulators
    }
}

public enum ShiftPaths {
    /// No spaces in this path on purpose: dev tooling breaks on "Application Support".
    /// Development builds ("Shift Dev") keep their own data in ~/.shift-dev so they can never touch the
    /// tasks of the Shift you use; SHIFT_HOME overrides both (e.g. a task's build of Shift, being tested).
    public static let root: URL = {
        if let home = ProcessInfo.processInfo.environment["SHIFT_HOME"], !home.isEmpty {
            return URL(fileURLWithPath: (home as NSString).expandingTildeInPath)
        }
        let dev = Bundle.main.bundleIdentifier?.hasSuffix(".dev") == true
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(dev ? ".shift-dev" : ".shift")
    }()
    public static let state = root.appendingPathComponent("state.json")
    public static let logs = root.appendingPathComponent("logs")
    public static let worktrees = root.appendingPathComponent("worktrees")
    /// The command the project chat's agent runs Shift with.
    public static let controlScript = root.appendingPathComponent("bin/shiftctl")
    public static let screenshots = root.appendingPathComponent("screenshots")
    /// SHIFT_HOME of a task's build when Shift opens it, so a build of Shift keeps its own data.
    // ponytail: never cleaned up; delete it with the task if builds of Shift pile up.
    public static func build(taskID: Int) -> URL { root.appendingPathComponent("builds/\(taskID)") }

    public static func worktree(project: Project, taskID: Int, root: URL = worktrees) -> URL {
        let slug = project.name.lowercased().map { $0.isLetter || $0.isNumber ? $0 : "-" }
        return root.appendingPathComponent(String(slug)).appendingPathComponent(String(taskID))
    }
}
