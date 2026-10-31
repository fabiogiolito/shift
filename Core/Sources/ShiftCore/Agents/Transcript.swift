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
            if event["type"] as? String == RunMarker.type { continue }
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

    /// Drops the SHIFT_… handoff lines, which Shift shows elsewhere. Agents sometimes wrap them in markdown.
    static func withoutProtocol(_ text: String) -> String {
        text.components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: "*_`"))).hasPrefix("SHIFT_") }
            .joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Run markers

/// The line Shift writes to an agent's log when prompts reach the agent, which is what ties prompts to
/// what the agent did. The agents' `result` events can't: interrupted runs never emit one, and a prompt
/// can arrive mid-run. Logs from before markers existed have none.
enum RunMarker {
    static let type = "shift_run"

    /// `text`: Shift's own instructions, for a run no `Prompt` stands for ("Continue the task.").
    /// `note`: something to tell the user at this point in the conversation.
    static func line(agent: AgentKind, promptIDs: [Prompt.ID], text: String? = nil, note: String? = nil) -> String {
        var marker: [String: Any] = ["type": type, "agent": agent.rawValue, "prompts": promptIDs.map(\.uuidString)]
        marker["text"] = text
        marker["note"] = note
        return jsonLine(marker)
    }
}

// MARK: - Conversation

/// One tool call: a command, a file read, an edit…
public struct TranscriptStep: Identifiable, Hashable, Sendable {
    public enum Kind: Hashable, Sendable { case command, read, edit, search, web, agent, other }

    /// The agent's own id for the call.
    public var id: String
    public var kind: Kind
    /// One short line, e.g. "Read Models.swift".
    public var title: String
    /// What exactly it did, e.g. the whole command.
    public var detail: String?
    /// The start of its output. The rest stays in the log: `TranscriptReader.fullOutput(of:)`.
    public var preview = ""
    public var isTruncated = false
    /// The failure, in one line. nil if it succeeded or is still running.
    public var failure: String?
    /// Where its output is in the log, in bytes.
    var outputRange: Range<UInt64>?

