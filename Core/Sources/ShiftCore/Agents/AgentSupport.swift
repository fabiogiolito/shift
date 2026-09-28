import Foundation

// Shared by ClaudeCodeAdapter and CodexAdapter: outcome protocol, login-shell
// environment, executable detection, and the process runner.

// MARK: - Outcome protocol

enum OutcomeProtocol {
    static let marker = "SHIFT_STATUS:"
    static let titleMarker = "SHIFT_TITLE:"
    static let descriptionMarker = "SHIFT_DESCRIPTION:"
    static let optionMarker = "SHIFT_OPTION:"

    /// Appended to every prompt (Codex) or to the system prompt (Claude Code).
    /// `firstTurn`: the task has no title or description of its own yet (new, or created before agents wrote them).
    static func instructions(firstTurn: Bool) -> String {
        outcome + "\n\n" + (firstTurn ? describeFirst : describeAgain) + "\n\n" + describeRules
    }

    static let describeFirst = """
    Before doing any work, start your first message with these two lines, each on a line of its own. \
    If there were earlier messages in this conversation, describe the whole task, not only this message:

    SHIFT_TITLE: <title>
    SHIFT_DESCRIPTION: <description>
    """

    static let describeAgain = """
    This task already has a title and a description. Only if this message changes what the task is meant \
    to accomplish, start your first message with these two lines, each on a line of its own; otherwise \
    do not write them at all:

    SHIFT_TITLE: <title>
    SHIFT_DESCRIPTION: <description>
    """

    static let describeRules = """
    The title says what the task will accomplish, written like a changelog entry: at most about six \
    words, sentence case, no trailing punctuation, for example "Marketing homepage with separate ordering \
    page". Name the outcome, not the problem, and do not reuse the user's wording.
    The description is one or two plain sentences on what you are going to do and why, from the user's \
    point of view. It is not a restatement of the prompt and not a list of steps.
    """

    static let outcome = """
    You are running unattended inside a task-management app. Nobody can answer questions while you \
    work. Only ask a question when you truly cannot proceed without a decision from the user. When the work is done, commit it with git. \
    Your turn ending means the task is finished: never end it while a command or subagent you started is still running in the background; \
    wait for it and use its result first. The app runs the project's dev server itself, so do not start one.

    End your final message with exactly one of these blocks, as the last thing you write:

    SHIFT_STATUS: completed
    <1-3 sentence handoff note: what changed, in plain language. Not a narrative of what you analysed.>

    SHIFT_STATUS: needs_input
    <the one question the user must answer>

    SHIFT_STATUS: blocked
    <what prevented completion, one or two sentences>

    After the needs_input or blocked text you may add up to 4 suggested replies, one per line:

    SHIFT_OPTION: <reply>

    Each is a complete reply the user could send as-is: an instruction to you in the user's voice, at most \
    about 60 characters, such as "Copy .env from the main repo in the setup command" or "Only when there \
    are no results". Most likely first, no two alike. For a question, the realistic answers; for a block, \
    concrete ways forward you could carry out or the user could choose (not "Open Terminal"). Leave them \
    out if there are no sensible ones. Never add them after completed.
    """

    /// - Parameters:
    ///   - finalMessage: the agent's last message, if any.
    ///   - exitCode: process exit status (non-zero also covers crashes and signals).
    ///   - error: an error reported by the CLI itself (auth, rate limit, API error) or stderr.
    ///   - cliFailed: true if the CLI reported the turn as failed in its own output.
    static func parse(finalMessage: String?, exitCode: Int32, error: String? = nil, cliFailed: Bool = false) -> AgentOutcome {
        let (rest, options) = extractingOptions(strippingDescribed(finalMessage ?? ""))
        let message = rest.trimmingCharacters(in: .whitespacesAndNewlines)
        if !cliFailed, let range = message.range(of: marker, options: .backwards) {
            let lines = message[range.upperBound...].split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            let status = lines.first.map { $0.trimmingCharacters(in: .whitespaces).lowercased() } ?? ""
            let after = lines.count > 1 ? String(lines[1]) : ""
            let before = String(message[..<range.lowerBound])
            let text = short(after.isEmpty || short(after).isEmpty ? before : after)
            switch status {
            case "completed": return .completed(summary: text)
            case "needs_input": return .needsInput(question: text, options: options)
            case "blocked": return .blocked(reason: text, options: options)
            default: break
            }
        }
        if exitCode == 0 && !cliFailed {
            return .completed(summary: message.isEmpty ? "Done." : short(message))
        }
        let reason = short(error ?? "")
        return .blocked(reason: reason.isEmpty ? "The agent stopped unexpectedly (exit code \(exitCode))." : reason)
    }

