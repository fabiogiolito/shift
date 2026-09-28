import XCTest
@testable import ShiftCore

/// The real services together, driving the real agent CLIs against a scratch repo.
/// Off unless SHIFT_LIVE_AGENT_TESTS=1: `SHIFT_LIVE_AGENT_TESTS=1 swift test --filter EndToEndTests`
@MainActor
final class EndToEndTests: XCTestCase {
    var temp: URL!
    var repo: URL!
    var worktrees: URL!
    var notifier: MockNotifier!
    var model: AppModel!
    var project: Project!

    static let turn: TimeInterval = 300

    override func setUp() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIFT_LIVE_AGENT_TESTS"] == "1", "live agent tests are off")
        let name = "shift-e2e-\(UUID().uuidString.prefix(8).lowercased())"
        temp = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        repo = temp.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try "<!doctype html>\n<link rel=\"stylesheet\" href=\"style.css\">\n<h1>Hello</h1>\n"
            .write(to: repo.appendingPathComponent("index.html"), atomically: true, encoding: .utf8)
        try "body {\n  color: black;\n}\n".write(to: repo.appendingPathComponent("style.css"), atomically: true, encoding: .utf8)
        sh("git init -q -b main && git config user.name e2e && git config user.email e2e@example.com && git add . && git commit -qm init", in: repo)