    /// Say "Ran 6 commands, read 2 files" for these steps.
    public static func summary(_ steps: [TranscriptStep]) -> String {
        func count(_ kind: Kind) -> Int { steps.filter { $0.kind == kind }.count }
        func phrase(_ kind: Kind, _ verb: String, _ noun: String, _ plural: String? = nil) -> String? {
            let n = count(kind)
            return n == 0 ? nil : "\(verb) \(n) \(n == 1 ? noun : plural ?? noun + "s")"
        }
        let phrases = [phrase(.command, "ran", "command"), phrase(.read, "read", "file"), phrase(.edit, "edited", "file"),
                       phrase(.search, "ran", "search", "searches"), phrase(.web, "fetched", "page"),
                       phrase(.agent, "ran", "subagent"), phrase(.other, "used", "tool")].compactMap { $0 }
        let text = phrases.joined(separator: ", ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }
}

public enum TranscriptBlock: Hashable, Sendable {
    case message(String)
    case step(TranscriptStep)
    case error(String)
    /// The agent asks to do this, e.g. "Run `pnpm install`".
    case approval(String)
}

/// What the agent did, as a person reads it: its messages in full and consecutive steps as one group.
public enum TranscriptSection: Identifiable, Hashable, Sendable {
    case message(id: Int, String)
    case steps(id: Int, [TranscriptStep])
    case error(id: Int, String)
    case approval(id: Int, String)

    public var id: Int {
        switch self {
        case .message(let id, _), .steps(let id, _), .error(let id, _), .approval(let id, _): id
        }
    }
}

/// A prompt and everything the agent did in response.
public struct TranscriptTurn: Identifiable, Hashable, Sendable {
    public var id: Int
    /// The prompts this turn answers, as named by the run's marker. Empty in logs from before markers.
    public var promptIDs: [Prompt.ID] = []
    /// Shift's own instructions, for a run no `Prompt` stands for.
    public var text: String?
    public var note: String?
    public var blocks: [TranscriptBlock] = []

    public var sections: [TranscriptSection] {
        var sections: [TranscriptSection] = []
        for (index, block) in blocks.enumerated() {
            switch block {
            case .message(let text):
                if !text.isEmpty { sections.append(.message(id: index, text)) }
            case .error(let text): sections.append(.error(id: index, text))
            case .approval(let summary): sections.append(.approval(id: index, summary))
            case .step(let step):
                if case .steps(let id, let steps) = sections.last {
                    sections[sections.count - 1] = .steps(id: id, steps + [step])
                } else {
                    sections.append(.steps(id: index, [step]))
                }
            }
        }
        return sections
    }
}

/// Turns a log into `TranscriptTurn`s, one chunk of bytes at a time. Holds on to no tool output beyond its previews.
struct TranscriptParser {
    static let previewLimit = 1_500

    private(set) var turns: [TranscriptTurn] = []
    private var agent: AgentKind
    private var partial = Data()
    /// Where `partial` starts in the log.
    private var offset: UInt64 = 0
    /// Where each step whose result is still to come is.
    private var openSteps: [String: (turn: Int, block: Int)] = [:]
    /// The message arriving in pieces right now.
    private var streaming: (turn: Int, block: Int, text: String)?
    /// Once a marker was seen, markers alone start turns. Before that the agent's own events are all there is.
    private var hasMarkers = false
    private var endedTurn = false
    /// Codex: the thread being read. Its subagents' threads report on the same stream.
    private var thread: String?

    init(agent: AgentKind) { self.agent = agent }

    /// Takes the next bytes of the log. Returns true if any turn changed.
    mutating func feed(_ data: Data) -> Bool {
        let before = turns
        partial.append(data)
        var start = partial.startIndex
        while let newline = partial[start...].firstIndex(of: 0x0A) {
            let length = UInt64(newline - start) + 1
            handle(line: partial[start..<newline], range: offset..<(offset + length))
            offset += length
            start = newline + 1
        }
        partial = Data(partial[start...])
        // Earlier builds logged no newlines at all: a last line that is whole JSON won't get one.
        if partial.last == UInt8(ascii: "}"),
           Transcript.pieces(of: String(decoding: partial, as: UTF8.self)).allSatisfy({ jsonObject($0) != nil }) {
            let length = UInt64(partial.count)
            handle(line: partial, range: offset..<(offset + length))
            offset += length
            partial = Data()
        }
        return turns != before
    }

    private mutating func handle(line data: Data, range: Range<UInt64>) {
        let line = String(decoding: data, as: UTF8.self)
        for piece in Transcript.pieces(of: line) {
            // Not the agent's JSON: setup commands, stderr, a first line cut in half. The raw view has those.
            guard let event = jsonObject(piece) else { continue }
            if event["type"] as? String == RunMarker.type {
                hasMarkers = true
                endedTurn = false
                startTurn(event)
                continue
            }
            switch agent {
            case .claudeCode: claude(event, piece, range)
            case .codex: codex(event, piece, range)
            }
        }
    }

    private mutating func startTurn(_ marker: [String: Any]? = nil) {
        var turn = TranscriptTurn(id: turns.count)
        if let marker {
            turn.promptIDs = (marker["prompts"] as? [String] ?? []).compactMap(UUID.init)
            turn.text = marker["text"] as? String
            turn.note = marker["note"] as? String
            agent = (marker["agent"] as? String).flatMap(AgentKind.init) ?? agent
        }
        turns.append(turn)
    }

    private mutating func append(_ block: TranscriptBlock) -> Int {
        if turns.isEmpty || endedTurn {
            endedTurn = false
            startTurn()
        }
        turns[turns.count - 1].blocks.append(block)
        return turns[turns.count - 1].blocks.count - 1
    }

    // MARK: Blocks

    /// A whole message. It replaces the pieces of it that streamed in.
    private mutating func addMessage(_ text: String) {
        let text = Transcript.withoutProtocol(text)
        if let streaming {
            turns[streaming.turn].blocks[streaming.block] = .message(text)
            self.streaming = nil
        } else if !text.isEmpty {
            _ = append(.message(text))
        }
    }

    private mutating func addDelta(_ delta: String) {
        if streaming == nil {
            let block = append(.message(""))
            streaming = (turns.count - 1, block, "")
        }
        streaming?.text += delta
        if let streaming { turns[streaming.turn].blocks[streaming.block] = .message(Transcript.withoutProtocol(streaming.text)) }
    }

    private mutating func addStep(_ step: TranscriptStep) {
        let block = append(.step(step))
        openSteps[step.id] = (turns.count - 1, block)
    }

    private mutating func addError(_ text: String) {
        // A failed run's last message is usually its error too.
        if turns.last?.blocks.last == .message(Transcript.withoutProtocol(text)) { turns[turns.count - 1].blocks.removeLast() }
        _ = append(.error(OutcomeProtocol.short(text)))
    }

    private mutating func finishStep(_ id: String, output: String, failed: Bool, range: Range<UInt64>) {
        guard let place = openSteps.removeValue(forKey: id), case .step(var step) = turns[place.turn].blocks[place.block] else { return }
        let output = output.trimmingCharacters(in: .newlines)
        step.preview = String(output.prefix(Self.previewLimit))
        step.isTruncated = output.count > Self.previewLimit
        step.outputRange = range
        step.failure = failed ? Transcript.failureLine(output) : nil
        turns[place.turn].blocks[place.block] = .step(step)
    }

    // MARK: Claude Code

    private mutating func claude(_ event: [String: Any], _ line: String, _ range: Range<UInt64>) {
        // A subagent's work is the subagent step's, not the conversation's.
        if let parent = event["parent_tool_use_id"], !(parent is NSNull) { return }
        let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        switch event["type"] as? String {
        case "system":
            // Each run of the agent starts with this; a run cut short never said `result`.
            if !hasMarkers, event["subtype"] as? String == "init", turns.last?.blocks.isEmpty == false { endedTurn = true }
        case "stream_event":
            let inner = event["event"] as? [String: Any] ?? [:]
            if inner["type"] as? String == "content_block_delta", let delta = inner["delta"] as? [String: Any],
               delta["type"] as? String == "text_delta", let text = delta["text"] as? String {
                addDelta(text)
            }
        case "assistant":
            for block in content {
                switch block["type"] as? String {
                case "text": addMessage(block["text"] as? String ?? "")
                case "tool_use": addStep(Self.claudeStep(block))
                default: break // thinking
                }
            }
        case "user":
            // Prompts aren't echoed here (they come from the markers). What is text here is injected by
            // Claude Code ("[Image: original 3200x2000…]", `isSynthetic`), so only tool results count.
            for block in content where block["type"] as? String == "tool_result" {
                finishStep(block["tool_use_id"] as? String ?? "", output: Transcript.claudeOutput(block),
                           failed: block["is_error"] as? Bool == true, range: range)
            }
        case "control_request", "result":
            var state = TurnState()
            _ = ClaudeCodeAdapter.parse(line: line, state: &state)
            state.approvals.forEach { _ = append(.approval($0.summary)) }
            if let error = state.error { addError(error) }
            if event["type"] as? String == "result", !hasMarkers { endedTurn = true }
        default:
            break // rate limit events and the like
        }
    }

    private static func claudeStep(_ block: [String: Any]) -> TranscriptStep {
        let tool = block["name"] as? String ?? "Tool"
        let input = block["input"] as? [String: Any] ?? [:]
        let path = input["file_path"] as? String ?? input["notebook_path"] as? String
        let kind: TranscriptStep.Kind, title: String, detail: String?
        switch tool {
        case "Bash":
            kind = .command
            let command = input["command"] as? String ?? ""
            title = oneLine(input["description"] as? String ?? command)
            detail = command
        case "Read":
            (kind, title, detail) = (.read, "Read \(fileName(path) ?? "a file")", path)
        case "Edit", "MultiEdit", "Write", "NotebookEdit":
            (kind, title, detail) = (.edit, "\(tool == "Write" ? "Wrote" : "Edited") \(fileName(path) ?? "a file")", path)
        case "Grep", "Glob":
            let pattern = input["pattern"] as? String ?? ""
            (kind, title, detail) = (.search, "Searched for \(oneLine(pattern))", input["path"] as? String)
        case "WebFetch":
            (kind, title, detail) = (.web, "Fetched \(oneLine(input["url"] as? String ?? "a page"))", input["prompt"] as? String)
        case "WebSearch":
            (kind, title, detail) = (.web, "Searched the web for \(oneLine(input["query"] as? String ?? ""))", nil)
        case "Task", "Agent":
            (kind, title, detail) = (.agent, oneLine(input["description"] as? String ?? "Ran a subagent"), input["prompt"] as? String)
        default:
            (kind, title, detail) = (.other, "Used \(tool)", nil)
        }
        return TranscriptStep(id: block["id"] as? String ?? UUID().uuidString, kind: kind, title: title, detail: detail)
    }

    private static func oneLine(_ text: String) -> String {
        OutcomeProtocol.short(text.trimmingCharacters(in: .whitespacesAndNewlines).components(separatedBy: .newlines)[0], limit: 120)
    }

    // MARK: Codex

    private mutating func codex(_ message: [String: Any], _ line: String, _ range: Range<UInt64>) {
        var state = TurnState()
        _ = CodexAdapter.parseAppServer(line, &state, prompt: "", resume: nil, cwd: "")
        if let session = state.sessionID { thread = session }
        let params = message["params"] as? [String: Any] ?? [:]
        if let other = params["threadId"] as? String, let thread, other != thread { return }
        state.approvals.forEach { _ = append(.approval($0.summary)) }
        let item = params["item"] as? [String: Any] ?? [:]

        switch message["method"] as? String {
        case "thread/started":
            if thread == nil { thread = (params["thread"] as? [String: Any])?["id"] as? String }
        case "item/agentMessage/delta":
            if let delta = params["delta"] as? String { addDelta(delta) }
        case "item/started":
            if let step = Self.codexStep(item) { addStep(step) }
        case "item/completed":
            if let text = state.finalMessage { addMessage(text) }
            if let id = item["id"] as? String, openSteps[id] != nil {
                finishStep(id, output: Transcript.codexOutput(item), failed: ["failed", "declined"].contains(item["status"] as? String ?? ""), range: range)
            }
        case "turn/completed":
            if let error = state.error { addError(error) }
            if !hasMarkers { endedTurn = true }
        case "error":
            // Codex retries many of these by itself; only the last one, if any, is the turn's.
            if params["willRetry"] as? Bool != true, let error = state.error { addError(error) }
        default:
            if message["error"] != nil, let error = state.error { addError(error) } // A request of ours failed.
        }
    }

    private static func codexStep(_ item: [String: Any]) -> TranscriptStep? {
        guard let id = item["id"] as? String else { return nil }
        switch item["type"] as? String {
        case "commandExecution":
            let command = CodexAdapter.unwrap(item["command"] as? String ?? "")
            let action = (item["commandActions"] as? [[String: Any]])?.first
            switch action?["type"] as? String {
            case "read":
                return .init(id: id, kind: .read, title: "Read \((action?["name"] as? String) ?? "a file")", detail: command)
            case "search", "listFiles":
                return .init(id: id, kind: .search, title: oneLine(command), detail: command)
            default:
                return .init(id: id, kind: .command, title: oneLine(command), detail: command)
            }
        case "fileChange":
            let paths = (item["changes"] as? [[String: Any]] ?? []).compactMap { $0["path"] as? String }
            return .init(id: id, kind: .edit, title: "Edited \(fileName(paths.first) ?? "files")",
                         detail: paths.joined(separator: "\n"))
        case "webSearch":
            return .init(id: id, kind: .web, title: "Searched the web", detail: item["query"] as? String)
        case "mcpToolCall":
            return .init(id: id, kind: .other, title: "Used \(item["tool"] as? String ?? "a tool")", detail: nil)
        default:
            return nil
        }
    }
}

extension Transcript {
    /// One line of the log as JSON lines: earlier builds logged lines without a newline; `}{"` splits them.
    // ponytail: rarely also inside a string; only lines that aren't valid JSON as they are get split.
    static func pieces(of line: String) -> [String] {
        guard line.contains("}{\""), jsonObject(line) == nil else { return [line] }
        return line.replacingOccurrences(of: "}{\"", with: "}\n{\"").components(separatedBy: "\n")
    }

    /// A step's whole output, from the line of the log its result is on.
    static func output(ofStep id: String, line: String) -> String? {
        for piece in pieces(of: line) {
            guard let event = jsonObject(piece) else { continue }
            let content = (event["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
            if let block = content.first(where: { $0["tool_use_id"] as? String == id }) { return claudeOutput(block) }
            if let item = (event["params"] as? [String: Any])?["item"] as? [String: Any], item["id"] as? String == id {
                return codexOutput(item)
            }
        }
        return nil
    }

    /// `tool_result` content: a string, or a list of text and image blocks.
    fileprivate static func claudeOutput(_ block: [String: Any]) -> String {
        if let text = block["content"] as? String { return text }
        return (block["content"] as? [[String: Any]] ?? []).map {
            $0["type"] as? String == "text" ? $0["text"] as? String ?? "" : "[\($0["type"] as? String ?? "other")]"
        }.joined(separator: "\n")
    }

    fileprivate static func codexOutput(_ item: [String: Any]) -> String {
        if let output = item["aggregatedOutput"] as? String { return output }
        if let changes = item["changes"] as? [[String: Any]] {
            return changes.compactMap { $0["diff"] as? String }.joined(separator: "\n")
        }
        if let error = item["error"] as? [String: Any] { return error["message"] as? String ?? "" }
        return ""
    }

    /// The line of a failed step's output that says why: not the "Exit code 1" Claude Code puts first.
    fileprivate static func failureLine(_ output: String) -> String {
        let line = output.components(separatedBy: .newlines).first {
            !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.range(of: #"^Exit code \d+$"#, options: .regularExpression) == nil
        }
        return OutcomeProtocol.short(line ?? "Failed", limit: 200)
    }
}

/// Reads one agent log as a conversation, off the main thread. The first `update` parses the whole log;
/// later ones only what was appended since.
public actor TranscriptReader {
    private static let chunk = 1_000_000

    private let log: AgentLog
    private let store: StateStoring
    private var parser: TranscriptParser
    private var offset: UInt64 = 0

    init(log: AgentLog, store: StateStoring, agent: AgentKind) {
        self.log = log
        self.store = store
        self.parser = TranscriptParser(agent: agent)
    }

    /// The turns so far, with nothing to show for turns that have nothing yet. nil if nothing changed.
    public func update() async -> [TranscriptTurn]? {
        var changed = false
        while true {
            let data = await store.logBytes(log, from: offset, length: Self.chunk)
            if data.isEmpty { break }
            offset += UInt64(data.count)
            if parser.feed(data) { changed = true }
            if data.count < Self.chunk { break }
        }
        return changed ? parser.turns : nil
    }

    /// A step's whole output, which only its preview is kept of.
    public func fullOutput(of step: TranscriptStep) async -> String {
        guard let range = step.outputRange else { return step.preview }
        let data = await store.logBytes(log, from: range.lowerBound, length: Int(range.count))
        return Transcript.output(ofStep: step.id, line: String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines))?
            .trimmingCharacters(in: .newlines) ?? step.preview
    }
}

// MARK: - Markdown

/// What an agent's message is made of, for showing it as formatted text. Inline styles stay in the text.
public enum MarkdownBlock: Hashable, Sendable {
    case paragraph(String)
    case heading(level: Int, String)
    /// `marker`: "•" or "1."
    case listItem(level: Int, marker: String, String)
    case code(String)
    /// Shown as is, in a fixed-width font.
    case table(String)
    case quote(String)
    case rule

    public static func parse(_ text: String) -> [MarkdownBlock] {
        var blocks: [MarkdownBlock] = []
        var paragraph: [String] = []
        func flush() {
            if !paragraph.isEmpty { blocks.append(.paragraph(paragraph.joined(separator: "\n"))) }
            paragraph = []
        }
        var lines = text.components(separatedBy: .newlines)[...]
        while let line = lines.popFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("```") || trimmed.hasPrefix("~~~") {
                flush()
                let fence = String(trimmed.prefix(3))
                var code: [String] = []
                // An open fence runs to the end: the message may still be arriving.
                while let next = lines.popFirst(), !next.trimmingCharacters(in: .whitespaces).hasPrefix(fence) { code.append(next) }
                blocks.append(.code(code.joined(separator: "\n")))
            } else if trimmed.isEmpty {
                flush()
            } else if let match = trimmed.wholeMatch(of: #/(#{1,6})\s+(.*?)\s*#*/#) {
                flush()
                blocks.append(.heading(level: match.1.count, String(match.2)))
            } else if trimmed.wholeMatch(of: #/(-{3,}|\*{3,}|_{3,})/#) != nil {
                flush()
                blocks.append(.rule)
            } else if trimmed.hasPrefix("|") {
                flush()
                var rows = [trimmed]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix("|") {
                    rows.append(next)
                    lines.removeFirst()
                }
                blocks.append(.table(rows.joined(separator: "\n")))
            } else if trimmed.hasPrefix(">") {
                flush()
                var quote = [trimmed]
                while let next = lines.first?.trimmingCharacters(in: .whitespaces), next.hasPrefix(">") {
                    quote.append(next)
                    lines.removeFirst()
                }
                blocks.append(.quote(quote.map { $0.drop { ">".contains($0) }.trimmingCharacters(in: .whitespaces) }.joined(separator: "\n")))
            } else if let match = line.wholeMatch(of: #/(\s*)([-*+]|\d+[.)])\s+(.*)/#) {
                flush()
                var body = String(match.3)
                // Its wrapped lines, indented under it.
                while let next = lines.first, next.first?.isWhitespace == true, !next.trimmingCharacters(in: .whitespaces).isEmpty,
                      next.wholeMatch(of: #/\s*([-*+]|\d+[.)])\s+.*/#) == nil {
                    body += " " + next.trimmingCharacters(in: .whitespaces)
                    lines.removeFirst()
                }
                let marker = match.2.first?.isNumber == true ? String(match.2) : "•"
                blocks.append(.listItem(level: match.1.count / 2, marker: marker, body))
            } else {
                paragraph.append(line)
            }
        }
        flush()
        return blocks
    }
}
