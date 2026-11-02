import Foundation

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