        notifier = MockNotifier()
        // Task ids are also preferred ports; keep clear of the real app's 3001 range.
        await JSONStateStore(root: temp.appendingPathComponent("state")).save(AppState(nextTaskID: 43001))
        model = makeModel()
        await model.start()
        let added = await model.addProject(at: repo)
        var project = try XCTUnwrap(added, model.lastError ?? "")
        project.serverCommand = "python3 -m http.server $PORT"
        model.updateProject(project)
        self.project = project
        worktrees = temp.appendingPathComponent("worktrees").appendingPathComponent(name)
    }

    override func tearDown() async throws {
        guard model != nil else { return }
        for task in model.tasks { await model.delete(taskID: task.id) }
        await model.shutdown()
        XCTAssertEqual(leftovers(), "", "processes left in the scratch worktrees")
        try? FileManager.default.removeItem(at: worktrees)
        try? FileManager.default.removeItem(at: temp)
    }

    func makeModel() -> AppModel {
        // Everything, worktrees included, stays in this test's temp directory.
        AppModel(services: Services(
            git: GitService(),
            agents: [.claudeCode: ClaudeCodeAdapter(), .codex: CodexAdapter()],
            servers: ServerManager(logDirectory: temp.appendingPathComponent("state/logs"),
                                   worktreesDirectory: temp.appendingPathComponent("worktrees")),
            ports: PortAllocator(),
            notifier: notifier,
            store: JSONStateStore(root: temp.appendingPathComponent("state"))),
                 worktrees: temp.appendingPathComponent("worktrees"))
    }

    // MARK: Scenarios

    // Bypass is the product default; the auto runs confirm that mode can still commit from a
    // worktree, whose index and refs live in the repository's .git, outside the worktree.
    func testLifecycleClaudeCode() async throws { try await lifecycle(.claudeCode) }
    func testLifecycleCodex() async throws { try await lifecycle(.codex) }
    func testAutoClaudeCode() async throws { try await lifecycle(.claudeCode, .auto) }
    func testAutoCodex() async throws { try await lifecycle(.codex, .auto) }
    func testManualClaudeCode() async throws { try await manual(.claudeCode) }
    func testManualCodex() async throws { try await manual(.codex) }

    func testConflictClaudeCode() async throws { try await conflict(.claudeCode) }
    func testNeedsInputClaudeCode() async throws { try await needsInput(.claudeCode) }
    func testRecoveryClaudeCode() async throws { try await recovery(.claudeCode) }
    func testStopAndDeleteClaudeCode() async throws { try await stopAndDelete(.claudeCode) }

    func testFollowUpClaudeCode() async throws { try await followUp(.claudeCode) }
    func testFollowUpCodex() async throws { try await followUp(.codex) }

    /// Instructions sent while the agent works reach the running session and are acted on in the same turn.
    private func followUp(_ agent: AgentKind) async throws {
        let id = try create("Create a.txt containing a and commit it. Then run the shell command `sleep 30`. "
                            + "Then finish.", agent)
        let worktree = try XCTUnwrap(model.task(id)?.worktreeURL)
        let deadline = Date().addingTimeInterval(Self.turn)
        while !FileManager.default.fileExists(atPath: worktree.appendingPathComponent("a.txt").path), Date() < deadline {
            try await Task.sleep(for: .milliseconds(250))
        }
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(model.task(id)?.status, .working)
        let sent = Date()
        model.sendPrompt(taskID: id, text: "Also create b.txt containing b.")
        await waitFor("the follow-up to reach the agent", timeout: 60) { self.model.task(id)?.prompts.last?.isPending == false }
        let delivered = Date().timeIntervalSince(sent)
        let stillWorking = model.task(id)?.status == .working
        try await settle(id, .completed)
        let log = await model.rawOutput(taskID: id)
        print("E2E \(agent) follow-up delivered after \(String(format: "%.1f", delivered))s, while working: \(stillWorking); "
              + "summary: \(model.task(id)?.summary ?? "-")")
        XCTAssertTrue(stillWorking)
        XCTAssertLessThan(delivered, 5, "delivered into the running session, not after the turn")
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("b.txt").path), log.suffix(3000).description)
        XCTAssertEqual(model.task(id)?.prompts.map(\.isPending), [false, false])
    }

    func testSetupCommandRunsBeforeTheAgent() async throws {
        project.setupCommand = "echo teal > colour.txt && echo \"$SHIFT_REPO $SHIFT_WORKTREE $PORT\" > setup-env.txt"
        model.updateProject(project)
        let id = try create("In style.css set the body color to the colour named in colour.txt. Change nothing else.", .claudeCode)
        try await settle(id, .completed)
        let task = try XCTUnwrap(model.task(id))
        XCTAssertEqual(sh("cat setup-env.txt", in: task.worktreeURL), "\(repo.path) \(task.worktreePath) \(task.port ?? 0)")
        XCTAssertTrue(sh("cat style.css", in: task.worktreeURL).contains("teal"))
        let log = await model.rawOutput(taskID: id)
        XCTAssertTrue(log.hasPrefix("$ echo teal"), "setup is the first thing in the log")
    }

    func testFailingSetupCommandBlocksTheTask() async throws {
        project.setupCommand = "echo 'no such package manager' >&2; exit 3"
        model.updateProject(project)
        let id = try create("In style.css change the body color from black to red.", .claudeCode)
        try await settle(id, .blocked)
        let task = try XCTUnwrap(model.task(id))
        XCTAssertEqual(task.blockedReason, "Setup failed (exit code 3).\nno such package manager")
        XCTAssertNil(task.sessionID, "the agent never ran")
        XCTAssertNil(task.serverPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.worktreePath))
        XCTAssertEqual(sh("git branch --list 'shift/*'", in: repo), "")

        // Fixing the command and sending a prompt sets the task up again.
        project.setupCommand = ""
        model.updateProject(project)
        model.sendPrompt(taskID: id, text: "Try again.")
        try await settle(id, .completed)
        XCTAssertTrue(sh("cat style.css", in: task.worktreeURL).contains("red"))
    }

    private func lifecycle(_ agent: AgentKind, _ permissions: AgentPermissions = .bypass) async throws {
        project.permissions = permissions
        model.updateProject(project)
        let id = try create("In index.html change the heading text from Hello to Hello Shift.", agent)
        try await settle(id, .completed)
        var task = try XCTUnwrap(model.task(id))
        XCTAssertFalse((task.summary ?? "").isEmpty)
        XCTAssertTrue(task.worktreePath.hasPrefix(worktrees.path + "/"), task.worktreePath)
        let session = try XCTUnwrap(task.sessionID)
        let port = try XCTUnwrap(task.port)

        let page = try await fetch(port)
        XCTAssertTrue(page.contains("Hello Shift"), page)
        let changes = await model.changes(taskID: id)
        XCTAssertEqual(changes?.files.map(\.path), ["index.html"])
        let diff = await model.diff(taskID: id)
        XCTAssertFalse(diff.flatMap(\.hunks).isEmpty)
        XCTAssertEqual(sh("git status --porcelain", in: task.worktreeURL), "", "everything is committed")
        // The app's own snapshot commit is named after the task; anything else is the agent's.
        let subjects = sh("git log --format=%s main..HEAD", in: task.worktreeURL)
        XCTAssertFalse(subjects.isEmpty || subjects == task.title, "\(agent) (\(permissions)) did not commit by itself: \(subjects)")
        await model.flush()
        XCTAssertEqual(notifier.notifications.last?.title, "\(task.title) is ready")

        model.sendPrompt(taskID: id, text: "In style.css change the body color from black to green.")
        try await settle(id, .completed)
        task = try XCTUnwrap(model.task(id))
        XCTAssertEqual(task.sessionID, session)
        XCTAssertEqual(task.port, port)
        let css = try await fetch(port, "style.css")
        XCTAssertTrue(css.contains("green"), css)

        await model.merge(taskID: id)
        XCTAssertNil(model.lastError)
        task = try XCTUnwrap(model.task(id))
        XCTAssertEqual(task.status, .merged)
        XCTAssertNil(task.serverPID)
        XCTAssertTrue(try String(contentsOf: repo.appendingPathComponent("index.html"), encoding: .utf8).contains("Hello Shift"))
        XCTAssertTrue(try String(contentsOf: repo.appendingPathComponent("style.css"), encoding: .utf8).contains("green"))
        XCTAssertEqual(sh("git status --porcelain", in: repo), "")
        assertReleased(task, port: port)
    }

    private func conflict(_ agent: AgentKind) async throws {
        let first = try create("In style.css change the body color from black to red.", agent)
        let second = try create("In style.css change the body color from black to blue.", agent)
        try await settle(first, .completed)
        try await settle(second, .completed)
        XCTAssertNotEqual(model.task(first)?.port, model.task(second)?.port)

        await model.merge(taskID: first)
        XCTAssertEqual(model.task(first)?.status, .merged)
        await model.merge(taskID: second)
        XCTAssertEqual(model.task(second)?.status, .conflict)
        XCTAssertTrue(sh("cat style.css", in: repo).contains("red"), "a conflict leaves base alone")

        model.resolveConflict(taskID: second)
        // Red and blue cannot both win; Claude Code (stream-json input) asks which one, which is fair.
        await waitFor("task \(second) to settle", timeout: Self.turn) { self.model.task(second)?.status != .working }
        if model.task(second)?.status == .needsInput {
            print("E2E conflict question: \(model.task(second)?.question ?? "")")
            model.sendPrompt(taskID: second, text: "Use blue.")
        }
        try await settle(second, .completed)
        await model.merge(taskID: second)
        XCTAssertNil(model.lastError)
        XCTAssertEqual(model.task(second)?.status, .merged)
        XCTAssertFalse(sh("cat style.css", in: repo).contains("<<<<"))
        XCTAssertEqual(sh("git branch --list 'shift/*'", in: repo), "")
    }

    private func needsInput(_ agent: AgentKind) async throws {
        let id = try create("Change the body color in style.css. Ask me which colour to use before doing anything.", agent)
        try await settle(id, .needsInput)
        XCTAssertFalse((model.task(id)?.question ?? "").isEmpty)
        let none = await model.changes(taskID: id)
        XCTAssertEqual(none?.files, [])

        model.sendPrompt(taskID: id, text: "purple")
        try await settle(id, .completed)
        XCTAssertNil(model.task(id)?.question)
        let css = try await fetch(try XCTUnwrap(model.task(id)?.port), "style.css")
        XCTAssertTrue(css.contains("purple"), css)
    }

    private func recovery(_ agent: AgentKind) async throws {
        let id = try create("Run the shell command `sleep 45`, then create done.txt containing ok.", agent)
        await waitFor("the agent to get busy", timeout: Self.turn) {
            self.model.task(id)?.sessionID != nil && self.model.task(id)?.activity != nil
        }
        await model.shutdown()
        XCTAssertEqual(leftovers(), "", "shutdown leaves nothing running")

        model = makeModel()
        await model.start()
        let task = try XCTUnwrap(model.task(id))
        XCTAssertEqual(task.status, .blocked)
        XCTAssertEqual(task.blockedReason, AppModel.interruptedReason)
        XCTAssertNotNil(task.sessionID)
        XCTAssertFalse(leftovers().contains("claude") || leftovers().contains("codex"), leftovers())
        _ = try await fetch(try XCTUnwrap(task.port)) // the server is back for a task that can continue

        model.sendPrompt(taskID: id, text: "Do not sleep. Just create done.txt containing ok.")
        try await settle(id, .completed)
        XCTAssertEqual(model.task(id)?.sessionID, task.sessionID)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.worktreeURL.appendingPathComponent("done.txt").path))
    }

    func testFinishedTaskWithoutChangesSurvivesRestart() async throws {
        let id = try create("Change no files and run no commands. Just say that you are ready.", .claudeCode)
        try await settle(id, .completed)
        await model.shutdown()

        model = makeModel()
        await model.start()
        let task = try XCTUnwrap(model.task(id))
        XCTAssertEqual(task.status, .completed)
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.worktreePath))
        _ = try await fetch(try XCTUnwrap(task.port))
    }

    /// Allow, deny, and stop while a request waits, through AppModel.
    private func manual(_ agent: AgentKind) async throws {
        project.permissions = .manual
        model.updateProject(project)
        let id = try create("Run `ls` and write the output to files.txt. Do not commit.", agent)
        let allowed = try await answering(id, allow: true)
        XCTAssertFalse(allowed.isEmpty)
        try await settle(id, .completed)
        let task = try XCTUnwrap(model.task(id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: task.worktreeURL.appendingPathComponent("files.txt").path))
        await model.flush()
        XCTAssertTrue(notifier.notifications.contains { $0.title.hasSuffix("needs your approval") && $0.body == allowed[0] })

        model.sendPrompt(taskID: id, text: "Now run `ls -a` and write the output to files2.txt. Do not commit.")
        let denied = try await answering(id, allow: false)
        XCTAssertFalse(denied.isEmpty)
        XCTAssertNotEqual(model.task(id)?.status, .working)
        XCTAssertNil(model.task(id)?.approvalRequest)
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.worktreeURL.appendingPathComponent("files2.txt").path))

        model.sendPrompt(taskID: id, text: "Now run `ls -l` and write the output to files3.txt. Do not commit.")
        await waitFor("an approval request", timeout: Self.turn) { self.model.task(id)?.approvalRequest != nil }
        model.stop(taskID: id)
        XCTAssertEqual(model.task(id)?.status, .blocked)
        XCTAssertNil(model.task(id)?.approvalRequest)
        try await Task.sleep(for: .seconds(3))
        let running = leftovers()
        XCTAssertFalse(running.contains("claude") || running.contains("codex"), running)
    }

    /// Answers every approval request until the turn ends. Returns the requests, in order.
    private func answering(_ id: Int, allow: Bool) async throws -> [String] {
        var requests: [String] = []
        while true {
            await waitFor("task \(id) to stop working", timeout: Self.turn) { self.model.task(id)?.status != .working }
            guard let request = model.task(id)?.approvalRequest else { return requests }
            print("E2E \(id) approval: \(request) → \(allow ? "allow" : "deny")")
            requests.append(request)
            model.answerApproval(taskID: id, allow: allow)
        }
    }

    private func stopAndDelete(_ agent: AgentKind) async throws {
        let id = try create("Run the shell command `sleep 45`, then create done.txt containing ok.", agent)
        await waitFor("the agent to get busy", timeout: Self.turn) { self.model.task(id)?.activity != nil }
        let task = try XCTUnwrap(model.task(id))
        let port = try XCTUnwrap(task.port)

        model.stop(taskID: id)
        XCTAssertEqual(model.task(id)?.status, .blocked)
        XCTAssertEqual(model.task(id)?.blockedReason, "Stopped")
        try await Task.sleep(for: .seconds(3))
        let running = leftovers()
        XCTAssertFalse(running.contains("claude") || running.contains("codex") || running.contains("sleep"), running)
        _ = try await fetch(port) // stopping the agent keeps the server

        await model.delete(taskID: id)
        XCTAssertNil(model.task(id))
        XCTAssertNil(model.lastError)
        assertReleased(task, port: port)
        XCTAssertEqual(leftovers(), "")
    }

    // MARK: Helpers

    private func create(_ prompt: String, _ agent: AgentKind) throws -> Int {
        try XCTUnwrap(model.createTask(projectID: project.id, prompt: prompt, agent: agent))
    }

    /// Waits for the agent's turn to end and fails with the task's own explanation if it ended elsewhere.
    private func settle(_ id: Int, _ expected: TaskStatus, file: StaticString = #filePath, line: UInt = #line) async throws {
        await waitFor("task \(id) to settle", timeout: Self.turn, file: file, line: line) {
            self.model.task(id)?.status != .working
        }
        let task = try XCTUnwrap(model.task(id))
        guard task.status != expected else { return }
        let log = await model.rawOutput(taskID: id)
        XCTFail("task \(id) is \(task.status), expected \(expected). reason: \(task.blockedReason ?? "-") "
            + "question: \(task.question ?? "-") summary: \(task.summary ?? "-")\n\(log.suffix(3000))", file: file, line: line)
        throw CancellationError()
    }

    private func assertReleased(_ task: TaskItem, port: Int, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(FileManager.default.fileExists(atPath: task.worktreePath), "worktree", file: file, line: line)
        XCTAssertEqual(sh("git branch --list \(task.branch)", in: repo), "", "branch", file: file, line: line)
        XCTAssertFalse(sh("git worktree list", in: repo).contains(task.worktreePath), "worktree list", file: file, line: line)
        XCTAssertTrue(PortAllocator.isFree(port), "port \(port) still in use", file: file, line: line)
    }

    /// The dev server may need a moment after it was started.
    private func fetch(_ port: Int, _ path: String = "") async throws -> String {
        let url = try XCTUnwrap(URL(string: "http://localhost:\(port)/\(path)"))
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: 5)
        request.httpMethod = "GET"
        var failure: Error?
        for _ in 0..<40 {
            do {
                let (data, response) = try await URLSession.shared.data(for: request)
                XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
                return String(decoding: data, as: UTF8.self)
            } catch {
                failure = error
                try await Task.sleep(for: .milliseconds(250))
            }
        }
        throw try XCTUnwrap(failure)
    }

    /// Commands of the processes whose working directory is inside this test's worktrees.
    private func leftovers() -> String {
        sh("lsof -d cwd -Fcn 2>/dev/null | grep -B1 '\(worktrees.lastPathComponent)' | grep '^c' | sort -u", in: temp)
    }

    @discardableResult
    private func sh(_ command: String, in directory: URL) -> String {
        (AgentEnvironment.capture("/bin/sh", ["-c", command], environment: AgentEnvironment.loginShell, directory: directory) ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
