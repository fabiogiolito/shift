import Foundation

public struct ClaudeCodeAdapter: AgentAdapter {
    public let kind = AgentKind.claudeCode

    public init() {}

    // MARK: Permissions — review here

    /// Bypass: every permission check is bypassed and the OS sandbox is off, whatever the user's own
    /// settings say.
    /// Auto: Claude Code's auto mode; its own classifier approves routine actions and refuses risky
    /// ones. Whatever would still prompt is denied, since nobody is asked.
    /// Manual: Claude Code's manual (default) mode; every permission prompt goes to the host, us, as a
    /// `can_use_tool` control request on stdout, answered with a `control_response` on stdin.
    static func autonomyArguments(_ permissions: AgentPermissions) -> [String] {
        switch permissions {
        case .bypass: [
            "--permission-mode", "bypassPermissions",
            "--permission-prompts", "none",
            "--settings", #"{"sandbox":{"enabled":false}}"#,
        ]
        case .auto: ["--permission-mode", "auto", "--permission-prompts", "none"]
        case .manual: [
            "--permission-mode", "manual",
            "--permission-prompts", "host", "--permission-prompt-tool", "stdio",
        ]
        }
    }

    static func arguments(for request: AgentRequest) -> [String] {
        // The prompt goes in on stdin as a user message, and stdin stays open for follow-ups: Claude Code
        // takes a user message that arrives mid-turn into that turn, and one that arrives after
        // the turn's result as a new turn before it exits.
        var arguments = ["--print", "--input-format", "stream-json", "--output-format", "stream-json", "--verbose"]
        arguments += autonomyArguments(request.permissions)
        if let model = request.model { arguments += ["--model", model] }
        arguments += ["--append-system-prompt", OutcomeProtocol.instructions(firstTurn: request.needsDescription)]
        if let sessionID = request.sessionID { arguments += ["--resume", sessionID] }
        return arguments
    }

    public func detect() async -> AgentInstallation? {
        await Task.detached { AgentEnvironment.detect(.claudeCode) }.value
    }

    /// Claude Code's aliases, which always point at the latest of each model.
    static let models = [("fable", "Fable"), ("opus", "Opus"), ("sonnet", "Sonnet"), ("haiku", "Haiku")]
        .map { AgentModel(id: $0, name: $1) }

    public func models() async -> [AgentModel] { Self.models }

