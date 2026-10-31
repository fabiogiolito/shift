import XCTest
@testable import ShiftCore

/// Log lines are real ones, from Claude Code 2.1 and Codex 0.157, cut down to the fields that matter.
final class ConversationTests: XCTestCase {
    private func turns(_ lines: [String], agent: AgentKind = .claudeCode) -> [TranscriptTurn] {
        var parser = TranscriptParser(agent: agent)
        _ = parser.feed(Data((lines.joined(separator: "\n") + "\n").utf8))
        return parser.turns
    }

    private func marker(_ ids: [UUID] = [], agent: AgentKind = .claudeCode, text: String? = nil, note: String? = nil) -> String {
        RunMarker.line(agent: agent, promptIDs: ids, text: text, note: note).trimmingCharacters(in: .newlines)
    }

    // MARK: Claude Code lines

    private let claudeInit = #"{"type":"system","subtype":"init","cwd":"/w","session_id":"s","tools":["Bash"]}"#
    private let hook = #"{"type":"system","subtype":"hook_started","hook_id":"5c","hook_name":"SessionStart:startup","session_id":"s"}"#
    private let rateLimit = #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"},"session_id":"s"}"#
    private let thinking = #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"thinking","thinking":"","signature":"CAQ"}]},"parent_tool_use_id":null,"session_id":"s"}"#
    private let injected = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"[Image: original 3200x2000, displayed at 2000x1250. Multiply coordinates by 1.60 to map to original image.]"}]},"parent_tool_use_id":null,"session_id":"s","isSynthetic":true}"#
    private let result = #"{"type":"result","subtype":"success","is_error":false,"result":"All done.","stop_reason":"end_turn","session_id":"s"}"#

    private func text(_ text: String) -> String {
        let escaped = String(data: try! JSONEncoder().encode(text), encoding: .utf8)!
        return #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"# + escaped + #"}]},"parent_tool_use_id":null,"session_id":"s"}"#
    }

    private func bash(_ id: String, _ command: String, description: String = "List repo") -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Bash","input":{"command":"\#(command)","description":"\#(description)"},"caller":{"type":"direct"}}]},"parent_tool_use_id":null,"session_id":"s"}"#
    }

    private func read(_ id: String, _ path: String) -> String {
        #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"\#(id)","name":"Read","input":{"file_path":"\#(path)"}}]},"parent_tool_use_id":null,"session_id":"s"}"#
    }

    private func toolResult(_ id: String, _ output: String, error: Bool = false) -> String {
        #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","content":"\#(output)","is_error":\#(error),"tool_use_id":"\#(id)"}]},"parent_tool_use_id":null,"session_id":"s"}"#
    }

    // MARK: Turn grouping

    func testMarkersStartTurnsAndNamePrompts() {
        let first = UUID(), second = UUID(), third = UUID()
        let turns = turns([
            marker([first]), claudeInit, text("One."), result,
            marker([second, third]), claudeInit, text("Two."), result,
        ])
        XCTAssertEqual(turns.map(\.promptIDs), [[first], [second, third]])
        XCTAssertEqual(turns.map(\.blocks), [[.message("One.")], [.message("Two.")]])
    }

    func testPromptArrivingMidRunStartsATurnWithoutAResult() {
        let first = UUID(), queued = UUID()
        let turns = turns([marker([first]), text("Starting."), bash("t1", "ls"), marker([queued]), toolResult("t1", "a.txt"), text("Now the other thing."), result])
        XCTAssertEqual(turns.map(\.promptIDs), [[first], [queued]])
        // The step that was under way when the prompt arrived keeps its place, and gets its result.
        guard case .step(let step) = turns[0].blocks[1] else { return XCTFail("Expected a step") }
        XCTAssertEqual(step.preview, "a.txt")
        XCTAssertEqual(turns[1].blocks, [.message("Now the other thing.")])
    }

    func testInterruptedRunNeverSaidResult() {
        let first = UUID(), second = UUID()
        let turns = turns([marker([first]), claudeInit, text("Halfway."), bash("t1", "sleep 100"), marker([second]), claudeInit, text("Again."), result])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].blocks, [.message("Again.")])
        guard case .step(let step) = turns[0].blocks[1] else { return XCTFail("Expected a step") }
        XCTAssertNil(step.failure)
        XCTAssertEqual(step.preview, "")
    }

    func testShiftsOwnInstructionsAndNotesComeThroughTheMarker() {
        let turns = turns([marker(text: "Continue the task.", note: "Started over."), text("OK.")])
        XCTAssertEqual(turns[0].text, "Continue the task.")
        XCTAssertEqual(turns[0].note, "Started over.")
        XCTAssertEqual(turns[0].promptIDs, [])
    }

    func testLogWithoutMarkersSplitsOnTheAgentsOwnEvents() {
        let turns = turns([
            "$ cp -R docs .", claudeInit, text("One."), result,
            // Follow-up in the same process, after the result.
            text("Two."), bash("t1", "ls"),
            // A run cut short: no result, then a new run.
            claudeInit, text("Three."), result,
        ])
        XCTAssertEqual(turns.map(\.promptIDs), [[], [], []])
        XCTAssertEqual(turns.count, 3)
        XCTAssertEqual(turns[2].blocks, [.message("Three.")])
    }

    func testLogThatGainsMarkersStopsSplittingOnResult() {
        let id = UUID()
        let turns = turns([claudeInit, text("Old."), result, marker([id]), text("New."), result, text("Same turn.")])
        XCTAssertEqual(turns.count, 2)
        XCTAssertEqual(turns[1].blocks, [.message("New."), .message("Same turn.")])
    }

    func testTruncatedFirstLineIsSkipped() {
        let cut = #"ol_use_id":"t0"}]},"parent_tool_use_id":null,"session_id":"s"}"#
        let turns = turns([cut, text("Whole.")])
        XCTAssertEqual(turns.map(\.blocks), [[.message("Whole.")]])
        // And the raw view's readable form doesn't show half of it, once the store has cut at a line.
        XCTAssertFalse(Transcript.readable(text("Whole."), agent: .claudeCode).contains("{"))
    }

    func testGluedLinesWithoutNewlines() {
        var parser = TranscriptParser(agent: .claudeCode)
        _ = parser.feed(Data(("$ setup\n" + claudeInit + text("One.") + bash("t1", "ls") + toolResult("t1", "a") + result).utf8))
        XCTAssertEqual(parser.turns.count, 1)
        guard case .step(let step) = parser.turns[0].blocks[1], let range = step.outputRange else { return XCTFail("Expected a step") }
        XCTAssertEqual(step.preview, "a")
        XCTAssertEqual(range.lowerBound, 8)
    }

    func testHiddenAndInjectedLinesShowNothing() {
        let turns = turns([marker(), hook, thinking, rateLimit, injected, claudeInit, text("Only this.")])
        XCTAssertEqual(turns.map(\.blocks), [[.message("Only this.")]])
    }

    func testSubagentWorkStaysInsideItsStep() {
        let agent = #"{"type":"assistant","message":{"content":[{"type":"tool_use","id":"a1","name":"Agent","input":{"description":"Look around","prompt":"Go"}}]},"parent_tool_use_id":null}"#
        let inner = #"{"type":"assistant","message":{"content":[{"type":"text","text":"Inner"},{"type":"tool_use","id":"i1","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":"a1"}"#
        let turns = turns([agent, inner, toolResult("a1", "Report")])
        XCTAssertEqual(turns[0].blocks.count, 1)
        guard case .step(let step) = turns[0].blocks[0] else { return XCTFail("Expected a step") }
        XCTAssertEqual(step.kind, .agent)
        XCTAssertEqual(step.preview, "Report")
    }

    func testProtocolLinesAreStripped() {
        let turns = turns([text("SHIFT_TITLE: X\nSHIFT_DESCRIPTION: Y"), text("Done it.\n\n**SHIFT_STATUS: completed**\nAdded the page.\nSHIFT_OPTION: Go")])
        XCTAssertEqual(turns[0].blocks.filter { $0 != .message("") }, [.message("Done it.\n\nAdded the page.")])
    }

    func testPartsOfALogCanArriveAnywhere() {
        let log = Data(([marker(), text("Héllo."), bash("t1", "ls"), toolResult("t1", "a.txt")].joined(separator: "\n") + "\n").utf8)
        var whole = TranscriptParser(agent: .claudeCode), pieces = TranscriptParser(agent: .claudeCode)
        _ = whole.feed(log)
        for byte in log { _ = pieces.feed(Data([byte])) }
        // Where a whole line ends can differ by its newline, which reading an output skips.
        func withoutRanges(_ turns: [TranscriptTurn]) -> [TranscriptBlock] {
            turns.flatMap(\.blocks).map {
                guard case .step(var step) = $0 else { return $0 }
                step.outputRange = nil
                return .step(step)
            }
        }
        XCTAssertEqual(withoutRanges(whole.turns), withoutRanges(pieces.turns))
    }

    // MARK: Step collapsing

    func testConsecutiveStepsCollapseIntoOneSection() {
        let turns = turns([
            text("Looking."), bash("t1", "ls"), toolResult("t1", "a"), bash("t2", "ls b"), toolResult("t2", "b"),
            read("t3", "/w/App.swift"), toolResult("t3", "code"), text("Now editing."), read("t4", "/w/B.swift"),
        ])
        let sections = turns[0].sections
        XCTAssertEqual(sections.count, 4)
        guard case .steps(_, let steps) = sections[1], case .steps(_, let last) = sections[3] else { return XCTFail("Expected steps") }
        XCTAssertEqual(steps.count, 3)
        XCTAssertEqual(TranscriptStep.summary(steps), "Ran 2 commands, read 1 file")
        XCTAssertEqual(steps[2].title, "Read App.swift")
        XCTAssertEqual(steps[2].detail, "/w/App.swift")
        XCTAssertEqual(last.count, 1)
    }

    func testFailedStepSaysWhy() {
        let turns = turns([bash("t1", "ls images"), toolResult("t1", #"Exit code 1\ntotal 8\nls: images: No such file"#, error: true)])
        guard case .step(let step) = turns[0].blocks[0] else { return XCTFail("Expected a step") }
        XCTAssertEqual(step.failure, "total 8")
    }

    func testLongOutputKeepsOnlyAPreviewAndLoadsTheRestFromItsLine() {
        let output = String(repeating: "x", count: TranscriptParser.previewLimit + 500)
        let line = toolResult("t1", output)
        var parser = TranscriptParser(agent: .claudeCode)
        let log = bash("t1", "ls") + "\n" + line + "\n"
        _ = parser.feed(Data(log.utf8))
        guard case .step(let step) = parser.turns[0].blocks[0], let range = step.outputRange else { return XCTFail("Expected a step") }
        XCTAssertEqual(step.preview.count, TranscriptParser.previewLimit)
        XCTAssertTrue(step.isTruncated)
        let bytes = Data(log.utf8)[Int(range.lowerBound)..<Int(range.upperBound)]
        XCTAssertEqual(Transcript.output(ofStep: "t1", line: String(decoding: bytes, as: UTF8.self)), output)
    }

    func testImageResultsAreNotKept() {
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":[{"type":"image","source":{"type":"base64","data":"iVBORw0KGgo"}}]}]},"parent_tool_use_id":null}"#
        let turns = turns([read("t1", "/w/a.png"), line])
        guard case .step(let step) = turns[0].blocks[0] else { return XCTFail("Expected a step") }
        XCTAssertEqual(step.preview, "[image]")
    }

    // MARK: Errors and approvals

    func testErrorsAndApprovalsAreBlocks() {
        let error = #"{"type":"result","subtype":"success","is_error":true,"result":"You've hit your usage limit","session_id":"s"}"#
        let approval = #"{"type":"control_request","request_id":"r","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"pnpm install"}}}"#
        let turns = turns([approval, text("You've hit your usage limit"), error])
        XCTAssertEqual(turns[0].blocks, [.approval("Run `pnpm install`"), .error("You've hit your usage limit")])
    }

    func testStreamingPiecesAreReplacedByTheWholeMessage() {
        func delta(_ text: String) -> String {
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"\#(text)"}},"session_id":"s","parent_tool_use_id":null}"#
        }
        var parser = TranscriptParser(agent: .claudeCode)
        _ = parser.feed(Data((delta("The magic") + "\n" + delta(" word") + "\n").utf8))
        XCTAssertEqual(parser.turns[0].blocks, [.message("The magic word")])
        XCTAssertEqual(parser.feed(Data((text("The magic word is here.") + "\n").utf8)), true)
        XCTAssertEqual(parser.turns[0].blocks, [.message("The magic word is here.")])
    }

    // MARK: Codex

    private let thread = "01a19197-b290-7562-8983-ba4514887bbb"
    private var codexStart: String { #"{"id":2,"result":{"thread":{"id":"\#(thread)","cwd":"/w"},"model":"gpt-6-astra","sandbox":{"type":"readOnly","networkAccess":false}}}"# }
    private var turnStarted: String { #"{"method":"turn/started","params":{"threadId":"\#(thread)","turn":{"id":"u1","status":"inProgress"}}}"# }
    private var turnCompleted: String { #"{"method":"turn/completed","params":{"threadId":"\#(thread)","turn":{"id":"u1","status":"completed","error":null}}}"# }

    private func codexItem(_ method: String, _ item: String, thread other: String? = nil) -> String {
        #"{"method":"\#(method)","params":{"item":\#(item),"threadId":"\#(other ?? thread)","turnId":"u1"}}"#
    }

    private var failedCommand: String { #"{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'echo x >> README.md'","cwd":"/w","status":"failed","commandActions":[{"type":"unknown","command":"echo x >> README.md"}],"aggregatedOutput":"zsh:1: operation not permitted: README.md\n","exitCode":1}"# }

    func testCodexTurn() {
        let id = UUID()
        let started = #"{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'echo x >> README.md'","cwd":"/w","status":"inProgress","commandActions":[{"type":"unknown","command":"echo x >> README.md"}],"aggregatedOutput":null,"exitCode":null}"#
        let read = #"{"type":"commandExecution","id":"exec-2","command":"/bin/zsh -lc 'cat README.md'","status":"inProgress","commandActions":[{"type":"read","command":"cat README.md","name":"README.md","path":"/w/README.md"}]}"#
        let readDone = #"{"type":"commandExecution","id":"exec-2","command":"/bin/zsh -lc 'cat README.md'","status":"completed","commandActions":[],"aggregatedOutput":"hello\n","exitCode":0}"#
        let user = #"{"type":"userMessage","id":"m0","content":[{"type":"text","text":"You are helping"}]}"#
        let message = #"{"type":"agentMessage","id":"msg_1","text":"Blocked.\nSHIFT_STATUS: completed\n","phase":"commentary"}"#
        let turns = turns([
            marker([id], agent: .codex), "2026-10-31 ERROR failed to load skill", codexStart, turnStarted,
            codexItem("item/started", user), codexItem("item/completed", user),
            codexItem("item/started", started), #"{"method":"item/commandExecution/outputDelta","params":{"threadId":"\#(thread)","itemId":"exec-1","delta":"zsh"}}"#,
            codexItem("item/completed", failedCommand),
            codexItem("item/started", read), codexItem("item/completed", readDone),
            #"{"method":"item/agentMessage/delta","params":{"threadId":"\#(thread)","itemId":"msg_1","delta":"Bloc"}}"#,
            codexItem("item/completed", message), turnCompleted,
        ], agent: .codex)
        XCTAssertEqual(turns.count, 1)
        XCTAssertEqual(turns[0].promptIDs, [id])
        let sections = turns[0].sections
        XCTAssertEqual(sections.count, 2)
        guard case .steps(_, let steps) = sections[0] else { return XCTFail("Expected steps") }
        XCTAssertEqual(steps.map(\.title), ["echo x >> README.md", "Read README.md"])
        XCTAssertEqual(steps[0].failure, "zsh:1: operation not permitted: README.md")
        XCTAssertEqual(steps[1].preview, "hello")
        XCTAssertEqual(TranscriptStep.summary(steps), "Ran 1 command, read 1 file")
        guard case .message(_, let text) = sections[1] else { return XCTFail("Expected a message") }
        XCTAssertEqual(text, "Blocked.")
    }

    func testCodexFileChange() {
        let started = #"{"type":"fileChange","id":"call_1","changes":[{"path":"/w/README.md","kind":{"type":"update"},"diff":"+second"}],"status":"inProgress"}"#
        let done = #"{"type":"fileChange","id":"call_1","changes":[{"path":"/w/README.md","kind":{"type":"update"},"diff":"+second"}],"status":"completed"}"#
        let turns = turns([codexStart, codexItem("item/started", started), codexItem("item/completed", done)], agent: .codex)
        guard case .step(let step) = turns[0].blocks[0] else { return XCTFail("Expected a step") }
        XCTAssertEqual(step.kind, .edit)
        XCTAssertEqual(step.title, "Edited README.md")
        XCTAssertEqual(step.preview, "+second")
    }

    func testCodexSubagentsThreadStaysOut() {
        let item = #"{"type":"agentMessage","id":"sub","text":"From the subagent"}"#
        let turns = turns([codexStart, codexItem("item/completed", item, thread: "other"), codexItem("item/completed", #"{"type":"agentMessage","id":"m","text":"Mine"}"#)], agent: .codex)
        XCTAssertEqual(turns[0].blocks, [.message("Mine")])
    }

    func testCodexWithoutMarkersSplitsOnTurnCompleted() {
        func message(_ text: String) -> String { codexItem("item/completed", #"{"type":"agentMessage","id":"m","text":"\#(text)"}"#) }
        let turns = turns([codexStart, turnStarted, message("One."), turnCompleted, turnStarted, message("Two."), turnCompleted], agent: .codex)
        XCTAssertEqual(turns.map(\.blocks), [[.message("One.")], [.message("Two.")]])
    }

    func testCodexFailures() {
        let failed = #"{"method":"turn/completed","params":{"threadId":"\#(thread)","turn":{"id":"u1","status":"failed","error":{"message":"Model overloaded"}}}}"#
        let retried = #"{"method":"error","params":{"threadId":"\#(thread)","willRetry":true,"error":{"message":"Reconnecting 1/5"}}}"#
        let turns = turns([codexStart, retried, failed], agent: .codex)
        XCTAssertEqual(turns[0].blocks, [.error("Model overloaded")])
    }

    func testMarkerSwitchesTheAgent() {
        let turns = turns([marker(), text("From Claude."), marker(agent: .codex), codexStart, codexItem("item/completed", #"{"type":"agentMessage","id":"m","text":"From Codex."}"#)])
        XCTAssertEqual(turns.map(\.blocks), [[.message("From Claude.")], [.message("From Codex.")]])
    }

    func testReadableSkipsMarkers() {
        XCTAssertEqual(Transcript.readable(marker(), agent: .claudeCode), "")
    }

    // MARK: Reader

    func testReaderReadsOnlyWhatsNew() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-transcript-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = JSONStateStore(root: root)
        let reader = TranscriptReader(log: .task(1), store: store, agent: .claudeCode)
        var turns = await reader.update()
        XCTAssertNil(turns, "No log yet")
        let output = String(repeating: "y", count: 5_000)
        await store.appendLog(taskID: 1, text: marker() + "\n" + bash("t1", "ls") + "\n" + toolResult("t1", output) + "\n")
        turns = await reader.update()
        guard case .step(let step) = turns?[0].blocks[0] else { return XCTFail("Expected a step") }
        let full = await reader.fullOutput(of: step)
        XCTAssertEqual(full, output)
        turns = await reader.update()
        XCTAssertNil(turns, "Nothing new")
        await store.appendLog(taskID: 1, text: text("More.") + "\n")
        turns = await reader.update()
        XCTAssertEqual(turns?[0].blocks.count, 2)
    }

    /// Set SHIFT_SAMPLE_LOG to a log to check timing and that nothing in it crashes the parser.
    func testSampleLog() throws {
        guard let path = ProcessInfo.processInfo.environment["SHIFT_SAMPLE_LOG"] else { throw XCTSkip("SHIFT_SAMPLE_LOG not set") }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        var parser = TranscriptParser(agent: .claudeCode)
        let start = Date()
        _ = parser.feed(data)
        let steps = parser.turns.flatMap(\.blocks).filter { if case .step = $0 { true } else { false } }.count
        print("Parsed \(data.count) bytes in \(Date().timeIntervalSince(start))s: \(parser.turns.count) turns, \(steps) steps")
    }

    // MARK: Markdown

    func testMarkdown() {
        let text = """
        # Title
        A paragraph with **bold**
        over two lines.

        - One
          wrapped
        - Two
            - Nested
        1. First

        ```swift
        let x = 1

        let y = 2
        ```
        > Quoted
        | a | b |
        |---|---|
        | 1 | 2 |

        ---
        ```
        still open
        """
        XCTAssertEqual(MarkdownBlock.parse(text), [
            .heading(level: 1, "Title"),
            .paragraph("A paragraph with **bold**\nover two lines."),
            .listItem(level: 0, marker: "•", "One wrapped"),
            .listItem(level: 0, marker: "•", "Two"),
            .listItem(level: 2, marker: "•", "Nested"),
            .listItem(level: 0, marker: "1.", "First"),
            .code("let x = 1\n\nlet y = 2"),
            .quote("Quoted"),
            .table("| a | b |\n|---|---|\n| 1 | 2 |"),
            .rule,
            .code("still open"),
        ])
    }
}
