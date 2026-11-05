import Foundation
import Observation

/// The single source of truth the UI binds to. Owns the task lifecycle.
/// The public surface here is a contract with the UI: change signatures only with the PM's sign-off.
@MainActor
@Observable
public final class AppModel {
    public private(set) var projects: [Project] = []
    public private(set) var tasks: [TaskItem] = []
    public private(set) var installedAgents: [AgentKind: AgentInstallation] = [:]
    /// Subscription limits per agent, as of the last `refreshUsage`.
    public private(set) var usage: [AgentKind: AgentUsage] = [:]
    /// The models each installed agent offers, besides its default.
    public private(set) var models: [AgentKind: [AgentModel]] = [:]
    /// The Mac can't reach the internet while an agent runs. Working tasks and chats show
    /// `TaskItem.offlineActivity`, and pick up again by themselves once it's back.
    public private(set) var isOffline = false
    /// Set when an operation fails outside of any task (e.g. adding a project). UI shows it as an alert.
    public var lastError: String?
    /// Whether each project's base branch has commits to push. No entry: the repo has no remote (or
    /// it was not checked yet).
    public internal(set) var pushStates: [Project.ID: PushState] = [:]

    public struct PushState: Equatable, Sendable {
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
    }

    /// Each task's latest pull request, as of the last check. No entry: none, or not known (no `gh`).
    public internal(set) var pullRequests: [TaskItem.ID: PullRequest] = [:]
    private var refreshingPullRequests: Set<Project.ID> = []

    /// Web projects: the port of the dev server running on the project's own checkout, its base branch.
    /// No entry: not started yet.
    public private(set) var basePorts: [Project.ID: Int] = [:]
    /// This Mac's name on the tailnet (e.g. "mac.tail1234.ts.net"), once a task server was shared there.
    /// Nil: Tailscale is not installed or not running.
    public private(set) var tailnetHost: String?

    /// Projects whose base server is coming up to be opened in the browser.
    public private(set) var openingBase: Set<Project.ID> = []

    /// App projects: the latest build of each task's targets since launch. No entry: not built yet.
    public private(set) var builds: [BuildKey: BuildState] = [:]
    /// The `.run` target each task has open. Its server slot holds one, so starting another replaces it.
    public private(set) var runningTargets: [TaskItem.ID: BuildTarget.ID] = [:]

    public typealias BuildKey = ShiftProtocol.BuildKey

    public typealias BuildState = ShiftProtocol.BuildState

    /// Each project's chat, once it has been used.
    public private(set) var chats: [ProjectChat] = []
    /// Projects whose chat's agent is replying.
    public private(set) var replyingChats: Set<Project.ID> = []
    /// Why the chat's last reply failed, until the next message.
    public private(set) var chatErrors: [Project.ID: String] = [:]
    /// Manual permissions: what each chat's agent waits to be allowed to do, oldest first.
    private var chatApprovals: [Project.ID: [(id: String, summary: String)]] = [:]

    private let services: Services?
    /// What a paired phone goes through. nil without `Services.remote`.
    var remote: RemoteServer?
    var store: StateStoring? { services?.store }

    /// One agent run (setup + turns) for a task. A run may only write to its task while it is
    /// the entry in `runs` and still `active`; stop/merge/delete revoke that before cancelling,
    /// so whatever a cancelled run produces late is dropped.
    private struct Run {
        let token: UUID
        let task: Task<Void, Never>
        var active = true
    }

    /// What a finished run turns the task into.
    private struct Settled {
        var status: TaskStatus
        var summary: String?
        var question: String?
        var blockedReason: String?
        var options: [String]?
    }

    private struct Failure: LocalizedError {
        let message: String
        init(_ message: String) { self.message = message }
        var errorDescription: String? { message }
    }

    static let interruptedReason = TaskItem.interruptedReason
    static let continuePrompt = "Continue the task."

    /// The chat's run, like a task's `Run`, and how to reach the agent while it runs.
    private struct ChatRun {
        let token: UUID
        let task: Task<Void, Never>
        var active = true
        var channel: ApprovalChannel?
    }

    private let worktreesRoot: URL
    /// What happened to the tasks each chat follows, until its agent has been told.
    @ObservationIgnored private var chatReports: [Project.ID: [String]] = [:]
    /// Where the chats' agents reach `shiftctl`'s server, and which project each one's access is for.
    @ObservationIgnored private var controlPort: Int?
    @ObservationIgnored var controlTokens: [String: Project.ID] = [:]
    @ObservationIgnored private var chatRuns: [Project.ID: ChatRun] = [:]
    @ObservationIgnored private var nextTaskID = 3001
    @ObservationIgnored private var runs: [TaskItem.ID: Run] = [:]
    /// Tasks whose worktree is being set up (created, setup command, server) right now.
    /// A task whose worktree folder does not exist is set up again before its next agent run.
    @ObservationIgnored private var settingUp: Set<TaskItem.ID> = []
    /// Why the task's dev server last failed to start, until it starts. Shown with its log.
    @ObservationIgnored private var serverFailures: [TaskItem.ID: String] = [:]
    /// Tasks whose dev server Shift left off: at launch, unused, or with the project's servers off.
    /// Opening the task, or an agent running in it, starts it.
    @ObservationIgnored private var dormant: Set<TaskItem.ID> = []
    /// When each server, by its ID in `services.servers`, was last wanted: shown, opened, or an agent running.
    @ObservationIgnored private var serverUsed: [Int: Date] = [:]
    /// Each base server's process group, which its own connections to itself come from.
    @ObservationIgnored private var baseGroups: [Project.ID: Int32] = [:]
    /// Added to every project's server TTL when checking it (tests use it to make servers idle at once).
    @ObservationIgnored var serverIdleSlack: TimeInterval = 0
    /// The command each task's dev server was last started with.
    @ObservationIgnored private var serverCommands: [TaskItem.ID: String] = [:]
    @ObservationIgnored private var buildRuns: [BuildKey: Task<CommandResult, Error>] = [:]
    @ObservationIgnored private var buildLogs: [BuildKey: String] = [:]
    /// Tasks with a merge or delete in progress.
    @ObservationIgnored private var busy: Set<TaskItem.ID> = []
    /// Manual permissions: how to answer the running agent, and its unanswered requests, oldest first.
    /// The first one is the task's `approvalRequest`.
    @ObservationIgnored private var approvalChannels: [TaskItem.ID: ApprovalChannel] = [:]
    @ObservationIgnored private var pendingApprovals: [TaskItem.ID: [(id: String, summary: String)]] = [:]
    /// Serial queue for saves, badge updates and notifications, so they land in order.
    @ObservationIgnored private var io: Task<Void, Never>?
    @ObservationIgnored private var savePending = false
    @ObservationIgnored private var lastBadge: Int?
    /// Base servers share the servers' task ID space; they get negative IDs so no task has theirs.
    @ObservationIgnored private var baseServerIDs: [Project.ID: Int] = [:]
    /// How often a base server that is coming up is checked (tests shorten it).
    @ObservationIgnored var baseServerPoll: Duration = .milliseconds(200)
    /// How often the connection is checked while offline, and the wait before trying a failed turn again (tests shorten it).
    @ObservationIgnored var connectionPoll: Duration = .seconds(3)
    /// `start()` runs once per launch; the window calls it again whenever it is reopened.
    @ObservationIgnored private var started = false
    /// When each task was last continued after its limit reset, so a stale usage reading can't retry it in a loop.
    @ObservationIgnored private var autoContinued: [TaskItem.ID: Date] = [:]

    public init(services: Services) {
        self.services = services
        self.worktreesRoot = ShiftPaths.worktrees
    }

    /// `worktrees`: where new tasks' worktrees go (tests).
    init(services: Services, worktrees: URL) {
        self.services = services
        self.worktreesRoot = worktrees
    }

    /// In-memory model with fixed data, for previews and UI work. Actions are no-ops.
    public init(previewProjects: [Project], tasks: [TaskItem]) {
        self.services = nil
        self.worktreesRoot = ShiftPaths.worktrees
        self.projects = previewProjects
        self.tasks = tasks
        self.installedAgents = [.claudeCode: .init(path: "/usr/local/bin/claude"), .codex: .init(path: "/usr/local/bin/codex")]
        self.models = [.claudeCode: ClaudeCodeAdapter.models]
    }

    // MARK: Queries

    public func tasks(in projectID: Project.ID) -> [TaskItem] {
        tasks.filter { $0.projectID == projectID }
    }

    public func task(_ id: TaskItem.ID) -> TaskItem? {
        tasks.first { $0.id == id }
    }

    public func project(_ id: Project.ID) -> Project? {
        projects.first { $0.id == id }
    }

    /// Number of tasks waiting on the user (needs input, blocked, conflict, completed). Drives the Dock badge.
    public var attentionCount: Int {
        tasks.filter { $0.status.needsAttention || $0.status == .completed }.count
    }

    /// Keeps the last known usage if it can't be read now (offline, rate limited).
    public func refreshUsage(_ kind: AgentKind) async {
        if let usage = await services?.agents[kind]?.usage() { self.usage[kind] = usage }
    }

    /// When a usage-limited task's limit resets, if its agent's usage says. May be in the past.
    public func limitResetsAt(taskID: TaskItem.ID) -> Date? {
        guard let task = task(taskID), task.isUsageLimited else { return nil }
        return usage[task.agent]?.limitResetsAt
    }

    /// Usage-limited tasks carry on by themselves once their limit resets.
    public var continuesAfterLimit = UserDefaults.standard.bool(forKey: "continuesAfterLimit") {
        didSet { UserDefaults.standard.set(continuesAfterLimit, forKey: "continuesAfterLimit") }
    }

    /// Continues the usage-limited tasks whose limit has reset, if `continuesAfterLimit`.
    func continueLimitedTasks() async {
        guard continuesAfterLimit else { return }
        for task in tasks where task.isUsageLimited {
            guard let resets = limitResetsAt(taskID: task.id), resets <= .now,
                  autoContinued[task.id].map({ $0.timeIntervalSinceNow < -300 }) ?? true else { continue }
            await refreshUsage(task.agent)
            // The reading was stale and the limit is still reached: wait for the new reset.
            if let resets = limitResetsAt(taskID: task.id), resets > .now { continue }
            autoContinued[task.id] = .now
            resume(taskID: task.id)
        }
    }

    // MARK: Lifecycle