    /// The title and description the agent gave in `message`, wherever in it they are.
    static func described(in message: String) -> (title: String?, description: String?) {
        func value(_ marker: String, limit: Int) -> String? {
            guard let range = message.range(of: marker) else { return nil }
            let line = String(message[range.upperBound...].prefix { !$0.isNewline })
            let value = line.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*_`")))
            return value.isEmpty ? nil : short(value, limit: limit)
        }
        return (value(titleMarker, limit: 80), value(descriptionMarker, limit: 400))
    }

    /// `message` without its `SHIFT_OPTION:` lines, and the replies they offer: trimmed of markdown
    /// and quotes, no empties or duplicates, at most 4 of at most 80 characters.
    static func extractingOptions(_ message: String) -> (message: String, options: [String]) {
        var kept: [String] = [], options: [String] = []
        for line in message.components(separatedBy: "\n") {
            guard let range = line.range(of: optionMarker) else { kept.append(line); continue }
            var option = line[range.upperBound...].trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*_`")))
            if option.count > 1, let first = option.first, "\"'“".contains(first), let last = option.last, "\"'”".contains(last) {
                option = String(option.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
            }
            option = short(option, limit: 80)
            if !option.isEmpty, options.count < 4, !options.contains(where: { $0.caseInsensitiveCompare(option) == .orderedSame }) {
                options.append(option)
            }
        }
        return (kept.joined(separator: "\n"), options)
    }

    /// `message` without the title and description lines, which are not for the user to read.
    static func strippingDescribed(_ message: String) -> String {
        message.components(separatedBy: "\n")
            .filter { !$0.contains(titleMarker) && !$0.contains(descriptionMarker) }
            .joined(separator: "\n")
    }

    static func short(_ text: String, limit: Int = 400) -> String {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.count <= limit ? trimmed : String(trimmed.prefix(limit - 1)) + "…"
    }
}

// MARK: - Stream parsing state

/// What an adapter's line parser has learned so far about the current turn.
struct TurnState: Equatable {
    struct Approval: Equatable {
        var id: String
        var summary: String
    }

    var sessionID: String?
    var finalMessage: String?
    var error: String?
    /// The CLI itself said the turn failed (as opposed to the agent saying it is blocked).
    var cliFailed = false

    // Manual permissions only: the parser's side of a conversation over stdin.
    /// Approval requests found in the current line; the runner takes them.
    var approvals: [Approval] = []
    /// Lines to write to the agent's stdin; the runner takes them.
    var outgoing: [String] = []
    /// The turn is over: close stdin so the agent exits.
    var closeInput = false
    /// Codex: file-change item id → the file it changes, for its approval request.
    var files: [String: String] = [:]

    // Follow-up instructions sent into a running session (Codex app server).
    /// The turn in progress, which follow-ups steer.
    var turnID: String?
    /// Steer requests waiting for their response: request id → the text they carry.
    var steers: [Int: String] = [:]
    /// Follow-ups whose steer came too late for the turn; they start the next turn instead.
    var unsteered: [String] = []
    var nextRequestID = 100
}

/// Parses one line of stdout. Returns a short activity line if the event deserves one.
typealias LineParser = @Sendable (_ line: String, _ state: inout TurnState) -> String?

/// Follow-up instructions: the stdin line that hands `text` to the running agent, or nil if it cannot
/// take it now. Called under the same lock as the parser.
typealias MessageSender = @Sendable (_ text: String, _ state: inout TurnState) -> String?

/// Manual permissions: the stdin line that answers the approval request that arrived as `request`
/// (a whole stdout line), and whether `message` went with it.
typealias ApprovalReply = @Sendable (_ request: String, _ allow: Bool, _ message: String?) -> (line: String, deliveredMessage: Bool)

func jsonLine(_ object: Any) -> String {
    let data = (try? JSONSerialization.data(withJSONObject: object, options: [.withoutEscapingSlashes, .sortedKeys])) ?? Data()
    return String(decoding: data, as: UTF8.self) + "\n"
}

/// "Run `pnpm install`": a verb and a short excerpt of code, on one line.
func approvalSummary(_ verb: String, _ code: String) -> String {
    let line = code.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)[0]
    return "\(verb) `\(OutcomeProtocol.short(line, limit: 60))`"
}

func jsonObject(_ line: String) -> [String: Any]? {
    guard line.first == "{", let data = line.data(using: .utf8) else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
}

func fileName(_ path: String?) -> String? {
    guard let path, !path.isEmpty else { return nil }
    return (path as NSString).lastPathComponent
}

// MARK: - Environment and detection

enum AgentEnvironment {
    static let fallbackDirectories = [
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin").path,
        "/opt/homebrew/bin",
        "/usr/local/bin",
    ]

