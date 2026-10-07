import XCTest
@testable import ShiftCore

@MainActor
final class AppModelTests: XCTestCase {
    var git: MockGit!
    var agent: MockAgent!
    var servers: MockServers!
    var ports: MockPorts!
    var notifier: MockNotifier!
    var store: MockStore!
    var model: AppModel!
    var project: Project!
    var temp: URL!

    override func setUp() async throws {
        git = MockGit()
        agent = MockAgent()
        servers = MockServers()
        ports = MockPorts()
        notifier = MockNotifier()
        store = MockStore()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("shift-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        project = Project(name: "Spot", repoPath: temp.path, baseBranch: "main", serverCommand: "pnpm dev")
        store.state = AppState(projects: [project])
        model = makeModel()
        await model.start()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func makeModel() -> AppModel {
        AppModel(services: Services(git: git, agents: [.claudeCode: agent], servers: servers, ports: ports,
                                    notifier: notifier, store: store),
                 worktrees: temp.appendingPathComponent("worktrees"))
    }

    func status(_ id: Int) -> TaskStatus? { model.task(id)?.status }

    func waitForStatus(_ id: Int, _ expected: TaskStatus, file: StaticString = #filePath, line: UInt = #line) async {
        await waitFor("task \(id) to become \(expected)", file: file, line: line) { self.status(id) == expected }
    }

    /// A task whose agent is parked mid-turn until the returned gate is opened.
    func createPausedTask(then outcome: AgentOutcome = .completed(summary: "Done")) async -> (Int, Gate) {
        let gate = Gate()
        agent.scripts.append([.emit(.sessionStarted(id: "s1")), .emit(.activity("Thinking…")),
                              .pause(gate), .emit(.finished(outcome))])
        let id = model.createTask(projectID: project.id, prompt: "Do the thing")!
        await waitFor("the agent to pause") { gate.waiting == 1 && self.model.task(id)?.activity == "Thinking…" }
        return (id, gate)
    }

    /// A finished task, with everything the first run produced already delivered.
    func createCompletedTask() async -> Int {
        let id = model.createTask(projectID: project.id, prompt: "Do the thing")!
        await waitForStatus(id, .completed)
        await model.flush()
        return id
    }

    /// State left behind by a previous launch.
    func relaunch(with task: TaskItem) async {
        store.state = AppState(projects: [project], tasks: [task], nextTaskID: task.id + 1)
        model = makeModel()
        await model.start()
        await model.flush()
    }

    func savedTask(_ id: Int, status: TaskStatus, worktreeExists: Bool = true, serverPID: Int32? = nil) -> TaskItem {
        TaskItem(id: id, projectID: project.id, title: "Old", status: status, agent: .claudeCode,
                 branch: "shift/\(id)", worktreePath: worktreeExists ? temp.path : temp.path + "/gone",
                 sessionID: "s9", port: id, serverPID: serverPID)
    }

    // MARK: Create

    func testAttachmentsGoToTheAgentAsPaths() async {
        agent.scripts = [[.emit(.sessionStarted(id: "s1")), .emit(.finished(.completed(summary: "Done")))]]
        let id = model.createTask(projectID: project.id, prompt: "", attachments: ["/tmp/shot.png"])!
        XCTAssertEqual(model.task(id)?.title, "shot.png")
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.requests[0].prompt, "Attached files:\n- /tmp/shot.png")
        XCTAssertEqual(Prompt(text: "Fix this", attachments: ["/a", "/b"]).agentText, "Fix this\n\nAttached files:\n- /a\n- /b")
    }

    func testCreateRunsToCompleted() async {
        agent.scripts = [[.emit(.sessionStarted(id: "s1")), .emit(.activity("Editing…")), .emit(.rawOutput("raw")),
                          .emit(.finished(.completed(summary: "Gap is 4px")))]]

        let id = model.createTask(projectID: project.id, prompt: "Set the gap to 4px. Thanks!")
        XCTAssertEqual(id, 3001)
        XCTAssertEqual(status(3001), .working)
        XCTAssertNotNil(model.task(3001)?.workingSince)

        await waitForStatus(3001, .completed)
        await model.flush()

        let task = model.task(3001)!
        XCTAssertEqual(task.title, "Set the gap to 4px")
        XCTAssertEqual(task.branch, "shift/3001")
        XCTAssertEqual(task.worktreePath, ShiftPaths.worktree(project: project, taskID: 3001,
                                                              root: temp.appendingPathComponent("worktrees")).path)
        XCTAssertEqual(task.port, 3001)
        XCTAssertEqual(task.serverPID, servers.running[3001])
        XCTAssertEqual(task.sessionID, "s1")
        XCTAssertEqual(task.summary, "Gap is 4px")
        XCTAssertNil(task.activity)
        XCTAssertNil(task.workingSince)
        XCTAssertEqual(git.calls, ["create shift/3001 from main", "commit 3001"])
        XCTAssertEqual(servers.starts, [.init(taskID: 3001, command: "pnpm dev", port: 3001)])
        XCTAssertEqual(agent.requests.count, 1)
        XCTAssertNil(agent.requests[0].sessionID)
        XCTAssertEqual(agent.requests[0].prompt, "Set the gap to 4px. Thanks!")
        XCTAssertEqual(agent.requests[0].environment["PORT"], "3001")
        XCTAssertEqual(store.logs[3001], "raw\n")
        XCTAssertEqual(notifier.notifications, [.init(title: "Set the gap to 4px is ready", body: "Gap is 4px", taskID: 3001)])
        XCTAssertEqual(notifier.badges.last, 1)
        XCTAssertEqual(store.state.tasks, model.tasks)
        XCTAssertEqual(store.state.nextTaskID, 3002)
    }

    func testActivityIsShownWhileWorking() async {
        let (id, gate) = await createPausedTask()
        XCTAssertEqual(model.task(id)?.activity, "Thinking…")
        XCTAssertEqual(model.task(id)?.sessionID, "s1")
        XCTAssertEqual(status(id), .working)
        gate.open()
        await waitForStatus(id, .completed)
    }

    func testCompletedWithConflictingBaseBecomesConflict() async {
        git.canMerge = false
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .conflict)
        XCTAssertEqual(model.task(id)?.summary, "Done")
    }

    func testNeedsInputThenAnswerCompletes() async {
        agent.scripts = [[.emit(.sessionStarted(id: "s1")), .emit(.finished(.needsInput(question: "Which one?")))]]
        let id = model.createTask(projectID: project.id, prompt: "Add an empty state")!
        await waitForStatus(id, .needsInput)
        XCTAssertEqual(model.task(id)?.question, "Which one?")

        model.sendPrompt(taskID: id, text: "The first")
        XCTAssertEqual(status(id), .working)
        XCTAssertNil(model.task(id)?.question)

        await waitForStatus(id, .completed)
        await model.flush()
        XCTAssertEqual(agent.requests.count, 2)
        XCTAssertEqual(agent.requests[1].sessionID, "s1")
        XCTAssertEqual(agent.requests[1].prompt, "The first")
        XCTAssertEqual(model.task(id)?.prompts.map(\.text), ["Add an empty state", "The first"])
        XCTAssertEqual(notifier.notifications.map(\.title), ["Add an empty state needs your input", "Add an empty state is ready"])
        // Same worktree and server throughout.
        XCTAssertEqual(git.calls.filter { $0.hasPrefix("create") }.count, 1)
        XCTAssertEqual(servers.starts.count, 1)
    }

    func testOptionsAreSetWithAQuestionAndClearedByTheAnswer() async {
        agent.scripts = [[.emit(.sessionStarted(id: "s1")), .emit(.finished(.needsInput(question: "Which language?", options: ["English", "Spanish"])))],
                         [.emit(.finished(.blocked(reason: "No network.", options: ["Retry"])))],
                         [.emit(.finished(.blocked(reason: "Still no network.")))]]
        let id = model.createTask(projectID: project.id, prompt: "Add a greeting")!
        await waitForStatus(id, .needsInput)
        XCTAssertEqual(model.task(id)?.options, ["English", "Spanish"])

        model.sendPrompt(taskID: id, text: "English")
        XCTAssertNil(model.task(id)?.options)
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.options, ["Retry"])

