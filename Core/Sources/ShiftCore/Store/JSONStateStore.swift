import Foundation

public actor JSONStateStore: StateStoring {
    private let root: URL
    private var stateURL: URL { root.appendingPathComponent("state.json") }
    private let fm = FileManager.default
    static let maxLogRead: UInt64 = 200_000

    public init(root: URL = ShiftPaths.root) {
        self.root = root
    }

    public func load() -> AppState {
        guard let data = try? Data(contentsOf: stateURL) else { return AppState() }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        if let state = try? decoder.decode(AppState.self, from: data) { return state }
        // Corrupt: keep it for inspection, never overwrite an earlier corrupt copy.
        var aside = root.appendingPathComponent("state.json.corrupt")
        if fm.fileExists(atPath: aside.path) {
            aside = root.appendingPathComponent("state.json.corrupt.\(Int(Date().timeIntervalSince1970))")
        }
        try? fm.moveItem(at: stateURL, to: aside)
        return AppState()
    }

    public func save(_ state: AppState) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        do {
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
            try encoder.encode(state).write(to: stateURL, options: .atomic)
        } catch {
            NSLog("Shift: could not save state: \(error)")
        }
    }

    private func logURL(_ taskID: Int) -> URL { url(of: .task(taskID)) }

    private func url(of log: AgentLog) -> URL {
        let name = switch log {
        case .task(let id): "agent-\(id).log"
        case .chat(let id): "chat-\(id.uuidString).log"
        }
        return root.appendingPathComponent("logs").appendingPathComponent(name)
    }

    public func appendLog(taskID: Int, text: String) {
        let url = logURL(taskID)
        if !fm.fileExists(atPath: url.path) {
            try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            fm.createFile(atPath: url.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: Data(text.utf8))
    }

    public func readLog(taskID: Int) -> String {
        guard let handle = try? FileHandle(forReadingFrom: logURL(taskID)) else { return "" }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > Self.maxLogRead ? size - Self.maxLogRead : 0)
        let data = (try? handle.readToEnd()) ?? Data()
        guard size > Self.maxLogRead else { return String(decoding: data, as: UTF8.self) }
        // The cut lands inside a line: what's before the first newline is half a line of JSON.
        let lines = data.firstIndex(of: 0x0A).map { data[($0 + 1)...] } ?? Data()
        return Self.omitted + String(decoding: lines, as: UTF8.self)
    }

    static let omitted = "[Earlier output not shown]\n"

    public func logBytes(_ log: AgentLog, from offset: UInt64, length: Int) -> Data {
        guard let handle = try? FileHandle(forReadingFrom: url(of: log)) else { return Data() }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        return (try? handle.read(upToCount: length)) ?? Data()
    }

    public func deleteLog(taskID: Int) {
        try? fm.removeItem(at: logURL(taskID))
    }
}