    /// Loads persisted state, detects agents, reconciles with reality (see docs/specs/orchestrator.md).
    public func start() async {
        guard let services, !started else { return }
        started = true
        let state = await services.store.load()
        projects = state.projects
        tasks = state.tasks
        // Nothing is running yet: what never reached the agent was never sent.
        chats = state.chats.filter { chat in projects.contains { $0.id == chat.projectID } }.map {
            var chat = $0
            chat.prompts.removeAll(where: \.isPending)
            return chat
        }
        nextTaskID = max(state.nextTaskID, (tasks.map(\.id).max() ?? 0) + 1)

        // Nothing is running yet, so nothing may claim to be working or wait for an approval.
        // Done before the first await.
        for task in tasks where task.status == .working || task.approvalRequest != nil {
            update(task.id) { Self.apply(Settled(status: .blocked, blockedReason: Self.interruptedReason), to: &$0) }
        }
        // Prompts that never reached the agent before Shift quit were never sent.
        tasks.map(\.id).forEach(dropPending)
        // Saved before tasks had their own base: they keep the one they have been using.
        for task in tasks where task.baseBranch == nil {
            if let base = project(task.projectID)?.baseBranch { update(task.id) { $0.baseBranch = base } }
        }
        // Saved before tasks had their own model and permissions: they keep the project's.
        for task in tasks where task.permissions == nil {
            guard let project = project(task.projectID) else { continue }
            update(task.id) {
                $0.permissions = project.permissions
                $0.model = project.models[task.agent]
            }
        }

        for kind in AgentKind.allCases {
            installedAgents[kind] = await services.agents[kind]?.detect()
            models[kind] = await services.agents[kind]?.models()
        }
        Task { await services.notifier.requestAuthorization() }
        controlPort = await services.control?.start { [weak self] token, arguments in
            await self?.handleControl(token: token, arguments: arguments) ?? ControlReply(ok: false, text: "Shift is quitting.")
        }

        if let listener = services.remote {
            remote = RemoteServer(model: self, listener: listener)
            await remote?.start()
        }

        for task in tasks where task.status != .merged {
            await reconcile(task.id)
        }
        // Its base may have gained code while Shift was closed (a pull request merged, a commit by hand).
        for project in projects { await adoptDetectedType(project.id) }
        changed()
        Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(30))) != nil, let self { await self.continueLimitedTasks() }
        }
        if let connectivity = services.connectivity {
            Task { [weak self] in
                while let poll = self?.connectionPoll, (try? await Task.sleep(for: poll)) != nil, let self {
                    await self.checkConnection(connectivity)
                }
            }
        }
        Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(60))) != nil, let self { await self.stopUnusedServers() }
        }
        watchMemory()
        Task { [weak self] in
            await self?.refreshAllPullRequests()
            while (try? await Task.sleep(for: .seconds(60))) != nil, let self { await self.refreshAllPullRequests() }
        }
    }

    /// Called on app termination: stop servers and agents, persist.
    public func shutdown() async {
        guard let services else { return }
        remote?.stop()
        tasks.map(\.id).forEach(dropPending)
        let running = runs.values.map(\.task)
        for id in runs.keys { runs[id]?.active = false }
        running.forEach { $0.cancel() }
        pendingApprovals = [:]
        for task in tasks where task.status == .working || task.approvalRequest != nil {
            update(task.id) { Self.apply(Settled(status: .blocked, blockedReason: Self.interruptedReason), to: &$0) }
        }
        for run in running { await run.value }
        runs = [:]
        for id in chatRuns.keys { await cancelChat(id) }
        await services.servers.stopAll()
        for task in tasks where task.serverPID != nil {
            update(task.id) { $0.serverPID = nil }
        }
        changed()
        await flush()
    }

    /// Only while an agent runs, or until the connection is back: nobody else needs to know.
    private func checkConnection(_ connectivity: ConnectivityChecking) async {
        guard !runs.isEmpty || !replyingChats.isEmpty || isOffline else { return }
        if !connectivity.hasNetwork {
            isOffline = true
        } else if isOffline {
            isOffline = !(await connectivity.reachesInternet())
        }
    }

    /// After an agent turn failed with `reason`: if it was for want of internet, waits until it's back and
    /// returns true, to run the turn again. Throws `CancellationError` once `isCurrent` says the run is over.
    private func waitsForInternet(after reason: String, blips: inout Int, isCurrent: () -> Bool) async throws -> Bool {
        guard let connectivity = services?.connectivity,
              isOffline || OutcomeProtocol.isNetworkFailure(reason) else { return false }
        func check() throws { if !isCurrent() { throw CancellationError() } }
        if await connectivity.reachesInternet() {
            try check()
            // Online after all: a passing failure. Tried again a few times, then it's an error like any other.
            blips += 1
            guard blips <= 3, OutcomeProtocol.isNetworkFailure(reason) else { return false }
            try await Task.sleep(for: connectionPoll * blips)
        } else {
            isOffline = true
            repeat {
                try await Task.sleep(for: connectionPoll)
                try check()
            } while !(await connectivity.reachesInternet())
            isOffline = false
        }
        try check()
        return true
    }

    // MARK: Projects

    /// For asking before `addProject(at:initializingGit:)`. True for a folder that is already a project.
    public func isRepository(_ url: URL) async -> Bool {
        guard let services else { return true }
        return await services.git.isRepository(url)
    }

    /// Validates that `url` is a Git repository and adds it with sensible defaults.
    /// `initializingGit`: a folder that is not a repository is made one, with everything in it committed.
    @discardableResult
    public func addProject(at url: URL, initializingGit: Bool = false) async -> Project? {
        guard let services else { return nil }
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.repoPath == path }) { return existing }
        if !(await services.git.isRepository(url)) {
            guard initializingGit else {
                lastError = "\(url.lastPathComponent) is not a Git repository."
                return nil
            }
            do {
                try await services.git.initRepository(url)
            } catch {
                lastError = "Could not initialize Git in \(url.lastPathComponent): \(Self.describe(error))"
                return nil
            }
        }
        let branches = (try? await services.git.branches(repo: url)) ?? []
        var base = ["main", "master"].first(where: branches.contains)
        if base == nil { base = try? await services.git.currentBranch(repo: url) }
        guard let base else {
            lastError = "Could not find a branch in \(url.lastPathComponent)."
            return nil
        }
        let suggested = await ProjectSetup.suggest(repo: url, git: services.git, servers: services.servers)
        if let existing = projects.first(where: { $0.repoPath == path }) { return existing }
        let project = Project(name: url.lastPathComponent, repoPath: path, baseBranch: base, type: suggested.type,
                              defaultAgent: AgentKind.allCases.first { installedAgents[$0] != nil } ?? .claudeCode,
                              serverCommand: suggested.server, setupCommand: suggested.setup, buildTargets: suggested.targets)
        projects.append(project)
        changed()
        return project
    }

    public func updateProject(_ project: Project) {
        guard let services, let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let old = projects[index]
        projects[index] = project
        if basePorts[project.id] != nil,
           (old.serverCommand, old.buildTargets, old.isApp) != (project.serverCommand, project.buildTargets, project.isApp) {
            Task { await startBaseServer(project.id, restart: true) }
        }
        if project.serversOff && !old.serversOff && !project.isApp {
            Task { await startBaseServer(project.id) }
            for task in tasks(in: project.id) where task.serverPID != nil { Task { await stopServer(task.id) } }
        }
        // Back on: each task's server starts once the task is opened.
        if !project.serversOff && old.serversOff {
            for task in tasks(in: project.id) where task.status != .merged && task.serverPID == nil { dormant.insert(task.id) }
        }
        // Now an app: its tasks are tested by building, so their dev servers and ports go. A running app goes
        // when the project stops being one, but not on any other change to its settings.
        if project.isApp ? !old.isApp : old.runsApp && !project.runsApp {
            for task in tasks(in: project.id) where task.serverPID != nil || task.port != nil {
                update(task.id) { $0.serverPID = nil; $0.port = nil }
                runningTargets[task.id] = nil
                Task {
                    await services.servers.stop(taskID: task.id)
                    if let port = task.port { await services.tailscale?.unserve(port: port) }
                }
            }
        }
        // The target a task has open is gone, or no longer one that stays open.
        let runnable = project.targets.filter { $0.kind == .run }.map(\.id)
        for task in tasks(in: project.id) {
            guard let running = runningTargets[task.id], !runnable.contains(running) else { continue }
            Task { await stopApp(taskID: task.id) }
        }
        changed()
    }

    /// The project as `type`, with the commands guessed from the repo. Other keeps the commands it has.
    public func project(_ project: Project, as type: ProjectType) async -> Project {
        var project = project
        project.type = type
        guard let services, type != .other else { return project }
        let suggested = await ProjectSetup.suggest(repo: project.repoURL, git: services.git, servers: services.servers, as: type)
        project.setupCommand = suggested.setup
        project.serverCommand = suggested.server
        project.buildTargets = suggested.targets
        return project
    }

    /// A project added as an empty folder gets Static website and no commands. Once its base has code (a merged
    /// task, the chat's work), it takes the type and commands that code calls for, so its servers run.
    // ponytail: also re-types a project the user set to Static website by hand on a repo with a dev script;
    // a "type chosen by the user" flag if that comes up.
    func adoptDetectedType(_ projectID: Project.ID) async {
        func undetected(_ project: Project) -> Bool {
            [.staticWebsite, .other].contains(project.type) && project.serverCommand.isEmpty
                && project.setupCommand.isEmpty && !project.buildTargets.contains(where: \.hasCommand)
        }
        guard let services, let project = project(projectID), undetected(project) else { return }
        let suggested = await ProjectSetup.suggest(repo: project.repoURL, git: services.git, servers: services.servers)
        guard [.dynamicWebsite, .nativeApp, .electronApp].contains(suggested.type),
              var now = self.project(projectID), undetected(now) else { return }
        now.type = suggested.type
        now.serverCommand = suggested.server
        now.setupCommand = suggested.setup
        now.buildTargets = suggested.targets
        updateProject(now)
    }

    /// Set while the project's base is empty and another task holds work: a new task starts from the empty base,
    /// without that work.
    // ponytail: reads the repo folder, so it speaks for the checked-out branch, which is the base in practice.
    public func emptyBaseWarning(projectID: Project.ID) -> String? {
        guard let project = project(projectID),
              let other = tasks(in: projectID).last(where: { $0.status != .merged }) else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: project.repoPath)) ?? []
        guard !files.contains(where: { $0 != ".git" && $0 != ".DS_Store" }) else { return nil }
        return "\(project.baseBranch) is empty, so a new task starts without the work in “\(other.title)”. "
            + "To build on that work, continue in that task, or merge it first."
    }

    public func moveProjects(from source: IndexSet, to destination: Int) {
        guard services != nil else { return }
        let moved = source.map { projects[$0] }
        var rest = projects.indices.filter { !source.contains($0) }.map { projects[$0] }
        rest.insert(contentsOf: moved, at: destination - source.count(in: 0..<destination))
        projects = rest
        changed()
    }

    /// Removes the project and cleans up all of its tasks.
    public func removeProject(_ id: Project.ID) async {
        guard services != nil else { return }
        for task in tasks(in: id) { await delete(taskID: task.id) }
        // A task that was already mid-merge or mid-delete was skipped above; keep the project
        // (and its repo path) until those are gone rather than orphan them.
        guard tasks(in: id).isEmpty else {
            lastError = "Some tasks are still being cleaned up. Try again in a moment."
            return
        }
        await cancelChat(id)
        chatReports[id] = nil
        if let chat = chat(projectID: id) { await services?.store.deleteChatLog(chatID: chat.id) }
        chats.removeAll { $0.projectID == id }
        chatErrors[id] = nil
        projects.removeAll { $0.id == id }
        pushStates[id] = nil
        await startBaseServer(id)
        changed()
    }

    /// Branches that can be the project's base: not its tasks' own branches, which merging would delete.
    public func branches(for projectID: Project.ID) async -> [String] {
        guard let services, let project = project(projectID) else { return [] }
        let taskBranches = Set(tasks(in: projectID).map(\.branch))
        return ((try? await services.git.branches(repo: project.repoURL)) ?? []).filter { !taskBranches.contains($0) }
    }

    /// Creates a branch in the project's repo at the tip of `source`. False (and `lastError`) if it could not.
    public func createBranch(projectID: Project.ID, name: String, from source: String) async -> Bool {
        guard let services, let project = project(projectID) else { return false }
        do {
            try await services.git.createBranch(repo: project.repoURL, name: name, from: source)
            return true
        } catch {
            lastError = "Could not create \(name): \(Self.firstLine(Self.describe(error)))"
            return false
        }
    }

    // MARK: Tasks

    /// Creates the task and returns immediately with status `.working`; setup continues in the background.
    /// `agent` nil means the project default.
    @discardableResult
    public func createTask(projectID: Project.ID, prompt: String, attachments: [String] = [],
                           agent: AgentKind? = nil) -> TaskItem.ID? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard services != nil, let project = project(projectID), !prompt.isEmpty || !attachments.isEmpty else { return nil }
        let first = Prompt(text: prompt, attachments: attachments)
        let id = nextTaskID
        nextTaskID += 1
        let title = TaskItem.localTitle(id: id, prompt: prompt, attachments: attachments)
        var task = TaskItem(
            id: id, projectID: projectID, title: title, status: .working,
            agent: agent ?? project.defaultAgent, branch: "shift/\(id)", baseBranch: project.baseBranch,
            worktreePath: ShiftPaths.worktree(project: project, taskID: id, root: worktreesRoot).path,
            prompts: [first], workingSince: Date())
        // The footer's choices are the new task's own from here on: changing them later leaves it as it is.
        task.model = project.models[task.agent]
        task.permissions = project.permissions
        tasks.append(task)
        changed()
        startRun(id, prompt: first.agentText, promptIDs: [first.id])
        return id
    }

    /// Follow-up instructions, an answer to a question, or instructions for a blocked task.
    /// While the agent works they go into its running session as soon as it can take them, and are
    /// `isPending` until then.
    /// `/task <prompt>` starts a new task in the same project instead.
    public func sendPrompt(taskID: TaskItem.ID, text: String, attachments: [String] = []) {
        if let prompt = Self.taskCommand(text), let task = task(taskID) {
            createTask(projectID: task.projectID, prompt: prompt, attachments: attachments)
            return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard services != nil, let task = task(taskID), task.status != .merged,
              !busy.contains(taskID), !text.isEmpty || !attachments.isEmpty else { return }
        guard runs[taskID]?.active == true else {
            let prompt = Prompt(text: text, attachments: attachments)
            update(taskID) { $0.prompts.append(prompt) }
            beginWorking(taskID)
            startRun(taskID, prompt: prompt.agentText, promptIDs: [prompt.id])
            return
        }
        let prompt = Prompt(text: text, isPending: true, attachments: attachments)
        update(taskID) { $0.prompts.append(prompt) }
        // A prompt instead of an answer to an approval request denies it, and goes to the agent
        // with the denial if the agent takes a message.
        if let pending = pendingApprovals.removeValue(forKey: taskID), let first = pending.first,
           let channel = approvalChannels[taskID] {
            resumeWorking(taskID)
            pending.dropFirst().forEach { channel.answer(id: $0.id, allow: false) }
            if channel.answer(id: first.id, allow: false, message: prompt.agentText) {
                logDelivered(taskID, [prompt.id])
                markDelivered(taskID)
                return
            }
        }
        deliverPending(taskID)
    }

    /// The prompt of a `/task <prompt>` message, or nil when the message isn't one.
    nonisolated static func taskCommand(_ text: String) -> String? {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("/task"), text.count == 5 || text.dropFirst(5).first!.isWhitespace else { return nil }
        return String(text.dropFirst(5)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Carries on with a task that was stopped or interrupted (`TaskItem.canResume`), in the same
    /// session, without adding anything to its prompts.
    public func resume(taskID: TaskItem.ID) {
        guard services != nil, let task = task(taskID), task.canResume, !busy.contains(taskID),
              runs[taskID]?.active != true else { return }
        beginWorking(taskID)
        startRun(taskID, prompt: Self.continuePrompt)
    }

    public func merge(taskID: TaskItem.ID) async {
        guard let services, let task = task(taskID), task.status != .merged,
              let project = project(task.projectID), !busy.contains(taskID) else { return }
        busy.insert(taskID)
        defer { busy.remove(taskID) }

        // Merging means the user is done with this work: the agent stops first so that what gets
        // committed and merged is not still being written to.
        if let missing = await missingBase(task, project) {
            lastError = "Could not merge \(task.title): \(missing)"
            return
        }
        let wasRunning = runs[taskID] != nil
        await cancelRun(taskID)
        do {
            // A worktree folder deleted by hand has nothing left to commit; the branch has the work.
            if FileManager.default.fileExists(atPath: task.worktreePath) {
                try await services.git.commitAll(worktree: task.worktreeURL, message: task.title)
            }
            let result = try await services.git.merge(repo: project.repoURL, branch: task.branch,
                                                      into: task.base(in: project), message: task.title)
            switch result {
            case .merged:
                await cleanUp(taskID, keepingBranchUnlessIn: task.base(in: project))
                markMerged(taskID)
                await adoptDetectedType(project.id)
                await refreshPushState(projectID: project.id)
                // Base moved: other tasks may not merge cleanly any more.
                await refreshMergeability()
            case .conflict:
                update(taskID) { Self.apply(Settled(status: .conflict, summary: $0.summary), to: &$0) }
            }
        } catch {
            lastError = "Could not merge \(task.title): \(Self.firstLine(Self.describe(error)))"
            // Status is left alone, unless the agent was stopped for this merge: it is not working any more.
            if wasRunning {
                update(taskID) { Self.apply(Settled(status: .blocked, blockedReason: TaskItem.stoppedReason), to: &$0) }
            }
        }
    }

    /// The project's base for new tasks, then every other base its tasks have (merged ones included).
    public func bases(of projectID: Project.ID) -> [String] {
        guard let project = project(projectID) else { return [] }
        var bases = [project.baseBranch]
        for task in tasks(in: projectID) where !bases.contains(task.base(in: project)) { bases.append(task.base(in: project)) }
        return bases
    }

    /// Reads whether the project's bases have anything to push (no network access).
    /// ponytail: one remote for all bases, the default base's; per-branch remotes if anyone needs them.
    public func refreshPushState(projectID: Project.ID) async {
        guard let services, let project = project(projectID), pushStates[projectID]?.isPushing != true else { return }
        let bases = bases(of: projectID)
        let remote = await services.git.remote(repo: project.repoURL, branch: project.baseBranch)
        var counts: [(String, Int)] = []
        if let remote {
            for base in bases where await services.git.branchExists(repo: project.repoURL, branch: base) {
                let count = (try? await services.git.unpushedCount(repo: project.repoURL, branch: base, remote: remote)) ?? 0
                if count > 0 { counts.append((base, count)) }
            }
        }
        // A push started or the bases changed meanwhile: this answer is stale.
        guard pushStates[projectID]?.isPushing != true, self.bases(of: projectID) == bases else { return }
        pushStates[projectID] = remote.map {
            PushState(remote: $0, unpushed: counts.reduce(0) { $0 + $1.1 }, branches: counts.map(\.0))
        }
    }

    /// Pushes every base of the project that has commits to push, merging in what the remote has that
    /// they lack. Never forced.
    public func push(projectID: Project.ID) async {
        guard let services, let project = project(projectID), let state = pushStates[projectID],
              !state.isPushing, state.unpushed > 0 else { return }
        pushStates[projectID]?.isPushing = true
        do {
            for branch in state.branches {
                try await services.git.push(repo: project.repoURL, branch: branch, remote: state.remote)
            }
        } catch {
            lastError = Self.firstLine(Self.describe(error))
        }
        pushStates[projectID]?.isPushing = false
        await refreshPushState(projectID: projectID)
        // The remote's changes may have moved a base: other tasks may not merge cleanly any more.
        await refreshMergeability()
    }

    /// Commits what the task has and pushes its branch to the project's remote, which updates its open
    /// pull request. Never forced.
    public func pushBranch(taskID: TaskItem.ID) async {
        guard let services, let task = task(taskID), let project = project(task.projectID),
              let remote = await services.git.remote(repo: project.repoURL, branch: task.branch) else { return }
        do {
            if FileManager.default.fileExists(atPath: task.worktreePath) {
                try await services.git.commitAll(worktree: task.worktreeURL, message: task.title)
            }
            try await services.git.push(repo: project.repoURL, branch: task.branch, remote: remote)
            // GitHub may take a moment to show the new head; the next check has it.
            if pullRequests[taskID]?.state == .open { pullRequests[taskID]?.hasNewWork = false }
        } catch {
            lastError = "Could not push \(task.title): \(Self.firstLine(Self.describe(error)))"
        }
    }

    /// Pushes the task's branch and returns the page that opens a pull request for it into its base,
    /// with the task's title and what the agent said about it filled in.
    /// Nil (and `lastError`) if the push fails or the remote is not on GitHub.
    public func pullRequestURL(taskID: TaskItem.ID) async -> URL? {
        guard let services, let task = task(taskID), let project = project(task.projectID) else { return nil }
        guard let remote = await services.git.remote(repo: project.repoURL, branch: task.branch),
              let remoteURL = await services.git.remoteURL(repo: project.repoURL, remote: remote),
              let url = Self.pullRequestURL(remoteURL: remoteURL, branch: task.branch, base: task.base(in: project),
                                            title: task.title,
                                            body: [task.description, task.summary].compactMap { $0 }.joined(separator: "\n\n")) else {
            lastError = "Could not open a pull request for \(task.title): the project has no GitHub remote."
            return nil
        }
        do {
            try await services.git.push(repo: project.repoURL, branch: task.branch, remote: remote)
        } catch {
            lastError = "Could not push \(task.title): \(Self.firstLine(Self.describe(error)))"
            return nil
        }
        await refreshPushState(projectID: project.id)
        return url
    }

    /// GitHub's compare page for `branch` into `base`, from an https or ssh remote URL. Nil for other hosts.
    /// An empty `body` is left out so the repo's pull request template still applies.
    static func pullRequestURL(remoteURL: String, branch: String, base: String, title: String, body: String) -> URL? {
        guard let repo = githubRepo(remoteURL: remoteURL) else { return nil }
        // `+` must be escaped too: GitHub reads a bare one in a query as a space.
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+"))
        func encoded(_ text: String) -> String { text.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        let page = "https://github.com/\(repo)/compare/\(base)...\(branch)?expand=1&title=\(encoded(title))"
        let filled = "\(page)&body=\(encoded(body))"
        // ponytail: GitHub rejects very long URLs, so a huge body is dropped rather than truncated mid-sentence.
        return URL(string: body.isEmpty || filled.count > 6000 ? page : filled)
    }

    /// The project's GitHub page, from its base branch's remote. Nil, with an error shown, if it has none.
    public func repositoryURL(projectID: Project.ID) async -> URL? {
        guard let services, let project = project(projectID) else { return nil }
        guard let remote = await services.git.remote(repo: project.repoURL, branch: project.baseBranch),
              let remoteURL = await services.git.remoteURL(repo: project.repoURL, remote: remote),
              let repo = Self.githubRepo(remoteURL: remoteURL) else {
            lastError = "\(project.name) has no GitHub remote."
            return nil
        }
        return URL(string: "https://github.com/\(repo)")
    }

    /// "owner/repo" from an https or ssh remote URL. Nil for other hosts.
    static func githubRepo(remoteURL: String) -> String? {
        remoteURL.firstMatch(of: #/github\.com[:/]([^/]+/[^/]+?)(\.git)?/?$/#).map { String($0.1) }
    }

    private func refreshAllPullRequests() async {
        for id in projects.map(\.id) { await refreshPullRequests(projectID: id) }
    }

    /// Reads the pull requests of the project's tasks from GitHub. A task whose pull request was merged
    /// is done, unless it has work that was not in it: that stays, and can go into a new pull request.
    public func refreshPullRequests(projectID: Project.ID) async {
        guard let services, let project = project(projectID), !refreshingPullRequests.contains(projectID),
              tasks(in: projectID).contains(where: { $0.status != .merged }),
              let remote = await services.git.remote(repo: project.repoURL, branch: project.baseBranch),
              let remoteURL = await services.git.remoteURL(repo: project.repoURL, remote: remote),
              let github = Self.githubRepo(remoteURL: remoteURL) else { return }
        refreshingPullRequests.insert(projectID)
        defer { refreshingPullRequests.remove(projectID) }
        // No `gh`, signed out or offline: what is known stays.
        guard let found = try? await services.git.pullRequests(repo: project.repoURL, github: github) else { return }

        var newlyMergedBases: Set<String> = []
        for id in tasks(in: projectID).map(\.id) {
            guard let task = task(id), task.status != .merged else { continue }
            guard var pullRequest = found[task.branch],
                  await services.git.branchExists(repo: project.repoURL, branch: task.branch) else {
                pullRequests[id] = nil
                continue
            }
            pullRequest.hasNewWork = await hasWork(id, outside: pullRequest, remote: remote)
            if pullRequest.state == .merged, pullRequests[id]?.state != .merged { newlyMergedBases.insert(task.base(in: project)) }
            pullRequests[id] = pullRequest
            if pullRequest.state == .merged, !pullRequest.hasNewWork, isSettled(id) {
                busy.insert(id)
                await cleanUp(id)
                markMerged(id)
                update(id) { $0.mergedPullRequest = pullRequest.number }
                busy.remove(id)
            }
        }
        guard !newlyMergedBases.isEmpty else { return }
        // Merged on GitHub: new tasks must start from it, and other tasks must be checked against it.
        // Not moved if the local base has its own commits or the move would overwrite uncommitted changes.
        for base in newlyMergedBases { try? await services.git.fastForward(repo: project.repoURL, branch: base, remote: remote) }
        await refreshPushState(projectID: projectID)
        await refreshMergeability()
    }

    /// Finished, with nothing happening to it.
    private func isSettled(_ id: TaskItem.ID) -> Bool {
        guard let task = task(id), task.status == .completed || task.status == .conflict else { return false }
        return runs[id] == nil && !busy.contains(id)
    }

    /// Whether the task has anything the pull request does not. Unknown counts as yes: a yes keeps the
    /// work, a wrong no deletes it. Local commits behind the pull request (GitHub's "Update branch") are not work.
    private func hasWork(_ id: TaskItem.ID, outside pullRequest: PullRequest, remote: String) async -> Bool {
        guard let services, let task = task(id), let project = project(task.projectID) else { return true }
        if isSettled(id), FileManager.default.fileExists(atPath: task.worktreePath) {
            do { try await services.git.commitAll(worktree: task.worktreeURL, message: task.title) } catch { return true }
        }
        func isContained() async -> Bool? {
            try? await services.git.isContained(repo: project.repoURL, branch: task.branch, in: pullRequest.headRefOid)
        }
        if let contained = await isContained() { return !contained }
        // The head commit is not here yet.
        try? await services.git.fetchPullRequest(repo: project.repoURL, number: pullRequest.number, remote: remote)
        return await isContained() != true
    }

    /// The project's base branch in the browser: its base server, started again first if it stopped, once it
    /// answers. Nil (and `lastError`) if it never does.
    public func baseServerURL(projectID: Project.ID) async -> URL? {
        guard let services, !openingBase.contains(projectID) else { return nil }
        if let project = project(projectID), project.serversOff {
            lastError = "Servers are off for \(project.name). Turn them on from its menu in the sidebar."
            return nil
        }
        func url(_ port: Int) -> URL? { URL(string: "http://localhost:\(port)") }
        if let id = baseServerIDs[projectID] { serverUsed[id] = .now }
        if let id = baseServerIDs[projectID], let port = basePorts[projectID],
           await services.servers.isRunning(taskID: id), await isListening(port) { return url(port) }

        openingBase.insert(projectID)
        defer { openingBase.remove(projectID) }
        await startBaseServer(projectID)
        guard let project = project(projectID), let id = baseServerIDs[projectID],
              var port = basePorts[projectID] else { return nil }
        // Up for 3 seconds before it counts: Next.js listens for a second or two before it finds another
        // dev server running on the folder and quits. Given up on after 30 seconds.
        var up = 0, polls = 0, retries = 0
        while polls < 150 {
            polls += 1
            guard await services.servers.isRunning(taskID: id) else {
                guard retries < Self.portRetries, await lostPort(id) else { break }
                retries += 1
                (up, polls) = (0, 0)
                await startBaseServer(projectID)
                guard let next = basePorts[projectID] else { return nil }
                port = next
                continue
            }
            up = await isListening(port) ? up + 1 : 0
            if up == 15 { return url(port) }
            try? await Task.sleep(for: baseServerPoll)
        }
        // Not on its port, but its output may say where the project is served: Next.js names the server
        // already running on the folder, and some servers ignore PORT.
        // ponytail: only the last 30 lines of output are read; the project's command should honor $PORT.
        let log = await services.servers.log(taskID: id, lines: 30)
        let others = Set(tasks.filter { $0.status != .merged }.compactMap(\.port))
            .union(basePorts.filter { $0.key != projectID }.values)
        for match in log.matches(of: #/https?://(?:localhost|127\.0\.0\.1):(\d+)/#).reversed() {
            guard let logged = Int(match.1), !others.contains(logged), await isListening(logged) else { continue }
            // Still running, just not on the port it was given: found right away next time.
            if await services.servers.isRunning(taskID: id), basePorts[projectID] == port { basePorts[projectID] = logged }
            return url(logged)
        }
        lastError = "The server for \(project.name) did not start on port \(port). "
            + "Its output is in \(ShiftPaths.logs.appendingPathComponent("server-\(id).log").path)."
        return nil
    }

    /// Whether something answers on the port: the allocator only passes over a port that is taken.
    private func isListening(_ port: Int) async -> Bool {
        await services?.ports.allocate(preferred: port, reserved: []) != port
    }

    /// Starts a web project's base server if it is not running, and stops it once the project is gone or
    /// became an app. Only ever started by opening it: a project's server command can do anything (Facet's
    /// opens its Electron app), so it must not run just because Shift launched.
    /// `restart`: start it again even if it runs, for a changed command.
    /// ponytail: serves the repo folder, which shows base only while base is checked out there.
    private func startBaseServer(_ projectID: Project.ID, restart: Bool = false) async {
        guard let services else { return }
        let id = baseServerIDs[projectID] ?? -(baseServerIDs.count + 1)
        baseServerIDs[projectID] = id
        guard let project = project(projectID), !project.isApp, !project.serversOff else {
            basePorts[projectID] = nil
            await services.servers.stop(taskID: id)
            return
        }
        if !restart, basePorts[projectID] != nil, await services.servers.isRunning(taskID: id) { return }
        guard FileManager.default.fileExists(atPath: project.repoPath) else {
            basePorts[projectID] = nil
            await services.servers.stop(taskID: id)
            lastError = "The folder for \(project.name) no longer exists: \(project.repoPath)"
            return
        }
        let reserved = Set(tasks.filter { $0.status != .merged }.compactMap(\.port))
            .union(basePorts.filter { $0.key != projectID }.values)
        let port = await services.ports.allocate(preferred: basePorts[projectID] ?? 3000, reserved: reserved)
        do {
            baseGroups[projectID] = try await services.servers.start(
                taskID: id, command: ProjectSetup.serverCommand(for: project, in: project.repoURL),
                directory: project.repoURL, port: port)
            basePorts[projectID] = port
            serverUsed[id] = .now
        } catch {
            basePorts[projectID] = nil
            lastError = "Could not start the server for \(project.name): \(Self.firstLine(Self.describe(error)))"
        }
        // Removed, made an app or turned off while starting: the server must not outlive it.
        if self.project(projectID).map({ $0.isApp || $0.serversOff }) != false { await startBaseServer(projectID) }
    }

    /// Checks every completed or conflicting task against its base again, which may have moved since,
    /// and flips it between completed and conflict. Tells the user about each new conflict.
    public func refreshMergeability() async {
        guard let services else { return }
        func eligible(_ id: TaskItem.ID) -> TaskItem? {
            guard let task = task(id), task.status == .completed || task.status == .conflict,
                  runs[id] == nil, !busy.contains(id) else { return nil }
            return task
        }
        for id in tasks.map(\.id) {
            guard let task = eligible(id), let project = project(task.projectID) else { continue }
            if FileManager.default.fileExists(atPath: task.worktreePath) {
                _ = try? await services.git.commitAll(worktree: task.worktreeURL, message: task.title)
            }
            guard let clean = try? await services.git.canMergeCleanly(repo: project.repoURL, branch: task.branch,
                                                                      base: task.base(in: project)),
                  let now = eligible(id) else { continue }
            let status: TaskStatus = clean ? .completed : .conflict
            guard now.status != status else { continue }
            update(id) { $0.status = status }
            if status == .conflict {
                notify(now)
                reportToChat(now, "has a conflict: it no longer merges cleanly into \(now.base(in: project)).")
            }
        }
    }

    /// Manual permissions: allow or deny the action in `task.approvalRequest`; the agent continues either way.
    public func answerApproval(taskID: TaskItem.ID, allow: Bool) {
        guard services != nil, runs[taskID]?.active == true, var pending = pendingApprovals[taskID],
              !pending.isEmpty, let channel = approvalChannels[taskID] else { return }
        let answered = pending.removeFirst()
        pendingApprovals[taskID] = pending.isEmpty ? nil : pending
        if pending.isEmpty { resumeWorking(taskID) } else { showApproval(taskID) }
        channel.answer(id: answered.id, allow: allow)
    }

    /// The files that keep a conflicting task from merging into its base. Empty if none or unknown.
    public func conflictedFiles(taskID: TaskItem.ID) async -> [String] {
        guard let services, let task = task(taskID), task.status == .conflict, let project = project(task.projectID) else { return [] }
        return (try? await services.git.conflictedFiles(repo: project.repoURL, branch: task.branch,
                                                         base: task.base(in: project))) ?? []
    }

    /// Hands a conflict back to the agent.
    public func resolveConflict(taskID: TaskItem.ID) {
        guard services != nil, let task = task(taskID), task.status == .conflict, !busy.contains(taskID),
              runs[taskID]?.active != true, let project = project(task.projectID) else { return }
        beginWorking(taskID)
        update(taskID) { $0.isResolvingConflict = true }
        startRun(taskID, prompt: """
            This branch no longer merges cleanly into `\(task.base(in: project))`. Merge `\(task.base(in: project))` \
            into this branch, resolve the conflicts keeping the intent of both sides, verify that the \
            project still builds and its tests pass, and commit the result.
            """)
    }

    /// The agent for the task's next prompt. Sessions don't carry over between agents, so it starts a new one
    /// with the task's prompts replayed; the model becomes the project's for that agent. Not while it's working.
    public func setAgent(taskID: TaskItem.ID, to agent: AgentKind) {
        guard let task = task(taskID), task.agent != agent, task.status != .merged, installedAgents[agent] != nil,
              !busy.contains(taskID), !settingUp.contains(taskID), runs[taskID]?.active != true else { return }
        update(taskID) {
            $0.agent = agent
            $0.sessionID = nil
            $0.model = project(task.projectID)?.models[agent]
        }
    }

    /// The model for the task's next prompt; nil is the agent's own default. The project's stays as it is.
    public func setModel(taskID: TaskItem.ID, to model: String?) {
        update(taskID) { $0.model = model }
    }

    /// The permissions for the task's next prompt. The project's stay as they are.
    public func setPermissions(taskID: TaskItem.ID, to permissions: AgentPermissions) {
        update(taskID) { $0.permissions = permissions }
    }

    /// Points the task at another base: its own commits move onto `base` (a rebase), so merging brings
    /// only its work. If they conflict there, the agent moves them. Not while the agent is working.
    public func changeBase(taskID: TaskItem.ID, to base: String) async {
        guard let services, let task = task(taskID), task.status != .merged, !busy.contains(taskID),
              !settingUp.contains(taskID), runs[taskID]?.active != true, let project = project(task.projectID),
              base != task.branch else { return }
        let old = task.base(in: project)
        guard base != old else { return }
        busy.insert(taskID)
        var clean = true
        do {
            // Without a branch there is nothing to move: the task starts from the new base next time.
            if await services.git.branchExists(repo: project.repoURL, branch: task.branch) {
                guard FileManager.default.fileExists(atPath: task.worktreePath) else {
                    throw Failure("The task's folder is missing. Restart its server to recreate it, then change the base.")
                }
                try await services.git.commitAll(worktree: task.worktreeURL, message: task.title)
                clean = try await services.git.rebase(worktree: task.worktreeURL, from: old, onto: base)
            }
        } catch {
            busy.remove(taskID)
            lastError = "Could not change the base of \(task.title): \(Self.firstLine(Self.describe(error)))"
            return
        }
        update(taskID) { $0.baseBranch = base }
        busy.remove(taskID)
        if clean {
            await refreshMergeability()
        } else {
            beginWorking(taskID)
            update(taskID) { $0.isResolvingConflict = true }
            startRun(taskID, prompt: """
                This task's base branch changed from `\(old)` to `\(base)`. Move this branch's own commits onto \
                `\(base)`: `git rebase --onto \(base) $(git merge-base \(old) HEAD)` (or onto `\(base)` if `\(old)` \
                no longer exists). Resolve the conflicts keeping the intent of both sides, verify that the project \
                still builds and its tests pass, and finish the rebase.
                """)
        }
        await refreshPushState(projectID: project.id)
    }

    /// Merges the latest of the task's base into its branch. On a conflict nothing changes and the
    /// conflicting files are returned, for the user to undo or hand to `fixSyncConflict`. Not while the agent works.
    @discardableResult
    public func syncBase(taskID: TaskItem.ID) async -> [String] {
        guard let services, let task = task(taskID), task.status != .merged, !busy.contains(taskID),
              !settingUp.contains(taskID), runs[taskID]?.active != true, let project = project(task.projectID) else { return [] }
        let base = task.base(in: project)
        if let missing = await missingBase(task, project) {
            lastError = "Could not re-sync \(task.title): \(missing)"
            return []
        }
        busy.insert(taskID)
        let clean: Bool
        do {
            guard FileManager.default.fileExists(atPath: task.worktreePath) else {
                throw Failure("The task's folder is missing. Restart its server to recreate it, then re-sync.")
            }
            try await services.git.commitAll(worktree: task.worktreeURL, message: task.title)
            clean = try await services.git.mergeBase(worktree: task.worktreeURL, base: base)
        } catch {
            busy.remove(taskID)
            lastError = "Could not re-sync \(task.title): \(Self.firstLine(Self.describe(error)))"
            return []
        }
        busy.remove(taskID)
        guard !clean else {
            await refreshMergeability()
            return []
        }
        let files = (try? await services.git.conflictedFiles(repo: project.repoURL, branch: task.branch, base: base)) ?? []
        // Unknown files still mean a conflict: the caller must offer the choice.
        return files.isEmpty ? ["(files unknown)"] : files
    }

    /// Hands a re-sync that conflicted to the agent, which merges the base in and resolves it.
    public func fixSyncConflict(taskID: TaskItem.ID) {
        guard services != nil, let task = task(taskID), task.status != .merged, !busy.contains(taskID),
              runs[taskID]?.active != true, let project = project(task.projectID) else { return }
        beginWorking(taskID)
        update(taskID) { $0.isResolvingConflict = true }
        startRun(taskID, prompt: """
            Merge `\(task.base(in: project))` into this branch to bring in its latest changes. Resolve the conflicts \
            keeping the intent of both sides, verify that the project still builds and its tests pass, and commit the result.
            """)
    }

    /// The branch checked out in the project's own folder, which is what it shows.
    public func checkedOutBranch(projectID: Project.ID) async -> String? {
        guard let services, let project = project(projectID) else { return nil }
        return try? await services.git.currentBranch(repo: project.repoURL)
    }

    /// Why the task's base cannot be used, nil when it exists.
    private func missingBase(_ task: TaskItem, _ project: Project) async -> String? {
        guard let services else { return nil }
        let base = task.base(in: project)
        guard await !services.git.branchExists(repo: project.repoURL, branch: base) else { return nil }
        return "The base branch \(base) no longer exists. Pick another one in the task's More menu."
    }

    /// The name the user gave it. From here on the agent can't change it.
    public func rename(taskID: TaskItem.ID, to title: String) {
        let title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return }
        update(taskID) { $0.title = title }
    }

    /// Stops the agent. The task becomes blocked and can be restarted with a prompt.
    public func stop(taskID: TaskItem.ID) {
        guard services != nil, let task = task(taskID), task.status == .working || task.approvalRequest != nil,
              !busy.contains(taskID) else { return }
        // Prompts the agent never got are not sent: they leave the history.
        dropPending(taskID)
        pendingApprovals[taskID] = nil
        // The entry stays (inactive) until the run has wound down, so that a restart can wait for it.
        runs[taskID]?.active = false
        runs[taskID]?.task.cancel()
        update(taskID) { Self.apply(Settled(status: .blocked, blockedReason: TaskItem.stoppedReason), to: &$0) }
    }

    /// Removes the task and all of its resources without merging.
    public func delete(taskID: TaskItem.ID) async {
        guard let services, let task = task(taskID), !busy.contains(taskID) else { return }
        busy.insert(taskID)
        defer { busy.remove(taskID) }
        // Resources first, the record last: if the app dies halfway the task is still there to retry.
        if task.status != .merged { await cleanUp(taskID) }
        for shot in self.task(taskID)?.screenshots ?? [] { try? FileManager.default.removeItem(at: shot.url) }
        tasks.removeAll { $0.id == taskID }
        changed()
        await services.store.deleteLog(taskID: taskID)
    }

    /// Restarts the dev server. If the worktree folder is gone it is recreated first, and the
    /// project's setup command run in it again.
    public func restartServer(taskID: TaskItem.ID) async {
        guard services != nil, let task = task(taskID), task.status != .merged, !busy.contains(taskID),
              !settingUp.contains(taskID) else { return }
        guard FileManager.default.fileExists(atPath: task.worktreePath) else {
            // A run sets its worktree up itself before the agent starts.
            guard runs[taskID] == nil else { return }
            startRun(taskID, prompt: nil)
            await runs[taskID]?.task.value
            return
        }
        if let failure = await startServer(taskID) { lastError = failure }
    }

    /// True while the task's dev server process is alive. Poll it: a server can die at any time.
    public func isServerRunning(taskID: TaskItem.ID) async -> Bool {
        guard let services else { return Self.previewServerRunning(task(taskID)) }
        return await services.servers.isRunning(taskID: taskID)
    }

    /// True while something answers on the task's port: the server is up, not just started.
    /// A server can run without answering: still starting, or crashed inside a watcher that stays alive.
    public func isServerAnswering(taskID: TaskItem.ID) async -> Bool {
        guard let services else { return Self.previewServerRunning(task(taskID)) }
        guard let port = task(taskID)?.port else { return false }
        return await services.ports.isListening(port)
    }

    /// The last 200 lines of the dev server's output, and why it failed to start if it did.
    public func serverLog(taskID: TaskItem.ID) async -> String {
        guard let services else { return Self.previewServerLog }
        let log = await services.servers.log(taskID: taskID, lines: 200)
        guard let failure = serverFailures[taskID] else { return log }
        return log.isEmpty ? failure : log + "\n" + failure
    }

    /// App projects: runs the target's command in the task's worktree. A task can build different targets at the
    /// same time; this does nothing while the target is already building. Returns the Mac app to open: the last
    /// line of the output, if that is the path of a .app. An iOS app is run on a simulator right here instead.
    public func build(taskID: TaskItem.ID, target targetID: BuildTarget.ID) async -> URL? {
        let key = BuildKey(taskID: taskID, targetID: targetID)
        guard let services, let task = task(taskID), task.status != .merged, let project = project(task.projectID),
              project.isApp, builds[key] != .building,
              let chosen = project.targets.first(where: { $0.id == targetID }), chosen.kind != .run else { return nil }
        guard FileManager.default.fileExists(atPath: task.worktreePath) else {
            builds[key] = .failed("The task's folder is recreated the next time the agent runs.")
            return nil
        }
        let target = ProjectSetup.resolved(chosen, in: task.worktreeURL)
        let command = target.command
        guard !command.isEmpty else {
            builds[key] = .failed("Nothing to build yet. Add a build command in the project's settings.")
            return nil
        }
        builds[key] = .building
        update(taskID) { $0.lastBuiltTargetID = targetID }
        let run = Task {
            try await services.servers.run(command: command, directory: task.worktreeURL, environment: [
                "SHIFT_REPO": project.repoPath, "SHIFT_WORKTREE": task.worktreePath, "SHIFT_TASK": String(taskID),
                "SHIFT_TARGET": target.name])
        }
        buildRuns[key] = run
        let result = await run.result
        // Deleted or merged meanwhile: nothing left to report on.
        guard buildRuns[key] == run else { return nil }
        buildRuns[key] = nil
        switch result {
        case .success(let result):
            buildLogs[key] = "$ \(command)\n" + result.output
            guard result.exitCode == 0 else {
                builds[key] = .failed("Build failed (exit code \(result.exitCode)).")
                return nil
            }
            guard target.kind != .script else {
                builds[key] = .succeeded(app: nil)
                return nil
            }
            let last = result.output.split(whereSeparator: \.isNewline).last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let app = last.hasSuffix(".app") && FileManager.default.fileExists(atPath: last)
                ? URL(fileURLWithPath: last) : nil
            guard target.kind == .iOSSimulator else {
                builds[key] = .succeeded(app: app)
                return app
            }
            guard let app else {
                builds[key] = .failed("The build didn't print the path of a .app, so there is nothing to run.")
                return nil
            }
            await runOnSimulator(app, key: key, services: services)
            return nil
        case .failure(let error):
            builds[key] = .failed("Build could not start: \(Self.describe(error))")
            return nil
        }
    }

    /// With the same isolation a Mac build gets from SHIFT_HOME. The target counts as building until it's launched.
    private func runOnSimulator(_ app: URL, key: BuildKey, services: Services) async {
        var failure: String?
        if let simulators = services.simulators {
            do {
                let home = ShiftPaths.build(taskID: key.taskID)
                var environment = ["SIMCTL_CHILD_SHIFT_HOME": home.path]
                // A build of Shift's own iOS app talks to the task's Mac build. Other apps ignore it.
                if services.remote != nil { environment["SIMCTL_CHILD_SHIFT_SERVER"] = RemoteListener.localServer(home: home, taskID: key.taskID) }
                try await simulators.run(app: app, environment: environment)
            } catch {
                failure = Self.describe(error)
            }
        } else {
            failure = "This version of Shift can't run iOS apps."
        }
        // Deleted or merged meanwhile: nothing left to report on.
        guard builds[key] == .building else { return }
        if let failure {
            buildLogs[key, default: ""] += "\n" + failure
            builds[key] = .failed("Could not run on the simulator: \(Self.firstLine(failure))")
        } else {
            builds[key] = .succeeded(app: app)
        }
    }

    /// Electron and the like: opens the task's app. It gets a home folder of its own, so copies from different tasks
    /// run side by side: no shared data and no single-instance lock. It starts with empty data, kept between runs.
    /// Runs as the task's server, for its log and to be stopped with the task, but it has no port.
    // ponytail: one per task, since that's what the server slot holds; starting another `.run` target replaces it.
    // ponytail: macOS only hook (CoreFoundation's home override), fine while Shift is a Mac app.
    public func runApp(taskID: TaskItem.ID, target targetID: BuildTarget.ID) async {
        let key = BuildKey(taskID: taskID, targetID: targetID)
        guard let services, let task = task(taskID), task.status != .merged, let project = project(task.projectID),
              let target = project.targets.first(where: { $0.id == targetID }), target.kind == .run else { return }
        guard FileManager.default.fileExists(atPath: task.worktreePath) else {
            builds[key] = .failed("The task's folder is recreated the next time the agent runs.")
            return
        }
        builds[key] = nil
        let command = "export CFFIXED_USER_HOME=\"\(ShiftPaths.build(taskID: taskID).path)\"; "
            + "export SHIFT_TARGET=\(ProjectSetup.quoted(target.name)); \(target.command)"
        do {
            let pid = try await services.servers.start(taskID: taskID, command: command, directory: task.worktreeURL, port: 0)
            guard self.task(taskID)?.status != .merged else {
                await services.servers.stop(taskID: taskID)
                return
            }
            runningTargets[taskID] = targetID
            update(taskID) { $0.serverPID = pid; $0.lastBuiltTargetID = targetID }
        } catch {
            builds[key] = .failed("The app could not start: \(Self.firstLine(Self.describe(error)))")
        }
    }

    public func stopApp(taskID: TaskItem.ID) async {
        await services?.servers.stop(taskID: taskID)
        runningTargets[taskID] = nil
        update(taskID) { $0.serverPID = nil }
    }

    /// The latest build of the target since launch. Nil: not built yet.
    public func buildState(taskID: TaskItem.ID, target: BuildTarget.ID) -> BuildState? {
        builds[BuildKey(taskID: taskID, targetID: target)]
    }

    /// The output of the target's last build.
    public func buildLog(taskID: TaskItem.ID, target: BuildTarget.ID) -> String {
        let key = BuildKey(taskID: taskID, targetID: target)
        return buildLogs[key] ?? (builds[key] == .building ? "Building…" : "")
    }

    /// What to build for this task: the target whose paths match the most files the task changed against its
    /// base, else the one last built for it, else the first.
    public func suggestedTarget(taskID: TaskItem.ID) async -> BuildTarget? {
        guard let task = task(taskID), let targets = project(task.projectID)?.targets else { return nil }
        // A question with one answer: no need to read the diff.
        guard targets.count > 1 else { return targets.first }
        let changed = await changes(taskID: taskID)?.files.map(\.path) ?? []
        return BuildTarget.suggested(among: targets, changed: changed, lastBuilt: task.lastBuiltTargetID)
    }

    /// nil if they could not be read; `loadChanges` says why.
    public func changes(taskID: TaskItem.ID) async -> DiffSummary? {
        try? await loadChanges(taskID: taskID).get()
    }

    /// Empty if it could not be read; `loadDiff` says why.
    public func diff(taskID: TaskItem.ID) async -> [FileDiff] {
        (try? await loadDiff(taskID: taskID).get()) ?? []
    }

    public func loadChanges(taskID: TaskItem.ID) async -> Result<DiffSummary, Error> {
        await readDiff(taskID) { git, worktree, base in try await git.changes(worktree: worktree, base: base) }
            ?? .success(DiffSummary(files: Self.previewDiff(task(taskID)).map(\.change)))
    }

    public func loadDiff(taskID: TaskItem.ID) async -> Result<[FileDiff], Error> {
        await readDiff(taskID) { git, worktree, base in try await git.diff(worktree: worktree, base: base) }
            ?? .success(Self.previewDiff(task(taskID)))
    }

    /// Files for the two sides of a changed image, for thumbnails and Quick Look: the worktree's copy after,
    /// and the base's copy before, written to a temporary folder. nil for a side that doesn't exist.
    public func imageVersions(taskID: TaskItem.ID, change: FileChange) async -> (before: URL?, after: URL?) {
        guard let task = task(taskID) else { return (nil, nil) }
        let after = change.kind == .deleted ? nil : task.worktreeURL.appendingPathComponent(change.path)
        guard change.kind != .added else { return (nil, after) }
        let oldPath = change.oldPath ?? change.path
        guard let data = await readDiff(taskID, { git, worktree, base in
            try await git.baseContents(worktree: worktree, base: base, path: oldPath)
        }).flatMap({ try? $0.get() }) else { return (nil, after) }
        // Its own folder, so Quick Look shows the file's real name.
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("shift-diff-\(UUID().uuidString)")
        let before = folder.appendingPathComponent((oldPath as NSString).lastPathComponent)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: before)
        } catch { return (nil, after) }
        return (before, after)
    }

    /// nil for the preview model.
    private func readDiff<T>(_ id: TaskItem.ID, _ read: (GitServicing, URL, String) async throws -> T) async -> Result<T, Error>? {
        guard let services else { return nil }
        guard let task = task(id), let project = project(task.projectID) else {
            return .failure(Failure("The task no longer exists."))
        }
        guard FileManager.default.fileExists(atPath: task.worktreePath) else {
            return .failure(Failure("The task's worktree folder is missing. Restart its server to recreate it."))
        }
        do { return .success(try await read(services.git, task.worktreeURL, task.base(in: project))) } catch {
            return .failure(Failure(Self.firstLine(Self.describe(error))))
        }
    }

    /// Raw agent output.
    public func rawOutput(taskID: TaskItem.ID) async -> String {
        guard let services else { return "" }
        return await services.store.readLog(taskID: taskID)
    }

    /// Serves the port on the tailnet, for a phone. nil: Tailscale isn't running, or is set up without HTTPS.
    func shareOnTailnet(port: Int, local: Int? = nil) async -> (host: String, owner: String)? {
        guard let tailscale = services?.tailscale, let host = await tailscale.serve(port: port, local: local),
              let owner = await tailscale.ownerLogin() else { return nil }
        return (host, owner)
    }

    func stopSharingOnTailnet(port: Int) async {
        await services?.tailscale?.unserve(port: port)
    }

    /// Reads the task's log as a conversation. nil for the preview model.
    public func transcript(taskID: TaskItem.ID) -> TranscriptReader? {
        guard let services, let agent = task(taskID)?.agent else { return nil }
        return TranscriptReader(log: .task(taskID), store: services.store, agent: agent)
    }

    // MARK: - Project chat

    public func chat(projectID: Project.ID) -> ProjectChat? {
        chats.first { $0.projectID == projectID }
    }

    /// Reads the chat's log as a conversation. nil if the chat has not been used, and for the preview model.
    public func chatTranscript(projectID: Project.ID) -> TranscriptReader? {
        guard let services, let chat = chat(projectID: projectID), let project = project(projectID) else { return nil }
        return TranscriptReader(log: .chat(chat.id), store: services.store, agent: chat.agent ?? project.defaultAgent)
    }

    /// Manual permissions: what the chat's agent is asking to do right now.
    public func chatApprovalRequest(projectID: Project.ID) -> String? {
        chatApprovals[projectID]?.first?.summary
    }

    /// Manual permissions: allow or deny `chatApprovalRequest`; the agent continues either way.
    public func answerChatApproval(projectID: Project.ID, allow: Bool) {
        guard let channel = chatRuns[projectID]?.channel, let answered = chatApprovals[projectID]?.first else { return }
        chatApprovals[projectID]?.removeFirst()
        channel.answer(id: answered.id, allow: allow)
    }

    /// Sends a message to the project's chat. While the agent replies it goes into the running session as
    /// soon as it can take it, or else into a next turn.
    /// `/task <prompt>` starts a new task instead.
    public func sendChat(projectID: Project.ID, text: String, attachments: [String] = []) {
        if let prompt = Self.taskCommand(text) {
            createTask(projectID: projectID, prompt: prompt, attachments: attachments)
            return
        }
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard services != nil, project(projectID) != nil, !text.isEmpty || !attachments.isEmpty else { return }
        chatErrors[projectID] = nil
        guard chatRuns[projectID]?.active == true else {
            let prompt = Prompt(text: text, attachments: attachments)
            updateChat(projectID) { $0.prompts.append(prompt) }
            startChatRun(projectID, prompt: prompt)
            return
        }
        let prompt = Prompt(text: text, isPending: true, attachments: attachments)
        updateChat(projectID) { $0.prompts.append(prompt) }
        // A message instead of an answer to an approval request denies it, and goes to the agent
        // with the denial if the agent takes a message.
        if let pending = chatApprovals.removeValue(forKey: projectID), let first = pending.first,
           let channel = chatRuns[projectID]?.channel {
            pending.dropFirst().forEach { channel.answer(id: $0.id, allow: false) }
            if channel.answer(id: first.id, allow: false, message: prompt.agentText) {
                markChatDelivered(projectID, prompt)
                return
            }
        }
        deliverChatPending(projectID)
    }

    /// Stops the reply. What the agent never got is not sent.
    public func stopChat(projectID: Project.ID) {
        if chat(projectID: projectID) != nil { updateChat(projectID) { $0.prompts.removeAll(where: \.isPending) } }
        // The entry stays (inactive) until the run has wound down, so that the next one can wait for it.
        chatRuns[projectID]?.active = false
        chatRuns[projectID]?.task.cancel()
        chatApprovals[projectID] = nil
        replyingChats.remove(projectID)
    }

    /// Forgets the conversation: the next message starts a new session.
    public func newChat(projectID: Project.ID) async {
        guard let services, let old = chat(projectID: projectID) else { return }
        await cancelChat(projectID)
        chatReports[projectID] = nil
        await services.store.deleteChatLog(chatID: old.id)
        chats.removeAll { $0.projectID == projectID }
        chatErrors[projectID] = nil
        changed()
    }

    /// From here on the project's chat hears how the task goes, until the chat is replaced by a new one.
    func follow(taskID: TaskItem.ID) {
        guard let task = task(taskID), let chat = chat(projectID: task.projectID) else { return }
        update(taskID) { $0.chatID = chat.id }
    }

    /// Tells the chat that follows the task what happened, in the reply under way or in a new one.
    /// ponytail: a task waiting for an approval doesn't wake the chat (it would for every command in Manual);
    /// the user gets a notification and the chat sees it in `shiftctl tasks`.
    private func reportToChat(_ task: TaskItem, _ text: String) {
        guard let chatID = task.chatID, chat(projectID: task.projectID)?.id == chatID else { return }
        chatReports[task.projectID, default: []].append("[Shift] Task \(task.id) “\(task.title)” \(text)")
        if chatRuns[task.projectID]?.active == true {
            deliverChatPending(task.projectID)
        } else {
            startChatRun(task.projectID, prompt: nil)
        }
    }

    private func updateChat(_ projectID: Project.ID, _ change: (inout ProjectChat) -> Void) {
        if let index = chats.firstIndex(where: { $0.projectID == projectID }) {
            change(&chats[index])
        } else {
            var chat = ProjectChat(projectID: projectID)
            change(&chat)
            chats.append(chat)
        }
        changed()
    }

    private func isChatCurrent(_ projectID: Project.ID, _ token: UUID) -> Bool {
        guard let run = chatRuns[projectID] else { return false }
        return run.token == token && run.active
    }

    /// Returns when the chat's run, if any, has completely stopped.
    private func cancelChat(_ projectID: Project.ID) async {
        stopChat(projectID: projectID)
        while let run = chatRuns.removeValue(forKey: projectID) {
            run.task.cancel()
            await run.task.value
        }
    }

    /// `prompt` nil: there is only `chatReports` to tell the agent.
    private func startChatRun(_ projectID: Project.ID, prompt: Prompt?) {
        let previous = chatRuns[projectID]?.task
        let token = UUID()
        let task = Task { [weak self] in
            // Never two runs of one session: the one before has to be completely gone first.
            await previous?.value
            await self?.runChat(projectID, token: token, prompt: prompt?.agentText ?? "", promptIDs: prompt.map { [$0.id] } ?? [])
        }
        chatRuns[projectID] = ChatRun(token: token, task: task)
        replyingChats.insert(projectID)
    }

    /// Runs agent turns until one ends with nothing pending. The agent can do anything to the project's
    /// repository, so what Shift knows about it is read again afterwards.
    private func runChat(_ projectID: Project.ID, token: UUID, prompt: String, promptIDs: [Prompt.ID]) async {
        defer {
            if chatRuns[projectID]?.token == token {
                chatRuns[projectID] = nil
                chatApprovals[projectID] = nil
                replyingChats.remove(projectID)
            }
            Task { [weak self] in
                await self?.adoptDetectedType(projectID)
                await self?.refreshPushState(projectID: projectID)
                await self?.refreshMergeability()
            }
        }
        guard let services else { return }
        var prompt = prompt, promptIDs = promptIDs, blips = 0
        while isChatCurrent(projectID, token) {
            guard let project = project(projectID), let log = chat(projectID: projectID)?.id else { return }
            let kind = project.defaultAgent
            guard installedAgents[kind] != nil, let adapter = services.agents[kind] else {
                updateChat(projectID) { $0.prompts.removeAll(where: \.isPending) }
                chatErrors[projectID] = "\(kind.displayName) is not installed."
                return
            }
            // Sessions don't carry over from one agent to another.
            var note: String?
            if let old = chat(projectID: projectID), old.sessionID != nil, old.agent != kind {
                note = "The project's agent is now \(kind.displayName), so this is a new session. It doesn't know what was said above."
                updateChat(projectID) { $0.sessionID = nil }
            }
            updateChat(projectID) { $0.agent = kind }
            let pending = chat(projectID: projectID)?.prompts.filter(\.isPending) ?? []
            let reports = chatReports.removeValue(forKey: projectID) ?? []
            let text = ([prompt] + reports + pending.map(\.agentText)).filter { !$0.isEmpty }.joined(separator: "\n\n")
            let delivered = promptIDs + pending.map(\.id)
            updateChat(projectID) { chat in
                for index in chat.prompts.indices { chat.prompts[index].isPending = false }
            }
            await services.store.appendChatLog(chatID: log, text: RunMarker.line(
                agent: kind, promptIDs: delivered, text: reports.isEmpty ? nil : reports.joined(separator: "\n"), note: note))
            guard isChatCurrent(projectID, token) else { return }

            let channel = ApprovalChannel()
            chatRuns[projectID]?.channel = channel
            let request = AgentRequest(prompt: text, sessionID: chat(projectID: projectID)?.sessionID, worktree: project.repoURL,
                                       environment: controlEnvironment(projectID),
                                       permissions: project.permissions, model: project.models[kind], needsDescription: false,
                                       approvals: channel, chat: true,
                                       chatContext: OutcomeProtocol.chatContext(tasks: tasks(in: projectID), project: project))
            var failure: String?
            events: for await event in adapter.run(request) {
                guard isChatCurrent(projectID, token) else { return }
                switch event {
                case .sessionStarted(let id): updateChat(projectID) { $0.sessionID = id }
                case .rawOutput(let output): await services.store.appendChatLog(chatID: log, text: output + "\n")
                case .finished(let outcome):
                    if case .blocked(let reason, _) = outcome { failure = reason }
                    break events
                case .approvalRequested(let id, let summary): chatApprovals[projectID, default: []].append((id, summary))
                case .activity, .described, .screenshots: break
                }
                guard isChatCurrent(projectID, token) else { return }
                deliverChatPending(projectID)
            }
            guard isChatCurrent(projectID, token) else { return }
            chatRuns[projectID]?.channel = nil
            chatApprovals[projectID] = nil
            if let reason = failure,
               (try? await waitsForInternet(after: reason, blips: &blips, isCurrent: { isChatCurrent(projectID, token) })) == true {
                // The same message again: a chat has no task to carry on with, and it may not have reached the agent.
                prompt = text
                promptIDs = []
                continue
            }
            guard isChatCurrent(projectID, token) else { return }
            chatErrors[projectID] = failure

            // From here to the end of the iteration there is no await: a message sent now either
            // is pending already, or finds the run over and starts one of its own.
            let more = chat(projectID: projectID)?.prompts.filter(\.isPending) ?? []
            // Reports stay for the next run if this one failed: the agent still has to hear them.
            guard !more.isEmpty || chatReports[projectID] != nil, failure == nil else {
                updateChat(projectID) { $0.prompts.removeAll(where: \.isPending) }
                return
            }
            prompt = more.map(\.agentText).joined(separator: "\n\n")
            promptIDs = more.map(\.id)
            updateChat(projectID) { chat in
                for index in chat.prompts.indices { chat.prompts[index].isPending = false }
            }
        }
    }

    /// What `shiftctl` needs to reach this project, and nothing else, from the chat's agent.
    private func controlEnvironment(_ projectID: Project.ID) -> [String: String] {
        guard let controlPort else { return [:] }
        let token = controlTokens.first { $0.value == projectID }?.key ?? UUID().uuidString
        controlTokens[token] = projectID
        return ["SHIFT_URL": "http://127.0.0.1:\(controlPort)", "SHIFT_ACCESS": token]
    }

    private func deliverChatPending(_ projectID: Project.ID) {
        guard let channel = chatRuns[projectID]?.channel, let chat = chat(projectID: projectID) else { return }
        while let report = chatReports[projectID]?.first, channel.send(report) {
            chatReports[projectID]?.removeFirst()
            if chatReports[projectID]?.isEmpty == true { chatReports[projectID] = nil }
            if let services, let agent = chat.agent {
                Task { await services.store.appendChatLog(chatID: chat.id, text: RunMarker.line(agent: agent, promptIDs: [], text: report)) }
            }
        }
        for prompt in chat.prompts where prompt.isPending {
            guard channel.send(prompt.agentText) else { return }
            markChatDelivered(projectID, prompt)
        }
    }

    private func markChatDelivered(_ projectID: Project.ID, _ prompt: Prompt) {
        guard let services, let chat = chat(projectID: projectID), let agent = chat.agent else { return }
        Task { await services.store.appendChatLog(chatID: chat.id, text: RunMarker.line(agent: agent, promptIDs: [prompt.id])) }
        updateChat(projectID) {
            if let index = $0.prompts.firstIndex(where: { $0.id == prompt.id }) { $0.prompts[index].isPending = false }
        }
    }

    // MARK: - Runs

    private func isCurrent(_ id: TaskItem.ID, _ token: UUID) -> Bool {
        guard let run = runs[id] else { return false }
        return run.token == token && run.active
    }

    /// Called after every await inside a run, before touching the task.
    private func check(_ id: TaskItem.ID, _ token: UUID) throws {
        guard isCurrent(id, token) else { throw CancellationError() }
    }

    private func beginWorking(_ id: TaskItem.ID) {
        update(id) {
            $0.status = .working
            $0.question = nil
            $0.approvalRequest = nil
            $0.options = nil
            $0.blockedReason = nil
            $0.activity = nil
            $0.isResolvingConflict = false
            $0.workingSince = Date()
        }
    }

    /// Shows the oldest unanswered approval request and tells the user.
    private func showApproval(_ id: TaskItem.ID) {
        guard services != nil, let summary = pendingApprovals[id]?.first?.summary, let task = task(id) else { return }
        let isNew = task.approvalRequest != summary || task.status != .needsInput
        update(id) {
            $0.status = .needsInput
            $0.approvalRequest = summary
            $0.activity = nil
        }
        if isNew {
            notify(task, needsAttention: true)
        }
    }

    /// Back to work after the last approval request was answered, within the same run.
    private func resumeWorking(_ id: TaskItem.ID) {
        update(id) {
            $0.status = .working
            $0.approvalRequest = nil
        }
    }

    /// `prompt` nil: only set the worktree up (Restart Server), unless prompts arrive meanwhile.
    /// `promptIDs`: the `Prompt`s that `prompt` is, if it's the user's and not Shift's own instructions.
    private func startRun(_ id: TaskItem.ID, prompt: String?, promptIDs: [Prompt.ID] = []) {
        let previous = runs[id]?.task
        previous?.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            // Never two runs in one worktree: the one before has to be completely gone first.
            await previous?.value
            await self?.run(id, token: token, prompt: prompt, promptIDs: promptIDs)
        }
        runs[id] = Run(token: token, task: task)
    }

    private func run(_ id: TaskItem.ID, token: UUID, prompt: String?, promptIDs: [Prompt.ID]) async {
        defer {
            if runs[id]?.token == token { runs[id] = nil }
            serverUsed[id] = .now
        }
        do {
            try check(id, token)
            // New, or its folder is gone (deleted, or never finished before a crash).
            if let task = task(id), !FileManager.default.fileExists(atPath: task.worktreePath) {
                try await setUp(id, token: token)
            }
            var prompt = prompt, promptIDs = promptIDs
            if prompt == nil {
                promptIDs = pendingIDs(id)
                let pending = takePending(id)
                guard !pending.isEmpty else { return }
                beginWorking(id)
                prompt = pending
            }
            // The agent may test its work on the server.
            await wakeServer(id)
            try check(id, token)
            try await converse(id, token: token, prompt: prompt ?? "", promptIDs: promptIDs)
        } catch {
            // Not current any more: whoever cancelled this run has already decided the status.
            guard isCurrent(id, token) else { return }
            dropPending(id)
            finish(id, Settled(status: .blocked, blockedReason: Self.describe(error)))
        }
    }

    /// Worktree (the task's branch if it still exists, else a new one from base), port, setup
    /// command and dev server. Leaves nothing behind if it fails or is cancelled.
    private func setUp(_ id: TaskItem.ID, token: UUID) async throws {
        guard let services, let task = task(id) else { throw CancellationError() }
        guard let project = project(task.projectID) else { throw Failure("The project no longer exists.") }
        settingUp.insert(id)
        defer { settingUp.remove(id) }
        var created = false, createdBranch = false
        do {
            let hasBranch = await services.git.branchExists(repo: project.repoURL, branch: task.branch)
            try check(id, token)
            if hasBranch {
                try await services.git.addWorktree(repo: project.repoURL, branch: task.branch, at: task.worktreeURL)
            } else {
                if let missing = await missingBase(task, project) { throw Failure(missing) }
                try await services.git.createWorktree(repo: project.repoURL, branch: task.branch,
                                                      base: task.base(in: project), at: task.worktreeURL)
                createdBranch = true
            }
            created = true
            try check(id, token)
            // A branch made from base has none of the old work: nothing to resume, the prompts replay.
            if createdBranch && task.sessionID != nil { update(id) { $0.sessionID = nil } }
            var port = task.port
            if port == nil && !project.isApp {
                let reserved = Set(tasks.filter { $0.id != id && $0.status != .merged }.compactMap(\.port)).union(basePorts.values)
                port = await services.ports.allocate(preferred: id, reserved: reserved)
                try check(id, token)
                update(id) { $0.port = port }
            }
            try await prepare(id, project: project, port: port)
            try check(id, token)
            update(id) { $0.activity = nil }
            await startServer(id)
            try check(id, token)
        } catch {
            // Only undo what this attempt created: a branch that was already there is not ours to delete.
            if created {
                await services.servers.stop(taskID: id)
                try? await services.git.removeWorktree(repo: project.repoURL, path: task.worktreeURL,
                                                       deleteBranch: createdBranch ? task.branch : nil)
                update(id) { $0.port = nil; $0.serverPID = nil }
            }
            throw error
        }
    }

    /// Runs the project's setup command in the fresh worktree. Throws if it fails.
    private func prepare(_ id: TaskItem.ID, project: Project, port: Int?) async throws {
        let command = project.setupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let services, let task = task(id), !command.isEmpty else { return }
        update(id) { $0.activity = "Setting up…" }
        await services.store.appendLog(taskID: id, text: "$ \(command)\n")
        var environment = ["SHIFT_REPO": project.repoPath, "SHIFT_WORKTREE": task.worktreePath]
        environment["PORT"] = port.map(String.init)
        let result = try await services.servers.run(command: command, directory: task.worktreeURL,
                                                    environment: environment)
        await services.store.appendLog(taskID: id, text: result.output)
        guard result.exitCode == 0 else { throw Failure(ProjectSetup.failure(result)) }
        // What setup created (dependencies, a copied .env) is not the task's work. If this fails the
        // task must not start: the agent's commit would take those files with it.
        try await services.git.excludeUntracked(worktree: task.worktreeURL)
    }

    /// The task's agent, or, if that one is not installed, the project's default agent, which the
    /// task switches to for good (a new session: sessions do not carry over, the prompts replay).
    private func adapter(for id: TaskItem.ID) throws -> AgentAdapter {
        guard let services, let task = task(id) else { throw CancellationError() }
        if installedAgents[task.agent] != nil, let adapter = services.agents[task.agent] { return adapter }
        if let fallback = project(task.projectID)?.defaultAgent, installedAgents[fallback] != nil,
           let adapter = services.agents[fallback] {
            update(id) {
                $0.agent = fallback
                $0.sessionID = nil
                $0.model = project(task.projectID)?.models[fallback]
            }
            return adapter
        }
        throw Failure("\(task.agent.displayName) is not installed.")
    }

    /// Runs agent turns until one ends with nothing pending, then settles the task.
    private func converse(_ id: TaskItem.ID, token: UUID, prompt: String, promptIDs: [Prompt.ID]) async throws {
        guard let services else { return }
        var prompt = prompt, promptIDs = promptIDs, blips = 0
        while true {
            var shots = await screenshotTurn(id)
            let screenshots = shots.map { $0.isApp ? ScreenshotRequest.app(wantsBefore: $0.wantsBefore) : .page }
            try check(id, token)
            let adapter = try adapter(for: id)
            guard let task = task(id) else { throw CancellationError() }
            // Without a session there is nothing to resume, so the agent needs the whole story.
            let replay = task.sessionID == nil && !task.isResolvingConflict
            // Prompts sent while it was being set up go in with this turn's prompt.
            let delivered = promptIDs + pendingIDs(id)
            let text = replay ? task.prompts.map(\.agentText).joined(separator: "\n\n")
                : [prompt, takePending(id)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            markDelivered(id)
            let channel = ApprovalChannel()
            let request = AgentRequest(prompt: text, sessionID: task.sessionID, worktree: task.worktreeURL,
                                       environment: task.port.map { ["PORT": String($0)] } ?? [:],
                                       permissions: task.permissions ?? project(task.projectID)?.permissions ?? .bypass,
                                       // A fallback agent (see `adapter(for:)`) doesn't run the other one's model.
                                       model: adapter.kind == task.agent ? task.model : project(task.projectID)?.models[adapter.kind],
                                       needsDescription: task.description == nil && !task.isResolvingConflict,
                                       description: task.description,
                                       approvals: channel, screenshots: screenshots)
            approvalChannels[id] = channel
            await services.store.appendLog(taskID: id, text: RunMarker.line(
                agent: adapter.kind, promptIDs: delivered, text: delivered.isEmpty ? prompt : nil))
            defer {
                // Whatever this agent run asked is moot once it is over.
                if approvalChannels[id] === channel {
                    approvalChannels[id] = nil
                    pendingApprovals[id] = nil
                }
            }

            var outcome = AgentOutcome.blocked(reason: "The agent stopped unexpectedly.")
            events: for await event in adapter.run(request) {
                try check(id, token)
                switch event {
                case .sessionStarted(let sessionID): update(id) { $0.sessionID = sessionID }
                case .activity(let line): update(id) { $0.activity = line }
                case .described(let title, let description):
                    // The prompt of a conflict resolution is ours; it does not change what the task is for.
                    if !task.isResolvingConflict {
                        update(id) {
                            // Named once: only the local title gives way, never the agent's or the user's.
                            if let title, $0.hasLocalTitle { $0.title = title }
                            $0.description = description ?? $0.description
                        }
                    }
                case .screenshots(let targets):
                    shots?.pagesNamed += 1
                    shots?.targets = targets
                    // Not awaited: the agent may be waiting for an answer to an approval meanwhile.
                    if shots?.wantsBefore == true, let target = targets.first, let diff = shots?.diff {
                        shots?.before = Task { await takeBeforeScreenshot(id, target, unchangedFrom: diff) }
                    }
                    shots?.wantsBefore = false
                case .rawOutput(let output): await services.store.appendLog(taskID: id, text: output + "\n")
                case .approvalRequested(let approvalID, let summary):
                    pendingApprovals[id, default: []].append((approvalID, summary))
                    showApproval(id)
                case .finished(let result):
                    outcome = result
                    break events
                }
                // Prompts the agent could not take yet: it may be able to now.
                try check(id, token)
                deliverPending(id)
            }
            try check(id, token)
            if case .blocked(let reason, _) = outcome {
                update(id) { $0.activity = nil }
                if try await waitsForInternet(after: reason, blips: &blips, isCurrent: { isCurrent(id, token) }) {
                    prompt = Self.continuePrompt
                    promptIDs = []
                    continue
                }
            }
            let settled = await settle(id, outcome)
            try check(id, token)
            // The agent may have created the project (a package.json with a dev script): serve that now.
            if let now = self.task(id), let owner = self.project(now.projectID), serverCommands[id] != nil,
               serverCommands[id] != ProjectSetup.serverCommand(for: owner, in: now.worktreeURL) {
                await startServer(id)
                try check(id, token)
            }
            if let shots {
                await takeAfterScreenshot(id, shots)
                try check(id, token)
            }

            // From here to the end of the iteration there is no await: a prompt sent now either
            // is pending already, or finds the task settled and starts a run of its own.
            let moreIDs = pendingIDs(id)
            let more = takePending(id)
            if !more.isEmpty {
                prompt = more
                promptIDs = moreIDs
                continue
            }
            finish(id, settled)
            return
        }
    }

    // MARK: - Screenshots

    /// What one agent turn needs to know to take its screenshots.
    private struct ScreenshotTurn {
        /// The task's changes when the turn started: a prompt that leaves them as they are gets no screenshot.
        let diff: [FileDiff]
        /// Nothing has changed yet, so the next page named can still be shot as it was.
        var wantsBefore: Bool
        /// The agent takes the screenshots and a target is the image it took, as an app has no page to load.
        let isApp: Bool
        /// The home page unless the agent names something else. An app's agent has to name one. Empty: nothing visible changes.
        var targets: [ScreenshotTarget]
        var pagesNamed = 0
        /// Whether it got a screenshot.
        var before: Task<Bool, Never>?
    }

    /// Nil if this turn takes no screenshots. Conflict resolutions are Shift's own prompts, not the user's.
    private func screenshotTurn(_ id: TaskItem.ID) async -> ScreenshotTurn? {
        guard let services, services.screenshots != nil, let task = task(id), let project = project(task.projectID),
              project.takesScreenshots, project.isApp || task.port != nil, !task.isResolvingConflict,
              let diff = try? await services.git.diff(worktree: task.worktreeURL, base: task.base(in: project)) else { return nil }
        let wantsBefore = diff.isEmpty && task.screenshots?.contains(where: \.isBefore) != true
        // The agent starts as soon as this returns, and the "before" has to beat its first edit.
        if wantsBefore && !project.isApp { _ = await serverAnswers(id) }
        return ScreenshotTurn(diff: diff, wantsBefore: wantsBefore, isApp: project.isApp,
                              targets: project.isApp ? [] : [ScreenshotTarget(page: "/")])
    }

    /// ponytail: checked only once, before the page loads; an edit during the seconds it takes can end up in the
    /// picture. Checking after too would drop good ones: dev servers rewrite tracked files on first compile.
    private func takeBeforeScreenshot(_ id: TaskItem.ID, _ target: ScreenshotTarget, unchangedFrom diff: [FileDiff]) async -> Bool {
        guard let services, let task = task(id), let project = project(task.projectID),
              (try? await services.git.diff(worktree: task.worktreeURL, base: task.base(in: project))) == diff else { return false }
        // A page as it loads: what a script would select is what the agent is about to build.
        return await takeScreenshot(id, project.isApp ? target : ScreenshotTarget(page: target.page), isBefore: true)
    }

    private func takeAfterScreenshot(_ id: TaskItem.ID, _ shots: ScreenshotTurn) async {
        let tookBefore = await shots.before?.value ?? false
        // A page is loaded again, but an app's image is what it was: it can't be the "after" too.
        if shots.isApp && tookBefore && shots.pagesNamed < 2 { return }
        guard let services, !shots.targets.isEmpty, let task = task(id), let project = project(task.projectID),
              let diff = try? await services.git.diff(worktree: task.worktreeURL, base: task.base(in: project)),
              diff != shots.diff else { return }
        update(id) { $0.activity = "Taking a screenshot…" }
        for target in shots.targets { await takeScreenshot(id, target, isBefore: false) }
    }

    @discardableResult
    private func takeScreenshot(_ id: TaskItem.ID, _ target: ScreenshotTarget, isBefore: Bool) async -> Bool {
        guard let services, let screenshots = services.screenshots, let task = task(id),
              let project = project(task.projectID) else { return false }
        let file = ShiftPaths.screenshots.appendingPathComponent("\(id)-\(UUID().uuidString).png")
        let source: URL, captured: Bool
        var shown = target.page
        if project.isApp {
            // The line is a path, and any space in it looks like the start of a script.
            let path = [target.page, target.script].compactMap { $0 }.joined(separator: " ")
            source = URL(fileURLWithPath: path, relativeTo: task.worktreeURL).absoluteURL
            shown = source.deletingPathExtension().lastPathComponent
            captured = await screenshots.copyImage(at: source, to: file)
        } else {
            guard let server = task.serverURL else { return false }
            source = Self.screenshotURL(page: target.page, server: server)
            captured = await serverAnswers(id) ? await screenshots.capture(url: source, script: target.script, to: file) : false
        }
        guard captured else {
            await services.store.appendLog(taskID: id, text: "Could not take a screenshot of \(source.absoluteString)\n")
            return false
        }
        // Deleted meanwhile: nothing will ever clean this one up.
        guard self.task(id) != nil else {
            try? FileManager.default.removeItem(at: file)
            return false
        }
        let shot = TaskScreenshot(path: file.path, isBefore: isBefore, page: shown)
        update(id) { $0.screenshots = ($0.screenshots ?? []) + [shot] }
        return true
    }

    /// `page` on the task's server. The agent wrote it, so anything that leads elsewhere means the home page.
    static func screenshotURL(page: String, server: URL) -> URL {
        guard let url = URL(string: page, relativeTo: server)?.absoluteURL,
              url.host == server.host, url.port == server.port, url.scheme == server.scheme else { return server }
        return url
    }

    /// Waits up to 30 seconds for the task's server to answer. False if it does not, or is not running.
    private func serverAnswers(_ id: TaskItem.ID) async -> Bool {
        guard let services, let port = task(id)?.port else { return false }
        for _ in 0..<150 {
            if await services.ports.isListening(port) { return true }
            guard await services.servers.isRunning(taskID: id) else { return false }
            try? await Task.sleep(for: baseServerPoll)
        }
        return false
    }

    // MARK: - Pending prompts

    private func deliverPending(_ id: TaskItem.ID) {
        guard let channel = approvalChannels[id], let task = task(id) else { return }
        for prompt in task.prompts where prompt.isPending {
            guard channel.send(prompt.agentText) else { return }
            logDelivered(id, [prompt.id])
            update(id) {
                if let index = $0.prompts.firstIndex(where: { $0.id == prompt.id }) { $0.prompts[index].isPending = false }
            }
        }
    }

    private func pendingIDs(_ id: TaskItem.ID) -> [Prompt.ID] {
        (task(id)?.prompts ?? []).filter(\.isPending).map(\.id)
    }

    /// Prompts that reached the agent in the middle of a run: what it does from here on answers them.
    private func logDelivered(_ id: TaskItem.ID, _ promptIDs: [Prompt.ID]) {
        guard let services, let agent = task(id)?.agent else { return }
        Task { await services.store.appendLog(taskID: id, text: RunMarker.line(agent: agent, promptIDs: promptIDs)) }
    }

    private func markDelivered(_ id: TaskItem.ID) {
        guard task(id)?.prompts.contains(where: \.isPending) == true else { return }
        update(id) { task in
            for index in task.prompts.indices { task.prompts[index].isPending = false }
        }
    }

    /// The pending prompts as the next turn's prompt ("" if none), now delivered.
    private func takePending(_ id: TaskItem.ID) -> String {
        let text = (task(id)?.prompts ?? []).filter(\.isPending).map(\.agentText).joined(separator: "\n\n")
        markDelivered(id)
        return text
    }

    private func dropPending(_ id: TaskItem.ID) {
        guard task(id)?.prompts.contains(where: \.isPending) == true else { return }
        update(id) { $0.prompts.removeAll(where: \.isPending) }
    }

    private func settle(_ id: TaskItem.ID, _ outcome: AgentOutcome) async -> Settled {
        guard let services, let task = task(id), let project = project(task.projectID) else {
            return Settled(status: .blocked, blockedReason: "The project no longer exists.")
        }
        switch outcome {
        case .needsInput(let question, let options):
            return Settled(status: .needsInput, summary: task.summary, question: question, options: options.isEmpty ? nil : options)
        case .blocked(let reason, let options):
            return Settled(status: .blocked, summary: task.summary, blockedReason: reason, options: options.isEmpty ? nil : options)
        case .completed(let summary):
            do {
                try await services.git.commitAll(worktree: task.worktreeURL, message: task.title)
                // Nothing to check against; Merge says why it cannot, and a new base can be picked.
                if await missingBase(task, project) != nil { return Settled(status: .completed, summary: summary) }
                let clean = try await services.git.canMergeCleanly(repo: project.repoURL, branch: task.branch,
                                                                   base: task.base(in: project))
                if clean { return Settled(status: .completed, summary: summary) }
                if task.isResolvingConflict {
                    return Settled(status: .blocked, summary: summary,
                                   blockedReason: "The conflict with \(task.base(in: project)) could not be resolved.")
                }
                return Settled(status: .conflict, summary: summary)
            } catch {
                return Settled(status: .blocked, summary: summary, blockedReason: Self.describe(error))
            }
        }
    }

    /// A notification titled with the project's name: "<task> is ready for review." or "<task> needs your attention."
    private func notify(_ task: TaskItem, needsAttention: Bool = true) {
        guard let services else { return }
        let title = project(task.projectID)?.name ?? ""
        let body = "\(task.title) \(needsAttention ? "needs your attention" : "is ready for review")."
        enqueue { await services.notifier.notify(title: title, body: body, taskID: task.id) }
    }

    /// Ends the current run: applies the outcome, releases the run and tells the user. No awaits.
    private func finish(_ id: TaskItem.ID, _ settled: Settled) {
        guard services != nil, let task = task(id) else { return }
        runs[id] = nil
        update(id) { Self.apply(settled, to: &$0) }
        notify(task, needsAttention: settled.status.needsAttention)
        let body = switch settled.status {
        case .needsInput: settled.question ?? ""
        case .blocked: settled.blockedReason ?? ""
        default: settled.summary ?? ""
        }
        let report = switch settled.status {
        case .needsInput: "needs input: \(body)"
        case .blocked: "is blocked: \(body)"
        case .conflict: "is finished but has a conflict: it does not merge cleanly."
        default: "is finished: \(body)"
        }
        reportToChat(task, report)
        // For the countdown to the reset: the last reading is likely from before the limit was reached.
        if self.task(id)?.isUsageLimited == true { Task { await refreshUsage(task.agent) } }
        let pushes = settled.status == .completed && project(task.projectID)?.pushTaskBranches == true
        if pushes || pullRequests[id] != nil {
            Task {
                if pushes { await pushBranch(taskID: id) }
                await refreshPullRequests(projectID: task.projectID)
            }
        }
    }

    private static func apply(_ settled: Settled, to task: inout TaskItem) {
        task.status = settled.status
        task.summary = settled.summary ?? task.summary
        task.question = settled.question
        task.approvalRequest = nil
        task.blockedReason = settled.blockedReason
        task.options = settled.options
        task.activity = nil
        task.isResolvingConflict = false
        task.workingSince = nil
    }

    // MARK: - Resources

    /// Returns when the task's run, if any, has completely stopped.
    private func cancelRun(_ id: TaskItem.ID) async {
        dropPending(id)
        pendingApprovals[id] = nil
        while let run = runs.removeValue(forKey: id) {
            run.task.cancel()
            await run.task.value
        }
    }

    /// Releases everything a task holds: agent, server, worktree and branch. The caller clears the record.
    /// `keepingBranchUnlessIn`: the branch is deleted only if all of its work is in that branch.
    private func cleanUp(_ id: TaskItem.ID, keepingBranchUnlessIn base: String? = nil) async {
        guard let services, let task = task(id) else { return }
        await cancelRun(id)
        serverFailures[id] = nil
        dormant.remove(id)
        for key in buildRuns.keys where key.taskID == id { buildRuns.removeValue(forKey: key)?.cancel() }
        builds = builds.filter { $0.key.taskID != id }
        buildLogs = buildLogs.filter { $0.key.taskID != id }
        runningTargets[id] = nil
        await services.servers.stop(taskID: id)
        if let port = task.port { await services.tailscale?.unserve(port: port) }
        if let pid = task.serverPID, !(await services.servers.isRunning(taskID: id)) {
            // Not one of ours from this launch; harmless if it is already gone.
            await services.servers.stopOrphan(pid: pid)
        }
        guard let project = project(task.projectID) else { return }
        var deleteBranch: String? = task.branch
        if let base, (try? await services.git.isContained(repo: project.repoURL, branch: task.branch, in: base)) != true {
            deleteBranch = nil
            lastError = "Kept the branch \(task.branch): some of its work is not in \(base)."
        }
        do {
            try await services.git.removeWorktree(repo: project.repoURL, path: task.worktreeURL,
                                                  deleteBranch: deleteBranch)
        } catch {
            lastError = "Could not remove the worktree of \(task.title): \(Self.describe(error))"
        }
    }

    private func markMerged(_ id: TaskItem.ID) {
        pullRequests[id] = nil
        update(id) {
            Self.apply(Settled(status: .merged), to: &$0)
            $0.port = nil
            $0.serverPID = nil
            $0.mergedAt = Date()
        }
    }

    /// Starts (or replaces) the task's dev server. Returns a message if it could not be started.
    @discardableResult
    private func startServer(_ id: TaskItem.ID, retries: Int = 0) async -> String? {
        guard let services, let task = task(id), let project = project(task.projectID), !project.isApp else { return nil }
        guard !project.serversOff else {
            dormant.insert(id)
            return "Servers are off for \(project.name). Turn them on from its menu in the sidebar."
        }
        // Our own server must be off to tell whether something else (another project's dev server,
        // which may have hopped to the next port while ours was down) now holds the task's port.
        await services.servers.stop(taskID: id)
        // Our own share from the last start holds the port against the check below, and against the server.
        // If something answers there now, the share is that server's, from another build of Shift: left alone.
        if let port = task.port, await services.ports.isListening(port) == false {
            await services.tailscale?.unserve(port: port)
        }
        // A task from before every task had a server has no port yet.
        let reserved = Set(tasks.filter { $0.id != id && $0.status != .merged }.compactMap(\.port)).union(basePorts.values)
        let port = await services.ports.allocate(preferred: task.port ?? id, reserved: reserved)
        guard let now = self.task(id), now.status != .merged else { return nil }
        if port != now.port { update(id) { $0.port = port } }
        let command = ProjectSetup.serverCommand(for: project, in: task.worktreeURL)
        serverCommands[id] = command
        let install = ProjectSetup.installStep(for: project, in: task.worktreeURL)
        do {
            let pid = try await services.servers.start(taskID: id, command: install.map { "\($0) && \(command)" } ?? command,
                                                       directory: task.worktreeURL, port: port)
            // Merged or deleted while the server was starting: it must not outlive the task.
            guard let now = self.task(id), now.status != .merged else {
                await services.servers.stop(taskID: id)
                return nil
            }
            update(id) { $0.serverPID = pid }
            serverFailures[id] = nil
            dormant.remove(id)
            serverUsed[id] = .now
            watchServer(id, pid: pid, port: port, retries: retries)
            return nil
        } catch {
            let message = "Dev server failed to start: \(Self.describe(error))"
            serverFailures[id] = message
            await services.store.appendLog(taskID: id, text: message + "\n")
            update(id) { $0.serverPID = nil }
            return message
        }
    }

    /// How many other ports a server gets to try after losing the one it was given.
    private static let portRetries = 5

    /// Whether the server quit because something else was already on its port. Checking a port doesn't reserve it:
    /// other apps and other builds of Shift want the same ones, and an install can run before the server gets to it.
    private func lostPort(_ serverID: Int) async -> Bool {
        guard let services, await services.servers.isRunning(taskID: serverID) == false else { return false }
        let log = await services.servers.log(taskID: serverID, lines: 30)
        return log.contains("EADDRINUSE") || log.localizedCaseInsensitiveContains("address already in use")
    }

    /// Shares the server on the tailnet once it is on its port: `tailscale serve` takes the port on the tailnet's
    /// addresses at once, and a server still getting there would then fail to bind it. Starts the server on another
    /// free port if it loses this one. Watches for five minutes, to see it through an install; its log starts over
    /// with each start, so an old failure doesn't count.
    private func watchServer(_ id: TaskItem.ID, pid: Int32, port: Int, retries: Int) {
        Task { [weak self] in
            var shared = false
            let deadline = ContinuousClock.now + .seconds(300)
            while ContinuousClock.now < deadline {
                guard let self, self.task(id)?.serverPID == pid else { return }
                guard let services = self.services, await services.servers.isRunning(taskID: id) else { break }
                if !shared, await services.ports.isListening(port) {
                    shared = true
                    if let tailscale = services.tailscale { self.tailnetHost = await tailscale.serve(port: port) }
                }
                try? await Task.sleep(for: self.baseServerPoll)
            }
            guard let self, retries < Self.portRetries, self.task(id)?.serverPID == pid, await self.lostPort(id) else { return }
            await self.startServer(id, retries: retries + 1)
        }
    }

    /// Starts the task's server if Shift left it off, and marks it wanted.
    private func wakeServer(_ id: TaskItem.ID) async {
        serverUsed[id] = .now
        guard dormant.contains(id), !settingUp.contains(id), !busy.contains(id), let task = task(id),
              project(task.projectID)?.serversOff == false, FileManager.default.fileExists(atPath: task.worktreePath) else { return }
        dormant.remove(id)
        await startServer(id)
    }

    /// Stops the task's dev server, for opening the task to start again.
    private func stopServer(_ id: TaskItem.ID) async {
        guard let services, let task = task(id) else { return }
        dormant.insert(id)
        update(id) { $0.serverPID = nil }
        await services.servers.stop(taskID: id)
        if let port = task.port { await services.tailscale?.unserve(port: port) }
    }

    /// Minutes a task's or a base's dev server may sit idle (no agent running, no browser tab connected) before
    /// it is stopped, for every project. A new prompt or the server button starts it again. 0: never stopped.
    public var serverTTL = UserDefaults.standard.object(forKey: "serverTTL") as? Int ?? 5 {
        didSet { UserDefaults.standard.set(serverTTL, forKey: "serverTTL") }
    }

    /// Stops the dev servers idle for longer than `serverTTL`, for their memory: no agent running,
    /// no browser tab connected. A new prompt, or the server button, starts it again.
    func stopUnusedServers() async {
        guard let services else { return }
        let ttl = serverTTL
        guard ttl > 0 else { return }
        func idle(_ id: Int) -> Bool {
            serverUsed[id] ?? .distantPast < Date.now.addingTimeInterval(-TimeInterval(ttl) * 60 + serverIdleSlack)
        }
        for task in tasks where task.status != .merged {
            guard let pid = task.serverPID, runs[task.id] == nil, !settingUp.contains(task.id), !busy.contains(task.id),
                  project(task.projectID)?.isApp == false, idle(task.id) else { continue }
            if let port = task.port, await services.ports.hasClients(port, besides: pid) {
                serverUsed[task.id] = .now
                continue
            }
            guard self.task(task.id)?.serverPID == pid, runs[task.id] == nil, idle(task.id) else { continue }
            await stopServer(task.id)
        }
        for (projectID, id) in baseServerIDs {
            guard let port = basePorts[projectID], idle(id),
                  await services.servers.isRunning(taskID: id) else { continue }
            if await services.ports.hasClients(port, besides: baseGroups[projectID] ?? 0) {
                serverUsed[id] = .now
                continue
            }
            await services.servers.stop(taskID: id)
        }
    }

    // MARK: - Memory

    /// A project gets a memory warning when its tasks use this much…
    public static let memoryWarning: UInt64 = 2 << 30
    /// …or this much while macOS is short of memory.
    public static let memoryWarningUnderPressure: UInt64 = 1 << 30
    /// How often memory is measured while an agent or server runs.
    static let memoryPoll: Duration = .seconds(4)

    /// Memory used by each task's agent and server, with everything they started, as of the last sample.
    /// macOS counts it as Shift's. Only tasks using some.
    public private(set) var taskMemory: [TaskItem.ID: MemoryUse] = [:]
    /// The same for each project chat's agent.
    public private(set) var chatMemory: [Project.ID: UInt64] = [:]
    /// macOS reports memory pressure as warning or critical.
    public private(set) var memoryPressure = false
    @ObservationIgnored private var memoryPressureSource: DispatchSourceMemoryPressure?

    public func memoryUsed(projectID: Project.ID) -> UInt64 {
        tasks(in: projectID).reduce(chatMemory[projectID] ?? 0) { $0 + (taskMemory[$1.id]?.total ?? 0) }
    }

    /// The project's tasks use enough memory to point it out.
    public func memoryWarning(projectID: Project.ID) -> Bool {
        let used = memoryUsed(projectID: projectID)
        return used >= Self.memoryWarning || (memoryPressure && used >= Self.memoryWarningUnderPressure)
    }

    /// Stops the task's dev server or app, for its memory. Opening the task, or an agent running in it, starts it again.
    public func stopServer(taskID: TaskItem.ID) async {
        if runningTargets[taskID] != nil { await stopApp(taskID: taskID) } else { await stopServer(taskID) }
    }

    private func watchMemory() {
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.normal, .warning, .critical], queue: .main)
        source.setEventHandler { [weak self, weak source] in
            guard let event = source?.data else { return }
            MainActor.assumeIsolated { self?.memoryPressure = !event.contains(.normal) }
        }
        source.resume()
        memoryPressureSource = source
        Task { [weak self] in
            while (try? await Task.sleep(for: Self.memoryPoll)) != nil, let self { await self.sampleMemory() }
        }
    }

    func sampleMemory() async {
        let servers = tasks.compactMap { task in task.serverPID.map { ($0, task.id) } }
        guard !runs.isEmpty || !chatRuns.isEmpty || !servers.isEmpty else {
            if !taskMemory.isEmpty { taskMemory = [:] }
            if !chatMemory.isEmpty { chatMemory = [:] }
            return
        }
        let worktrees = tasks.filter { $0.status != .merged }.map { ($0.worktreePath, $0.id) }
        let chats = projects.filter { chatRuns[$0.id] != nil }.map { ($0.repoPath, $0.id) }
        let bases = Set(baseGroups.values)
        let (taskUse, chatUse) = await Task.detached {
            Self.attribute(ProcessMemory.ownChildren(), servers: servers, worktrees: worktrees, chats: chats, ignoring: bases)
        }.value
        if taskMemory != taskUse { taskMemory = taskUse }
        if chatMemory != chatUse { chatMemory = chatUse }
    }

    /// Who each of Shift's children belongs to: a task's server by its pid, else a task's agent (or setup command)
    /// or a chat's agent by the folder it runs in. `ignoring`: base servers, which run in the project's folder too.
    // ponytail: agents are found by their working directory, not their pid; pass the pid out of the adapter if one
    // ever changes directory.
    nonisolated static func attribute(_ children: [ProcessMemory.Child], servers: [(pid_t, TaskItem.ID)],
                                      worktrees: [(String, TaskItem.ID)], chats: [(String, Project.ID)],
                                      ignoring: Set<pid_t>) -> ([TaskItem.ID: MemoryUse], [Project.ID: UInt64]) {
        let servers = Dictionary(servers, uniquingKeysWith: { first, _ in first })
        let worktrees = Dictionary(worktrees.compactMap { path, id in ServerManager.realPath(path).map { ($0, id) } },
                                   uniquingKeysWith: { first, _ in first })
        let chats = Dictionary(chats.compactMap { path, id in ServerManager.realPath(path).map { ($0, id) } },
                               uniquingKeysWith: { first, _ in first })
        var tasks: [TaskItem.ID: MemoryUse] = [:], projects: [Project.ID: UInt64] = [:]
        for child in children where child.footprint > 0 && !ignoring.contains(child.pid) {
            if let id = servers[child.pid] {
                tasks[id, default: MemoryUse()].server += child.footprint
            } else if let directory = child.directory, let id = worktrees[directory] {
                tasks[id, default: MemoryUse()].agent += child.footprint
            } else if let directory = child.directory, let id = chats[directory] {
                projects[id, default: 0] += child.footprint
            }
        }
        return (tasks, projects)
    }

    // MARK: - Recovery

    private func reconcile(_ id: TaskItem.ID) async {
        guard let services, let task = task(id) else { return }
        if let pid = task.serverPID {
            await services.servers.stopOrphan(pid: pid)
            update(id) { $0.serverPID = nil }
        }
        guard let project = project(task.projectID) else {
            update(id) { Self.apply(Settled(status: .blocked, blockedReason: "The project no longer exists."), to: &$0) }
            return
        }
        // A port kept from before the project was an app.
        if project.isApp && task.port != nil { update(id) { $0.port = nil } }
        let hasBranch = await services.git.branchExists(repo: project.repoURL, branch: task.branch)
        let hasWorktree = FileManager.default.fileExists(atPath: task.worktreePath)

        if hasBranch, await wasMergedExternally(task, project, hasWorktree: hasWorktree) {
            await cleanUp(id)
            markMerged(id)
        } else if !hasBranch {
            update(id) {
                Self.apply(Settled(status: .blocked, blockedReason: Self.branchMissingReason(task, project)), to: &$0)
            }
        } else if hasWorktree {
            // Started once the task is opened: servers for every open task would take a lot of memory.
            dormant.insert(id)
        }
        // A worktree folder that is gone is recreated from the branch when it is next needed:
        // before the agent runs again, or on Restart Server.
    }

    /// ponytail: the contract cannot say whether a branch has commits of its own (a brand-new branch
    /// is also "merged"), so this only trusts tasks that had finished and have nothing left that is
    /// not in base. Replace with a real check if GitServicing grows one.
    private func wasMergedExternally(_ task: TaskItem, _ project: Project, hasWorktree: Bool) async -> Bool {
        guard let services, task.status == .completed || task.status == .conflict,
              (try? await services.git.isMerged(repo: project.repoURL, branch: task.branch,
                                                base: task.base(in: project))) == true else { return false }
        guard hasWorktree else { return true }
        let changes = try? await services.git.changes(worktree: task.worktreeURL, base: task.base(in: project))
        return changes?.files.isEmpty == true
    }

    // MARK: - Persistence

    private func update(_ id: TaskItem.ID, _ change: (inout TaskItem) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        change(&tasks[index])
        changed()
    }

    /// Call after every state change. Saves are serialized and coalesced: each one writes the state
    /// as it is when the write starts, so the file never goes back in time.
    private func changed() {
        guard let services else { return }
        if !savePending {
            savePending = true
            enqueue { [weak self] in
                guard let self else { return }
                self.savePending = false
                await services.store.save(AppState(projects: self.projects, tasks: self.tasks,
                                                   nextTaskID: self.nextTaskID, chats: self.chats))
            }
        }
        let count = attentionCount
        if count != lastBadge {
            lastBadge = count
            enqueue { await services.notifier.setBadge(count: count) }
        }
    }

    private func enqueue(_ operation: @escaping @MainActor () async -> Void) {
        let previous = io
        io = Task {
            await previous?.value
            await operation()
        }
    }

    /// Returns once everything queued so far (saves, badge, notifications) has been delivered.
    func flush() async {
        while let pending = io {
            await pending.value
            if io == pending { io = nil }
        }
    }

    // MARK: - Helpers

    nonisolated static func title(for prompt: String) -> String { TaskItem.title(for: prompt) }

    static func branchMissingReason(_ task: TaskItem, _ project: Project) -> String {
        "The branch \(task.branch) is missing. Send a prompt to start the task again from \(task.base(in: project))."
    }

    /// The first non-empty line without git's "fatal: " or "error: ", at most 200 characters.
    static func firstLine(_ text: String) -> String {
        let line = text.components(separatedBy: .newlines).first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? text
        let trimmed = line.trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: #"^(fatal|error): "#, with: "", options: .regularExpression)
        return trimmed.count <= 200 ? trimmed : String(trimmed.prefix(199)) + "…"
    }

    private static func describe(_ error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? String(describing: error)
    }
}
