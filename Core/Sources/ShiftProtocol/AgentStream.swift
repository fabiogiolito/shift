import Foundation

// How the agents' output reads, one line at a time. Shared by the adapters, which run the agents on the Mac,
// and the transcript parser, which also runs on the phone.

/// `OutcomeProtocol`'s instructions and parsing are the Mac's (see ShiftCore/Agents/AgentSupport.swift).
package enum OutcomeProtocol {
    package static func short(_ text: String, limit: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit - 1)) + "…"
    }

    /// The agent's error is a lost or failed connection to its API, which passes once the internet is back.
    // ponytail: matched on the CLIs' wording; an agent-written reason with these words also counts.
    /// The agent's login expired or it was signed out ("Failed to authenticate", "Not logged in · Please run /login").
    // ponytail: matched on the agents' wording.
    package static func isSignedOut(_ error: String) -> Bool {
        error.range(of: "failed to authenticate|run /login|not logged in|auth login|codex login|oauth token (has )?expired|invalid api key",
                    options: [.regularExpression, .caseInsensitive]) != nil
    }

    package static func isNetworkFailure(_ error: String) -> Bool {
        error.range(of: #"connection error|connection refused|connection reset|network|timed out|timeout|ECONN|ENOTFOUND|EAI_AGAIN|ETIMEDOUT|EHOSTUNREACH|socket hang up|fetch failed|stream disconnected|error sending request|could not resolve|offline"#,
                    options: [.regularExpression, .caseInsensitive]) != nil
    }
}

// MARK: - Stream parsing state

/// What an adapter's line parser has learned so far about the current turn.
package struct TurnState: Equatable {
    package struct Approval: Equatable {
        package var id: String
        package var summary: String
        package init(id: String, summary: String) {
            self.id = id
            self.summary = summary
        }
    }

    package init(sessionID: String? = nil) { self.sessionID = sessionID }

    package var sessionID: String?
    package var finalMessage: String?
    package var error: String?
    /// The CLI itself said the turn failed (as opposed to the agent saying it is blocked).
    package var cliFailed = false

    // Manual permissions only: the parser's side of a conversation over stdin.
    /// Approval requests found in the current line; the runner takes them.
    package var approvals: [Approval] = []
    /// Lines to write to the agent's stdin; the runner takes them.
    package var outgoing: [String] = []
    /// The turn is over: close stdin so the agent exits.
    package var closeInput = false
    /// Codex: file-change item id → the file it changes, for its approval request.
    package var files: [String: String] = [:]

    // Follow-up instructions sent into a running session (Codex app server).
    /// The turn in progress, which follow-ups steer.
    package var turnID: String?
    /// Steer requests waiting for their response: request id → the text they carry.
    package var steers: [Int: String] = [:]
    /// Follow-ups whose steer came too late for the turn; they start the next turn instead.
    package var unsteered: [String] = []
    package var nextRequestID = 100
}

package func jsonLine(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
}

/// "Run `pnpm install`": a verb and a short excerpt of code, on one line.
package func approvalSummary(_ verb: String, _ code: String) -> String {
    let line = code.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)[0]
    return "\(verb) `\(OutcomeProtocol.short(line, limit: 60))`"
}

