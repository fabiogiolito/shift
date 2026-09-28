import XCTest
@testable import ShiftCore

final class StoreTests: XCTestCase {
    var root: URL!
    var store: JSONStateStore!

    override func setUp() {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-store-\(UUID().uuidString)")
        store = JSONStateStore(root: root)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: root)
    }

    func testLoadWithoutFileIsEmpty() async {
        let state = await store.load()
        XCTAssertEqual(state, AppState())
    }

    func testRoundTrip() async throws {
        let project = Project(name: "Site", repoPath: "/tmp/site", baseBranch: "main", serverCommand: "pnpm dev")
        // Whole seconds: ISO-8601 drops fractions.
        let date = Date(timeIntervalSince1970: 1_750_000_000)
        let task = TaskItem(id: 3001, projectID: project.id, title: "Fix header", status: .needsInput,
                            agent: .codex, branch: "shift/3001", worktreePath: "/tmp/wt", sessionID: "abc",
                            port: 3001, serverPID: 42, prompts: [Prompt(text: "Fix it", date: date)],
                            question: "Which one?", createdAt: date, workingSince: date)
        let state = AppState(projects: [project], tasks: [task], nextTaskID: 3002)
        await store.save(state)
        let loaded = await JSONStateStore(root: root).load()
        XCTAssertEqual(loaded, state)

        let text = try String(contentsOf: root.appendingPathComponent("state.json"), encoding: .utf8)
        XCTAssertTrue(text.contains("\n"), "pretty-printed")
        XCTAssertTrue(text.contains("2025-06-15T"), "ISO-8601 dates")
    }

    func testCorruptFileIsMovedAside() async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let file = root.appendingPathComponent("state.json")
        try Data("{ not json".utf8).write(to: file)

        let state = await store.load()
        XCTAssertEqual(state, AppState())
        XCTAssertFalse(fm.fileExists(atPath: file.path))
        let aside = root.appendingPathComponent("state.json.corrupt")
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json")

        // A second corrupt file must not replace the first.
        try Data("again".utf8).write(to: file)
        _ = await store.load()
        XCTAssertEqual(try String(contentsOf: aside, encoding: .utf8), "{ not json")
        let kept = try fm.contentsOfDirectory(atPath: root.path).filter { $0.hasPrefix("state.json.corrupt") }
        XCTAssertEqual(kept.count, 2)
    }

    func testLogAppendReadDelete() async {
        var log = await store.readLog(taskID: 1)
        XCTAssertEqual(log, "")
        await store.appendLog(taskID: 1, text: "one\n")
        await store.appendLog(taskID: 1, text: "two\n")
        await store.appendLog(taskID: 2, text: "other")
        log = await store.readLog(taskID: 1)
        XCTAssertEqual(log, "one\ntwo\n")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("logs/agent-1.log").path))

        await store.deleteLog(taskID: 1)
        await store.deleteLog(taskID: 1) // already gone: no crash
        log = await store.readLog(taskID: 1)
        XCTAssertEqual(log, "")
        log = await store.readLog(taskID: 2)
        XCTAssertEqual(log, "other")
    }

    func testReadLogReturnsOnlyTheTail() async {
        await store.appendLog(taskID: 1, text: String(repeating: "a", count: 300_000))
        await store.appendLog(taskID: 1, text: "END")
        let log = await store.readLog(taskID: 1)
        XCTAssertEqual(log.utf8.count, Int(JSONStateStore.maxLogRead))
        XCTAssertTrue(log.hasSuffix("END"))
    }
}
