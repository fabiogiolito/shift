import Foundation

public struct CodexAdapter: AgentAdapter {
    public let kind = AgentKind.codex

    public init() {}

    // MARK: Permissions — review here

    /// Every run goes through `codex app-server` (JSON-RPC over stdin/stdout), because only it can take
    /// follow-up instructions into a running turn (`turn/steer`). Permissions are `-c` config overrides:
    /// Bypass: no approvals and no sandbox.
    /// Auto: what `--approve-for-me` sets ("route approval requests through automatic review using the
    /// workspace-write sandbox"): commands run in the OS sandbox (writes only to the worktree and temp
    /// directories, no network); anything beyond that is escalated to Codex's auto-review agent, which
    /// approves or refuses it. Whatever still reaches us is declined.
    /// `gitDirectory` is the repository's shared .git directory: a worktree keeps its index and
    /// refs there, outside the worktree itself, so commits do not each need an escalation.
    /// Manual: Codex's read-only preset (the sandbox allows reading only; editing files, other commands
    /// and the network need approval), with approval requests routed to the user over JSON-RPC.
    static func autonomyArguments(_ permissions: AgentPermissions, gitDirectory: String?) -> [String] {
        switch permissions {
        case .bypass:
            return ["-c", #"approval_policy="never""#, "-c", #"sandbox_mode="danger-full-access""#]
        case .auto:
            var arguments = ["-c", #"approval_policy="on-request""#, "-c", #"approvals_reviewer="auto_review""#,
                             "-c", #"sandbox_mode="workspace-write""#]
            if let gitDirectory, let roots = try? tomlEncoder.encode([gitDirectory]) {
                arguments += ["-c", "sandbox_workspace_write.writable_roots=" + String(decoding: roots, as: UTF8.self)]
            }
            return arguments
        case .manual:
            return ["-c", #"approval_policy="on-request""#, "-c", #"approvals_reviewer="user""#,
                    "-c", #"sandbox_mode="read-only""#]
        }
    }

    /// A JSON array of strings is also a valid TOML array, as long as "/" is not escaped.
    private static let tomlEncoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = .withoutEscapingSlashes
        return encoder
    }()

    /// The app server takes the session and the prompt over stdin.
    static func arguments(for request: AgentRequest, gitDirectory: String?) -> [String] {
        ["app-server"] + autonomyArguments(request.permissions, gitDirectory: gitDirectory)
    }

    static func gitCommonDirectory(of worktree: URL) -> String? {
        guard let output = AgentEnvironment.capture("/usr/bin/env", ["git", "rev-parse", "--git-common-dir"],
                                                    environment: AgentEnvironment.loginShell, directory: worktree)
        else { return nil }
        let path = output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path, relativeTo: worktree).resolvingSymlinksInPath().path
    }

    public func detect() async -> AgentInstallation? {
        await Task.detached { AgentEnvironment.detect(.codex) }.value
    }

    public func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        let prompt = request.prompt + "\n\n" + OutcomeProtocol.instructions(firstTurn: request.needsDescription)
        let session = request.sessionID, cwd = request.worktree.path, manual = request.permissions == .manual
        return runAgentProcess(kind: kind, request: request,
                               arguments: {
                                   // Only the sandbox needs to be told about the shared .git directory.
                                   Self.arguments(for: $0, gitDirectory: $0.permissions == .auto
                                       ? Self.gitCommonDirectory(of: $0.worktree) : nil)
                               },
                               stdin: Self.initialize,
                               parse: { Self.parseAppServer($0, &$1, prompt: prompt, resume: session, cwd: cwd, manual: manual) },
                               reply: Self.reply, send: Self.send)
    }

    // MARK: `codex app-server` (JSON-RPC, one message per line)

    static let initialize = jsonLine(["id": 1, "method": "initialize", "params": ["clientInfo": ["name": "shift", "version": "1"]]])

