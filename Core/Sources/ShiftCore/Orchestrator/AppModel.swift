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
    /// Set when an operation fails outside of any task (e.g. adding a project). UI shows it as an alert.
    public var lastError: String?
    /// Whether each project's base branch has commits to push. No entry: the repo has no remote (or
    /// it was not checked yet).
    public internal(set) var pushStates: [Project.ID: PushState] = [:]

    public struct PushState: Equatable, Sendable {
        public var remote: String
        /// Commits on base that the remote does not have, as of the last fetch.
        public var unpushed: Int
        public var isPushing = false

        public init(remote: String, unpushed: Int, isPushing: Bool = false) {
            self.remote = remote
            self.unpushed = unpushed
            self.isPushing = isPushing
        }
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
    /// `start()` runs once per launch; the window calls it again whenever it is reopened.
    @ObservationIgnored private var started = false

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

        for kind in AgentKind.allCases {
            installedAgents[kind] = await services.agents[kind]?.detect()
        }
        Task { await services.notifier.requestAuthorization() }

        for task in tasks where task.status != .merged {
            await reconcile(task.id)
        }
        changed()
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

    /// Validates that `url` is a Git repository and adds it with sensible defaults.
    @discardableResult
    public func addProject(at url: URL) async -> Project? {
        guard let services else { return nil }
        let path = url.standardizedFileURL.path
        if let existing = projects.first(where: { $0.repoPath == path }) { return existing }
        guard await services.git.isRepository(url) else {
            lastError = "\(url.lastPathComponent) is not a Git repository."
            return nil
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
        return project
    }

    public func updateProject(_ project: Project) {
        guard services != nil, let index = projects.firstIndex(where: { $0.id == project.id }) else { return }
        projects[index] = project
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
        changed()
    }

    public func branches(for projectID: Project.ID) async -> [String] {
        guard let services, let project = project(projectID) else { return [] }
        return (try? await services.git.branches(repo: project.repoURL)) ?? []
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
    public func createTask(projectID: Project.ID, prompt: String, agent: AgentKind? = nil) -> TaskItem.ID? {
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard services != nil, let project = project(projectID), !prompt.isEmpty else { return nil }
        let id = nextTaskID
        nextTaskID += 1
        let title = Self.title(for: prompt)
        tasks.append(TaskItem(
            id: id, projectID: projectID, title: title.isEmpty ? "Task \(id)" : title, status: .working,
            agent: agent ?? project.defaultAgent, branch: "shift/\(id)",
            worktreePath: ShiftPaths.worktree(project: project, taskID: id, root: worktreesRoot).path,
            prompts: [Prompt(text: prompt)], workingSince: Date()))
        changed()
        startRun(id, prompt: prompt)
        return id
    }

    /// Follow-up instructions, an answer to a question, or instructions for a blocked task.
    /// While the agent works they go into its running session as soon as it can take them, and are
    /// `isPending` until then.
    public func sendPrompt(taskID: TaskItem.ID, text: String) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard services != nil, let task = task(taskID), task.status != .merged,
              !busy.contains(taskID), !text.isEmpty else { return }
        guard runs[taskID]?.active == true else {
            update(taskID) { $0.prompts.append(Prompt(text: text)) }
            beginWorking(taskID)
            startRun(taskID, prompt: text)
            return
        }
        let prompt = Prompt(text: text, isPending: true)
        update(taskID) { $0.prompts.append(prompt) }
        // A prompt instead of an answer to an approval request denies it, and goes to the agent
        // with the denial if the agent takes a message.
        if let pending = pendingApprovals.removeValue(forKey: taskID), let first = pending.first,
           let channel = approvalChannels[taskID] {
            resumeWorking(taskID)
            pending.dropFirst().forEach { channel.answer(id: $0.id, allow: false) }
            if channel.answer(id: first.id, allow: false, message: text) {
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
        let wasRunning = runs[taskID] != nil
        await cancelRun(taskID)
        do {
            // A worktree folder deleted by hand has nothing left to commit; the branch has the work.
            if FileManager.default.fileExists(atPath: task.worktreePath) {
                try await services.git.commitAll(worktree: task.worktreeURL, message: task.title)
            }
            let result = try await services.git.merge(repo: project.repoURL, branch: task.branch,
                                                      into: project.baseBranch, message: task.title)
            switch result {
            case .merged:
                await cleanUp(taskID)
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

    /// Reads whether the project's base branch has anything to push (no network access).
    public func refreshPushState(projectID: Project.ID) async {
        guard let services, let project = project(projectID), pushStates[projectID]?.isPushing != true else { return }
        let remote = await services.git.remote(repo: project.repoURL, branch: project.baseBranch)
        let count = if let remote {
            (try? await services.git.unpushedCount(repo: project.repoURL, branch: project.baseBranch, remote: remote)) ?? 0
        } else { 0 }
        // A push started or the project changed meanwhile: this answer is stale.
        guard pushStates[projectID]?.isPushing != true, self.project(projectID)?.baseBranch == project.baseBranch else { return }
        pushStates[projectID] = remote.map { PushState(remote: $0, unpushed: count) }
    }

    /// Pushes the project's base branch to its remote. Never forced.
    public func push(projectID: Project.ID) async {
        guard let services, let project = project(projectID), let state = pushStates[projectID],
              !state.isPushing, state.unpushed > 0 else { return }
        pushStates[projectID]?.isPushing = true
        do {
            try await services.git.push(repo: project.repoURL, branch: project.baseBranch, remote: state.remote)
        } catch {
            lastError = Self.firstLine(Self.describe(error))
        }
        pushStates[projectID]?.isPushing = false
        await refreshPushState(projectID: projectID)
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
                                                                      base: project.baseBranch),
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
            This branch no longer merges cleanly into `\(project.baseBranch)`. Merge `\(project.baseBranch)` \
            into this branch, resolve the conflicts keeping the intent of both sides, verify that the \
            project still builds and its tests pass, and commit the result.
            """)
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

    /// The last 200 lines of the dev server's output, and why it failed to start if it did.
    public func serverLog(taskID: TaskItem.ID) async -> String {
        guard let services else { return Self.previewServerLog }
        let log = await services.servers.log(taskID: taskID, lines: 200)
        guard let failure = serverFailures[taskID] else { return log }
        return log.isEmpty ? failure : log + "\n" + failure
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
        do { return .success(try await read(services.git, task.worktreeURL, project.baseBranch)) } catch {
            return .failure(Failure(Self.firstLine(Self.describe(error))))
        }
    }

    /// Raw agent output, for the debugging view only.
    public func rawOutput(taskID: TaskItem.ID) async -> String {
        guard let services else { return "" }
        return await services.store.readLog(taskID: taskID)
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
                try await services.git.createWorktree(repo: project.repoURL, branch: task.branch,
                                                      base: project.baseBranch, at: task.worktreeURL)
                createdBranch = true
            }
            created = true
            try check(id, token)
            // A branch made from base has none of the old work: nothing to resume, the prompts replay.
            if createdBranch && task.sessionID != nil { update(id) { $0.sessionID = nil } }
            var port = task.port
            if port == nil {
                let reserved = Set(tasks.filter { $0.id != id && $0.status != .merged }.compactMap(\.port))
                port = await services.ports.allocate(preferred: id, reserved: reserved)
                try check(id, token)
                update(id) { $0.port = port }
            }
            try await prepare(id, project: project, port: port ?? id)
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
    private func prepare(_ id: TaskItem.ID, project: Project, port: Int) async throws {
        let command = project.setupCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let services, let task = task(id), !command.isEmpty else { return }
        update(id) { $0.activity = "Setting up…" }
        await services.store.appendLog(taskID: id, text: "$ \(command)\n")
        let result = try await services.servers.run(command: command, directory: task.worktreeURL, environment: [
            "SHIFT_REPO": project.repoPath, "SHIFT_WORKTREE": task.worktreePath, "PORT": String(port)])
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
            let text = replay ? task.prompts.map(\.text).joined(separator: "\n\n")
                : [prompt, takePending(id)].filter { !$0.isEmpty }.joined(separator: "\n\n")
            markDelivered(id)
            let channel = ApprovalChannel()
            let request = AgentRequest(prompt: text, sessionID: task.sessionID, worktree: task.worktreeURL,
                                       environment: task.port.map { ["PORT": String($0)] } ?? [:],
                                       permissions: project(task.projectID)?.permissions ?? .bypass,
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
                case .rawOutput(let output): await services.store.appendLog(taskID: id, text: output)
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
            guard channel.send(prompt.text) else { return }
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
        let text = (task(id)?.prompts ?? []).filter(\.isPending).map(\.text).joined(separator: "\n\n")
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
                let clean = try await services.git.canMergeCleanly(repo: project.repoURL, branch: task.branch,
                                                                   base: project.baseBranch)
                if clean { return Settled(status: .completed, summary: summary) }
                if task.isResolvingConflict {
                    return Settled(status: .blocked, summary: summary,
                                   blockedReason: "The conflict with \(project.baseBranch) could not be resolved.")
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
    private func cleanUp(_ id: TaskItem.ID) async {
        guard let services, let task = task(id) else { return }
        await cancelRun(id)
        serverFailures[id] = nil
        await services.servers.stop(taskID: id)
        if let pid = task.serverPID, !(await services.servers.isRunning(taskID: id)) {
            // Not one of ours from this launch; harmless if it is already gone.
            await services.servers.stopOrphan(pid: pid)
        }
        guard let project = project(task.projectID) else { return }
        do {
            try await services.git.removeWorktree(repo: project.repoURL, path: task.worktreeURL,
                                                  deleteBranch: task.branch)
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
        guard let services, let task = task(id), let project = project(task.projectID) else { return nil }
        var port = task.port
        if port == nil {
            // A task from before every task had a server.
            let reserved = Set(tasks.filter { $0.id != id && $0.status != .merged }.compactMap(\.port))
            port = await services.ports.allocate(preferred: id, reserved: reserved)
            guard let now = self.task(id), now.status != .merged else { return nil }
            update(id) { $0.port = port }
        }
        guard let port else { return nil }
        do {
            let pid = try await services.servers.start(taskID: id, command: ProjectSetup.serverCommand(for: project),
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
                                                base: project.baseBranch)) == true else { return false }
        guard hasWorktree else { return true }
        let changes = try? await services.git.changes(worktree: task.worktreeURL, base: project.baseBranch)
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
        "The branch \(task.branch) is missing. Send a prompt to start the task again from \(project.baseBranch)."
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
