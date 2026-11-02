import Foundation

// Plain data the orchestrator, its services and the remote protocol share.

public enum MergeResult: Equatable, Sendable {
    case merged
    case conflict
}

/// A pull request on GitHub, as `gh pr list --json` gives it.
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

public enum AgentEvent: Equatable, Sendable {
    /// The agent's own session id, to persist and pass back in on the next run.
    case sessionStarted(id: String)
    /// One short human line, e.g. "Running tests…". Not a transcript.
    case activity(String)
    /// The agent's own words for what the task will accomplish. Either may be missing.
    case described(title: String?, description: String?)
    /// Screenshots are on: the page this turn's change shows on, nil if nothing visible changes. The first one
    /// comes before the agent's work; a later one replaces it.
    case screenshotPage(String?)
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

/// An app project's latest build of a task.
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

    public init(projects: [Project] = [], tasks: [TaskItem] = [], nextTaskID: Int = 3001, chats: [ProjectChat] = []) {
        self.projects = projects
        self.tasks = tasks
        self.nextTaskID = nextTaskID
        self.chats = chats
    }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        projects = try values.decode([Project].self, forKey: .projects)
        tasks = try values.decode([TaskItem].self, forKey: .tasks)
        nextTaskID = try values.decode(Int.self, forKey: .nextTaskID)
        chats = try values.decodeIfPresent([ProjectChat].self, forKey: .chats) ?? []
    }
}

/// One agent log: a task's, or a project chat's.
public enum AgentLog: Codable, Hashable, Sendable {
    case task(Int)
    case chat(UUID)
}