    /// The user's login-shell environment. A GUI app does not inherit it. Resolved once.
    static let loginShell: [String: String] = {
        var env = ProcessInfo.processInfo.environment
        let shell = env["SHELL"] ?? "/bin/zsh"
        let marker = "__SHIFT_ENV__"
        if let output = capture(shell, ["-lc", "echo \(marker); /usr/bin/env -0"], environment: env),
           let start = output.range(of: marker + "\n") {
            for entry in output[start.upperBound...].split(separator: "\0") {
                let pair = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
                if pair.count == 2 { env[String(pair[0])] = String(pair[1]) }
            }
        }
        var path = (env["PATH"] ?? "/usr/bin:/bin").split(separator: ":").map(String.init)
        path += fallbackDirectories.filter { !path.contains($0) }
        env["PATH"] = path.joined(separator: ":")
        return env
    }()

    static func detect(_ kind: AgentKind) -> AgentInstallation? {
        let name = kind.executableName
        let shell = loginShell["SHELL"] ?? "/bin/zsh"
        var candidates = fallbackDirectories.map { $0 + "/" + name }
        if let found = capture(shell, ["-lc", "command -v \(name)"], environment: loginShell)?
            .split(separator: "\n").last.map(String.init), found.hasPrefix("/") {
            candidates.insert(found, at: 0)
        }
        guard let path = candidates.first(where: FileManager.default.isExecutableFile(atPath:)) else { return nil }
        let output = capture(path, ["--version"], environment: loginShell) ?? ""
        let version = output.range(of: #"\d+(\.\d+)+"#, options: .regularExpression).map { String(output[$0]) }
        return AgentInstallation(path: path, version: version)
    }

    /// Runs a short helper command and returns its stdout. nil if it could not be started.
    /// Killed after `timeout`: a login shell that waits for input must not hang the app's launch.
    static func capture(_ executable: String, _ arguments: [String], environment: [String: String],
                        directory: URL? = nil, timeout: TimeInterval = 15) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        process.currentDirectoryURL = directory
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        // ponytail: SIGKILL of the process itself; a grandchild that keeps the pipe open would still block the read.
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout) {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}

// MARK: - Process runner

/// Launches the agent CLI in its own process group and turns its output into events.
/// `arguments` is called off the main thread.
/// Without `reply` or `send`, stdin gets `stdin` and is closed. With either, stdin stays open for the
/// parser's `outgoing` lines, the answers to approval requests and follow-up instructions, until the
/// parser sets `closeInput` or the process exits.
func runAgentProcess(kind: AgentKind, request: AgentRequest,
                     arguments: @escaping @Sendable (AgentRequest) -> [String],
                     stdin: String, parse: @escaping LineParser,
                     reply: ApprovalReply? = nil, send: MessageSender? = nil) -> AsyncStream<AgentEvent> {
    AsyncStream { continuation in
        let control = RunControl()
        continuation.onTermination = { _ in control.cancel() }

        Thread.detachNewThread {
            func finish(_ outcome: AgentOutcome) {
                continuation.yield(.finished(outcome))
                continuation.finish()
            }
            guard let installation = AgentEnvironment.detect(kind) else {
                return finish(.blocked(reason: "\(kind.displayName) is not installed (could not find `\(kind.executableName)`)."))
            }
            let environment = AgentEnvironment.loginShell.merging(request.environment) { _, new in new }
            let input = Pipe(), output = Pipe(), errors = Pipe()
            guard let pid = spawn(installation.path, arguments(request), environment: environment,
                                  directory: request.worktree, stdin: input, stdout: output, stderr: errors) else {
                return finish(.blocked(reason: "Could not start \(kind.displayName)."))
            }
            guard control.started(pid) else {
                kill(-pid, SIGKILL)
                waitpid(pid, nil, 0)
                return finish(.blocked(reason: "Stopped."))
            }

            // The process may exit without reading its input; never crash on SIGPIPE.
            signal(SIGPIPE, SIG_IGN)
            let writer = Writer(input.fileHandleForWriting)
            writer.write(stdin)
            if reply == nil && send == nil { writer.close() }

            let lock = NSLock()
            let turn = Box(TurnState(sessionID: request.sessionID))

            // Approval requests waiting for an answer: id → the line they arrived in.
            let pending = Pending()
            if let reply {
                request.approvals.onAnswer { id, allow, message in
                    guard let line = pending.lock.withLock({ pending.lines.removeValue(forKey: id) }) else { return false }
                    let answer = reply(line, allow, message)
                    return writer.write(answer.line) && answer.deliveredMessage
                }
            }
            if let send {
                request.approvals.onMessage { text in
                    // nil: the turn is over or not started; the orchestrator tries again or runs it next.
                    guard let line = lock.withLock({ send(text, &turn.value) }) else { return false }
                    return writer.write(line)
                }
            }
            defer {
                request.approvals.onAnswer(nil)
                request.approvals.onMessage(nil)
            }

            // Reap the process. Once the agent is gone its children go too, which also
            // guarantees the pipes reach end-of-file.
            let exit = DispatchSemaphore(value: 0)
            let status = Status()
            Thread.detachNewThread {
                var raw: Int32 = 0
                while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
                control.markExited()
                writer.close()
                kill(-pid, SIGTERM)
                status.value = raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f)
                exit.signal()
            }

            var lastErrorLine: String?
            let errorsDone = DispatchSemaphore(value: 0)
            Thread.detachNewThread {
                readLines(errors.fileHandleForReading) { line in
                    continuation.yield(.rawOutput(line))
                    lock.withLock { lastErrorLine = line }
                }
                errorsDone.signal()
            }
            readLines(output.fileHandleForReading) { line in
                continuation.yield(.rawOutput(line))
                let (activity, newSession, message, approvals, outgoing, close):
                    (String?, String?, String?, [TurnState.Approval], [String], Bool) = lock.withLock {
                    let before = turn.value
                    let activity = parse(line, &turn.value)
                    defer { turn.value.approvals = []; turn.value.outgoing = [] }
                    return (activity, turn.value.sessionID != before.sessionID ? turn.value.sessionID : nil,
                            turn.value.finalMessage != before.finalMessage ? turn.value.finalMessage : nil,
                            turn.value.approvals, turn.value.outgoing, turn.value.closeInput)
                }
                outgoing.forEach { writer.write($0) }
                if close { writer.close() }
                if let newSession { continuation.yield(.sessionStarted(id: newSession)) }
                for approval in approvals where reply != nil {
                    pending.lock.withLock { pending.lines[approval.id] = line }
                    continuation.yield(.approvalRequested(id: approval.id, summary: approval.summary))
                }
                if let message {
                    let (title, description) = OutcomeProtocol.described(in: message)
                    if title != nil || description != nil {
                        continuation.yield(.described(title: title, description: description))
                    }
                }
                if let activity { continuation.yield(.activity(activity)) }
            }
            errorsDone.wait()
            exit.wait()

            finish(OutcomeProtocol.parse(finalMessage: turn.value.finalMessage, exitCode: status.value,
                                         error: turn.value.error ?? lastErrorLine, cliFailed: turn.value.cliFailed))
        }
    }
}

