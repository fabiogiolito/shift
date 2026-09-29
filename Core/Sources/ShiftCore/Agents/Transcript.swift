import Foundation

/// An agent's raw log as a person reads it: what it said, what it did, what failed.
/// Reuses the adapters' own stream parsing, one line at a time. Lines that aren't the agent's JSON
/// (setup commands, stderr) are kept as they are.
enum Transcript {
    static func readable(_ log: String, agent: AgentKind) -> String {
        // ponytail: earlier builds logged lines without a newline; `}{"` splits them, rarely also inside a string.
        let lines = log.replacingOccurrences(of: "}{\"", with: "}\n{\"").components(separatedBy: .newlines)
        var out: [String] = []
        var lastText: String?
        for line in lines where !line.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let event = jsonObject(line) else {
                out.append(line)
                continue
            }
            var state = TurnState()
            let activity = switch agent {
            case .claudeCode: ClaudeCodeAdapter.parse(line: line, state: &state)
            case .codex: CodexAdapter.parseAppServer(line, &state, prompt: "", resume: nil, cwd: "")
            }
            if let text = state.finalMessage.map(withoutProtocol), !text.isEmpty, text != lastText {
                out.append("\n\(text)\n")
                lastText = text
            }
            if let activity { out.append("→ \(activity)") }
            out += state.approvals.map { "? Asks to \($0.summary)" }
            if let error = state.error ?? toolError(event) { out.append("✗ \(OutcomeProtocol.short(error, limit: 200))") }
            if event["type"] as? String == "result" || event["method"] as? String == "turn/completed" {
                out.append("\n——— Turn finished\n")
            }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Claude Code: a tool call that failed, first line of its output.
    private static func toolError(_ event: [String: Any]) -> String? {
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        guard let result = content.first(where: { $0["type"] as? String == "tool_result" && $0["is_error"] as? Bool == true })
        else { return nil }
        return (result["content"] as? String)?.components(separatedBy: .newlines).first ?? "A tool failed"
    }

    /// Drops the SHIFT_… handoff lines, which Shift shows elsewhere.
    private static func withoutProtocol(_ text: String) -> String {
        text.components(separatedBy: .newlines).filter { !$0.hasPrefix("SHIFT_") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