        // A block without options leaves none from before.
        model.sendPrompt(taskID: id, text: "Retry")
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Still no network.")
        XCTAssertNil(model.task(id)?.options)
    }

    func testOptionsAreClearedByMerge() async {
        agent.scripts = [[.emit(.finished(.blocked(reason: "Tests fail", options: ["Skip the failing test"])))]]
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.options, ["Skip the failing test"])
        await model.merge(taskID: id)
        XCTAssertEqual(status(id), .merged)
        XCTAssertNil(model.task(id)?.options)
    }

    func testAgentBlockedBecomesBlocked() async {
        agent.scripts = [[.emit(.finished(.blocked(reason: "No API key")))]]
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "No API key")
    }

    func testAgentStreamEndingWithoutOutcomeBecomesBlocked() async {
        agent.scripts = [[.emit(.activity("Starting…"))]]
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "The agent stopped unexpectedly.")
    }

    func testSetupFailureBlocksAndCanBeRetried() async {
        git.createError = MockError("base branch main not found")
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        await model.flush()

        XCTAssertEqual(model.task(id)?.blockedReason, "base branch main not found")
        XCTAssertTrue(agent.requests.isEmpty)
        XCTAssertTrue(servers.running.isEmpty)
        XCTAssertEqual(git.calls, [])
        XCTAssertEqual(store.state.tasks.first?.status, .blocked)

        git.createError = nil
        model.sendPrompt(taskID: id, text: "Try again")
        await waitForStatus(id, .completed)
        XCTAssertEqual(git.calls.first, "create shift/3001 from main")
        XCTAssertEqual(agent.requests.map(\.prompt), ["Do it\n\nTry again"])
    }

    // MARK: Setup command

    func useSetupCommand(_ command: String = "pnpm install") {
        project.setupCommand = command
        model.updateProject(project)
    }

    func testSetupCommandRunsInTheWorktreeBeforeServerAndAgent() async {
        useSetupCommand()
        let gate = Gate()
        servers.runGate = gate
        servers.runResult = CommandResult(exitCode: 0, output: "Done in 2s\n")
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("the setup command to start") { gate.waiting == 1 }

        let task = model.task(id)!
        XCTAssertEqual(task.activity, "Setting up…")
        XCTAssertEqual(servers.runs, [.init(command: "pnpm install", directory: task.worktreePath, environment: [
            "SHIFT_REPO": temp.path, "SHIFT_WORKTREE": task.worktreePath, "PORT": "3001"])])
        XCTAssertEqual(git.calls, ["create shift/3001 from main"])
        XCTAssertTrue(servers.starts.isEmpty)
        XCTAssertTrue(agent.requests.isEmpty)

        gate.open()
        await waitForStatus(id, .completed)
        XCTAssertEqual(store.logs[id], "$ pnpm install\nDone in 2s\n")
        XCTAssertEqual(servers.starts.count, 1)
        XCTAssertEqual(agent.requests.count, 1)
        XCTAssertNil(model.task(id)?.activity)

        // Once per worktree, not once per prompt.
        model.sendPrompt(taskID: id, text: "More")
        await waitFor("the second run") { self.agent.requests.count == 2 && self.status(id) == .completed }
        XCTAssertEqual(servers.runs.count, 1)
    }

    func testNoSetupCommandRunsNothing() async {
        _ = await createCompletedTask()
        XCTAssertTrue(servers.runs.isEmpty)
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("exclude") })
    }

    func testSetupFilesAreExcludedAfterTheCommandAndBeforeTheAgent() async {
        useSetupCommand()
        let gate = Gate()
        servers.runGate = gate
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("the setup command to start") { gate.waiting == 1 }
        XCTAssertEqual(git.calls, ["create shift/3001 from main"])

        gate.open()
        await waitForStatus(id, .completed)
        let worktree = model.task(id)!.worktreeURL.lastPathComponent
        XCTAssertEqual(Array(git.calls.prefix(3)),
                       ["create shift/3001 from main", "exclude \(worktree)", "commit \(worktree)"])
    }

    func testFailedSetupCommandExcludesNothing() async {
        useSetupCommand()
        servers.runResult = CommandResult(exitCode: 1, output: "boom\n")
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("exclude") })
    }

    func testFailingToExcludeSetupFilesBlocksBeforeTheAgentRuns() async {
        useSetupCommand()
        git.excludeError = GitError(message: "cannot write info/exclude")
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        XCTAssertTrue(agent.requests.isEmpty)
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("commit") })
    }

    func testSetupCommandFailureBlocksWithTheEndOfItsOutput() async {
        useSetupCommand()
        servers.runResult = CommandResult(exitCode: 1, output: "one\ntwo\nthree\nfour\nfive\n\nzsh: command not found: pnpm\n")
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        await model.flush()

        XCTAssertEqual(model.task(id)?.blockedReason,
                       "Setup failed (exit code 1).\ntwo\nthree\nfour\nfive\nzsh: command not found: pnpm")
        XCTAssertNil(model.task(id)?.activity)
        XCTAssertTrue(agent.requests.isEmpty)
        XCTAssertTrue(servers.starts.isEmpty)
        XCTAssertEqual(git.calls, ["create shift/3001 from main", "remove shift/3001"])
        XCTAssertEqual(notifier.notifications.last?.title, "Do it is blocked")

        // Fixed: the next prompt sets the task up again.
        servers.runResult = CommandResult(exitCode: 0)
        model.sendPrompt(taskID: id, text: "Try again")
        await waitForStatus(id, .completed)
        XCTAssertEqual(servers.runs.count, 2)
    }

    func testStopDuringSetupCommandCancelsItAndRollsBack() async {
        useSetupCommand()
        let gate = Gate()
        servers.runGate = gate
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("the setup command to start") { gate.waiting == 1 }

        model.stop(taskID: id)
        await waitFor("the setup command to be cancelled") { gate.cancellations == 1 }
        XCTAssertEqual(model.task(id)?.blockedReason, "Stopped")
        XCTAssertNil(model.task(id)?.activity)

        servers.runResult = CommandResult(exitCode: 143)
        gate.open()
        await waitFor("the rollback") { self.git.calls.last == "remove shift/3001" }
        await model.flush()
        XCTAssertEqual(model.task(id)?.blockedReason, "Stopped")
        XCTAssertTrue(agent.requests.isEmpty)
        XCTAssertTrue(servers.starts.isEmpty)
        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    func testDeleteDuringSetupCommandCancelsIt() async {
        useSetupCommand()
        let gate = Gate()
        servers.runGate = gate
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("the setup command to start") { gate.waiting == 1 }

        let deletion = Task { await self.model.delete(taskID: id) }
        await waitFor("the delete to cancel the setup command") { gate.cancellations == 1 }
        gate.open()
        await deletion.value

        XCTAssertNil(model.task(id))
        XCTAssertTrue(git.existingBranches.isEmpty)
        XCTAssertNil(store.logs[id])
        XCTAssertTrue(agent.requests.isEmpty)
    }

    func testAddProjectSuggestsCommands() async throws {
        let repo = temp.appendingPathComponent("app")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for (name, text) in [("pnpm-lock.yaml", ""), (".env", "A=1"), (".env.local", "B=2"),
                             ("package.json", #"{"scripts": {"dev": "vite"}}"#)] {
            try Data(text.utf8).write(to: repo.appendingPathComponent(name))
        }
        git.trackedPaths = [".env.local"]
        let added = await model.addProject(at: repo)
        XCTAssertEqual(added?.setupCommand, #"pnpm install && cp "$SHIFT_REPO/.env" ."#)
        XCTAssertEqual(added?.serverCommand, "pnpm run dev --port $PORT")
    }

    func testEveryRunUsesTheProjectsCurrentPermissions() async {
        XCTAssertEqual(project.permissions, .bypass)
        let id = await createCompletedTask()
        project.permissions = .auto
        model.updateProject(project)
        model.sendPrompt(taskID: id, text: "More")
        await waitFor("the second run") { self.agent.requests.count == 2 && self.status(id) == .completed }
        XCTAssertEqual(agent.requests.map(\.permissions), [.bypass, .auto])
    }

    func testUninstalledAgentSwitchesToTheProjectDefault() async {
        agent.scripts = [[.emit(.sessionStarted(id: "s2")), .emit(.finished(.completed(summary: "Done")))]]
        git.existingBranches = ["shift/2001"]
        var saved = savedTask(2001, status: .needsInput)
        saved.agent = .codex
        saved.prompts = [Prompt(text: "First"), Prompt(text: "Second")]
        await relaunch(with: saved)

        model.sendPrompt(taskID: 2001, text: "Third")
        await waitForStatus(2001, .completed)
        XCTAssertEqual(model.task(2001)?.agent, .claudeCode)
        XCTAssertEqual(model.task(2001)?.sessionID, "s2")
        XCTAssertNil(agent.requests.first?.sessionID, "a Codex session does not carry over")
        XCTAssertEqual(agent.requests.first?.prompt, "First\n\nSecond\n\nThird")
    }

    func testNoInstalledAgentBlocks() async {
        agent.installation = nil
        model = makeModel()
        await model.start()
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Claude Code is not installed.")
        XCTAssertTrue(agent.requests.isEmpty)
    }

    func testServerFailureDoesNotFailTheTask() async {
        servers.startError = MockError("pnpm: command not found")
        servers.logs[3001] = "zsh: command not found: pnpm"
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .completed)
        XCTAssertNil(model.task(id)?.serverPID)
        XCTAssertEqual(store.logs[id], "Dev server failed to start: pnpm: command not found\n")
        let running = await model.isServerRunning(taskID: id)
        XCTAssertFalse(running)
        let log = await model.serverLog(taskID: id)
        XCTAssertEqual(log, "zsh: command not found: pnpm\nDev server failed to start: pnpm: command not found")

        servers.startError = nil
        await model.restartServer(taskID: id)
        let restarted = await model.isServerRunning(taskID: id)
        XCTAssertTrue(restarted)
        let after = await model.serverLog(taskID: id)
        XCTAssertEqual(after, "zsh: command not found: pnpm")
    }

    func testServerThatDiesIsReportedNotRunning() async {
        let id = await createCompletedTask()
        let running = await model.isServerRunning(taskID: id)
        XCTAssertTrue(running)
        servers.crash(taskID: id)
        let dead = await model.isServerRunning(taskID: id)
        XCTAssertFalse(dead)
    }

    func testServerThatRunsButDoesNotAnswerIsReported() async {
        let id = await createCompletedTask()
        let answering = await model.isServerAnswering(taskID: id)
        XCTAssertTrue(answering)
        ports.silent = [model.task(id)!.port!]
        let silent = await model.isServerAnswering(taskID: id)
        XCTAssertFalse(silent)
        let running = await model.isServerRunning(taskID: id)
        XCTAssertTrue(running)
    }

    func testPortSkipsOnesHeldByOtherTasks() async {
        ports.taken = [3001]
        let first = await createCompletedTask()
        XCTAssertEqual(model.task(first)?.port, 3002)
        let second = model.createTask(projectID: project.id, prompt: "Another")!
        await waitForStatus(second, .completed)
        XCTAssertEqual(model.task(second)?.port, 3003)
    }

    func testIDsIncrementAndPersist() async {
        XCTAssertEqual(model.createTask(projectID: project.id, prompt: "One"), 3001)
        XCTAssertEqual(model.createTask(projectID: project.id, prompt: "Two"), 3002)
        await waitForStatus(3001, .completed)
        await waitForStatus(3002, .completed)
        await model.delete(taskID: 3002)
        await model.shutdown()
        XCTAssertEqual(store.state.nextTaskID, 3003)

        model = makeModel()
        await model.start()
        XCTAssertEqual(model.createTask(projectID: project.id, prompt: "Three"), 3003)
    }

    // MARK: Prompts

    func testPromptsSentWhileWorkingAreQueuedAndIntermediateOutcomeIsHidden() async {
        let (id, gate) = await createPausedTask(then: .needsInput(question: "Hidden?"))
        model.sendPrompt(taskID: id, text: "Also fix the header")
        model.sendPrompt(taskID: id, text: "And the footer")
        XCTAssertEqual(agent.requests.count, 1)
        XCTAssertEqual(status(id), .working)
        XCTAssertEqual(model.task(id)?.prompts.map(\.isPending), [false, true, true])

        var seen: Set<TaskStatus> = []
        let observer = observeStatuses(of: id) { seen.insert($0) }
        gate.open()
        await waitForStatus(id, .completed)
        await model.flush()
        observer.cancel()

        XCTAssertEqual(seen, [.completed])
        XCTAssertEqual(agent.requests.count, 2)
        XCTAssertEqual(agent.requests[1].prompt, "Also fix the header\n\nAnd the footer")
        XCTAssertEqual(agent.requests[1].sessionID, "s1")
        XCTAssertNil(model.task(id)?.question)
        XCTAssertEqual(model.task(id)?.prompts.map(\.isPending), [false, false, false])
        XCTAssertEqual(notifier.notifications.map(\.title), ["Do the thing is ready"])
    }

    func testPromptSentWhileWorkingGoesIntoTheRunningSession() async {
        agent.takesFollowUps = true
        let (id, gate) = await createPausedTask()
        model.sendPrompt(taskID: id, text: "Also create b.txt")
        XCTAssertEqual(agent.followUps, ["Also create b.txt"])
        XCTAssertEqual(model.task(id)?.prompts.map(\.isPending), [false, false])
        XCTAssertEqual(status(id), .working)

        gate.open()
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.requests.count, 1, "no second turn: the agent already had it")
    }

    func testPendingPromptIsDeliveredOnceTheAgentCanTakeIt() async {
        let first = Gate(), second = Gate()
        agent.scripts = [[.emit(.sessionStarted(id: "s1")), .pause(first), .listen, .emit(.activity("Editing…")),
                          .pause(second), .emit(.finished(.completed(summary: "Done")))]]
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("the agent to pause") { first.waiting == 1 }
        model.sendPrompt(taskID: id, text: "Also b.txt")
        XCTAssertEqual(model.task(id)?.prompts.last?.isPending, true)

        first.open()
        await waitFor("the follow-up to be delivered") { self.model.task(id)?.prompts.last?.isPending == false }
        XCTAssertEqual(agent.followUps, ["Also b.txt"])
        second.open()
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.requests.count, 1)
    }

    func testPendingPromptPersistsAsPendingAndIsDroppedOnRelaunch() async {
        let (id, _) = await createPausedTask()
        model.sendPrompt(taskID: id, text: "Queued")
        await model.flush()
        XCTAssertEqual(store.state.tasks.first?.prompts.last?.isPending, true)
        var saved = store.state.tasks[0]
        saved.status = .working
        git.existingBranches.insert(saved.branch)
        await relaunch(with: saved)
        XCTAssertEqual(model.task(id)?.prompts.map(\.text), ["Do the thing"])
    }

    func testPromptSentWhileTheRunIsSettlingIsNotLost() async {
        git.canMergeGate = Gate()
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("the run to reach the merge check") { self.git.canMergeGate?.waiting == 1 }

        model.sendPrompt(taskID: id, text: "One more thing")
        git.canMergeGate?.open()

        await waitFor("the second turn") { self.agent.requests.count == 2 }
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.requests[1].prompt, "Do it\n\nOne more thing")
    }

    // MARK: Merge

    func testMergeCleansUp() async {
        let id = await createCompletedTask()
        await model.merge(taskID: id)
        await model.flush()

        let task = model.task(id)!
        XCTAssertEqual(task.status, .merged)
        XCTAssertNotNil(task.mergedAt)
        XCTAssertNil(task.port)
        XCTAssertNil(task.serverPID)
        XCTAssertTrue(servers.running.isEmpty)
        XCTAssertTrue(git.existingBranches.isEmpty)
        XCTAssertEqual(git.calls.suffix(3), ["commit 3001", "merge shift/3001 into main", "remove shift/3001"])
        XCTAssertEqual(store.state.tasks.first?.status, .merged)
        XCTAssertEqual(notifier.badges.last, 0)
        XCTAssertNil(model.lastError)
    }

    // MARK: Base branches

    func testTaskKeepsItsBaseWhenTheProjectDefaultChanges() async {
        git.branchList = ["main", "develop"]
        let id = await createCompletedTask()
        project.baseBranch = "develop"
        model.updateProject(project)
        await model.merge(taskID: id)
        XCTAssertTrue(git.calls.contains("merge shift/\(id) into main"))
    }

    func testChangeBaseMovesTheWorkAndMergesThere() async {
        git.branchList = ["main", "develop"]
        let id = await createCompletedTask()
        let folder = model.task(id)!.worktreeURL.lastPathComponent
        await model.changeBase(taskID: id, to: "develop")
        XCTAssertTrue(git.calls.contains("rebase \(folder) from main onto develop"))
        XCTAssertEqual(model.task(id)?.baseBranch, "develop")
        XCTAssertEqual(status(id), .completed)
        await model.merge(taskID: id)
        XCTAssertTrue(git.calls.contains("merge shift/\(id) into develop"))
    }

    func testChangeBaseConflictGoesToTheAgent() async {
        git.branchList = ["main", "develop"]
        git.rebaseClean = false
        let id = await createCompletedTask()
        await model.changeBase(taskID: id, to: "develop")
        XCTAssertEqual(model.task(id)?.baseBranch, "develop")
        XCTAssertEqual(model.task(id)?.isResolvingConflict, true)
        await waitForStatus(id, .completed)
    }

    func testMergeKeepsABranchWhoseWorkIsNotInBase() async {
        let id = await createCompletedTask()
        git.contained = false
        await model.merge(taskID: id)
        XCTAssertEqual(status(id), .merged)
        XCTAssertTrue(git.existingBranches.contains("shift/\(id)"))
        XCTAssertNotNil(model.lastError)
    }

    func testMergeIntoAMissingBaseExplains() async {
        git.branchList = ["main", "develop"]
        let id = await createCompletedTask()
        git.branchList = ["develop"]
        await model.merge(taskID: id)
        XCTAssertEqual(status(id), .completed)
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("merge") })
        XCTAssertEqual(model.lastError?.contains("main no longer exists"), true)
    }

    func testPushCoversEveryBase() async {
        git.branchList = ["main", "develop"]
        _ = await createCompletedTask()
        project.baseBranch = "develop"
        model.updateProject(project)
        _ = await createCompletedTask()
        git.unpushed = 1
        await model.refreshPushState(projectID: project.id)
        XCTAssertEqual(model.pushStates[project.id], .init(remote: "origin", unpushed: 2, branches: ["develop", "main"]))
        await model.push(projectID: project.id)
        XCTAssertTrue(git.calls.contains("push develop to origin"))
        XCTAssertTrue(git.calls.contains("push main to origin"))
    }

    // MARK: Push

    func testPushStateFollowsTheRemote() async {
        git.remoteName = nil
        await model.refreshPushState(projectID: project.id)
        XCTAssertNil(model.pushStates[project.id])

        git.remoteName = "origin"
        git.unpushed = 2
        await model.refreshPushState(projectID: project.id)
        XCTAssertEqual(model.pushStates[project.id], .init(remote: "origin", unpushed: 2, branches: ["main"]))
    }

    func testCompletedTaskPushesItsBranchWhenTheProjectSaysSo() async {
        let first = await createCompletedTask()
        XCTAssertFalse(git.calls.contains("push shift/\(first) to origin"))

        project.pushTaskBranches = true
        model.updateProject(project)
        let second = await createCompletedTask()
        await waitFor("the branch push") { self.git.calls.contains("push shift/\(second) to origin") }
        XCTAssertNil(model.lastError)
    }

    func testMergeRefreshesPushState() async {
        let id = await createCompletedTask()
        git.unpushed = 1
        await model.merge(taskID: id)
        XCTAssertEqual(model.pushStates[project.id]?.unpushed, 1)
    }

    func testPushShowsProgressThenNothingToPush() async {
        git.unpushed = 3
        await model.refreshPushState(projectID: project.id)
        let gate = Gate()
        git.pushGate = gate
        let push = Task { await model.push(projectID: project.id) }
        await waitFor("the push to start") { gate.waiting == 1 }
        XCTAssertEqual(model.pushStates[project.id]?.isPushing, true)
        // A refresh while pushing must not clear the spinner.
        await model.refreshPushState(projectID: project.id)
        XCTAssertEqual(model.pushStates[project.id]?.isPushing, true)
        gate.open()
        await push.value
        XCTAssertEqual(model.pushStates[project.id], .init(remote: "origin", unpushed: 0))
        XCTAssertEqual(git.calls.last, "push main to origin")
        XCTAssertNil(model.lastError)

        // Nothing to push: nothing happens.
        await model.push(projectID: project.id)
        XCTAssertEqual(git.calls.filter { $0.hasPrefix("push") }.count, 1)
    }

    func testPushFailureIsReportedAndKeepsTheCount() async {
        git.unpushed = 2
        await model.refreshPushState(projectID: project.id)
        git.pushError = MockError("Couldn't sign in to github.com. Check your Git credentials.")
        await model.push(projectID: project.id)
        XCTAssertEqual(model.lastError, "Couldn't sign in to github.com. Check your Git credentials.")
        XCTAssertEqual(model.pushStates[project.id], .init(remote: "origin", unpushed: 2, branches: ["main"]))
    }

    func testMergeConflictThenResolveCompletes() async {
        let id = await createCompletedTask()
        git.mergeResult = .conflict
        await model.merge(taskID: id)
        XCTAssertEqual(status(id), .conflict)
        XCTAssertEqual(servers.running[id], model.task(id)?.serverPID)
        XCTAssertTrue(git.existingBranches.contains("shift/3001"))

        model.resolveConflict(taskID: id)
        XCTAssertEqual(status(id), .working)
        XCTAssertEqual(model.task(id)?.isResolvingConflict, true)

        await waitForStatus(id, .completed)
        XCTAssertEqual(model.task(id)?.isResolvingConflict, false)
        XCTAssertEqual(agent.requests.count, 2)
        XCTAssertTrue(agent.requests[1].prompt.contains("Merge `main` into this branch"))
        XCTAssertEqual(model.task(id)?.prompts.count, 1)
    }

    func testResolveThatStillConflictsBlocks() async {
        git.canMerge = false
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .conflict)

        model.resolveConflict(taskID: id)
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "The conflict with main could not be resolved.")
        XCTAssertEqual(model.task(id)?.isResolvingConflict, false)
    }

    func testResolveWhereAgentFailsBlocks() async {
        git.canMerge = false
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitForStatus(id, .conflict)

        agent.scripts = [[.emit(.finished(.blocked(reason: "Tests fail")))]]
        model.resolveConflict(taskID: id)
        await waitForStatus(id, .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Tests fail")
    }

    func testMergeFailureLeavesStatusAndReportsError() async {
        let id = await createCompletedTask()
        git.mergeError = MockError("base has uncommitted changes")
        await model.merge(taskID: id)

        XCTAssertEqual(status(id), .completed)
        XCTAssertEqual(model.lastError, "Could not merge Do the thing: base has uncommitted changes")
        XCTAssertNotNil(servers.running[id])
        XCTAssertTrue(git.existingBranches.contains("shift/3001"))
    }

    func testMergeWhileAgentIsRunningStopsItAndCleansUp() async {
        let (id, gate) = await createPausedTask()
        await model.merge(taskID: id)
        XCTAssertEqual(status(id), .merged)
        await waitFor("the agent to be terminated") { self.agent.terminated == 1 }

        gate.open()
        await model.flush()
        XCTAssertEqual(status(id), .merged)
        XCTAssertTrue(servers.running.isEmpty)
        XCTAssertTrue(git.existingBranches.isEmpty)
        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    func testFailedMergeWhileAgentWasRunningDoesNotLeaveItWorking() async {
        let (id, _) = await createPausedTask()
        git.mergeError = MockError("nope")
        await model.merge(taskID: id)
        XCTAssertEqual(status(id), .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Stopped")
        XCTAssertNotNil(model.lastError)
    }

    // MARK: Stop

    func testStopBlocksAndLateEventsAreIgnored() async {
        let (id, gate) = await createPausedTask()
        model.sendPrompt(taskID: id, text: "Queued, then abandoned")
        model.stop(taskID: id)

        XCTAssertEqual(status(id), .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Stopped")
        XCTAssertNil(model.task(id)?.activity)
        XCTAssertEqual(model.task(id)?.prompts.map(\.text), ["Do the thing"], "never sent, so not in the history")

        await waitFor("the agent to be terminated") { self.agent.terminated == 1 }
        gate.open()
        await model.flush()
        XCTAssertEqual(status(id), .blocked)
        XCTAssertEqual(agent.requests.count, 1)
        XCTAssertTrue(notifier.notifications.isEmpty)
        XCTAssertEqual(store.state.tasks.first?.status, .blocked)
        // Stopping keeps the task's resources: it can be restarted.
        XCTAssertNotNil(servers.running[id])
    }

    func testStoppedTaskRestartsWithAPrompt() async {
        let (id, _) = await createPausedTask()
        model.stop(taskID: id)
        model.sendPrompt(taskID: id, text: "Carry on")
        XCTAssertEqual(status(id), .working)
        XCTAssertNil(model.task(id)?.blockedReason)

        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.requests.count, 2)
        XCTAssertEqual(agent.requests[1].sessionID, "s1")
        XCTAssertEqual(agent.requests[1].prompt, "Carry on")
    }

    func testStopWhileSettlingIsNotOverwrittenByTheLateResult() async {
        git.canMergeGate = Gate()
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("the run to reach the merge check") { self.git.canMergeGate?.waiting == 1 }

        model.stop(taskID: id)
        git.canMergeGate?.open()
        git.canMergeGate = nil
        let second = Gate()
        agent.scripts = [[.pause(second)]]
        // A restart waits for the stopped run to be completely gone, so once this one has
        // finished, anything the old run was going to write has had its chance.
        model.sendPrompt(taskID: id, text: "Again")
        await waitFor("the second run") { second.waiting == 1 }
        model.stop(taskID: id)
        await model.flush()

        XCTAssertEqual(status(id), .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Stopped")
        XCTAssertNil(model.task(id)?.summary)
        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    func testStopDuringSetupRollsBackAndRestartSetsUpAgain() async {
        let gate = Gate()
        git.createGate = gate
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("worktree creation to start") { gate.waiting == 1 }

        model.stop(taskID: id)
        git.createGate = nil
        gate.open()
        model.sendPrompt(taskID: id, text: "Go on")
        await waitForStatus(id, .completed)

        XCTAssertEqual(git.calls, ["create shift/3001 from main", "remove shift/3001",
                                   "create shift/3001 from main", "commit 3001"])
        XCTAssertEqual(agent.requests.map(\.prompt), ["Do it\n\nGo on"])
        XCTAssertNotNil(servers.running[id])
    }

    // MARK: Delete

    func testDeleteReleasesEverything() async {
        let id = await createCompletedTask()
        await model.delete(taskID: id)
        await model.flush()

        XCTAssertNil(model.task(id))
        XCTAssertTrue(servers.running.isEmpty)
        XCTAssertTrue(git.existingBranches.isEmpty)
        XCTAssertEqual(git.calls.last, "remove shift/3001")
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("merge") })
        XCTAssertNil(store.logs[id])
        XCTAssertTrue(store.state.tasks.isEmpty)
        XCTAssertEqual(notifier.badges.last, 0)
    }

    func testDeleteWhileAgentIsRunning() async {
        let (id, gate) = await createPausedTask()
        await model.delete(taskID: id)
        XCTAssertNil(model.task(id))
        await waitFor("the agent to be terminated") { self.agent.terminated == 1 }

        gate.open()
        await model.flush()
        XCTAssertTrue(model.tasks.isEmpty)
        XCTAssertTrue(servers.running.isEmpty)
        XCTAssertTrue(git.existingBranches.isEmpty)
        XCTAssertTrue(notifier.notifications.isEmpty)
    }

    func testDeleteDuringSetupDoesNotLeakTheWorktree() async {
        let gate = Gate()
        git.createGate = gate
        let id = model.createTask(projectID: project.id, prompt: "Do it")!
        await waitFor("worktree creation to start") { gate.waiting == 1 }

        let deletion = Task { await self.model.delete(taskID: id) }
        await waitFor("the delete to cancel the run") { gate.cancellations == 1 }
        gate.open()
        await deletion.value

        XCTAssertNil(model.task(id))
        XCTAssertTrue(git.existingBranches.isEmpty)
        XCTAssertEqual(git.calls.first, "create shift/3001 from main")
        XCTAssertEqual(git.calls.last, "remove shift/3001")
        XCTAssertTrue(servers.running.isEmpty)
        XCTAssertTrue(agent.requests.isEmpty)
    }

    // MARK: Recovery

    func testRecoveryInterruptedWorkBecomesBlockedAndKeepsSession() async {
        git.existingBranches = ["shift/2001"]
        await relaunch(with: savedTask(2001, status: .working, serverPID: 77))

        let task = model.task(2001)!
        XCTAssertEqual(task.status, .blocked)
        XCTAssertEqual(task.blockedReason, "Interrupted when Shift quit.")
        XCTAssertEqual(task.sessionID, "s9")
        XCTAssertEqual(servers.stoppedOrphans, [77])
        XCTAssertEqual(servers.starts, [.init(taskID: 2001, command: "pnpm dev", port: 2001)])
        XCTAssertEqual(task.serverPID, servers.running[2001])
        XCTAssertEqual(store.state.tasks, model.tasks)
        XCTAssertEqual(notifier.badges.last, 1)

        model.sendPrompt(taskID: 2001, text: "Continue")
        await waitForStatus(2001, .completed)
        XCTAssertEqual(agent.requests.first?.sessionID, "s9")
        XCTAssertEqual(agent.requests.first?.prompt, "Continue")
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("create") })
    }

    // MARK: Server without a server command

    func useNoServerCommand() {
        project.serverCommand = ""
        model.updateProject(project)
    }

    func testAppProjectBuildsInsteadOfRunningAServer() async {
        project.buildCommand = "scripts/build.sh"
        model.updateProject(project)
        let id = await createCompletedTask()
        XCTAssertTrue(servers.starts.isEmpty)
        XCTAssertNil(model.task(id)?.port)

        let app = temp.appendingPathComponent("Spot.app")
        try? FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        servers.runResult = CommandResult(exitCode: 0, output: "Compiling…\n\(app.path)\n")
        let built = await model.build(taskID: id)
        XCTAssertEqual(built?.path, app.path)
        XCTAssertEqual(model.builds[id], .succeeded(app: built))
        XCTAssertEqual(servers.runs.last?.command, "scripts/build.sh")
        XCTAssertEqual(servers.runs.last?.environment["SHIFT_TASK"], String(id))

        servers.runResult = CommandResult(exitCode: 65, output: "error: nope\n")
        let failed = await model.build(taskID: id)
        XCTAssertNil(failed)
        XCTAssertEqual(model.builds[id], .failed("Build failed (exit code 65)."))
        XCTAssertTrue(model.buildLog(taskID: id).hasSuffix("error: nope\n"))
    }

    func testBaseServerRunsOnTheRepoAndComesBackWhenOpened() async {
        XCTAssertEqual(servers.baseStarts, [.init(taskID: -1, command: "pnpm dev", port: 3000)])
        XCTAssertEqual(model.basePorts[project.id], 3000)
        model.baseServerPoll = .milliseconds(1)
        servers.crash(taskID: -1)
        // Opened only once the restarted server answers on its port.
        async let opened = model.baseServerURL(projectID: project.id)
        await waitFor("the base server to restart") { self.servers.baseStarts.count == 2 && self.model.openingBase == [self.project.id] }
        ports.taken = [3000]
        let url = await opened
        XCTAssertEqual(url, URL(string: "http://localhost:3000"))
        XCTAssertEqual(model.openingBase, [])
        // Running and answering: opened right away.
        let again = await model.baseServerURL(projectID: project.id)
        XCTAssertEqual(again, url)
        XCTAssertEqual(servers.baseStarts.count, 2)

        // Quit without serving (Next.js, with a dev server already on the folder): opens the one its output names.
        servers.crash(taskID: -1)
        servers.exitOnStart = true
        ports.taken = [3000, 3005]
        servers.logs[-1] = "- Local: http://localhost:3001\nYou can access the existing server at http://localhost:3005,"
        let existing = await model.baseServerURL(projectID: project.id)
        XCTAssertEqual(existing, URL(string: "http://localhost:3005"))
        XCTAssertNil(model.lastError)
        // Nothing to open: says so.
        servers.logs[-1] = "npm: command not found"
        let none = await model.baseServerURL(projectID: project.id)
        XCTAssertNil(none)
        XCTAssertEqual(model.lastError?.hasPrefix("The server for Spot did not start on port 3001."), true)
        servers.exitOnStart = false
        ports.taken = []

        var app = project!
        app.buildCommand = "scripts/build.sh"
        model.updateProject(app)
        await waitFor("the base server to stop") { self.model.basePorts[self.project.id] == nil }
        XCTAssertTrue(servers.baseRunning.isEmpty)
    }

    func testBecomingAnAppReleasesTaskPorts() async {
        let id = await createCompletedTask()
        XCTAssertNotNil(model.task(id)?.port)
        project.buildCommand = "scripts/build.sh"
        model.updateProject(project)
        XCTAssertNil(model.task(id)?.port)

        await relaunch(with: savedTask(7, status: .completed))
        XCTAssertNil(model.task(7)?.port)
    }

    func testProjectWithoutServerCommandStillGetsAServer() async {
        useNoServerCommand()
        let id = await createCompletedTask()
        XCTAssertEqual(servers.starts, [.init(taskID: id, command: ProjectSetup.serverCommand(for: project), port: id)])
        XCTAssertEqual(servers.starts[0].command, ProjectSetup.staticServer)
        XCTAssertEqual(model.task(id)?.serverPID, servers.running[id])
    }

    func testServerSwitchesToTheDevScriptTheAgentCreated() async throws {
        useNoServerCommand()
        let (id, gate) = await createPausedTask()
        XCTAssertEqual(servers.starts.map(\.command), [ProjectSetup.staticServer])

        // The agent scaffolds a Next.js app in the empty folder, without installing it.
        let worktree = model.task(id)!.worktreeURL
        try Data(#"{"scripts":{"dev":"next dev"}}"#.utf8).write(to: worktree.appendingPathComponent("package.json"))
        gate.open()
        await waitForStatus(id, .completed)
        await model.flush()
        XCTAssertEqual(servers.starts.map(\.command), [ProjectSetup.staticServer, "npm install && npm run dev"])

        // Installed now: a restart runs the script alone.
        try FileManager.default.createDirectory(at: worktree.appendingPathComponent("node_modules"),
                                                withIntermediateDirectories: true)
        await model.restartServer(taskID: id)
        XCTAssertEqual(servers.starts.last?.command, "npm run dev")
    }

    func testRestartMovesOffAPortSomethingElseTookMeanwhile() async {
        let id = await createCompletedTask()
        XCTAssertEqual(model.task(id)?.port, id)
        ports.taken = [id]  // another project's server grabbed it while ours was down
        await model.restartServer(taskID: id)
        XCTAssertEqual(model.task(id)?.port, id + 1)
        XCTAssertEqual(servers.starts.last?.port, id + 1)
    }

    func testTaskFromBeforeEveryTaskHadAServerGetsOneOnLaunchAndRestart() async {
        project.serverCommand = ""
        git.existingBranches = ["shift/2001", "shift/2002"]
        var old = savedTask(2001, status: .completed)
        old.port = nil
        let other = savedTask(2002, status: .completed)
        ports.taken = [2001]
        store.state = AppState(projects: [project], tasks: [other, old], nextTaskID: 2003)
        model = makeModel()
        await model.start()
        await model.flush()

        let command = ProjectSetup.serverCommand(for: project)
        XCTAssertEqual(model.task(2001)?.port, 2003, "2001 is in use and 2002 belongs to the other task")
        XCTAssertEqual(servers.starts, [.init(taskID: 2002, command: command, port: 2002),
                                        .init(taskID: 2001, command: command, port: 2003)])
        XCTAssertEqual(store.state.tasks, model.tasks)

        await model.restartServer(taskID: 2001)
        XCTAssertEqual(servers.starts.last, .init(taskID: 2001, command: command, port: 2003))
        XCTAssertEqual(servers.starts.count, 3)
    }

    // MARK: Title and description

    func testAgentTitleAndDescriptionReplaceTheLocalTitle() async {
        let gate = Gate()
        agent.scripts.append([.emit(.sessionStarted(id: "s1")), .pause(gate),
                              .emit(.described(title: "Marketing homepage", description: "The homepage sells the brand first.")),
                              .emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "the homepage as is is focused on ordering")!
        await waitFor("the agent to pause") { gate.waiting == 1 }
        XCTAssertEqual(model.task(id)?.title, "the homepage as is is focused on ordering")
        XCTAssertNil(model.task(id)?.description)

        gate.open()
        await waitForStatus(id, .completed)
        await model.flush()
        XCTAssertEqual(model.task(id)?.title, "Marketing homepage")
        XCTAssertEqual(model.task(id)?.description, "The homepage sells the brand first.")
        XCTAssertEqual(notifier.notifications.last?.title, "Marketing homepage is ready")
        XCTAssertEqual(store.state.tasks, model.tasks)
    }

    func testPartialOrMissingDescriptionKeepsWhatIsThere() async {
        let id = await createCompletedTask()
        XCTAssertEqual(model.task(id)?.title, "Do the thing")

        agent.scripts.append([.emit(.described(title: nil, description: "Why it matters.")),
                              .emit(.finished(.completed(summary: "Done")))])
        model.sendPrompt(taskID: id, text: "More")
        await waitFor("the second run") { self.agent.requests.count == 2 && self.status(id) == .completed }
        XCTAssertEqual(model.task(id)?.title, "Do the thing")
        XCTAssertEqual(model.task(id)?.description, "Why it matters.")

        agent.scripts.append([.emit(.described(title: "New goal", description: nil)),
                              .emit(.finished(.completed(summary: "Done")))])
        model.sendPrompt(taskID: id, text: "Change of plan")
        await waitFor("the third run") { self.agent.requests.count == 3 && self.status(id) == .completed }
        XCTAssertEqual(model.task(id)?.title, "New goal")
        XCTAssertEqual(model.task(id)?.description, "Why it matters.")
    }

    func testStartingAgainDoesNotInterruptRunningTasks() async {
        // The window calls start() every time it is reopened.
        let gate = Gate()
        agent.scripts.append([.emit(.sessionStarted(id: "s1")), .pause(gate), .emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "Do the thing")!
        await waitFor("the agent to pause") { gate.waiting == 1 }
        let startsBefore = servers.starts.count

        await model.start()
        XCTAssertEqual(status(id), .working)
        XCTAssertEqual(servers.starts.count, startsBefore)

        gate.open()
        await waitForStatus(id, .completed)
    }

    func testTaskWithoutDescriptionAsksForOneOnItsNextTurn() async {
        // Tasks created before agents wrote titles have a session but no description.
        let id = await createCompletedTask()
        XCTAssertNil(model.task(id)?.description)

        agent.scripts.append([.emit(.described(title: "Real title", description: "What it does.")),
                              .emit(.finished(.completed(summary: "Done")))])
        model.sendPrompt(taskID: id, text: "More")
        await waitFor("the second run") { self.agent.requests.count == 2 && self.status(id) == .completed }
        XCTAssertTrue(agent.requests[1].needsDescription)

        agent.scripts.append([.emit(.finished(.completed(summary: "Done")))])
        model.sendPrompt(taskID: id, text: "Even more")
        await waitFor("the third run") { self.agent.requests.count == 3 && self.status(id) == .completed }
        XCTAssertFalse(agent.requests[2].needsDescription)
    }

    func testResolvingAConflictDoesNotRenameTheTask() async {
        git.canMerge = false
        let id = model.createTask(projectID: project.id, prompt: "Do the thing")!
        await waitForStatus(id, .conflict)
        git.canMerge = true
        agent.scripts.append([.emit(.described(title: "Resolve merge conflicts", description: "Merging main.")),
                              .emit(.finished(.completed(summary: "Resolved")))])
        model.resolveConflict(taskID: id)
        await waitForStatus(id, .completed)
        XCTAssertEqual(model.task(id)?.title, "Do the thing")
        XCTAssertNil(model.task(id)?.description)
    }

    func testMissingWorktreeIsRecreatedOnRestartServer() async {
        useSetupCommand()
        git.existingBranches = ["shift/2001"]
        await relaunch(with: savedTask(2001, status: .completed, worktreeExists: false, serverPID: 77))

        XCTAssertEqual(status(2001), .completed)
        XCTAssertEqual(servers.stoppedOrphans, [77])
        XCTAssertTrue(servers.starts.isEmpty)
        XCTAssertNil(model.task(2001)?.serverPID)

        await model.restartServer(taskID: 2001)
        XCTAssertTrue(FileManager.default.fileExists(atPath: temp.path + "/gone"))
        XCTAssertEqual(git.calls, ["add shift/2001", "exclude gone"])
        XCTAssertEqual(servers.runs.map(\.command), ["pnpm install"])
        XCTAssertEqual(servers.starts, [.init(taskID: 2001, command: "pnpm dev", port: 2001)])
        XCTAssertEqual(status(2001), .completed)
        XCTAssertTrue(agent.requests.isEmpty)
    }

    func testMissingWorktreeIsRecreatedBeforeTheAgentRuns() async {
        useSetupCommand()
        git.existingBranches = ["shift/2001"]
        await relaunch(with: savedTask(2001, status: .working, worktreeExists: false))
        XCTAssertTrue(model.task(2001)!.canResume)

        model.resume(taskID: 2001)
        await waitForStatus(2001, .completed)
        XCTAssertEqual(Array(git.calls.prefix(2)), ["add shift/2001", "exclude gone"])
        XCTAssertEqual(servers.runs.count, 1)
        XCTAssertEqual(servers.starts.count, 1)
        XCTAssertEqual(agent.requests.first?.sessionID, "s9", "the branch still has the work: same session")
        XCTAssertEqual(agent.requests.first?.worktree.path, temp.path + "/gone")
    }

    func testMissingBranchStartsOverFromBase() async {
        var saved = savedTask(2001, status: .working, worktreeExists: false)
        saved.prompts = [Prompt(text: "Do the thing")]
        await relaunch(with: saved)
        XCTAssertEqual(status(2001), .blocked)
        XCTAssertEqual(model.task(2001)?.blockedReason,
                       "The branch shift/2001 is missing. Send a prompt to start the task again from main.")

        model.sendPrompt(taskID: 2001, text: "Again")
        await waitForStatus(2001, .completed)
        XCTAssertEqual(git.calls.first, "create shift/2001 from main")
        XCTAssertNil(agent.requests.first?.sessionID)
        XCTAssertEqual(agent.requests.first?.prompt, "Do the thing\n\nAgain")
    }

    func testRecoveryExternallyMergedIsCleanedUp() async {
        git.existingBranches = ["shift/2001"]
        git.merged = true
        await relaunch(with: savedTask(2001, status: .completed, serverPID: 77))

        let task = model.task(2001)!
        XCTAssertEqual(task.status, .merged)
        XCTAssertNotNil(task.mergedAt)
        XCTAssertNil(task.port)
        XCTAssertNil(task.serverPID)
        XCTAssertEqual(git.calls, ["remove shift/2001"])
        XCTAssertEqual(servers.stoppedOrphans, [77])
        XCTAssertTrue(servers.running.isEmpty)
    }

    func testRecoveryDoesNotTreatUnfinishedOrDirtyWorkAsMerged() async {
        git.existingBranches = ["shift/2001"]
        git.merged = true
        // A branch without commits yet is "merged" as far as git can tell.
        await relaunch(with: savedTask(2001, status: .needsInput))
        XCTAssertEqual(status(2001), .needsInput)

        git.pendingChanges = DiffSummary(files: [FileChange(path: "a.txt", kind: .modified)])
        await relaunch(with: savedTask(2001, status: .completed))
        XCTAssertEqual(status(2001), .completed)
        XCTAssertEqual(git.calls, [])
    }

    func testRecoveryLeavesMergedTasksAlone() async {
        await relaunch(with: savedTask(2001, status: .merged, worktreeExists: false))
        XCTAssertEqual(status(2001), .merged)
        XCTAssertTrue(servers.starts.isEmpty)
    }

    func testStartDetectsAgents() {
        XCTAssertEqual(model.installedAgents, [.claudeCode: AgentInstallation(path: "/usr/local/bin/agent")])
    }

    // MARK: Manual permissions

    /// A manual-permissions task whose agent waits for an answer to "Run `pnpm install`".
    func createTaskAwaitingApproval(then rest: [MockAgent.Step] = [.emit(.finished(.completed(summary: "Installed")))])
        async -> Int {
        project.permissions = .manual
        model.updateProject(project)
        agent.scripts.append([.emit(.sessionStarted(id: "s1")), .emit(.activity("Installing…")),
                              .ask(id: "a1", summary: "Run `pnpm install`")] + rest)
        let id = model.createTask(projectID: project.id, prompt: "Add date-fns")!
        await waitForStatus(id, .needsInput)
        return id
    }

    func testApprovalAllowedContinuesTheSameRun() async {
        let id = await createTaskAwaitingApproval()
        let task = model.task(id)!
        XCTAssertEqual(task.approvalRequest, "Run `pnpm install`")
        XCTAssertNil(task.question)
        XCTAssertNil(task.activity)
        XCTAssertEqual(agent.requests.first?.permissions, .manual)
        await model.flush()
        XCTAssertEqual(notifier.notifications, [.init(title: "Add date-fns needs your approval", body: "Run `pnpm install`", taskID: id)])
        XCTAssertEqual(notifier.badges.last, 1)
        XCTAssertEqual(store.state.tasks.first?.approvalRequest, "Run `pnpm install`")

        model.answerApproval(taskID: id, allow: true)
        XCTAssertEqual(status(id), .working)
        XCTAssertNil(model.task(id)?.approvalRequest)

        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.answers, [.init(id: "a1", allow: true)])
        XCTAssertEqual(agent.requests.count, 1)
        XCTAssertEqual(model.task(id)?.summary, "Installed")
        XCTAssertNil(model.task(id)?.approvalRequest)
    }

    func testApprovalDeniedAgentCarriesOn() async {
        let id = await createTaskAwaitingApproval(then: [.emit(.finished(.completed(summary: "Skipped the install")))])
        model.answerApproval(taskID: id, allow: false)
        XCTAssertEqual(status(id), .working)
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.answers, [.init(id: "a1", allow: false)])
        XCTAssertEqual(agent.requests.count, 1)
        // Answering again, or with nothing pending, does nothing.
        model.answerApproval(taskID: id, allow: true)
        XCTAssertEqual(agent.answers.count, 1)
    }

    func testApprovalsAreShownOneAtATime() async {
        let id = await createTaskAwaitingApproval(then: [.ask(id: "a2", summary: "Edit `src/app.css`"),
                                                          .emit(.finished(.completed(summary: "Done")))])
        model.answerApproval(taskID: id, allow: true)
        await waitFor("the second request") { self.model.task(id)?.approvalRequest == "Edit `src/app.css`" }
        XCTAssertEqual(status(id), .needsInput)
        model.answerApproval(taskID: id, allow: false)
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.answers, [.init(id: "a1", allow: true), .init(id: "a2", allow: false)])
        await model.flush()
        XCTAssertEqual(notifier.notifications.map(\.body), ["Run `pnpm install`", "Edit `src/app.css`", "Done"])
    }

    func testPromptInsteadOfAnAnswerDeniesWithIt() async {
        let id = await createTaskAwaitingApproval()
        model.sendPrompt(taskID: id, text: "Use npm instead")
        XCTAssertEqual(status(id), .working)
        XCTAssertNil(model.task(id)?.approvalRequest)
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.answers, [.init(id: "a1", allow: false, message: "Use npm instead")])
        XCTAssertEqual(agent.requests.count, 1, "the agent took the prompt with the denial")
        XCTAssertEqual(model.task(id)?.prompts.map(\.text), ["Add date-fns", "Use npm instead"])
    }

    func testPromptInsteadOfAnAnswerIsQueuedIfTheAgentTakesNoMessage() async {
        agent = MockAgent(takesMessages: false)
        model = makeModel()
        await model.start()
        let id = await createTaskAwaitingApproval()
        model.sendPrompt(taskID: id, text: "Use npm instead")
        XCTAssertEqual(status(id), .working)
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.answers, [.init(id: "a1", allow: false, message: "Use npm instead")])
        XCTAssertEqual(agent.requests.map(\.prompt), ["Add date-fns", "Use npm instead"])
        XCTAssertEqual(agent.requests.last?.sessionID, "s1")
    }

    func testStopWhileApprovalIsPending() async {
        let id = await createTaskAwaitingApproval()
        model.stop(taskID: id)
        XCTAssertEqual(status(id), .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Stopped")
        XCTAssertNil(model.task(id)?.approvalRequest)
        await waitFor("the agent to be terminated") { self.agent.terminated == 1 }
        model.answerApproval(taskID: id, allow: true)
        XCTAssertTrue(agent.answers.isEmpty)
        XCTAssertEqual(status(id), .blocked)
        await model.flush()
        XCTAssertNil(store.state.tasks.first?.approvalRequest)

        model.sendPrompt(taskID: id, text: "Carry on")
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.requests.last?.prompt, "Carry on")
    }

    func testMergeWhileApprovalIsPending() async {
        let id = await createTaskAwaitingApproval()
        await model.merge(taskID: id)
        XCTAssertEqual(status(id), .merged)
        XCTAssertNil(model.task(id)?.approvalRequest)
        await waitFor("the agent to be terminated") { self.agent.terminated == 1 }
    }

    func testDeleteWhileApprovalIsPending() async {
        let id = await createTaskAwaitingApproval()
        await model.delete(taskID: id)
        XCTAssertNil(model.task(id))
        await waitFor("the agent to be terminated") { self.agent.terminated == 1 }
        XCTAssertTrue(git.existingBranches.isEmpty)
    }

    func testShutdownWhileApprovalIsPending() async {
        let id = await createTaskAwaitingApproval()
        await model.shutdown()
        XCTAssertEqual(status(id), .blocked)
        XCTAssertEqual(store.state.tasks.first?.blockedReason, AppModel.interruptedReason)
        XCTAssertNil(store.state.tasks.first?.approvalRequest)
    }

    func testRestartWithAPendingApprovalBecomesInterrupted() async {
        git.existingBranches = ["shift/2001"]
        var saved = savedTask(2001, status: .needsInput)
        saved.approvalRequest = "Run `pnpm install`"
        await relaunch(with: saved)
        let task = model.task(2001)!
        XCTAssertEqual(task.status, .blocked)
        XCTAssertEqual(task.blockedReason, AppModel.interruptedReason)
        XCTAssertNil(task.approvalRequest)
        XCTAssertEqual(task.sessionID, "s9")
        XCTAssertEqual(store.state.tasks, model.tasks)
    }

    // MARK: Shutdown

    func testShutdownStopsEverythingAndFlushes() async {
        let (id, gate) = await createPausedTask()
        await model.shutdown()
        gate.open()

        await waitFor("the agent to be terminated") { self.agent.terminated == 1 }
        XCTAssertTrue(servers.stoppedAll)
        XCTAssertEqual(store.state.tasks.first?.status, .blocked)
        XCTAssertEqual(store.state.tasks.first?.blockedReason, AppModel.interruptedReason)
        XCTAssertNil(store.state.tasks.first?.serverPID)
        XCTAssertEqual(store.state.tasks, model.tasks)
        XCTAssertEqual(status(id), .blocked)
    }

    // MARK: Projects

    func testAddProjectRejectsNonRepository() async {
        git.isRepo = false
        let added = await model.addProject(at: temp.appendingPathComponent("notes"))
        XCTAssertNil(added)
        XCTAssertEqual(model.lastError, "notes is not a Git repository.")
        XCTAssertEqual(model.projects.count, 1)
    }

    func testAddProjectInitializesGitWhenAsked() async {
        git.isRepo = false
        let added = await model.addProject(at: temp.appendingPathComponent("notes"), initializingGit: true)
        XCTAssertEqual(added?.name, "notes")
        XCTAssertEqual(git.calls, ["init notes"])
        XCTAssertNil(model.lastError)
    }

    func testAddProjectDefaults() async {
        git.branchList = ["develop", "master"]
        let added = await model.addProject(at: temp.appendingPathComponent("site"))
        await model.flush()
        XCTAssertEqual(added?.name, "site")
        XCTAssertEqual(added?.baseBranch, "master")
        XCTAssertEqual(added?.defaultAgent, .claudeCode)
        XCTAssertEqual(store.state.projects.count, 2)

        git.branchList = ["develop"]
        git.current = "develop"
        let other = await model.addProject(at: temp.appendingPathComponent("other"))
        XCTAssertEqual(other?.baseBranch, "develop")
    }

    func testMoveProjectsPersistsOrder() async {
        await model.addProject(at: temp.appendingPathComponent("b"))
        await model.addProject(at: temp.appendingPathComponent("c"))
        let names = { self.model.projects.map(\.name) }
        let first = names()[0]
        model.moveProjects(from: [2], to: 0)
        XCTAssertEqual(names(), ["c", first, "b"])
        model.moveProjects(from: [0], to: 3)
        XCTAssertEqual(names(), [first, "b", "c"])
        await model.flush()
        XCTAssertEqual(store.state.projects.map(\.name), [first, "b", "c"])
    }

    func testRemoveProjectDeletesItsTasks() async {
        let id = await createCompletedTask()
        await model.removeProject(project.id)
        await model.flush()
        XCTAssertNil(model.task(id))
        XCTAssertTrue(model.projects.isEmpty)
        XCTAssertTrue(servers.running.isEmpty)
        XCTAssertTrue(git.existingBranches.isEmpty)
        XCTAssertEqual(store.state, AppState(projects: [], tasks: [], nextTaskID: 3002))
    }

    func testInstructionFiles() throws {
        XCTAssertEqual(model.instructionFiles(for: project.id), [])
        try "x".write(to: temp.appendingPathComponent("CLAUDE.md"), atomically: true, encoding: .utf8)
        XCTAssertEqual(model.instructionFiles(for: project.id), ["CLAUDE.md"])
    }

    func testRestartServer() async {
        let id = await createCompletedTask()
        await model.restartServer(taskID: id)
        XCTAssertEqual(servers.starts.count, 2)
        XCTAssertEqual(model.task(id)?.serverPID, servers.running[id])

        servers.startError = MockError("port in use")
        await model.restartServer(taskID: id)
        XCTAssertEqual(model.lastError, "Dev server failed to start: port in use")
        XCTAssertNil(model.task(id)?.serverPID)
    }

    // MARK: Resume

    func testStoppedTaskResumesWithoutANewPrompt() async {
        let (id, _) = await createPausedTask()
        XCTAssertFalse(model.task(id)!.canResume)
        model.stop(taskID: id)
        XCTAssertTrue(model.task(id)!.canResume)

        model.resume(taskID: id)
        XCTAssertEqual(status(id), .working)
        await waitForStatus(id, .completed)
        XCTAssertEqual(agent.requests.last?.prompt, "Continue the task.")
        XCTAssertEqual(agent.requests.last?.sessionID, "s1")
        XCTAssertEqual(model.task(id)?.prompts.map(\.text), ["Do the thing"])
        XCTAssertFalse(model.task(id)!.canResume)
        model.resume(taskID: id)
        XCTAssertEqual(status(id), .completed, "only stopped or interrupted tasks resume")
    }

    // MARK: Mergeability

    func testRefreshFlipsBetweenCompletedAndConflictAndNotifiesOnce() async {
        let id = await createCompletedTask()
        git.canMerge = false
        await model.refreshMergeability()
        XCTAssertEqual(status(id), .conflict)
        await model.refreshMergeability()
        await model.flush()
        XCTAssertEqual(notifier.notifications.map(\.title), ["Do the thing is ready", "Do the thing has a conflict"])
        XCTAssertEqual(git.calls.filter { $0.hasPrefix("commit") }.count, 3, "leftovers are committed first")

        git.canMerge = true
        await model.refreshMergeability()
        XCTAssertEqual(status(id), .completed)
        await model.flush()
        XCTAssertEqual(notifier.notifications.count, 2)
    }

    func testRefreshLeavesWorkingTasksAlone() async {
        let (id, gate) = await createPausedTask()
        git.canMerge = false
        await model.refreshMergeability()
        XCTAssertEqual(status(id), .working)
        XCTAssertFalse(git.calls.contains("commit 3001"))
        gate.open()
        await waitForStatus(id, .conflict)
    }

    func testMergeRechecksTheOtherTasks() async {
        let first = await createCompletedTask()
        let second = await createCompletedTask()
        git.canMerge = false
        await model.merge(taskID: first)
        XCTAssertEqual(status(first), .merged)
        XCTAssertEqual(status(second), .conflict)
    }

    // MARK: Diff errors

    func testDiffErrorsAreReported() async {
        let id = await createCompletedTask()
        git.diffError = GitError(message: "fatal: bad object HEAD\nmore")
        guard case .failure(let error) = await model.loadDiff(taskID: id) else { return XCTFail("expected an error") }
        XCTAssertEqual(error.localizedDescription, "bad object HEAD")
        guard case .failure = await model.loadChanges(taskID: id) else { return XCTFail("expected an error") }
        let diff = await model.diff(taskID: id)
        XCTAssertEqual(diff, [])
        let changes = await model.changes(taskID: id)
        XCTAssertNil(changes)

        git.diffError = nil
        git.pendingChanges = DiffSummary(files: [FileChange(path: "a.txt", kind: .modified)])
        let loaded = await model.loadDiff(taskID: id)
        XCTAssertEqual(try loaded.get().map(\.id), ["a.txt"])
    }

    func testMergeErrorShowsItsFirstLine() async {
        let id = await createCompletedTask()
        git.mergeError = GitError(message: "fatal: refusing to merge\nhint: something")
        await model.merge(taskID: id)
        XCTAssertEqual(model.lastError, "Could not merge Do the thing: refusing to merge")
    }

    // MARK: Misc

    func testPreviewModelActionsAreNoOps() async {
        let preview = AppModel.preview()
        let before = preview.tasks
        XCTAssertNil(preview.createTask(projectID: preview.projects[0].id, prompt: "Hi"))
        preview.sendPrompt(taskID: 3001, text: "Hi")
        preview.stop(taskID: 3003)
        preview.resolveConflict(taskID: 3002)
        await preview.merge(taskID: 3001)
        await preview.delete(taskID: 3001)
        await preview.start()
        await preview.shutdown()
        preview.resume(taskID: 3005)
        await preview.refreshMergeability()
        XCTAssertEqual(preview.tasks, before)
        let running = await preview.isServerRunning(taskID: 3001)
        XCTAssertTrue(running)
        let merged = await preview.isServerRunning(taskID: 2998)
        XCTAssertFalse(merged)
        let blocked = await preview.isServerRunning(taskID: 3005)
        XCTAssertFalse(blocked, "blocked preview tasks show a stopped server")
        // Finished preview tasks have a sample diff; others none.
        let diff = await preview.loadDiff(taskID: 3001)
        XCTAssertEqual(try diff.get().count, 4)
        let changes = await preview.loadChanges(taskID: 3001)
        XCTAssertEqual(try changes.get().files.count, 4)
        let working = await preview.loadDiff(taskID: 3003)
        XCTAssertEqual(try working.get(), [])
    }

    func testTitles() {
        XCTAssertEqual(AppModel.title(for: "  Set the gap to 4px. Then check it.  "), "Set the gap to 4px")
        XCTAssertEqual(AppModel.title(for: "Bump to v1.2 now"), "Bump to v1.2 now")
        XCTAssertEqual(AppModel.title(for: "Fix the header\nIt overflows"), "Fix the header")
        XCTAssertEqual(AppModel.title(for: "Why is it broken?"), "Why is it broken")
        let long = AppModel.title(for: "Keep the focused board column expanded when another column is hovered")
        XCTAssertEqual(long, "Keep the focused board column expanded when")
        XCTAssertLessThanOrEqual(long.count, 50)
    }

    // MARK: Helpers

    /// Reports every status the task takes from now on, as the UI would see it.
    private func observeStatuses(of id: Int, _ report: @escaping @MainActor (TaskStatus) -> Void) -> Task<Void, Never> {
        let (changes, continuation) = AsyncStream<Void>.makeStream()
        @MainActor func track() {
            withObservationTracking { _ = self.model.tasks } onChange: {
                continuation.yield()
            }
        }
        track()
        return Task { @MainActor in
            for await _ in changes {
                if let status = self.status(id), status != .working { report(status) }
                track()
            }
        }
    }
}
