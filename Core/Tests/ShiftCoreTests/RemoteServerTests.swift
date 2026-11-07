import XCTest
@testable import ShiftCore

// The wire format, command dispatch against AppModel, auth and log streaming, the last two over real sockets.

final class WireTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(Wire.decode(T.self, from: Wire.encode(value)), value, file: file, line: line)
    }

    private func sampleSnapshot() -> RemoteSnapshot {
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let project = Project(name: "Spot", repoPath: "/spot", baseBranch: "main", models: [.claudeCode: "opus"])
        var task = TaskItem(id: 3001, projectID: project.id, title: "Do it", agent: .claudeCode, branch: "shift/3001",
                            worktreePath: "/w", port: 3001, prompts: [Prompt(text: "go", date: date, attachments: ["/a.png"])], createdAt: date)
        task.approvalRequest = "Run `pnpm install`"
        task.options = ["Yes"]
        var snapshot = RemoteSnapshot()
        snapshot.projects = [project]
        snapshot.tasks = [task]
        snapshot.chats = [ProjectChat(projectID: project.id, agent: .codex, prompts: [Prompt(text: "hi", date: date)])]
        snapshot.pullRequests = [3001: PullRequest(number: 7, url: URL(string: "https://github.com/a/b/pull/7")!, state: .open,
                                                   headRefName: "shift/3001", headRefOid: "abc", hasNewWork: true)]
        let target = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        snapshot.builds = [BuildKey(taskID: 3001, targetID: target): .succeeded(app: URL(fileURLWithPath: "/a.app")),
                           BuildKey(taskID: 3002, targetID: target): .failed("no"), BuildKey(taskID: 3003, targetID: target): .building]
        snapshot.usage = [.claudeCode: AgentUsage(windows: [.init(name: "5-hour", usedPercent: 10, resetsAt: date)])]
        snapshot.chatApprovals = [project.id: "Edit `a`"]
        snapshot.replyingChats = [project.id]
        snapshot.schedules = [Schedule(projectID: project.id, title: "Deps", prompt: "Update them", baseBranch: "main", agent: .claudeCode,
                                       permissions: .auto, timing: ScheduleTiming(start: date), paused: true,
                                       runs: [ScheduleRun(due: date, outcome: .missed, reason: "Mac was asleep"),
                                              ScheduleRun(due: nil, started: date, taskID: 3001, outcome: .review, summary: "Done")],
                                       createdAt: date)]
        return snapshot
    }

    func testEveryMessageRoundTrips() {
        let snapshot = sampleSnapshot()
        let id = UUID()
        let diff = [FileDiff(change: FileChange(path: "a", kind: .modified, additions: 1), hunks: [DiffHunk(header: "@@", lines: [DiffLine(kind: .added, text: "x", newNumber: 1)])])]
        let server: [ServerMessage] = [
            .hello(version: Wire.version), .snapshot(snapshot), .projects(snapshot.projects), .task(snapshot.tasks[0]), .taskRemoved(1),
            .chat(snapshot.chats[0]), .chatRemoved(id), .pullRequest(taskID: 1, nil), .pullRequest(taskID: 1, snapshot.pullRequests[3001]),
            .build(BuildKey(taskID: 1, targetID: id), .building), .usage(.codex, nil), .chatApproval(projectID: id, "x"), .replyingChats([id]),
            .schedules(snapshot.schedules!), .schedules([]),
            .reply(id: 1, result: .diff(diff), error: nil), .reply(id: 2, result: nil, error: "no"), .reply(id: 3, result: .changes(DiffSummary()), error: nil),
            .reply(id: 4, result: .url(nil), error: nil), .reply(id: 5, result: .taskID(4), error: nil),
            .log(.task(1), offset: 9, data: Data([0, 255])), .log(.chat(id), offset: 0, data: Data()),
        ]
        server.forEach { roundTrip($0) }
        let commands: [RemoteCommand] = [
            .createTask(projectID: id, prompt: "p", attachments: ["/a"], agent: nil), .sendPrompt(taskID: 1, text: "t", attachments: []),
            .answerApproval(taskID: 1, allow: false), .stop(taskID: 1), .resume(taskID: 1), .rename(taskID: 1, title: "t"), .merge(taskID: 1),
            .delete(taskID: 1), .resolveConflict(taskID: 1), .conflictedFiles(taskID: 1), .pushBranch(taskID: 1), .pullRequestURL(taskID: 1),
            .branches(projectID: id), .changeBase(taskID: 1, to: "main"), .loadChanges(taskID: 1), .loadDiff(taskID: 1), .restartServer(taskID: 1), .serverLog(taskID: 1), .build(taskID: 1, target: id), .buildLog(taskID: 1, target: id),
            .sendChat(projectID: id, text: "t", attachments: []), .answerChatApproval(projectID: id, allow: true), .stopChat(projectID: id), .newChat(projectID: id), .baseServerURL(projectID: id),
            .runScheduleNow(scheduleID: id), .setSchedulePaused(scheduleID: id, paused: true),
        ]
        commands.forEach { roundTrip(ClientMessage.command(CommandRequest(id: 1, command: $0))) }
        roundTrip(ClientMessage.hello(version: 1, device: "iPhone"))
        roundTrip(ClientMessage.subscribe(log: .chat(id), from: 5))
        roundTrip(ClientMessage.unsubscribe(log: .task(5)))
    }

    func testUnknownMessagesAndFieldsAreIgnored() throws {
        XCTAssertNil(Wire.decode(ServerMessage.self, from: Data(#"{"fromTheFuture":{"x":1}}"#.utf8)))
        XCTAssertNil(Wire.decode(ClientMessage.self, from: Data(#"{"fromTheFuture":{}}"#.utf8)))
        XCTAssertEqual(Wire.decode(ServerMessage.self, from: Data(#"{"hello":{"version":99,"newField":true},"alsoNew":1}"#.utf8)), .hello(version: 99))
        // A task with a field this version doesn't have.
        let task = sampleSnapshot().tasks[0]
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Wire.encode(task)) as? [String: Any])
        json["fromTheFuture"] = ["a": 1]
        let decoded = Wire.decode(TaskItem.self, from: try JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(decoded, task)
        // A command this version doesn't have still has an id to reply to.
        XCTAssertEqual(Wire.decode(ClientMessage.self, from: Data(#"{"command":{"_0":{"id":7,"command":{"fromTheFuture":{}}}}}"#.utf8)),
                       .command(CommandRequest(id: 7, command: nil)))
    }

    func testSchedulesAcrossVersions() throws {
        let snapshot = sampleSnapshot()
        // A newer phone, an older Mac: a snapshot without schedules decodes, with none.
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: Wire.encode(snapshot)) as? [String: Any])
        json["schedules"] = nil
        let old = try XCTUnwrap(Wire.decode(RemoteSnapshot.self, from: JSONSerialization.data(withJSONObject: json)))
        XCTAssertNil(old.schedules)
        XCTAssertEqual(old.tasks, snapshot.tasks)
        // An older phone, a newer Mac: the schedules message is one it doesn't know (as any unknown one), and the
        // snapshot's extra field is skipped (as the task's above). Its runs keep missed reasons and summaries.
        let message = String(decoding: Wire.encode(ServerMessage.schedules(snapshot.schedules!)), as: UTF8.self)
        XCTAssertTrue(message.hasPrefix(#"{"schedules":"#), message)
        XCTAssertEqual(Wire.decode(ServerMessage.self, from: Data(message.utf8)), .schedules(snapshot.schedules!))
        XCTAssertEqual(Wire.decode(RemoteSnapshot.self, from: Wire.encode(snapshot))?.schedules?[0].runs.map(\.reason), ["Mac was asleep", nil])
    }

    func testChangesTurnOneSnapshotIntoTheOther() {
        let old = sampleSnapshot()
        var new = old
        new.tasks[0].title = "Renamed"
        new.tasks.append(TaskItem(id: 3002, projectID: old.projects[0].id, title: "New", agent: .codex, branch: "b", worktreePath: "/x",
                                  createdAt: Date(timeIntervalSince1970: 1_800_000_000)))
        new.chats = []
        new.pullRequests = [:]
        new.builds[BuildKey(taskID: 3003, targetID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!)] = .failed("x")
        new.usage = [:]
        new.chatApprovals = [:]
        new.replyingChats = []
        new.projects[0].name = "Other"
        new.schedules![0].paused = false
        let messages = new.changes(since: old)
        // Whole entities, and only the ones that changed.
        XCTAssertTrue(messages.contains { if case .task(let task) = $0 { task.id == 3001 && task.title == "Renamed" } else { false } })
        XCTAssertFalse(messages.contains { if case .build(let key, _) = $0 { key.taskID == 3001 } else { false } })
        var phone = old
        messages.forEach { phone.apply($0) }
        XCTAssertEqual(phone, new)
        XCTAssertEqual(new.changes(since: new), [])
        var fresh = new
        new.changes(since: new).forEach { fresh.apply($0) }
        XCTAssertEqual(fresh, new)
        fresh = old
        fresh.apply(.snapshot(new))
        XCTAssertEqual(fresh, new)
    }

    func testPairingLinks() throws {
        let pairing = Pairing(host: "mac.tail1.ts.net", port: 5123, token: "a-b_c")
        XCTAssertEqual(Pairing(link: pairing.link), pairing)
        XCTAssertEqual(pairing.server.absoluteString, "https://mac.tail1.ts.net:5123")
        XCTAssertEqual(pairing.preview(port: 3001)?.absoluteString, "https://mac.tail1.ts.net:3001")
        XCTAssertNil(Pairing(link: URL(string: "https://evil.example/pair?host=a&port=1&token=b")!))
        XCTAssertNil(Pairing(link: URL(string: "shift-remote://pair?host=a&port=x&token=b")!))
        let local = try XCTUnwrap(Pairing(shiftServer: "http://127.0.0.1:5000?token=abc"))
        XCTAssertEqual(local.server.absoluteString, "http://127.0.0.1:5000")
        XCTAssertEqual(local.token, "abc")
        XCTAssertEqual(local.preview(port: 3001)?.absoluteString, "http://127.0.0.1:3001")
        XCTAssertNil(Pairing(shiftServer: "http://127.0.0.1:5000"))
    }

    func testWebSocketFrames() throws {
        XCTAssertEqual(WebSocketFrames.accept(key: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") // From the RFC.
        func masked(_ payload: Data, opcode: UInt8 = 1) -> Data {
            var plain = WebSocketFrames.encode(opcode: opcode, payload: payload)
            let start = plain.count - payload.count
            plain[plain.startIndex + 1] |= 0x80
            let mask: [UInt8] = [1, 2, 3, 4]
            return plain.prefix(start) + Data(mask) + Data(payload.enumerated().map { $1 ^ mask[$0 % 4] })
        }
        for size in [0, 5, 125, 126, 65535, 65536] {
            let payload = Data(repeating: 7, count: size)
            var buffer = masked(payload) + masked(Data([9]))
            XCTAssertEqual(try WebSocketFrames.next(from: &buffer, limit: 1 << 20)?.payload, payload)
            XCTAssertEqual(try WebSocketFrames.next(from: &buffer, limit: 1 << 20)?.payload, Data([9]))
            XCTAssertNil(try WebSocketFrames.next(from: &buffer, limit: 1 << 20))
        }
        var partial = masked(Data(repeating: 1, count: 300)).prefix(100) + Data()
        XCTAssertNil(try WebSocketFrames.next(from: &partial, limit: 1 << 20))
        var large = masked(Data(repeating: 1, count: 300))
        XCTAssertThrowsError(try WebSocketFrames.next(from: &large, limit: 100))
        var unmasked = WebSocketFrames.encode(opcode: 1, payload: Data([1]))
        XCTAssertThrowsError(try WebSocketFrames.next(from: &unmasked, limit: 100))
    }
}

final class RemoteAuthTests: XCTestCase {
    var home: URL!
    var auth: RemoteAuth!

    override func setUp() async throws {
        home = FileManager.default.temporaryDirectory.appendingPathComponent("shift-auth-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        auth = RemoteAuth(home: home)
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: home)
    }

    private func headers(token: String?, login: String? = nil, forwarded: Bool = false) -> [String: String] {
        var headers: [String: String] = [:]
        headers["authorization"] = token.map { "Bearer \($0)" }
        headers["tailscale-user-login"] = login
        if forwarded { headers["x-forwarded-for"] = "100.1.1.1" }
        return headers
    }

    func testPairedDeviceNeedsItsTokenAndTheOwnersLogin() {
        let (device, token) = auth.add()
        auth.setOwner("Me@example.com")
        XCTAssertEqual(auth.caller(headers: headers(token: token, login: "me@example.com", forwarded: true)), .device(device.id))
        XCTAssertNil(auth.caller(headers: headers(token: nil, login: "me@example.com")))
        XCTAssertNil(auth.caller(headers: headers(token: "wrong", login: "me@example.com")))
        XCTAssertNil(auth.caller(headers: headers(token: token, login: "someone@else.com")), "Another person on the tailnet")
        XCTAssertNil(auth.caller(headers: headers(token: token)), "A tagged device, or a local process")
        auth.setOwner(nil)
        XCTAssertNil(auth.caller(headers: headers(token: token, login: "me@example.com")), "The owner isn't known yet")
    }

    func testRevokedDeviceIsRefusedEvenAfterRestart() {
        let (device, token) = auth.add()
        auth.setOwner("me")
        XCTAssertEqual(RemoteAuth(home: home).devices.map(\.id), [device.id])
        auth.remove(device.id)
        XCTAssertNil(auth.caller(headers: headers(token: token, login: "me")))
        let again = RemoteAuth(home: home)
        again.setOwner("me")
        XCTAssertNil(again.caller(headers: headers(token: token, login: "me")))
        XCTAssertEqual(again.devices, [])
    }

    func testTokenIsNotStored() throws {
        let (_, token) = auth.add()
        let saved = try String(contentsOf: home.appendingPathComponent("remote.json"), encoding: .utf8)
        XCTAssertFalse(saved.contains(token))
        let permissions = try FileManager.default.attributesOfItem(atPath: home.appendingPathComponent("remote.json").path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
    }

    func testLocalTokenOnlyWorksStraightOverLoopback() throws {
        XCTAssertNil(auth.caller(headers: headers(token: "")), "No file, no local access")
        try "dev-token\n".write(to: home.appendingPathComponent("remote-dev-token"), atomically: true, encoding: .utf8)
        XCTAssertEqual(auth.caller(headers: headers(token: "dev-token")), .local)
        XCTAssertNil(auth.caller(headers: headers(token: "other")))
        XCTAssertNil(auth.caller(headers: headers(token: "dev-token", forwarded: true)), "It came through tailscale serve")
        XCTAssertNil(auth.caller(headers: headers(token: "dev-token", login: "me")), "It came through tailscale serve")
    }
}

@MainActor
final class RemoteServerTests: XCTestCase {
    var git: MockGit!
    var agent: MockAgent!
    var store: MockStore!
    var model: AppModel!
    var project: Project!
    var temp: URL!
    var listener: RemoteListener!
    var server: RemoteServer!
    var port = 0
    private let localToken = "local-token"

    override func setUp() async throws {
        git = MockGit()
        agent = MockAgent()
        store = MockStore()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("shift-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        project = Project(name: "Spot", repoPath: temp.path, baseBranch: "main")
        store.state = AppState(projects: [project])
        model = AppModel(services: Services(git: git, agents: [.claudeCode: agent], servers: MockServers(), ports: MockPorts(),
                                            notifier: MockNotifier(), store: store),
                         worktrees: temp.appendingPathComponent("worktrees"))
        await model.start()
        try localToken.write(to: temp.appendingPathComponent("remote-dev-token"), atomically: true, encoding: .utf8)
        listener = RemoteListener(home: temp, attachments: temp.appendingPathComponent("attachments"),
                                  screenshots: temp.appendingPathComponent("screenshots"))
        server = RemoteServer(model: model, listener: listener)
        server.logPoll = .milliseconds(10)
        await server.start()
        port = try XCTUnwrap(server.port)
    }

    override func tearDown() async throws {
        server.stop()
        try? FileManager.default.removeItem(at: temp)
    }

    // MARK: Helpers

    /// A real client, as the phone's.
    @MainActor
    private final class Client {
        let socket: URLSessionWebSocketTask
        init(port: Int, token: String?, headers: [String: String] = [:]) {
            var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(port)\(Wire.socketPath)")!)
            if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
            headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }
            socket = URLSession.shared.webSocketTask(with: request)
            socket.maximumMessageSize = Wire.maxMessage
            socket.resume()
        }

        func send(_ message: ClientMessage) async throws {
            try await socket.send(.string(String(decoding: Wire.encode(message), as: UTF8.self)))
        }

        func sendRaw(_ text: String) async throws { try await socket.send(.string(text)) }

        func next() async throws -> ServerMessage? {
            switch try await socket.receive() {
            case .string(let text): Wire.decode(ServerMessage.self, from: Data(text.utf8))
            case .data(let data): Wire.decode(ServerMessage.self, from: data)
            @unknown default: nil
            }
        }

        /// Reads until `match` says it's the one.
        func first<T>(_ match: (ServerMessage) -> T?, file: StaticString = #filePath, line: UInt = #line) async throws -> T {
            for _ in 0..<500 {
                if let message = try await next(), let found = match(message) { return found }
            }
            XCTFail("Never came", file: file, line: line)
            throw MockError("Never came")
        }

        func reply(to id: Int) async throws -> (RemoteResult?, String?) {
            try await first { if case .reply(id, let result, let error) = $0 { (result, error) } else { nil } }
        }
    }

    private func client() async throws -> Client {
        let client = Client(port: port, token: localToken)
        _ = try await client.first { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
        return client
    }

    func waitUntil(_ what: String, _ condition: @escaping () -> Bool) async {
        await waitFor(what, condition)
    }

    private func createPausedTask() async throws -> (Int, Gate) {
        let gate = Gate()
        agent.scripts.append([.emit(.sessionStarted(id: "s1")), .pause(gate), .emit(.finished(.completed(summary: "Done")))])
        let id = try XCTUnwrap(model.createTask(projectID: project.id, prompt: "Go"))
        await waitUntil("the agent to start") { self.agent.requests.count == 1 }
        return (id, gate)
    }

    private func status(_ request: URLRequest) async throws -> Int {
        let (_, response) = try await URLSession.shared.data(for: request)
        return try XCTUnwrap(response as? HTTPURLResponse).statusCode
    }

    // MARK: Command dispatch

    func testBaseServerURLSaysWhyItCouldNotStart() async {
        var gone = project!
        gone.repoPath = "/nonexistent/spot"
        model.updateProject(gone)
        let reply = await server.perform(.baseServerURL(projectID: project.id))
        XCTAssertNil(reply.0)
        XCTAssertEqual(reply.1, "The folder for Spot no longer exists: /nonexistent/spot")
    }

    func testCommandsReachTheModel() async throws {
        let created = await server.perform(.createTask(projectID: project.id, prompt: "Build it", attachments: [], agent: nil))
        guard case .taskID(let id?)? = created.0 else { return XCTFail("\(created)") }
        XCTAssertEqual(model.task(id)?.title, "Build it")
        await waitUntil("the agent to finish") { self.model.task(id)?.status != .working }

        _ = await server.perform(.rename(taskID: id, title: "Renamed"))
        XCTAssertEqual(model.task(id)?.title, "Renamed")

        agent.scripts.append([.emit(.finished(.completed(summary: "Again")))])
        _ = await server.perform(.sendPrompt(taskID: id, text: "More", attachments: ["/tmp/a.png"]))
        XCTAssertEqual(model.task(id)?.prompts.last?.text, "More")
        XCTAssertEqual(model.task(id)?.prompts.last?.attachments, ["/tmp/a.png"])
        await waitUntil("the second run") { self.model.task(id)?.summary == "Again" }

        let log = await server.perform(.buildLog(taskID: id, target: UUID()))
        XCTAssertEqual(log.0, .text(""))
        _ = await server.perform(.delete(taskID: id))
        XCTAssertNil(model.task(id))
    }

    func testSchedulesArePausedAndResumedAndSent() async throws {
        let schedule = Schedule(projectID: project.id, title: "Deps", prompt: "Update", baseBranch: "main", agent: .claudeCode,
                                permissions: .auto, timing: ScheduleTiming(start: Date().addingTimeInterval(3600)))
        model.addSchedule(schedule)
        XCTAssertEqual(RemoteServer.snapshot(of: model).schedules, model.schedules)
        _ = await server.perform(.setSchedulePaused(scheduleID: schedule.id, paused: true))
        XCTAssertEqual(model.schedule(schedule.id)?.paused, true)
        _ = await server.perform(.setSchedulePaused(scheduleID: schedule.id, paused: false))
        XCTAssertEqual(model.schedule(schedule.id)?.paused, false)
    }

    func testStopAndResume() async throws {
        let (id, gate) = try await createPausedTask()
        defer { gate.open() }
        _ = await server.perform(.stop(taskID: id))
        XCTAssertEqual(model.task(id)?.blockedReason, TaskItem.stoppedReason)
        agent.scripts.append([.emit(.finished(.completed(summary: "Resumed")))])
        _ = await server.perform(.resume(taskID: id))
        await waitUntil("it to carry on") { self.model.task(id)?.summary == "Resumed" }
    }

    func testAnswerApproval() async throws {
        agent.scripts.append([.ask(id: "a1", summary: "Run `x`"), .emit(.finished(.completed(summary: "Done")))])
        let id = try XCTUnwrap(model.createTask(projectID: project.id, prompt: "Go"))
        await waitUntil("the approval request") { self.model.task(id)?.approvalRequest != nil }
        XCTAssertEqual(RemoteServer.snapshot(of: model).tasks.first?.approvalRequest, "Run `x`")
        _ = await server.perform(.answerApproval(taskID: id, allow: true))
        XCTAssertNil(model.task(id)?.approvalRequest)
        await waitUntil("the agent to carry on") { self.model.task(id)?.status == .completed }
    }

    func testFailuresComeBackAsErrorsAndKeepAnEarlierAlert() async throws {
        let (id, gate) = try await createPausedTask()
        gate.open()
        await waitUntil("the agent to finish") { self.model.task(id)?.status == .completed }

        model.lastError = "Earlier"
        let fine = await server.perform(.rename(taskID: id, title: "x"))
        XCTAssertEqual(fine.0, .done)
        XCTAssertNil(fine.1)
        XCTAssertEqual(model.lastError, "Earlier")

        git.mergeError = MockError("nope")
        let merge = await server.perform(.merge(taskID: id))
        XCTAssertNil(merge.0)
        XCTAssertTrue(merge.1?.contains("nope") == true, "\(merge)")
        XCTAssertEqual(model.lastError, merge.1, "The Mac still shows it")
    }

    func testDiffIsFetchedAsAReply() async throws {
        git.pendingChanges = DiffSummary(files: [FileChange(path: "a.txt", kind: .added, additions: 2)])
        let (id, gate) = try await createPausedTask()
        defer { gate.open() }
        await waitUntil("the worktree") { FileManager.default.fileExists(atPath: self.model.task(id)?.worktreePath ?? "/none") }
        let client = try await client()
        try await client.send(.command(CommandRequest(id: 1, command: .loadDiff(taskID: id))))
        let reply = try await client.reply(to: 1)
        XCTAssertEqual(reply.0, .diff([FileDiff(change: git.pendingChanges.files[0], hunks: [])]))
    }

    // MARK: Over the socket

    func testSnapshotThenWholeChangedEntities() async throws {
        let (id, gate) = try await createPausedTask()
        defer { gate.open() }
        let client = Client(port: port, token: localToken)
        let hello = try await client.next()
        XCTAssertEqual(hello, .hello(version: Wire.version))
        let snapshot: RemoteSnapshot = try await client.first { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
        XCTAssertEqual(snapshot.projects, [project])
        XCTAssertEqual(snapshot.tasks.map(\.id), [id])

        model.rename(taskID: id, to: "Renamed on the Mac")
        let pushed: TaskItem = try await client.first { if case .task(let task) = $0, task.title == "Renamed on the Mac" { task } else { nil } }
        XCTAssertEqual(pushed, Wire.decode(TaskItem.self, from: Wire.encode(model.task(id)))) // Whole, dates to the second.
    }

    func testArchivedTasksReachAnOlderPhoneAsMerged() async throws {
        let id = try await createPausedTask().0
        model.stop(taskID: id)
        await model.archive(taskID: id)
        XCTAssertEqual(model.task(id)?.status, .archived)
        let client = Client(port: port, token: localToken)
        let old: RemoteSnapshot = try await client.first { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
        XCTAssertEqual(old.tasks.first?.status, .merged)
        try await client.send(.hello(version: Wire.version, device: "iPhone"))
        let current: RemoteSnapshot = try await client.first { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
        XCTAssertEqual(current.tasks.first?.status, .archived)
    }

    func testUnknownMessageIsIgnoredAndUnknownCommandIsAnswered() async throws {
        let client = try await client()
        try await client.sendRaw(#"{"fromTheFuture":{"x":1}}"#)
        try await client.sendRaw("not even json")
        try await client.sendRaw(#"{"command":{"_0":{"id":5,"command":{"fromTheFuture":{"x":1}}}}}"#)
        let reply = try await client.reply(to: 5)
        XCTAssertNil(reply.0)
        XCTAssertNotNil(reply.1)
        // Still connected.
        try await client.send(.command(CommandRequest(id: 6, command: .stop(taskID: 1))))
        let next = try await client.reply(to: 6)
        XCTAssertEqual(next.0, .done)
    }

    func testRefusedWithoutAToken() async throws {
        for token in [nil, "wrong"] {
            let client = Client(port: port, token: token)
            do {
                _ = try await client.next()
                XCTFail("Connected with \(String(describing: token))")
            } catch {
                XCTAssertEqual((client.socket.response as? HTTPURLResponse)?.statusCode, 401)
            }
        }
        var upload = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(Wire.attachmentsPath)?name=a.png")!)
        upload.httpMethod = "POST"
        upload.httpBody = Data([1, 2, 3])
        let refused = try await status(upload)
        XCTAssertEqual(refused, 401)
        let saved = (try? FileManager.default.contentsOfDirectory(atPath: temp.appendingPathComponent("attachments").path)) ?? []
        XCTAssertEqual(saved, [])
    }

    func testPairedDeviceThroughTheTailnetAndRevoked() async throws {
        let (device, token) = listener.auth.add()
        listener.auth.setOwner("me@example.com")
        let tailnet = ["Tailscale-User-Login": "me@example.com", "X-Forwarded-For": "100.1.1.1"]
        let phone = Client(port: port, token: token, headers: tailnet)
        _ = try await phone.first { if case .snapshot(let snapshot) = $0 { snapshot } else { nil } }
        try await phone.send(.hello(version: Wire.version, device: "My iPhone"))
        await waitUntil("its name") { self.listener.auth.devices.first?.name == "My iPhone" }
        XCTAssertNotNil(listener.auth.devices.first?.lastSeen)

        // Somebody else on the tailnet, with the same token.
        let other = Client(port: port, token: token, headers: ["Tailscale-User-Login": "them@example.com", "X-Forwarded-For": "100.1.1.2"])
        do {
            _ = try await other.next()
            XCTFail("Connected")
        } catch {}

        server.revoke(device.id)
        do {
            while try await phone.next() != nil || true {}
        } catch {}
        let again = Client(port: port, token: token, headers: tailnet)
        do {
            _ = try await again.next()
            XCTFail("Connected after being revoked")
        } catch {}
    }

    func testScreenshotIsServedOnlyFromItsFolder() async throws {
        let folder = temp.appendingPathComponent("screenshots")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data([1, 2, 3]).write(to: folder.appendingPathComponent("7-a.png"))
        try Data([4]).write(to: temp.appendingPathComponent("secret.png"))
        func get(_ name: String, token: String? = "local") async throws -> (Int, Data) {
            var components = URLComponents(string: "http://127.0.0.1:\(port)\(Wire.screenshotsPath)")!
            components.queryItems = [.init(name: "name", value: name)]
            var request = URLRequest(url: components.url!)
            if token != nil { request.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization") }
            let (data, response) = try await URLSession.shared.data(for: request)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }
        let (ok, data) = try await get("7-a.png")
        XCTAssertEqual(ok, 200)
        XCTAssertEqual(data, Data([1, 2, 3]))
        for name in ["../secret.png", "", "missing.png"] { let (status, _) = try await get(name); XCTAssertEqual(status, 404, name) }
        let (refused, _) = try await get("7-a.png", token: nil)
        XCTAssertEqual(refused, 401)
    }

    func testUpload() async throws {
        var upload = URLRequest(url: URL(string: "http://127.0.0.1:\(port)\(Wire.attachmentsPath)?name=../../evil.png")!)
        upload.httpMethod = "POST"
        upload.setValue("Bearer \(localToken)", forHTTPHeaderField: "Authorization")
        upload.httpBody = Data(repeating: 9, count: 300_000)
        let (data, _) = try await URLSession.shared.data(for: upload)
        let path = try XCTUnwrap(Wire.decode(AttachmentUploaded.self, from: data)).path
        XCTAssertTrue(path.hasPrefix(temp.appendingPathComponent("attachments").path), path)
        XCTAssertTrue(path.hasSuffix(".png"))
        XCTAssertEqual(FileManager.default.contents(atPath: path), upload.httpBody)
    }

    func testLogStreamsFromAnOffsetAndKeepsGoing() async throws {
        await store.appendLog(taskID: 42, text: "0123456789")
        let client = try await client()
        try await client.send(.subscribe(log: .task(42), from: 4))
        let first: (UInt64, Data) = try await client.first { if case .log(.task(42), let offset, let data) = $0 { (offset, data) } else { nil } }
        XCTAssertEqual(first.0, 4)
        XCTAssertEqual(String(decoding: first.1, as: UTF8.self), "456789")

        await store.appendLog(taskID: 42, text: "abc")
        let more: (UInt64, Data) = try await client.first { if case .log(.task(42), let offset, let data) = $0 { (offset, data) } else { nil } }
        XCTAssertEqual(more.0, 10)
        XCTAssertEqual(String(decoding: more.1, as: UTF8.self), "abc")

        // Past the end, nothing yet: a phone that already has it all.
        try await client.send(.unsubscribe(log: .task(42)))
        try await client.send(.subscribe(log: .task(42), from: 13))
        await store.appendLog(taskID: 42, text: "z")
        let last: (UInt64, Data) = try await client.first { if case .log(.task(42), let offset, let data) = $0 { (offset, data) } else { nil } }
        XCTAssertEqual(last.0, 13)
        XCTAssertEqual(String(decoding: last.1, as: UTF8.self), "z")
    }

    func testLargeLogArrivesWholeAndParses() async throws {
        let line = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Hello"}]}}"# + "\n"
        await store.appendLog(taskID: 7, text: String(repeating: line, count: 20_000))
        let client = try await client()
        try await client.send(.subscribe(log: .task(7), from: 0))
        var parser = TranscriptParser(agent: .claudeCode)
        var offset: UInt64 = 0
        let total = UInt64(store.logs[7]!.utf8.count)
        while offset < total {
            let (at, data): (UInt64, Data) = try await client.first { if case .log(.task(7), let offset, let data) = $0 { (offset, data) } else { nil } }
            XCTAssertEqual(at, offset)
            _ = parser.feed(data)
            offset += UInt64(data.count)
        }
        XCTAssertEqual(parser.turns.first?.blocks.count, 20_000)
    }

    // MARK: Port and keep-awake

    func testPortIsSavedInHomeAndKeptAcrossRestarts() async throws {
        let saved = try String(contentsOf: temp.appendingPathComponent("remote-port"), encoding: .utf8)
        XCTAssertEqual(Int(saved), port)
        server.stop()
        try await Task.sleep(for: .milliseconds(100))
        let again = RemoteServer(model: model, listener: RemoteListener(home: temp))
        await again.start()
        defer { again.stop() }
        XCTAssertEqual(again.port, port)

        // Taken by another build: finds its own and saves that.
        let other = FileManager.default.temporaryDirectory.appendingPathComponent("shift-remote-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try String(port).write(to: other.appendingPathComponent("remote-port"), atomically: true, encoding: .utf8)
        let second = RemoteServer(model: model, listener: RemoteListener(home: other))
        await second.start()
        defer { second.stop() }
        XCTAssertNotNil(second.port)
        XCTAssertNotEqual(second.port, port)
        XCTAssertEqual(try String(contentsOf: other.appendingPathComponent("remote-port"), encoding: .utf8), String(second.port!))
        // Phones keep the port they were paired with: Tailscale serves it from wherever this launch listens.
        XCTAssertEqual(second.tailnetPort, port)
        XCTAssertEqual(again.tailnetPort, port)
    }

    func testSimulatorBuildGetsItsMacBuildsAddress() throws {
        let home = temp.appendingPathComponent("builds/9001")
        let address = try XCTUnwrap(RemoteListener.localServer(home: home, taskID: 9001))
        let pairing = try XCTUnwrap(Pairing(shiftServer: address))
        XCTAssertEqual(pairing.server.port, 29001)
        // The Mac build lets it in, on loopback only, and takes the port it was given.
        XCTAssertEqual(RemoteAuth(home: home).caller(headers: ["authorization": "Bearer \(pairing.token)"]), .local)
        XCTAssertEqual(try String(contentsOf: home.appendingPathComponent("remote-port"), encoding: .utf8), "29001")
        // Running it again keeps them, whoever chose them.
        XCTAssertEqual(RemoteListener.localServer(home: home, taskID: 9001), address)
        try "5555\n".write(to: home.appendingPathComponent("remote-port"), atomically: true, encoding: .utf8)
        XCTAssertEqual(try XCTUnwrap(Pairing(shiftServer: RemoteListener.localServer(home: home, taskID: 9001)!)).server.port, 5555)
    }

    func testKeepAwakeHeldWhileATaskWorks() async throws {
        XCTAssertFalse(server.keepAwake.isHeld)
        let (id, gate) = try await createPausedTask()
        await waitUntil("the assertion") { self.server.keepAwake.isHeld }
        gate.open()
        await waitUntil("the task to finish") { self.model.task(id)?.status == .completed }
        await waitUntil("its release") { !self.server.keepAwake.isHeld }
    }
}
