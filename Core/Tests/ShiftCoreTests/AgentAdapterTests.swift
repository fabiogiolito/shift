import XCTest
@testable import ShiftCore

/// Fixtures are real output captured from claude 2.1.283 and codex-cli 0.156.1, shortened.
final class AgentAdapterTests: XCTestCase {

    // MARK: Usage

    func testUsageParsing() {
        let claude = #"{"five_hour":{"utilization":6.0,"resets_at":"2099-09-28T18:10:00.229627+00:00"},"seven_day":{"utilization":10.0,"resets_at":"2099-09-30T13:00:00.229645+00:00"},"seven_day_opus":null}"#
        let claudeUsage = ClaudeCodeAdapter.usage(from: Data(claude.utf8))
        XCTAssertEqual(claudeUsage?.windows.map(\.name), ["5-hour", "Weekly"])
        XCTAssertEqual(claudeUsage?.tightest?.name, "Weekly")
        XCTAssertNotNil(claudeUsage?.windows[0].resetsAt)

        let codex = """
        {"type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"limit_id":"codex","primary":{"used_percent":42.0,"window_minutes":300,"resets_at":4102444800},"secondary":{"used_percent":16.0,"window_minutes":10080,"resets_at":4102444800},"credits":null}}}
        {"type":"event_msg","payload":{"type":"agent_message","message":"done"}}
        """
        let codexUsage = CodexAdapter.usage(fromLog: codex)
        XCTAssertEqual(codexUsage?.tightest, .init(name: "5-hour", usedPercent: 42, resetsAt: Date(timeIntervalSince1970: 4102444800)))
        XCTAssertEqual(codexUsage?.tightest?.percentLeft(), 58)
        // A window past its reset time has started over.
        XCTAssertEqual(AgentUsage.Window(name: "5-hour", usedPercent: 90, resetsAt: .distantPast).percentLeft(), 100)
    }

    // MARK: Outcome parser