private final class Box<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

private final class Status: @unchecked Sendable { var value: Int32 = 0 }

private final class Pending: @unchecked Sendable {
    let lock = NSLock()
    var lines: [String: String] = [:]
}

/// The agent's stdin, written from several threads. Writes after `close` are dropped.
private final class Writer: @unchecked Sendable {
    private let lock = NSLock()
    private var handle: FileHandle?

    init(_ handle: FileHandle) { self.handle = handle }

    @discardableResult
    func write(_ text: String) -> Bool {
        lock.withLock {
            guard let handle, !text.isEmpty else { return false }
            return (try? handle.write(contentsOf: Data(text.utf8))) != nil
        }
    }

    func close() {
        lock.withLock {
            try? handle?.close()
            handle = nil
        }
    }
}

private func readLines(_ handle: FileHandle, _ body: (String) -> Void) {
    var buffer = Data()
    while true {
        let chunk = handle.availableData
        if chunk.isEmpty { break }
        buffer.append(chunk)
        while let newline = buffer.firstIndex(of: 0x0A) {
            let line = String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self)
            buffer.removeSubrange(buffer.startIndex...newline)
            if !line.isEmpty { body(line) }
        }
    }
    if !buffer.isEmpty { body(String(decoding: buffer, as: UTF8.self)) }
}

private func spawn(_ executable: String, _ arguments: [String], environment: [String: String],
                   directory: URL, stdin: Pipe, stdout: Pipe, stderr: Pipe) -> pid_t? {
    let pid = try? spawnProcessGroup(executable, arguments, environment: environment, directory: directory) {
        posix_spawn_file_actions_adddup2(&$0, stdin.fileHandleForReading.fileDescriptor, 0)
        posix_spawn_file_actions_adddup2(&$0, stdout.fileHandleForWriting.fileDescriptor, 1)
        posix_spawn_file_actions_adddup2(&$0, stderr.fileHandleForWriting.fileDescriptor, 2)
    }
    // Close the parent's copies of the child's ends, or the pipes never reach end-of-file.
    try? stdin.fileHandleForReading.close()
    try? stdout.fileHandleForWriting.close()
    try? stderr.fileHandleForWriting.close()
    return pid
}