package func jsonObject(_ line: String) -> [String: Any]? {
    guard line.first == "{", let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

package func fileName(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    return (path as NSString).lastPathComponent
}

// MARK: - Claude Code

package enum ClaudeStream {
    package static func approvalSummary(_ request: [String: Any]) -> String {
        let tool = request["tool_name"] as? String ?? "a tool"
        let input = request["input"] as? [String: Any] ?? [:]
        let description = request["description"] as? String
        switch tool {
        case "Bash":
            return ShiftProtocol.approvalSummary("Run", input["command"] as? String ?? description ?? "a command")
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            let path = description ?? fileName(input["file_path"] as? String ?? input["notebook_path"] as? String) ?? "a file"
            return ShiftProtocol.approvalSummary("Edit", path)
        case "WebFetch":
            return "Fetch \(OutcomeProtocol.short(input["url"] as? String ?? description ?? "a web page", limit: 80))"
        case "WebSearch":
            return "Search the web for “\(OutcomeProtocol.short(input["query"] as? String ?? "", limit: 60))”"
        default:
            return "Use \(request["display_name"] as? String ?? tool)"
        }
    }

    @Sendable package static func parse(line: String, state: inout TurnState) -> String? {
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

    package static func activity(tool: String, input: [String: Any]) -> String? {
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

// MARK: - Codex

package enum CodexStream {
    /// Drives the app server through one turn: initialize (1) → start or resume the thread (2) →
    /// start the turn (3) → events, approval requests and steers → `turn/completed`, then stdin closes.
    /// A follow-up that missed the turn starts one more turn before that.
    package static func parseAppServer(_ line: String, _ state: inout TurnState, prompt: String, resume: String?, cwd: String,
                               manual: Bool = true) -> String? {
        guard let message = jsonObject(line) else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let item = params["item"] as? [String: Any] ?? [:]

        guard let method = message["method"] as? String else {
            // A response to one of our requests.
            if let id = message["id"] as? Int, let text = state.steers.removeValue(forKey: id) {
                // The turn had ended: the follow-up goes into the next one.
                if message["error"] != nil { state.unsteered.append(text) }
                if state.turnID == nil { endTurn(&state) }
            } else if let error = message["error"] as? [String: Any] {
                state.cliFailed = true
                state.error = readable(error["message"] as? String) ?? "Codex refused the request."
                state.closeInput = true
            } else if message["id"] as? Int == 1 {
                state.outgoing = [jsonLine(["method": "initialized"]), jsonLine(resume.map {
                    ["id": 2, "method": "thread/resume", "params": ["threadId": $0, "cwd": cwd]]
                } ?? ["id": 2, "method": "thread/start", "params": ["cwd": cwd]])]
            } else if message["id"] as? Int == 2,
                      let thread = ((message["result"] as? [String: Any])?["thread"] as? [String: Any])?["id"] as? String {
                state.sessionID = thread
                state.outgoing = [jsonLine(["id": 3, "method": "turn/start", "params": [
                    "threadId": thread, "input": [["type": "text", "text": prompt]]]])]
            }
            return nil
        }

        if let id = message["id"] {
            // A request from the server.
            let isApproval = method == "item/commandExecution/requestApproval" || method == "item/fileChange/requestApproval"
            if isApproval && !manual {
                // Nobody is asked outside Manual: whatever would still prompt is denied.
                state.outgoing = [jsonLine(["id": id, "result": ["decision": "decline"]])]
                return nil
            }
            switch method {
            case "item/commandExecution/requestApproval":
                state.approvals.append(.init(id: "\(id)", summary: approvalSummary("Run", unwrap(params["command"] as? String ?? "a command"))))
            case "item/fileChange/requestApproval":
                let path = (params["itemId"] as? String).flatMap { state.files[$0] }
                let relative = path.map { $0.hasPrefix(cwd + "/") ? String($0.dropFirst(cwd.count + 1)) : fileName($0) ?? $0 }
                state.approvals.append(.init(id: "\(id)", summary: relative.map { approvalSummary("Edit", $0) } ?? "Edit files"))
            default:
                // Nothing else can be answered from here (questions, MCP forms); refuse rather than hang.
                state.outgoing = [jsonLine(["id": id, "error": ["code": -32601, "message": "Not supported by Shift."]])]
            }
            return nil
        }

        switch method {
        case "item/started":
            switch item["type"] as? String {
            case "commandExecution":
                guard let command = item["command"] as? String else { return nil }
                return OutcomeProtocol.short("Running \(unwrap(command))".components(separatedBy: .newlines)[0], limit: 80)
            case "fileChange":
                let path = (item["changes"] as? [[String: Any]])?.first?["path"] as? String
                if let id = item["id"] as? String, let path { state.files[id] = path }
                return "Editing \(fileName(path) ?? "files")"
            case "webSearch":
                return "Searching the web…"
            default:
                return nil
            }
        case "item/completed":
            if item["type"] as? String == "agentMessage", let text = item["text"] as? String { state.finalMessage = text }
        case "error":
            state.error = readable((params["error"] as? [String: Any])?["message"] as? String) ?? state.error
        case "turn/started":
            state.turnID = (params["turn"] as? [String: Any])?["id"] as? String
        case "turn/completed":
            let turn = params["turn"] as? [String: Any] ?? [:]
            state.turnID = nil
            state.cliFailed = turn["status"] as? String == "failed"
            if state.cliFailed {
                state.error = readable((turn["error"] as? [String: Any])?["message"] as? String) ?? state.error
            }
            endTurn(&state)
        default:
            break
        }
        return nil
    }

    /// After a turn: once no steer is waiting for its response, either start a turn with the follow-ups
    /// that missed the last one, or close stdin so the server exits.
    package static func endTurn(_ state: inout TurnState) {
        guard state.steers.isEmpty else { return }
        guard !state.unsteered.isEmpty, !state.cliFailed, let thread = state.sessionID else {
            state.closeInput = true
            return
        }
        let text = state.unsteered.joined(separator: "\n\n")
        state.unsteered = []
        state.outgoing.append(jsonLine(["id": state.nextRequestID, "method": "turn/start", "params": [
            "threadId": thread, "input": [["type": "text", "text": text]]]]))
        state.nextRequestID += 1
    }

    /// `/bin/zsh -lc 'npm test'` → `npm test`
    package static func unwrap(_ command: String) -> String {
        guard let range = command.range(of: #"^\S*sh -l?c "#, options: .regularExpression) else { return command }
        var inner = String(command[range.upperBound...])
        if inner.count >= 2, let quote = inner.first, quote == "'" || quote == "\"", inner.last == quote {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner
    }

    /// Codex wraps API errors as a JSON string; dig out the human message.
    package static func readable(_ message: String?) -> String? {
        guard let message else { return nil }
        guard let object = jsonObject(message) else { return message }
        return (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String ?? message
    }
}