    func testMarkerCompleted() {
        let message = "Created `hello.txt`.\n\nSHIFT_STATUS: completed\nCreated hello.txt with \"hi\" and committed the file."
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: message, exitCode: 0),
                       .completed(summary: "Created hello.txt with \"hi\" and committed the file."))
    }

    func testMarkerNeedsInputAndBlocked() {
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: "SHIFT_STATUS: needs_input\nShould the table be sortable?", exitCode: 0),
                       .needsInput(question: "Should the table be sortable?"))
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: "Tried.\nSHIFT_STATUS: blocked\nThe tests need a database.\n", exitCode: 0),
                       .blocked(reason: "The tests need a database."))
    }

    func testMarkerWithoutTextFallsBackToTextBeforeIt() {
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: "Added the button.\nSHIFT_STATUS: completed", exitCode: 0),
                       .completed(summary: "Added the button."))
    }

    func testLastMarkerWins() {
        let message = "I will end with SHIFT_STATUS: completed later.\nSHIFT_STATUS: blocked\nNo network."
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: message, exitCode: 0), .blocked(reason: "No network."))
    }

    func testNoMarkerExitZeroIsCompletedAndShort() {
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: " Done it. \n", exitCode: 0), .completed(summary: "Done it."))
        guard case .completed(let summary) = OutcomeProtocol.parse(finalMessage: String(repeating: "x", count: 5000), exitCode: 0)
        else { return XCTFail() }
        XCTAssertEqual(summary.count, 400)
    }

    // MARK: Suggested replies

    func testOptionsWithAQuestion() {
        let message = """
        I can add the greeting file, but the language changes its contents.

        SHIFT_STATUS: needs_input
        Which language should the greeting be in?
        SHIFT_OPTION: English
        SHIFT_OPTION: Spanish
        SHIFT_OPTION: Portuguese
        """
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: message, exitCode: 0),
                       .needsInput(question: "Which language should the greeting be in?", options: ["English", "Spanish", "Portuguese"]))
    }

    func testOptionsWithABlockToleratesMarkdown() {
        let message = """
        SHIFT_STATUS: blocked
        The dev server needs `DATABASE_URL`, which is only in the main repo's `.env`.

        - **SHIFT_OPTION:** Copy .env from the main repo in the setup command
        * SHIFT_OPTION: `Use SQLite for local development`
        1. SHIFT_OPTION: "Skip the database checks for now"
        **SHIFT_OPTION: Skip the database checks for now**
        SHIFT_OPTION:
        """
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: message, exitCode: 0), .blocked(
            reason: "The dev server needs `DATABASE_URL`, which is only in the main repo's `.env`.",
            options: ["Copy .env from the main repo in the setup command", "Use SQLite for local development",
                      "Skip the database checks for now"]))
    }

    func testOptionsAreCappedInNumberAndLength() {
        let long = String(repeating: "very ", count: 30) + "long"
        let message = "SHIFT_STATUS: needs_input\nWhen should the empty state show?\n"
            + ["Only when there are no results", "Always", "never", "Never", "While loading", "On error", long]
                .map { "SHIFT_OPTION: \($0)" }.joined(separator: "\n")
        guard case .needsInput(let question, let options) = OutcomeProtocol.parse(finalMessage: message, exitCode: 0)
        else { return XCTFail() }
        XCTAssertEqual(question, "When should the empty state show?")
        XCTAssertEqual(options, ["Only when there are no results", "Always", "never", "While loading"])
        XCTAssertEqual(OutcomeProtocol.extractingOptions("SHIFT_OPTION: " + long).options.first?.count, 80)
    }

    func testNoOptions() {
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: "SHIFT_STATUS: blocked\nThe CI token expired.", exitCode: 0),
                       .blocked(reason: "The CI token expired.", options: []))
    }

    func testOptionsIgnoredOnCompleted() {
        let message = "SHIFT_STATUS: completed\nAdded hello.txt in English.\nSHIFT_OPTION: Translate it to Spanish"
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: message, exitCode: 0), .completed(summary: "Added hello.txt in English."))
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: "Done.\nSHIFT_OPTION: More", exitCode: 0), .completed(summary: "Done."))
    }

    // MARK: Title and description

    func testDescribedAtTheStartOfAMessage() {
        let message = "SHIFT_TITLE: Marketing homepage with separate ordering page\nSHIFT_DESCRIPTION: The homepage will introduce the brand. Ordering moves to its own page.\n\nI'll start by reading index.html."
        let found = OutcomeProtocol.described(in: message)
        XCTAssertEqual(found.title, "Marketing homepage with separate ordering page")
        XCTAssertEqual(found.description, "The homepage will introduce the brand. Ordering moves to its own page.")
    }

    func testDescribedToleratesPositionAndEmphasis() {
        let message = "Sure, on it.\n\n**SHIFT_TITLE:** Sortable orders table\r\n**SHIFT_DESCRIPTION: Orders can be sorted by date.**\nNow working."
        let found = OutcomeProtocol.described(in: message)
        XCTAssertEqual(found.title, "Sortable orders table")
        XCTAssertEqual(found.description, "Orders can be sorted by date.")
    }

    func testDescribedMayBePartialOrAbsent() {
        XCTAssertEqual(OutcomeProtocol.described(in: "SHIFT_TITLE: Dark mode").title, "Dark mode")
        XCTAssertNil(OutcomeProtocol.described(in: "SHIFT_TITLE: Dark mode").description)
        XCTAssertNil(OutcomeProtocol.described(in: "SHIFT_TITLE:   \nSHIFT_DESCRIPTION: Why.").title)
        let none = OutcomeProtocol.described(in: "Reading the code.\nSHIFT_STATUS: completed\nDone.")
        XCTAssertNil(none.title)
        XCTAssertNil(none.description)
    }

    func testDescribedNeverLeaksIntoTheOutcome() {
        let lines = "SHIFT_TITLE: Greeting file\n**SHIFT_DESCRIPTION:** Adds a file that says hi.\n"
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: lines + "Added hello.txt.\nSHIFT_STATUS: completed", exitCode: 0),
                       .completed(summary: "Added hello.txt."))
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: lines + "\nSHIFT_STATUS: needs_input\nWhich greeting?", exitCode: 0),
                       .needsInput(question: "Which greeting?"))
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: lines + "Could not write the file.", exitCode: 0),
                       .completed(summary: "Could not write the file."))
    }

    func testInstructionsAskForADescriptionOnTheFirstTurnOnly() {
        let first = OutcomeProtocol.instructions(firstTurn: true), later = OutcomeProtocol.instructions(firstTurn: false)
        for text in [first, later] {
            XCTAssertTrue(text.contains("SHIFT_STATUS: completed"))
            XCTAssertTrue(text.contains("SHIFT_TITLE: <title>"))
            XCTAssertTrue(text.contains("SHIFT_OPTION: <reply>"))
        }
        XCTAssertTrue(first.contains("Before doing any work"))
        XCTAssertTrue(later.contains("otherwise do not write them"))
        XCTAssertEqual(ClaudeCodeAdapter.arguments(for: AgentRequest(prompt: "x", sessionID: "abc", worktree: URL(fileURLWithPath: "/tmp")))
            .contains(later), true)
    }

    func testFailuresAreBlocked() {
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: nil, exitCode: 1, error: "Not logged in"), .blocked(reason: "Not logged in"))
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: nil, exitCode: 143),
                       .blocked(reason: "The agent stopped unexpectedly (exit code 143)."))
        // The CLI failing beats anything the message says, even with exit code 0.
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: "SHIFT_STATUS: completed\nok", exitCode: 0, error: "Rate limited", cliFailed: true),
                       .blocked(reason: "Rate limited"))
    }

    // MARK: Claude Code stream

    private func run(_ parse: LineParser, _ lines: [String]) -> (state: TurnState, activities: [String]) {
        var state = TurnState()
        let activities = lines.compactMap { parse($0, &state) }
        return (state, activities)
    }

    func testClaudeStream() {
        let (state, activities) = run(ClaudeCodeAdapter.parse, [
            #"{"type":"system","subtype":"hook_started","hook_id":"dc1f3eb0","hook_name":"SessionStart:startup","hook_event":"SessionStart","uuid":"1c0cf480","session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee"}"#,
            #"{"type":"system","subtype":"init","cwd":"/private/tmp/lab/wt1","session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee","tools":["Task","Bash"]}"#,
            #"{"type":"assistant","message":{"model":"claude-fable-5-1","id":"msg_01","type":"message","role":"assistant","content":[{"type":"tool_use","id":"toolu_01","name":"Bash","input":{"command":"echo hi > hello.txt && ls","description":"Create hello.txt, list files, commit"},"caller":{"type":"direct"}}],"stop_reason":null},"parent_tool_use_id":null,"session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee"}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning"},"uuid":"75762cb3","session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee"}"#,
            #"{"type":"user","message":{"role":"user","content":[{"tool_use_id":"toolu_01","type":"tool_result","content":"hello.txt\nREADME.md","is_error":false}]},"parent_tool_use_id":null,"session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"toolu_02","name":"Write","input":{"file_path":"/private/tmp/lab/wt1/src/Table.tsx","content":"y"},"caller":{"type":"direct"}}]},"parent_tool_use_id":null,"session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee"}"#,
            #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"Created `hello.txt`.\n\nSHIFT_STATUS: completed\nCreated hello.txt."}]},"parent_tool_use_id":null,"session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee"}"#,
            #"{"duration_api_ms":6537,"stop_reason":"end_turn","session_id":"0f3d7677-9893-4c4a-bfb6-d33850f2a2ee","permission_denials":[],"terminal_reason":"completed","is_error":false,"num_turns":2,"subtype":"success","api_error_status":null,"result":"Created `hello.txt`.\n\nSHIFT_STATUS: completed\nCreated hello.txt.","type":"result"}"#,
            "not json at all",
        ])
        XCTAssertEqual(state.sessionID, "0f3d7677-9893-4c4a-bfb6-d33850f2a2ee")
        XCTAssertEqual(activities, ["Create hello.txt, list files, commit", "Editing Table.tsx"])
        XCTAssertFalse(state.cliFailed)
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: state.finalMessage, exitCode: 0), .completed(summary: "Created hello.txt."))
    }

    func testClaudeErrors() {
        let resume = run(ClaudeCodeAdapter.parse, [
            #"{"type":"result","subtype":"error_during_execution","duration_ms":0,"is_error":true,"num_turns":0,"stop_reason":null,"session_id":"11111111-1111-1111-1111-111111111111","permission_denials":[],"errors":["No conversation found with session ID: 11111111-1111-1111-1111-111111111111"]}"#,
        ]).state
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: resume.finalMessage, exitCode: 1, error: resume.error, cliFailed: resume.cliFailed),
                       .blocked(reason: "No conversation found with session ID: 11111111-1111-1111-1111-111111111111"))

        // API errors come back as a "success" subtype with is_error set.
        let api = run(ClaudeCodeAdapter.parse, [
            #"{"stop_reason":"stop_sequence","session_id":"dd8fbd80","terminal_reason":"api_error","is_error":true,"num_turns":1,"subtype":"success","api_error_status":404,"result":"There's an issue with the selected model (bogus-model-x). It may not exist or you may not have access to it.","type":"result"}"#,
        ]).state
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: api.finalMessage, exitCode: 1, error: api.error, cliFailed: api.cliFailed),
                       .blocked(reason: "There's an issue with the selected model (bogus-model-x). It may not exist or you may not have access to it."))
    }

    func testClaudeArguments() {
        let worktree = URL(fileURLWithPath: "/tmp/wt")
        let base = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        let tail = ["--append-system-prompt", OutcomeProtocol.instructions(firstTurn: true)]
        let bypass = base + ["--permission-mode", "bypassPermissions", "--permission-prompts", "none",
                             "--settings", #"{"sandbox":{"enabled":false}}"#] + tail
        let auto = base + ["--permission-mode", "auto", "--permission-prompts", "none"] + tail
        let manual = base + ["--permission-mode", "manual", "--permission-prompts", "host",
                             "--permission-prompt-tool", "stdio"] + tail

        func arguments(_ permissions: AgentPermissions, session: String? = nil) -> [String] {
            ClaudeCodeAdapter.arguments(for: AgentRequest(prompt: "p", sessionID: session, worktree: worktree,
                                                          permissions: permissions))
        }
        func resumed(_ arguments: [String]) -> [String] {
            arguments.dropLast() + [OutcomeProtocol.instructions(firstTurn: false), "--resume", "abc"]
        }
        XCTAssertEqual(arguments(.bypass), bypass)
        XCTAssertEqual(arguments(.bypass, session: "abc"), resumed(bypass))
        XCTAssertEqual(arguments(.auto), auto)
        XCTAssertEqual(arguments(.auto, session: "abc"), resumed(auto))
        XCTAssertEqual(arguments(.manual), manual)
        XCTAssertEqual(arguments(.manual, session: "abc"), resumed(manual))
        XCTAssertEqual(AgentRequest(prompt: "p", worktree: worktree).permissions, .bypass)
    }

    // Captured from real `--permission-prompts host --permission-prompt-tool stdio` runs (paths shortened).
    static let claudeBashRequest = #"{"type":"control_request","request_id":"887e3ea7-73dc-4b04-9c9c-85dbd6fdbd10","request":{"subtype":"can_use_tool","tool_name":"Bash","display_name":"Bash","input":{"command":"ls > files.txt; cat files.txt","description":"Write directory listing to files.txt"},"description":"Write directory listing to files.txt","permission_suggestions":[{"type":"addRules","rules":[{"toolName":"Bash","ruleContent":"ls > files.txt; cat files.txt"}],"behavior":"allow","destination":"localSettings"}],"blocked_path":"/tmp/wt/files.txt","tool_use_id":"toolu_01NZ7QfX4cUAnvLmT5bmse3o"}}"#

    func testClaudeApprovalRequests() {
        let (state, activities) = run(ClaudeCodeAdapter.parse, [
            Self.claudeBashRequest,
            #"{"type":"control_request","request_id":"4f65371d-aed8-4126-a98b-4881ae10cdc4","request":{"subtype":"can_use_tool","tool_name":"Edit","display_name":"Edit","input":{"file_path":"/tmp/wt/src/app.css","old_string":"body{}","new_string":"body{margin:0}","replace_all":false},"description":"src/app.css","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_01UtuTkyfrnRHLPGD6DCgeMH"}}"#,
            #"{"type":"control_request","request_id":"13b4f8cc-a8dc-440c-b1bc-c628eba3be8f","request":{"subtype":"can_use_tool","tool_name":"Write","display_name":"Write","input":{"file_path":"/tmp/wt/notes.md","content":"hi\n"},"description":"notes.md","permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}],"tool_use_id":"toolu_016oXAQi2YU6jADCMkwKirsA"}}"#,
            #"{"type":"control_request","request_id":"a9362cbf-b785-459c-b3b4-87cc145843df","request":{"subtype":"can_use_tool","tool_name":"WebFetch","display_name":"WebFetch","input":{"url":"https://example.com","prompt":"What is the page title?"},"description":"https://example.com","permission_suggestions":[{"type":"addRules","destination":"localSettings","rules":[{"toolName":"WebFetch","ruleContent":"domain:example.com"}],"behavior":"allow"}],"tool_use_id":"toolu_01DcCj1ikoAaA8vUFKigM2Wg"}}"#,
        ])
        XCTAssertEqual(state.approvals, [
            .init(id: "887e3ea7-73dc-4b04-9c9c-85dbd6fdbd10", summary: "Run `ls > files.txt; cat files.txt`"),
            .init(id: "4f65371d-aed8-4126-a98b-4881ae10cdc4", summary: "Edit `src/app.css`"),
            .init(id: "13b4f8cc-a8dc-440c-b1bc-c628eba3be8f", summary: "Edit `notes.md`"),
            .init(id: "a9362cbf-b785-459c-b3b4-87cc145843df", summary: "Fetch https://example.com"),
        ])
        XCTAssertEqual(activities, [])
        XCTAssertFalse(state.closeInput)
        XCTAssertEqual(ClaudeCodeAdapter.approvalSummary(["tool_name": "Bash", "input": ["command": String(repeating: "x", count: 100) + "\nrm -rf build"]]),
                       "Run `" + String(repeating: "x", count: 59) + "…`")

        var done = TurnState()
        _ = ClaudeCodeAdapter.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"s"}"#, state: &done)
        XCTAssertTrue(done.closeInput, "stdin closes when the turn is over")
    }

    func testClaudeApprovalReplies() throws {
        func decode(_ line: String) throws -> [String: Any] {
            XCTAssertTrue(line.hasSuffix("\n"))
            return try XCTUnwrap(jsonObject(String(line.dropLast())))
        }
        let allow = ClaudeCodeAdapter.reply(to: Self.claudeBashRequest, allow: true, message: nil)
        XCTAssertFalse(allow.deliveredMessage)
        var response = try decode(allow.line)
        XCTAssertEqual(response["type"] as? String, "control_response")
        var inner = try XCTUnwrap(response["response"] as? [String: Any])
        XCTAssertEqual(inner["subtype"] as? String, "success")
        XCTAssertEqual(inner["request_id"] as? String, "887e3ea7-73dc-4b04-9c9c-85dbd6fdbd10")
        var decision = try XCTUnwrap(inner["response"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "allow")
        XCTAssertEqual((decision["updatedInput"] as? [String: Any])?["command"] as? String, "ls > files.txt; cat files.txt")

        let deny = ClaudeCodeAdapter.reply(to: Self.claudeBashRequest, allow: false, message: "Use find instead")
        XCTAssertTrue(deny.deliveredMessage)
        response = try decode(deny.line)
        inner = try XCTUnwrap(response["response"] as? [String: Any])
        decision = try XCTUnwrap(inner["response"] as? [String: Any])
        XCTAssertEqual(decision["behavior"] as? String, "deny")
        XCTAssertEqual(decision["message"] as? String, "The user denied this and said instead: Use find instead")
        let plain = try decode(ClaudeCodeAdapter.reply(to: Self.claudeBashRequest, allow: false, message: nil).line)
        XCTAssertEqual(((plain["response"] as? [String: Any])?["response"] as? [String: Any])?["message"] as? String,
                       "The user denied this action.")
    }

    func testModelArguments() {
        let request = AgentRequest(prompt: "p", worktree: URL(fileURLWithPath: "/tmp/wt"), model: "opus")
        let claude = ClaudeCodeAdapter.arguments(for: request)
        XCTAssertEqual(claude.firstIndex(of: "--model").map { claude[$0 + 1] }, "opus")
        XCTAssertEqual(CodexAdapter.arguments(for: request, gitDirectory: nil).suffix(2), ["-c", #"model="opus""#])
        XCTAssertFalse(ClaudeCodeAdapter.arguments(for: AgentRequest(prompt: "p", worktree: request.worktree)).contains("--model"))
    }

    func testCodexModelsFromCache() {
        let cache = Data(#"{"models": [{"slug": "b", "display_name": "B", "visibility": "list", "priority": 2}, {"slug": "hidden", "visibility": "hide", "priority": 0}, {"slug": "a", "display_name": "A", "visibility": "list", "priority": 1}]}"#.utf8)
        XCTAssertEqual(CodexAdapter.models(fromCache: cache), [AgentModel(id: "a", name: "A"), AgentModel(id: "b", name: "B")])
    }

    // MARK: Codex

    func testCodexArguments() {
        let worktree = URL(fileURLWithPath: "/tmp/wt")
        func arguments(_ permissions: AgentPermissions, session: String? = nil, git: String? = "/repo/.git") -> [String] {
            CodexAdapter.arguments(for: AgentRequest(prompt: "p", sessionID: session, worktree: worktree,
                                                     permissions: permissions), gitDirectory: git)
        }
        // The session and prompt go over stdin (see testCodexAppServerTurn).
        let auto = ["-c", #"approval_policy="on-request""#, "-c", #"approvals_reviewer="auto_review""#,
                    "-c", #"sandbox_mode="workspace-write""#]
        let roots = ["-c", #"sandbox_workspace_write.writable_roots=["/repo/.git"]"#]
        XCTAssertEqual(arguments(.auto), ["app-server"] + auto + roots)
        XCTAssertEqual(arguments(.auto, session: "abc"), ["app-server"] + auto + roots)
        XCTAssertEqual(arguments(.auto, git: nil), ["app-server"] + auto)

        XCTAssertEqual(arguments(.bypass), ["app-server", "-c", #"approval_policy="never""#, "-c", #"sandbox_mode="danger-full-access""#])

        let manual = ["app-server", "-c", #"approval_policy="on-request""#, "-c", #"approvals_reviewer="user""#,
                      "-c", #"sandbox_mode="read-only""#]
        XCTAssertEqual(arguments(.manual, git: nil), manual)
        XCTAssertEqual(arguments(.manual, session: "abc", git: nil), manual)
    }

    func testClaudeFollowUpsGoInAsUserMessagesUntilStdinCloses() throws {
        var state = TurnState()
        let line = try XCTUnwrap(ClaudeCodeAdapter.send("Also b.txt", &state))
        let message = try XCTUnwrap(jsonObject(line.trimmingCharacters(in: .newlines)))
        XCTAssertEqual(message["type"] as? String, "user")
        XCTAssertEqual((message["message"] as? [String: Any])?["content"] as? String, "Also b.txt")
        _ = ClaudeCodeAdapter.parse(line: #"{"type":"result","subtype":"success","is_error":false,"result":"Done.","session_id":"s"}"#, state: &state)
        XCTAssertNil(ClaudeCodeAdapter.send("Too late", &state))
    }

    /// A follow-up steers the turn in progress; one that misses it starts the next turn before stdin closes.
    func testCodexFollowUpsSteerTheTurn() throws {
        func parse(_ line: String, _ state: inout TurnState, manual: Bool = false) {
            _ = CodexAdapter.parseAppServer(line, &state, prompt: "Do it", resume: "th", cwd: "/tmp/wt", manual: manual)
        }
        func decode(_ line: String?) throws -> [String: Any] {
            try XCTUnwrap(jsonObject(try XCTUnwrap(line).trimmingCharacters(in: .newlines)))
        }
        var state = TurnState(sessionID: "th")
        XCTAssertNil(CodexAdapter.send("Early", &state), "no turn yet")
        parse(#"{"method":"turn/started","params":{"threadId":"th","turn":{"id":"t1","status":"inProgress"}}}"#, &state)

        let steer = try decode(CodexAdapter.send("Also b.txt", &state))
        XCTAssertEqual(steer["method"] as? String, "turn/steer")
        XCTAssertEqual(steer["id"] as? Int, 100)
        let params = try XCTUnwrap(steer["params"] as? [String: Any])
        XCTAssertEqual(params["expectedTurnId"] as? String, "t1")
        XCTAssertEqual(params["threadId"] as? String, "th")
        XCTAssertEqual((params["input"] as? [[String: Any]])?.first?["text"] as? String, "Also b.txt")
        parse(#"{"id":100,"result":{"turnId":"t1"}}"#, &state)
        XCTAssertFalse(state.cliFailed)

        // The turn ends while a steer is on its way: stdin stays open for its answer.
        let late = try decode(CodexAdapter.send("And c.txt", &state))
        parse(#"{"method":"turn/completed","params":{"threadId":"th","turn":{"id":"t1","status":"completed"}}}"#, &state)
        XCTAssertFalse(state.closeInput)
        XCTAssertNil(CodexAdapter.send("After the turn", &state))
        parse(#"{"id":\#(late["id"] as! Int),"error":{"code":-32600,"message":"no active turn"}}"#, &state)
        XCTAssertFalse(state.cliFailed)
        XCTAssertFalse(state.closeInput)
        let next = try decode(state.outgoing.last)
        state.outgoing = []
        XCTAssertEqual(next["method"] as? String, "turn/start")
        XCTAssertEqual(((next["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String, "And c.txt")

        parse(#"{"method":"turn/started","params":{"threadId":"th","turn":{"id":"t2","status":"inProgress"}}}"#, &state)
        parse(#"{"method":"turn/completed","params":{"threadId":"th","turn":{"id":"t2","status":"completed"}}}"#, &state)
        XCTAssertTrue(state.closeInput)
    }

    func testCodexDeclinesApprovalsOutsideManual() {
        var state = TurnState()
        let request = #"{"method":"item/commandExecution/requestApproval","id":7,"params":{"command":"curl x"}}"#
        _ = CodexAdapter.parseAppServer(request, &state, prompt: "p", resume: nil, cwd: "/tmp/wt", manual: false)
        XCTAssertEqual(state.approvals, [])
        XCTAssertEqual(state.outgoing, [#"{"id":7,"result":{"decision":"decline"}}"# + "\n"])
    }

    /// Lines captured from a real `codex app-server` turn (paths shortened, noise left out).
    func testCodexAppServerTurn() throws {
        func turn(resume: String?, _ lines: [String]) -> (TurnState, [String], [[String]]) {
            var state = TurnState(sessionID: resume)
            var activities: [String] = [], written: [[String]] = []
            for line in lines {
                if let activity = CodexAdapter.parseAppServer(line, &state, prompt: "Do it", resume: resume, cwd: "/tmp/wt") {
                    activities.append(activity)
                }
                written.append(state.outgoing)
                state.outgoing = []
            }
            return (state, activities, written)
        }
        let lines = [
            #"{"id":1,"result":{"userAgent":"shift/0.157.0 (Mac OS 27.0.0; arm64)","codexHome":"/Users/me/.codex","platformFamily":"unix","platformOs":"macos"}}"#,
            #"{"id":2,"result":{"thread":{"id":"01a0e2d2-0f8b-70d0-9f32-2f6da4bf11cc","environments":[{"environmentId":"local","cwd":"/tmp/wt"}]}}}"#,
            #"{"method":"item/started","params":{"item":{"type":"commandExecution","id":"exec-1","command":"/bin/zsh -lc 'pnpm install'","status":"inProgress"},"threadId":"01a0e2d2-0f8b-70d0-9f32-2f6da4bf11cc"}}"#,
            #"{"method":"item/commandExecution/requestApproval","id":0,"params":{"kind":"command","threadId":"01a0e2d2-0f8b-70d0-9f32-2f6da4bf11cc","turnId":"t","itemId":"exec-1","startedAtMs":1790511820141,"environmentId":"local","command":"/bin/zsh -lc 'pnpm install'","cwd":"/tmp/wt","availableDecisions":["accept","cancel"]}}"#,
            #"{"method":"item/started","params":{"item":{"type":"fileChange","id":"exec-f8b4","changes":[{"path":"/tmp/wt/src/app.css","kind":{"type":"update","move_path":null},"diff":"@@ -1 +1 @@\n-hi\n+hello\n"}],"status":"inProgress"}}}"#,
            #"{"method":"item/fileChange/requestApproval","id":2,"params":{"threadId":"01a0e2d2-0f8b-70d0-9f32-2f6da4bf11cc","turnId":"t","itemId":"exec-f8b4","startedAtMs":1790511834352,"reason":null,"grantRoot":null}}"#,
            #"{"method":"item/tool/requestUserInput","id":3,"params":{"threadId":"t","turnId":"t","itemId":"q"}}"#,
            #"{"method":"item/completed","params":{"item":{"type":"agentMessage","id":"msg_1","text":"Done.\n\nSHIFT_STATUS: completed\nInstalled and restyled.","phase":"final_answer"}}}"#,
            #"{"method":"turn/completed","params":{"threadId":"t","turn":{"id":"t","items":[],"status":"completed","error":null}}}"#,
        ]
        let (state, activities, written) = turn(resume: nil, lines)
        XCTAssertEqual(state.sessionID, "01a0e2d2-0f8b-70d0-9f32-2f6da4bf11cc")
        XCTAssertEqual(written[0], [#"{"method":"initialized"}"# + "\n", #"{"id":2,"method":"thread/start","params":{"cwd":"/tmp/wt"}}"# + "\n"])
        let start = try XCTUnwrap(jsonObject(try XCTUnwrap(written[1].first).trimmingCharacters(in: .newlines)))
        XCTAssertEqual(start["method"] as? String, "turn/start")
        XCTAssertEqual((start["params"] as? [String: Any])?["threadId"] as? String, "01a0e2d2-0f8b-70d0-9f32-2f6da4bf11cc")
        XCTAssertEqual(((start["params"] as? [String: Any])?["input"] as? [[String: Any]])?.first?["text"] as? String, "Do it")
        XCTAssertEqual(state.approvals, [.init(id: "0", summary: "Run `pnpm install`"), .init(id: "2", summary: "Edit `src/app.css`")])
        XCTAssertEqual(written[6], [#"{"error":{"code":-32601,"message":"Not supported by Shift."},"id":3}"# + "\n"])
        XCTAssertEqual(activities, ["Running pnpm install", "Editing app.css"])
        XCTAssertTrue(state.closeInput)
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: state.finalMessage, exitCode: 0), .completed(summary: "Installed and restyled."))

        let (resumed, _, resumedWrites) = turn(resume: "abc", Array(lines.prefix(1)))
        XCTAssertEqual(resumedWrites[0].last, #"{"id":2,"method":"thread/resume","params":{"cwd":"/tmp/wt","threadId":"abc"}}"# + "\n")
        XCTAssertEqual(resumed.sessionID, "abc")

        let (failed, _, _) = turn(resume: "gone", [#"{"id":2,"error":{"code":-32600,"message":"no rollout found for thread id gone"}}"#])
        XCTAssertTrue(failed.cliFailed && failed.closeInput)
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: nil, exitCode: 0, error: failed.error, cliFailed: failed.cliFailed),
                       .blocked(reason: "no rollout found for thread id gone"))

        XCTAssertEqual(CodexAdapter.reply(to: lines[3], allow: true, message: "ignored").line, #"{"id":0,"result":{"decision":"accept"}}"# + "\n")
        XCTAssertEqual(CodexAdapter.reply(to: lines[5], allow: false, message: "x").line, #"{"id":2,"result":{"decision":"decline"}}"# + "\n")
        XCTAssertFalse(CodexAdapter.reply(to: lines[5], allow: false, message: "x").deliveredMessage)
    }

    func testCaptureGivesUpOnACommandThatHangs() {
        let started = Date()
        let output = AgentEnvironment.capture("/bin/sh", ["-c", "echo before; exec sleep 30"], environment: [:], timeout: 0.5)
        XCTAssertEqual(output, "before\n")
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    // MARK: Live (SHIFT_LIVE_AGENT_TESTS=1)

    func testLiveClaudeCode() async throws { try await live(ClaudeCodeAdapter()) }
    func testLiveCodex() async throws { try await live(CodexAdapter()) }

    /// Runs a real turn in a worktree of a throwaway repo, then resumes the session.
    func testLiveClaudeCodeFullAccessReachesTheNetwork() async throws { try await liveNetwork(ClaudeCodeAdapter()) }
    func testLiveCodexFullAccessReachesTheNetwork() async throws { try await liveNetwork(CodexAdapter()) }

    /// Full access, new and resumed session: commands that need the network are not blocked.
    private func liveNetwork(_ adapter: AgentAdapter) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIFT_LIVE_AGENT_TESTS"] == "1", "live agent tests are off")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-agent-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo"), worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = "git init -q -b main && echo scratch > README.md && git add . && git commit -qm init && git worktree add -q -b task ../wt"
        XCTAssertNotNil(AgentEnvironment.capture("/bin/sh", ["-c", setup], environment: AgentEnvironment.loginShell, directory: repo))

        var session: String?
        for file in ["status.txt", "again.txt"] {
            let turn = await collect(adapter.run(AgentRequest(
                prompt: "Run `curl -sI https://example.com | head -1` and put its output in \(file). Nothing else.",
                sessionID: session, worktree: worktree, permissions: .bypass)))
            guard case .finished(.completed) = turn.events.last else {
                return XCTFail("\(file): \(String(describing: turn.events.last))")
            }
            session = session ?? turn.sessions.first
            let status = try String(contentsOf: worktree.appendingPathComponent(file), encoding: .utf8)
            XCTAssertTrue(status.hasPrefix("HTTP/"), status)
        }
    }

    private func live(_ adapter: AgentAdapter) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIFT_LIVE_AGENT_TESTS"] == "1", "live agent tests are off")
        let installation = await adapter.detect()
        XCTAssertNotNil(installation?.version)

        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-agent-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo"), worktree = root.appendingPathComponent("wt")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let setup = "git init -q -b main && echo scratch > README.md && git add . && git commit -qm init && git worktree add -q -b task ../wt"
        XCTAssertNotNil(AgentEnvironment.capture("/bin/sh", ["-c", setup], environment: AgentEnvironment.loginShell, directory: repo))

        let first = await collect(adapter.run(AgentRequest(
            prompt: "Create hello.txt containing hi. Also remember the code word pineapple-42; do not write it to any file.",
            worktree: worktree)))
        XCTAssertEqual(first.finished.count, 1)
        guard case .finished(.completed) = first.events.last else { return XCTFail("first turn: \(String(describing: first.events.last))") }
        XCTAssertEqual(first.sessions.count, 1)
        let described = first.events.firstIndex { if case .described = $0 { true } else { false } }
        guard let described, case .described(let title?, let description?) = first.events[described] else {
            return XCTFail("no title and description: \(first.events)")
        }
        print("LIVE \(adapter.kind) title: \(title)\nLIVE \(adapter.kind) description: \(description)")
        XCTAssertLessThan(described, first.events.count - 1, "described before finished")
        XCTAssertFalse("Create hello.txt containing hi".lowercased().contains(title.lowercased()))
        XCTAssertFalse(title.lowercased().hasPrefix("create hello.txt containing hi"))
        if case .finished(.completed(let summary)) = first.events.last { XCTAssertFalse(summary.contains("SHIFT_")) }
        XCTAssertFalse(first.activities.isEmpty)
        XCTAssertEqual(try String(contentsOf: worktree.appendingPathComponent("hello.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines), "hi")
        let log = AgentEnvironment.capture("/usr/bin/git", ["log", "--oneline"], environment: AgentEnvironment.loginShell, directory: worktree) ?? ""
        XCTAssertEqual(log.split(separator: "\n").count, 2, "agent should have committed: \(log)")

        let second = await collect(adapter.run(AgentRequest(
            prompt: "What was the code word I asked you to remember? Put it in your handoff note. Change no files.",
            sessionID: first.sessions.first, worktree: worktree)))
        guard case .finished(.completed(let summary)) = second.events.last else { return XCTFail("second turn: \(String(describing: second.events.last))") }
        XCTAssertTrue(summary.contains("pineapple-42"), summary)
        XCTAssertTrue(second.sessions.isEmpty, "a resumed session keeps its id")
    }

    func testLiveClaudeCodeOptions() async throws { try await liveOptions(ClaudeCodeAdapter()) }
    func testLiveCodexOptions() async throws { try await liveOptions(CodexAdapter()) }

    /// A prompt that forces a question comes back as needs_input with suggested replies.
    private func liveOptions(_ adapter: AgentAdapter) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIFT_LIVE_AGENT_TESTS"] == "1", "live agent tests are off")
        let (root, worktree) = try scratchWorktree()
        defer { try? FileManager.default.removeItem(at: root) }
        let turn = await liveTurn(adapter, "Add a greeting file. Ask me which language it should be in before creating it.",
                                  worktree: worktree, permissions: .bypass)
        guard case .finished(.needsInput(let question, let options)) = turn.outcome else {
            return XCTFail(String(describing: turn.outcome))
        }
        print("LIVE \(adapter.kind) question: \(question)\nLIVE \(adapter.kind) options: \(options)")
        XCTAssertFalse(question.contains("SHIFT_"))
        XCTAssertTrue((2...4).contains(options.count), "\(options)")
    }

    func testLiveClaudeCodeAuto() async throws { try await liveAuto(ClaudeCodeAdapter()) }
    func testLiveCodexAuto() async throws { try await liveAuto(CodexAdapter()) }
    func testLiveClaudeCodeManual() async throws { try await liveManual(ClaudeCodeAdapter()) }
    func testLiveCodexManual() async throws { try await liveManual(CodexAdapter()) }

    /// A worktree of a throwaway repo in a temp directory, removed by the caller's `defer`.
    private func scratchWorktree() throws -> (root: URL, worktree: URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-agent-\(UUID().uuidString)")
        let repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        let setup = "git init -q -b main && echo scratch > README.md && git add . && git commit -qm init && git worktree add -q -b task ../wt"
        XCTAssertNotNil(AgentEnvironment.capture("/bin/sh", ["-c", setup], environment: AgentEnvironment.loginShell, directory: repo))
        return (root, root.appendingPathComponent("wt"))
    }

    private func commits(_ worktree: URL) -> Int {
        (AgentEnvironment.capture("/usr/bin/git", ["log", "--oneline"], environment: AgentEnvironment.loginShell,
                                  directory: worktree) ?? "").split(separator: "\n").count
    }

    /// One turn that answers every approval request with `allow`.
    private func liveTurn(_ adapter: AgentAdapter, _ prompt: String, session: String? = nil, worktree: URL,
                          permissions: AgentPermissions, allow: Bool = true)
        async -> (outcome: AgentEvent?, session: String?, approvals: [String]) {
        let request = AgentRequest(prompt: prompt, sessionID: session, worktree: worktree, permissions: permissions)
        var outcome: AgentEvent?, started: String?, approvals: [String] = []
        for await event in adapter.run(request) {
            switch event {
            case .sessionStarted(let id): started = id
            case .approvalRequested(let id, let summary):
                approvals.append(summary)
                print("LIVE \(adapter.kind) \(permissions) approval: \(summary) → \(allow ? "allow" : "deny")")
                request.approvals.answer(id: id, allow: allow)
            case .finished:
                XCTAssertNil(outcome, "one .finished")
                outcome = event
            default: break
            }
        }
        print("LIVE \(adapter.kind) \(permissions): \(String(describing: outcome))")
        return (outcome, started ?? session, approvals)
    }

    /// Auto: edits and commits in a worktree, reaches the network and installs a package, new and resumed.
    private func liveAuto(_ adapter: AgentAdapter) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIFT_LIVE_AGENT_TESTS"] == "1", "live agent tests are off")
        let (root, worktree) = try scratchWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        let first = await liveTurn(adapter, "Create hello.txt containing hi and commit it.", worktree: worktree, permissions: .auto)
        guard case .finished(.completed) = first.outcome else { return XCTFail("first: \(String(describing: first.outcome))") }
        XCTAssertTrue(first.approvals.isEmpty)
        XCTAssertEqual(commits(worktree), 2, "committed from the worktree")

        let second = await liveTurn(adapter, "Run `curl -sI https://example.com | head -1`, put its output in status.txt, "
                                    + "then run `npm install left-pad@1.3.0`, and commit status.txt, package.json and "
                                    + "package-lock.json (not node_modules).", session: first.session, worktree: worktree,
                                    permissions: .auto)
        guard case .finished(.completed) = second.outcome else { return XCTFail("second: \(String(describing: second.outcome))") }
        let status = try String(contentsOf: worktree.appendingPathComponent("status.txt"), encoding: .utf8)
        XCTAssertTrue(status.hasPrefix("HTTP/"), status)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("node_modules/left-pad").path))
        XCTAssertEqual(commits(worktree), 3, "resumed session committed too")
    }

    /// Manual: a shell command waits for the user; allowed it runs, denied the agent carries on without it.
    private func liveManual(_ adapter: AgentAdapter) async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIFT_LIVE_AGENT_TESTS"] == "1", "live agent tests are off")
        let (root, worktree) = try scratchWorktree()
        defer { try? FileManager.default.removeItem(at: root) }

        let allowed = await liveTurn(adapter, "Run `ls` and write the output to files.txt. Do not commit.",
                                     worktree: worktree, permissions: .manual, allow: true)
        guard case .finished(.completed) = allowed.outcome else { return XCTFail("allowed: \(String(describing: allowed.outcome))") }
        XCTAssertFalse(allowed.approvals.isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("files.txt").path))

        let denied = await liveTurn(adapter, "Now run `ls -a` and write the output to files2.txt. Do not commit.",
                                    session: allowed.session, worktree: worktree, permissions: .manual, allow: false)
        XCTAssertNotNil(denied.outcome, "the agent finished its turn")
        XCTAssertFalse(denied.approvals.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: worktree.appendingPathComponent("files2.txt").path))
    }

    func testLiveCancelKillsProcess() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SHIFT_LIVE_AGENT_TESTS"] == "1", "live agent tests are off")
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-agent-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        _ = AgentEnvironment.capture("/usr/bin/git", ["init", "-q"], environment: AgentEnvironment.loginShell, directory: root)

        let stream = ClaudeCodeAdapter().run(AgentRequest(prompt: "Run the command: sleep 120", worktree: root))
        let consumer = Task {
            for await event in stream {
                if case .activity = event { return }  // stop consuming once it is busy
            }
        }
        await consumer.value
        try await Task.sleep(for: .seconds(2))
        // Any process still running with its working directory inside the scratch repo.
        let survivors = AgentEnvironment.capture("/bin/sh", ["-c", "lsof -d cwd -Fn 2>/dev/null | grep \(root.lastPathComponent)"], environment: [:]) ?? ""
        XCTAssertEqual(survivors, "", "agent processes survived cancellation")
    }

    private func collect(_ stream: AsyncStream<AgentEvent>) async
        -> (events: [AgentEvent], sessions: [String], activities: [String], finished: [AgentEvent]) {
        var events: [AgentEvent] = [], sessions: [String] = [], activities: [String] = [], finished: [AgentEvent] = []
        for await event in stream {
            switch event {
            case .rawOutput: continue
            case .sessionStarted(let id): sessions.append(id)
            case .activity(let text): activities.append(text)
            case .described, .approvalRequested: break
            case .finished: finished.append(event)
            }
            events.append(event)
        }
        return (events, sessions, activities, finished)
    }
}