    public func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        runAgentProcess(kind: kind, request: request, arguments: { Self.arguments(for: $0) },
                        stdin: Self.userMessage(request.prompt), parse: Self.parse,
                        reply: request.permissions == .manual ? Self.reply : nil, send: Self.send)
    }

    static func userMessage(_ text: String) -> String {
        jsonLine(["type": "user", "message": ["role": "user", "content": text]])
    }

    /// A follow-up goes in as another user message, as long as stdin is still open.
    @Sendable static func send(_ text: String, _ state: inout TurnState) -> String? {
        state.closeInput ? nil : userMessage(text)
    }

    // MARK: Manual permissions

    /// Answers a `can_use_tool` control request. A denial's message is what the agent reads instead of
    /// the tool's result, so the user's own words can go with it.
    @Sendable static func reply(to line: String, allow: Bool, message: String?) -> (line: String, deliveredMessage: Bool) {
        let event = jsonObject(line) ?? [:]
        let input = (event["request"] as? [String: Any])?["input"] as? [String: Any] ?? [:]
        let decision: [String: Any] = allow
            ? ["behavior": "allow", "updatedInput": input]
            : ["behavior": "deny", "message": message.map { "The user denied this and said instead: \($0)" }
                ?? "The user denied this action."]
        let response: [String: Any] = ["type": "control_response", "response": [
            "subtype": "success", "request_id": event["request_id"] as? String ?? "", "response": decision]]
        return (jsonLine(response), !allow && message != nil)
    }

    static func approvalSummary(_ request: [String: Any]) -> String {
        let tool = request["tool_name"] as? String ?? "a tool"
        let input = request["input"] as? [String: Any] ?? [:]
        let description = request["description"] as? String
        switch tool {
        case "Bash":
            return ShiftCore.approvalSummary("Run", input["command"] as? String ?? description ?? "a command")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = description ?? fileName(input["file_path"] as? String ?? input["notebook_path"] as? String) ?? "a file"
            return ShiftCore.approvalSummary("Edit", path)
        case "WebFetch":
            return "Fetch \(OutcomeProtocol.short(input["url"] as? String ?? description ?? "a web page", limit: 80))"
        case "WebSearch":
            return "Search the web for “\(OutcomeProtocol.short(input["query"] as? String ?? "", limit: 60))”"
        default:
            return "Use \(request["display_name"] as? String ?? tool)"
        }
    }

    // MARK: Stream parsing

    @Sendable static func parse(line: String, state: inout TurnState) -> String? {
        guard let event = jsonObject(line) else { return nil }
        if let id = event["session_id"] as? String, !id.isEmpty { state.sessionID = id }

        switch event["type"] as? String {
        case "assistant":
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            var activity: String?
            for block in content {
                if block["type"] as? String == "text", let text = block["text"] as? String,
                   event["parent_tool_use_id"] is NSNull || event["parent_tool_use_id"] == nil {
                    state.finalMessage = text
                } else if block["type"] as? String == "tool_use", let name = block["name"] as? String {
                    activity = Self.activity(tool: name, input: block["input"] as? [String: Any] ?? [:]) ?? activity
                }
            }
            return activity
        case "control_request":
            let request = event["request"] as? [String: Any] ?? [:]
            if let id = event["request_id"] as? String, request["subtype"] as? String == "can_use_tool" {
                state.approvals.append(.init(id: id, summary: approvalSummary(request)))
            }
            return nil
        case "result":
            // The turn is over. Claude Code exits once its stdin closes, after answering whatever
            // follow-up was already written to it (another turn, whose result then counts).
            state.closeInput = true
            if let result = event["result"] as? String, !result.isEmpty { state.finalMessage = result }
            state.cliFailed = event["is_error"] as? Bool == true
            state.error = nil
            if state.cliFailed {
                state.error = (event["errors"] as? [String])?.first ?? event["result"] as? String
                    ?? "Claude Code reported an error (\(event["subtype"] as? String ?? "unknown"))."
            }
            return nil
        default:
            return nil
        }
    }

    static func activity(tool: String, input: [String: Any]) -> String? {
        switch tool {
        case "Edit", "Write", "NotebookEdit":
            return "Editing \(fileName(input["file_path"] as? String ?? input["notebook_path"] as? String) ?? "files")"
        case "Read":
            return "Reading \(fileName(input["file_path"] as? String) ?? "files")"
        case "Bash":
            let text = input["description"] as? String ?? (input["command"] as? String).map { "Running \($0)" }
            return text.map { OutcomeProtocol.short($0.components(separatedBy: .newlines)[0], limit: 80) }
        case "Grep", "Glob":
            return "Searching the code…"
        case "WebFetch", "WebSearch":
            return "Searching the web…"
        default:
            return nil
        }
    }
}

// MARK: - Usage

extension ClaudeCodeAdapter {
    /// What `/usage` shows: Claude Code's OAuth token, from the Keychain item it keeps it in, read
    /// through `security` (the item trusts it, so there is no prompt), sent to the usage endpoint.
    /// An expired token is left for Claude Code to refresh.
    public func usage() async -> AgentUsage? {
        guard let credentials = AgentEnvironment.capture(
                  "/usr/bin/security", ["find-generic-password", "-s", "Claude Code-credentials", "-w"],
                  environment: [:], timeout: 5),
              let oauth = jsonObject(credentials)?["claudeAiOauth"] as? [String: Any],
              let token = oauth["accessToken"] as? String else { return nil }
        var request = URLRequest(url: URL(string: "https://api.anthropic.com/api/oauth/usage")!)
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.usage(from: data)
    }

    /// `{"five_hour": {"utilization": 6.0, "resets_at": "2026-09-28T18:10:00.229627+00:00"}, "seven_day": …}`
    static func usage(from data: Data) -> AgentUsage? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let windows = [("five_hour", "5-hour"), ("seven_day", "Weekly")].compactMap { key, name -> AgentUsage.Window? in
            guard let window = object[key] as? [String: Any],
                  let used = window["utilization"] as? Double else { return nil }
            return .init(name: name, usedPercent: used, resetsAt: (window["resets_at"] as? String).flatMap(isoDate))
        }
        return windows.isEmpty ? nil : AgentUsage(windows: windows)
    }

    private static func isoDate(_ string: String) -> Date? {
        (try? Date.ISO8601FormatStyle(includingFractionalSeconds: true).parse(string))
            ?? (try? Date.ISO8601FormatStyle().parse(string))
    }
}