    /// Drives the app server through one turn: initialize (1) → start or resume the thread (2) →
    /// start the turn (3) → events, approval requests and steers → `turn/completed`, then stdin closes.
    /// A follow-up that missed the turn starts one more turn before that.
    static func parseAppServer(_ line: String, _ state: inout TurnState, prompt: String, resume: String?, cwd: String,
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
    static func endTurn(_ state: inout TurnState) {
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

    /// A follow-up steers the turn in progress. nil when there is none (not started yet, or over).
    @Sendable static func send(_ text: String, _ state: inout TurnState) -> String? {
        guard let turn = state.turnID, let thread = state.sessionID, !state.closeInput else { return nil }
        let id = state.nextRequestID
        state.nextRequestID += 1
        state.steers[id] = text
        return jsonLine(["id": id, "method": "turn/steer", "params": [
            "threadId": thread, "expectedTurnId": turn, "input": [["type": "text", "text": text]]]])
    }

    /// Answers an approval request. Codex takes no message with a denial.
    @Sendable static func reply(to line: String, allow: Bool, message: String?) -> (line: String, deliveredMessage: Bool) {
        let id = jsonObject(line)?["id"] ?? NSNull()
        return (jsonLine(["id": id, "result": ["decision": allow ? "accept" : "decline"]]), false)
    }

    /// `/bin/zsh -lc 'npm test'` → `npm test`
    static func unwrap(_ command: String) -> String {
        guard let range = command.range(of: #"^\S*sh -l?c "#, options: .regularExpression) else { return command }
        var inner = String(command[range.upperBound...])
        if inner.count >= 2, let quote = inner.first, quote == "'" || quote == "\"", inner.last == quote {
            inner = String(inner.dropFirst().dropLast())
        }
        return inner
    }

    /// Codex wraps API errors as a JSON string; dig out the human message.
    static func readable(_ message: String?) -> String? {
        guard let message else { return nil }
        guard let object = jsonObject(message) else { return message }
        return (object["error"] as? [String: Any])?["message"] as? String ?? object["message"] as? String ?? message
    }
}

// MARK: - Usage

extension CodexAdapter {
    /// Codex logs its rate limits into the session file after every turn; the latest one is current,
    /// since only Codex spends them.
    public func usage() async -> AgentUsage? {
        let home = AgentEnvironment.loginShell["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        let sessions = URL(fileURLWithPath: home).appendingPathComponent("sessions")
        guard let files = FileManager.default.enumerator(at: sessions, includingPropertiesForKeys: [.contentModificationDateKey])?
            .compactMap({ $0 as? URL }).filter({ $0.pathExtension == "jsonl" }) else { return nil }
        func modified(_ url: URL) -> Date {
            (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        }
        // A session that just started has no turn logged yet.
        for file in files.sorted(by: { modified($0) > modified($1) }).prefix(5) {
            if let usage = Self.usage(fromLog: Self.tail(of: file)) { return usage }
        }
        return nil
    }

    /// `{"payload": {"type": "token_count", "rate_limits": {"primary": {"used_percent": 42.0,
    /// "window_minutes": 300, "resets_at": 1790553456}, "secondary": …}}}`, the last one in the log.
    static func usage(fromLog log: String) -> AgentUsage? {
        for line in log.split(separator: "\n").reversed() where line.contains("\"rate_limits\"") {
            guard let limits = (jsonObject(String(line))?["payload"] as? [String: Any])?["rate_limits"] as? [String: Any]
            else { continue }
            let windows = ["primary", "secondary"].compactMap { key -> AgentUsage.Window? in
                guard let window = limits[key] as? [String: Any],
                      let used = (window["used_percent"] as? NSNumber)?.doubleValue else { return nil }
                let minutes = (window["window_minutes"] as? NSNumber)?.intValue ?? 0
                let name = minutes == 10080 ? "Weekly" : minutes > 0 && minutes % 60 == 0 ? "\(minutes / 60)-hour" : "Current"
                let resetsAt = (window["resets_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
                return .init(name: name, usedPercent: used, resetsAt: resetsAt)
            }
            if !windows.isEmpty { return AgentUsage(windows: windows) }
        }
        return nil
    }

    /// The end of a session log, which can grow large.
    private static func tail(of file: URL, bytes: UInt64 = 256 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: file) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > bytes ? size - bytes : 0)
        return String(decoding: handle.readDataToEndOfFile(), as: UTF8.self)
    }
}
