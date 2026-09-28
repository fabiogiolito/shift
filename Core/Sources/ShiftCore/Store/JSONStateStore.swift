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

    private func logURL(_ taskID: Int) -> URL {
        root.appendingPathComponent("logs").appendingPathComponent("agent-\(taskID).log")
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
        // Lossy decoding: the cut may land inside a multi-byte character.
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }

    public func deleteLog(taskID: Int) {
        try? fm.removeItem(at: logURL(taskID))
    }
}
