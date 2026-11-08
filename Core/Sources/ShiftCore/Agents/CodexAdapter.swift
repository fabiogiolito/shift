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
        var arguments = ["app-server"] + autonomyArguments(request.permissions, gitDirectory: gitDirectory)
        if let model = request.model, let value = try? tomlEncoder.encode(model) {
            arguments += ["-c", "model=" + String(decoding: value, as: UTF8.self)]
        }
        return arguments
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

    /// The models Codex lists in its picker, from the catalog it caches in its home directory.
    /// ponytail: empty until Codex has run once and fetched it; `model/list` over app-server if that matters.
    public func models() async -> [AgentModel] {
        let home = AgentEnvironment.loginShell["CODEX_HOME"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".codex").path
        guard let data = FileManager.default.contents(atPath: home + "/models_cache.json") else { return [] }
        return Self.models(fromCache: data)
    }

    /// `{"models": [{"slug": "gpt-6-astra", "display_name": "GPT-6-Astra", "visibility": "list", "priority": 1}, …]}`
    static func models(fromCache data: Data) -> [AgentModel] {
        let models = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["models"] as? [[String: Any]] ?? []
        return models
            .filter { $0["visibility"] as? String == "list" }
            .sorted { ($0["priority"] as? Int ?? .max) < ($1["priority"] as? Int ?? .max) }
            .compactMap { model in
                (model["slug"] as? String).map { AgentModel(id: $0, name: model["display_name"] as? String ?? $0) }
            }
    }

    public func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        let prompt = request.prompt + "\n\n" + (request.chat ? OutcomeProtocol.chatInstructions + request.chatContext
            : OutcomeProtocol.instructions(firstTurn: request.needsDescription, description: request.description,
                                           screenshots: request.screenshots, server: request.environment["SHIFT_ACCESS"] != nil,
                                           tags: request.tags))
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

    static func parseAppServer(_ line: String, _ state: inout TurnState, prompt: String, resume: String?, cwd: String,
                               manual: Bool = true) -> String? {
        CodexStream.parseAppServer(line, &state, prompt: prompt, resume: resume, cwd: cwd, manual: manual)
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

    static func unwrap(_ command: String) -> String { CodexStream.unwrap(command) }
    static func readable(_ message: String?) -> String? { CodexStream.readable(message) }
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
