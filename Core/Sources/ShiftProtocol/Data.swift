import Foundation

// Plain data the orchestrator, its services and the remote protocol share.

public enum MergeResult: Equatable, Sendable {
    case merged
    case conflict
}

/// Whether a project's base branches have commits to push to its remote.
public struct PushState: Codable, Equatable, Sendable {
    public var remote: String
    /// Commits on the project's bases that the remote does not have, as of the last fetch.
    public var unpushed: Int
    /// The bases those commits are on.
    public var branches: [String]
    public var isPushing = false

    public init(remote: String, unpushed: Int, branches: [String] = [], isPushing: Bool = false) {
        self.remote = remote
        self.unpushed = unpushed
        self.branches = branches
        self.isPushing = isPushing
    }

    /// "Push 3 commits to origin/main", or "Nothing to push".
    public var title: String {
        unpushed == 0 ? "Nothing to push"
            : "Push \(unpushed) \(unpushed == 1 ? "commit" : "commits") to " + branches.map { "\(remote)/\($0)" }.formatted(.list(type: .and))
    }
}

/// A pull request on GitHub, as `gh pr list --json` gives it.
extension PullRequest {
    /// The PR badge from SF Symbols in macOS and iOS 27; on 26, the pull arrows.
    public static func symbol(filled: Bool = false) -> String {
        if #available(macOS 27, iOS 27, *) { filled ? "pr.button.horizontal.fill" : "pr.button.horizontal" } else { "arrow.triangle.pull" }
    }
}

public struct PullRequest: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable {
        case open = "OPEN", merged = "MERGED", closed = "CLOSED"
    }

    public var number: Int
    public var url: URL
    public var state: State
    public var headRefName: String
    /// The commit the pull request is at: on a merged one, what was merged.
    public var headRefOid: String
    /// Set by the orchestrator: the task has work this pull request does not have.
    public var hasNewWork = false

    private enum CodingKeys: String, CodingKey { case number, url, state, headRefName, headRefOid, hasNewWork }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        number = try values.decode(Int.self, forKey: .number)
        url = try values.decode(URL.self, forKey: .url)
        state = try values.decode(State.self, forKey: .state)
        headRefName = try values.decode(String.self, forKey: .headRefName)
        headRefOid = try values.decode(String.self, forKey: .headRefOid)
        hasNewWork = try values.decodeIfPresent(Bool.self, forKey: .hasNewWork) ?? false // gh doesn't say.
    }

    public init(number: Int, url: URL, state: State, headRefName: String, headRefOid: String, hasNewWork: Bool = false) {
        self.number = number
        self.url = url
        self.state = state
        self.headRefName = headRefName
        self.headRefOid = headRefOid
        self.hasNewWork = hasNewWork
    }
}

public enum AgentOutcome: Equatable, Sendable {
    case completed(summary: String)
    /// `options`: up to 4 short suggested replies the agent offered, most likely first.
    case needsInput(question: String, options: [String] = [])
    case blocked(reason: String, options: [String] = [])
}

/// One screenshot an agent asks for: a page, and JavaScript that puts it in the state that shows the change.
public struct ScreenshotTarget: Equatable, Sendable {
    public var page: String
    public var script: String?

    public init(page: String, script: String? = nil) {
        self.page = page
        self.script = script
    }
}

public enum AgentEvent: Equatable, Sendable {
    /// The agent's own session id, to persist and pass back in on the next run.
    case sessionStarted(id: String)
    /// One short human line, e.g. "Running tests…". Not a transcript.
    case activity(String)
    /// The agent's own words for what the task will accomplish. Either may be missing.
    case described(title: String?, description: String?)
    /// Tags the agent picked for the task (`AgentRequest.tags`), at most 2.
    case tagged([String])
    /// Screenshots are on: what shows this turn's change, empty if nothing visible changes. The first one comes
    /// before the agent's work; a later one replaces it. In an app project, the images the agent took instead.
    case screenshots([ScreenshotTarget])
    /// Raw output for the debugging view only.
    case rawOutput(String)
    /// Manual permissions: the agent waits to be allowed to do `summary`, one short human line such as
    /// "Run `pnpm install`". Answer through `AgentRequest.approvals`; the run goes on either way.
    case approvalRequested(id: String, summary: String)
    /// Always the last event of a run.
    case finished(AgentOutcome)
}

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

/// A task's build of one of its project's targets.
public struct BuildKey: Codable, Hashable, Sendable {
    public var taskID: Int
    public var targetID: UUID

    public init(taskID: Int, targetID: UUID) {
        self.taskID = taskID
        self.targetID = targetID
    }
}

/// An app project's latest build of a task's target.
public enum BuildState: Codable, Equatable, Sendable {
    case building
    /// `app`: the .app it built, if the build command printed one.
    case succeeded(app: URL?)
    case failed(String)
}

public struct AppState: Codable, Equatable, Sendable {
    public var projects: [Project]
    public var tasks: [TaskItem]
    public var nextTaskID: Int
    /// Absent in state saved before project chats existed.
    public var chats: [ProjectChat]
    /// Absent in state saved before schedules existed.
    public var schedules: [Schedule]
    /// When Shift was last seen running, so a run due after it is known to be missed because Shift wasn't.
    public var lastAlive: Date?
    /// Set while the Mac sleeps with Shift running: a run due after it was missed because the Mac was asleep.
    public var asleepSince: Date?
    /// The wakes Shift has scheduled with `pmset`, so it can tell what's covered and cancel the stale ones.
    public var wakes: [Date]

    public init(projects: [Project] = [], tasks: [TaskItem] = [], nextTaskID: Int = 3001, chats: [ProjectChat] = [],
                schedules: [Schedule] = [], lastAlive: Date? = nil, asleepSince: Date? = nil, wakes: [Date] = []) {
        self.projects = projects
        self.tasks = tasks
        self.nextTaskID = nextTaskID
        self.chats = chats
        self.schedules = schedules
        self.lastAlive = lastAlive
        self.asleepSince = asleepSince
        self.wakes = wakes
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decode([Project].self, forKey: .projects)
        tasks = try values.decode([TaskItem].self, forKey: .tasks)
        nextTaskID = try values.decode(Int.self, forKey: .nextTaskID)
        chats = try values.decodeIfPresent([ProjectChat].self, forKey: .chats) ?? []
        schedules = try values.decodeIfPresent([Schedule].self, forKey: .schedules) ?? []
        lastAlive = try values.decodeIfPresent(Date.self, forKey: .lastAlive)
        asleepSince = try values.decodeIfPresent(Date.self, forKey: .asleepSince)
        wakes = try values.decodeIfPresent([Date].self, forKey: .wakes) ?? []
    }
}

/// One agent log: a task's, or a project chat's.
public enum AgentLog: Codable, Hashable, Sendable {
    case task(Int)
    case chat(UUID)
}
