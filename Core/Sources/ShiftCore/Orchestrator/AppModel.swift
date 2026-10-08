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

    /// Web projects: the port of the dev server running on the project's own checkout, its base branch.
    /// No entry: not started yet.
    public private(set) var basePorts: [Project.ID: Int] = [:]
    /// Projects whose base server is coming up to be opened in the browser.
    public private(set) var openingBase: Set<Project.ID> = []

    /// App projects: each task's latest build since launch. No entry: not built yet.
    public private(set) var builds: [TaskItem.ID: BuildState] = [:]

    public enum BuildState: Equatable, Sendable {
        case building
        /// `app`: the .app it built, if the build command printed one.
        case succeeded(app: URL?)
        case failed(String)
    }

    private let services: Services?

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

    private let worktreesRoot: URL
    @ObservationIgnored private var nextTaskID = 3001
    @ObservationIgnored private var runs: [TaskItem.ID: Run] = [:]
    /// Tasks whose worktree is being set up (created, setup command, server) right now.
    /// A task whose worktree folder does not exist is set up again before its next agent run.
    @ObservationIgnored private var settingUp: Set<TaskItem.ID> = []
    /// Why the task's dev server last failed to start, until it starts. Shown with its log.
    @ObservationIgnored private var serverFailures: [TaskItem.ID: String] = [:]
    /// The command each task's dev server was last started with.
    @ObservationIgnored private var serverCommands: [TaskItem.ID: String] = [:]
    @ObservationIgnored private var buildRuns: [TaskItem.ID: Task<CommandResult, Error>] = [:]
    @ObservationIgnored private var buildLogs: [TaskItem.ID: String] = [:]
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

        for kind in AgentKind.allCases {
            installedAgents[kind] = await services.agents[kind]?.detect()
            models[kind] = await services.agents[kind]?.models()
        }
        Task { await services.notifier.requestAuthorization() }

        for task in tasks where task.status != .merged {
            await reconcile(task.id)
        }
        changed()
        for project in projects { await startBaseServer(project.id) }
        Task { [weak self] in
            while (try? await Task.sleep(for: .seconds(30))) != nil, let self { await self.continueLimitedTasks() }
        }
    }

    /// Called on app termination: stop servers and agents, persist.
    public func shutdown() async {
        guard let services else { return }
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
        await services.servers.stopAll()
        for task in tasks where task.serverPID != nil {
            update(task.id) { $0.serverPID = nil }
        }
        changed()
        await flush()
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
        let suggested = await ProjectSetup.suggest(repo: url, git: services.git)
        if let existing = projects.first(where: { $0.repoPath == path }) { return existing }
        let project = Project(name: url.lastPathComponent, repoPath: path, baseBranch: base,
                              defaultAgent: AgentKind.allCases.first { installedAgents[$0] != nil } ?? .claudeCode,
                              serverCommand: suggested.server, setupCommand: suggested.setup)
        projects.append(project)
        changed()
        Task { await startBaseServer(project.id) }
        return project
    }

    public func updateProject(_ project: Project) {
        guard let services, let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        let old = projects[index]
        projects[index] = project
        if (old.serverCommand, old.buildCommand) != (project.serverCommand, project.buildCommand) {
            Task { await startBaseServer(project.id, restart: true) }
        }
        // Now an app: its tasks are tested by building, so their dev servers and ports go.
        if project.isApp {
            for task in tasks(in: project.id) where task.serverPID != nil || task.port != nil {
                update(task.id) { $0.serverPID = nil; $0.port = nil }
                Task { await services.servers.stop(taskID: task.id) }
            }
        }
        changed()
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

    /// Names of agent instruction files found in the repo root, e.g. ["AGENTS.md", "CLAUDE.md"].
    public func instructionFiles(for projectID: Project.ID) -> [String] {
        guard let project = project(projectID) else { return [] }
        return ["AGENTS.md", "CLAUDE.md"].filter {
            FileManager.default.fileExists(atPath: project.repoURL.appendingPathComponent($0).path)
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
        let title = Self.title(for: prompt.isEmpty ? URL(fileURLWithPath: attachments[0]).lastPathComponent : prompt)
        tasks.append(TaskItem(
            id: id, projectID: projectID, title: title.isEmpty ? "Task \(id)" : title, status: .working,
            agent: agent ?? project.defaultAgent, branch: "shift/\(id)", baseBranch: project.baseBranch,
            worktreePath: ShiftPaths.worktree(project: project, taskID: id, root: worktreesRoot).path,
            prompts: [first], workingSince: Date()))
        changed()
        startRun(id, prompt: first.agentText)
        return id
    }

    /// Follow-up instructions, an answer to a question, or instructions for a blocked task.
    /// While the agent works they go into its running session as soon as it can take them, and are
    /// `isPending` until then.
    public func sendPrompt(taskID: TaskItem.ID, text: String, attachments: [String] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard services != nil, let task = task(taskID), task.status != .merged,
              !busy.contains(taskID), !text.isEmpty || !attachments.isEmpty else { return }
        guard runs[taskID]?.active == true else {
            let prompt = Prompt(text: text, attachments: attachments)
            update(taskID) { $0.prompts.append(prompt) }
            beginWorking(taskID)
            startRun(taskID, prompt: prompt.agentText)
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
                markDelivered(taskID)
                return
            }
        }
        deliverPending(taskID)
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

    /// Pushes every base of the project that has commits to push. Never forced.
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
    }

    /// Pushes the task's branch to the project's remote. Never forced.
    public func pushBranch(taskID: TaskItem.ID) async {
        guard let services, let task = task(taskID), let project = project(task.projectID),
              let remote = await services.git.remote(repo: project.repoURL, branch: task.branch) else { return }
        do {
            try await services.git.push(repo: project.repoURL, branch: task.branch, remote: remote)
        } catch {
            lastError = "Could not push \(task.title): \(Self.firstLine(Self.describe(error)))"
        }
    }

    /// The project's base branch in the browser: its base server, started again first if it stopped, once it
    /// answers. Nil (and `lastError`) if it never does.
    public func baseServerURL(projectID: Project.ID) async -> URL? {
        guard let services, !openingBase.contains(projectID) else { return nil }
        func url(_ port: Int) -> URL? { URL(string: "http://localhost:\(port)") }
        if let id = baseServerIDs[projectID], let port = basePorts[projectID],
           await services.servers.isRunning(taskID: id), await isListening(port) { return url(port) }

        openingBase.insert(projectID)
        defer { openingBase.remove(projectID) }
        await startBaseServer(projectID)
        guard let project = project(projectID), let id = baseServerIDs[projectID],
              let port = basePorts[projectID] else { return nil }
        // Up for 3 seconds before it counts: Next.js listens for a second or two before it finds another
        // dev server running on the folder and quits. Given up on after 30 seconds.
        var up = 0
        for _ in 0..<150 {
            guard await services.servers.isRunning(taskID: id) else { break }
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

    /// Keeps a web project's base server running (starting it if it is not), and stops it once the project
    /// is gone or became an app. `restart`: start it again even if it runs, for a changed command.
    /// ponytail: serves the repo folder, which shows base only while base is checked out there.
    private func startBaseServer(_ projectID: Project.ID, restart: Bool = false) async {
        guard let services else { return }
        let id = baseServerIDs[projectID] ?? -(baseServerIDs.count + 1)
        baseServerIDs[projectID] = id
        guard let project = project(projectID), !project.isApp else {
            basePorts[projectID] = nil
            await services.servers.stop(taskID: id)
            return
        }
        if !restart, basePorts[projectID] != nil, await services.servers.isRunning(taskID: id) { return }
        let reserved = Set(tasks.filter { $0.status != .merged }.compactMap(\.port))
            .union(basePorts.filter { $0.key != projectID }.values)
        let port = await services.ports.allocate(preferred: basePorts[projectID] ?? 3000, reserved: reserved)
        do {
            _ = try await services.servers.start(taskID: id, command: ProjectSetup.serverCommand(for: project, in: project.repoURL),
                                                 directory: project.repoURL, port: port)
            basePorts[projectID] = port
        } catch {
            basePorts[projectID] = nil
            lastError = "Could not start the server for \(project.name): \(Self.firstLine(Self.describe(error)))"
        }
        // Removed or made an app while starting: the server must not outlive it.
        if self.project(projectID)?.isApp != false { await startBaseServer(projectID) }
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
                enqueue { await services.notifier.notify(title: "\(now.title) has a conflict", body: "It does not merge cleanly.", taskID: id) }
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

    /// App projects: runs the build command in the task's worktree. Returns the .app it built, to open:
    /// the last line of the output, if that is the path of one. Does nothing while a build is running.
    public func build(taskID: TaskItem.ID) async -> URL? {
        guard let services, let task = task(taskID), task.status != .merged, let project = project(task.projectID),
              project.isApp, builds[taskID] != .building else { return nil }
        guard FileManager.default.fileExists(atPath: task.worktreePath) else {
            builds[taskID] = .failed("The task's folder is recreated the next time the agent runs.")
            return nil
        }
        builds[taskID] = .building
        let command = project.buildCommand
        let run = Task {
            try await services.servers.run(command: command, directory: task.worktreeURL, environment: [
                "SHIFT_REPO": project.repoPath, "SHIFT_WORKTREE": task.worktreePath, "SHIFT_TASK": String(taskID)])
        }
        buildRuns[taskID] = run
        let result = await run.result
        // Deleted or merged meanwhile: nothing left to report on.
        guard buildRuns[taskID] == run else { return nil }
        buildRuns[taskID] = nil
        switch result {
        case .success(let result):
            buildLogs[taskID] = "$ \(command)\n" + result.output
            guard result.exitCode == 0 else {
                builds[taskID] = .failed("Build failed (exit code \(result.exitCode)).")
                return nil
            }
            let last = result.output.split(whereSeparator: \.isNewline).last
                .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            let app = last.hasSuffix(".app") && FileManager.default.fileExists(atPath: last)
                ? URL(fileURLWithPath: last) : nil
            builds[taskID] = .succeeded(app: app)
            return app
        case .failure(let error):
            builds[taskID] = .failed("Build could not start: \(Self.describe(error))")
            return nil
        }
    }

    /// The output of the task's last build.
    public func buildLog(taskID: TaskItem.ID) -> String {
        buildLogs[taskID] ?? (builds[taskID] == .building ? "Building…" : "")
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

    /// Raw agent output, for the debugging view only.
    public func rawOutput(taskID: TaskItem.ID) async -> String {
        guard let services else { return "" }
        return await services.store.readLog(taskID: taskID)
    }

    /// The agent's output as a person reads it: its messages, its actions, its errors.
    public func readableOutput(taskID: TaskItem.ID) async -> String {
        guard let agent = task(taskID)?.agent else { return "" }
        return Transcript.readable(await rawOutput(taskID: taskID), agent: agent)
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
        guard let services, let summary = pendingApprovals[id]?.first?.summary, let task = task(id) else { return }
        let isNew = task.approvalRequest != summary || task.status != .needsInput
        update(id) {
            $0.status = .needsInput
            $0.approvalRequest = summary
            $0.activity = nil
        }
        if isNew {
            enqueue { await services.notifier.notify(title: "\(task.title) needs your approval", body: summary, taskID: id) }
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
    private func startRun(_ id: TaskItem.ID, prompt: String?) {
        let previous = runs[id]?.task
        previous?.cancel()
        let token = UUID()
        let task = Task { [weak self] in
            // Never two runs in one worktree: the one before has to be completely gone first.
            await previous?.value
            await self?.run(id, token: token, prompt: prompt)
        }
        runs[id] = Run(token: token, task: task)
    }

    private func run(_ id: TaskItem.ID, token: UUID, prompt: String?) async {
        defer { if runs[id]?.token == token { runs[id] = nil } }
        do {
            try check(id, token)
            // New, or its folder is gone (deleted, or never finished before a crash).
            if let task = task(id), !FileManager.default.fileExists(atPath: task.worktreePath) {
                try await setUp(id, token: token)
            }
            var prompt = prompt
            if prompt == nil {
                let pending = takePending(id)
                guard !pending.isEmpty else { return }
                beginWorking(id)
                prompt = pending
            }
            try await converse(id, token: token, prompt: prompt ?? "")
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
            }
            return adapter
        }
        throw Failure("\(task.agent.displayName) is not installed.")
    }

    /// Runs agent turns until one ends with nothing pending, then settles the task.
    private func converse(_ id: TaskItem.ID, token: UUID, prompt: String) async throws {
        guard let services else { return }
        var prompt = prompt
        while true {
            let adapter = try adapter(for: id)
            guard let task = task(id) else { throw CancellationError() }
            // Without a session there is nothing to resume, so the agent needs the whole story.
            let replay = task.sessionID == nil && !task.isResolvingConflict
            // Prompts sent while it was being set up go in with this turn's prompt.
            let text = replay ? task.prompts.map(\.agentText).joined(separator: "\n\n")
                : [prompt, takePending(id)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            markDelivered(id)
            let channel = ApprovalChannel()
            let request = AgentRequest(prompt: text, sessionID: task.sessionID, worktree: task.worktreeURL,
                                       environment: task.port.map { ["PORT": String($0)] } ?? [:],
                                       permissions: project(task.projectID)?.permissions ?? .bypass,
                                       model: project(task.projectID)?.models[adapter.kind],
                                       needsDescription: task.description == nil && !task.isResolvingConflict,
                                       approvals: channel)
            approvalChannels[id] = channel
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
                            $0.title = title ?? $0.title
                            $0.description = description ?? $0.description
                        }
                    }
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
            let settled = await settle(id, outcome)
            try check(id, token)
            // The agent may have created the project (a package.json with a dev script): serve that now.
            if let now = self.task(id), let owner = self.project(now.projectID), serverCommands[id] != nil,
               serverCommands[id] != ProjectSetup.serverCommand(for: owner, in: now.worktreeURL) {
                await startServer(id)
                try check(id, token)
            }

            // From here to the end of the iteration there is no await: a prompt sent now either
            // is pending already, or finds the task settled and starts a run of its own.
            let more = takePending(id)
            if !more.isEmpty {
                prompt = more
                continue
            }
            finish(id, settled)
            return
        }
    }

    // MARK: - Pending prompts

    private func deliverPending(_ id: TaskItem.ID) {
        guard let channel = approvalChannels[id], let task = task(id) else { return }
        for prompt in task.prompts where prompt.isPending {
            guard channel.send(prompt.agentText) else { return }
            update(id) {
                if let index = $0.prompts.firstIndex(where: { $0.id == prompt.id }) { $0.prompts[index].isPending = false }
            }
        }
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

    /// Ends the current run: applies the outcome, releases the run and tells the user. No awaits.
    private func finish(_ id: TaskItem.ID, _ settled: Settled) {
        guard let services, let task = task(id) else { return }
        runs[id] = nil
        update(id) { Self.apply(settled, to: &$0) }
        let (title, body): (String, String) = switch settled.status {
        case .needsInput: ("\(task.title) needs your input", settled.question ?? "")
        case .blocked: ("\(task.title) is blocked", settled.blockedReason ?? "")
        case .conflict: ("\(task.title) has a conflict", "It does not merge cleanly.")
        default: ("\(task.title) is ready", settled.summary ?? "")
        }
        enqueue { await services.notifier.notify(title: title, body: body, taskID: id) }
        // For the countdown to the reset: the last reading is likely from before the limit was reached.
        if self.task(id)?.isUsageLimited == true { Task { await refreshUsage(task.agent) } }
        if settled.status == .completed, project(task.projectID)?.pushTaskBranches == true {
            Task { await pushBranch(taskID: id) }
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
        buildRuns.removeValue(forKey: id)?.cancel()
        builds[id] = nil
        buildLogs[id] = nil
        await services.servers.stop(taskID: id)
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
        update(id) {
            Self.apply(Settled(status: .merged), to: &$0)
            $0.port = nil
            $0.serverPID = nil
            $0.mergedAt = Date()
        }
    }

    /// Starts (or replaces) the task's dev server. Returns a message if it could not be started.
    @discardableResult
    private func startServer(_ id: TaskItem.ID) async -> String? {
        guard let services, let task = task(id), let project = project(task.projectID), !project.isApp else { return nil }
        // Our own server must be off to tell whether something else (another project's dev server,
        // which may have hopped to the next port while ours was down) now holds the task's port.
        await services.servers.stop(taskID: id)
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
            return nil
        } catch {
            let message = "Dev server failed to start: \(Self.describe(error))"
            serverFailures[id] = message
            await services.store.appendLog(taskID: id, text: message + "\n")
            update(id) { $0.serverPID = nil }
            return message
        }
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
            await startServer(id)
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
                                                   nextTaskID: self.nextTaskID))
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

    /// The title until the agent gives its own (`.described`), and the fallback if it never does.
    static func title(for prompt: String) -> String {
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
