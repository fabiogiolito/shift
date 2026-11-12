import AppKit

/// After Shift crashes, the next launch offers to report it: a GitHub issue opens in the browser with the crash's summary
/// filled in, for the user to read and submit, and the full report is shown in Finder as a .txt to attach (GitHub doesn't
/// take .ips files, and the whole report is too long for the link). Nothing is sent by Shift itself.
/// Reads the reports macOS writes to ~/Library/Logs/DiagnosticReports, only this app's (by bundle ID, so Shift Dev
/// never offers the installed Shift's), and each one once. Off in Debug builds unless SHIFT_CRASH_REPORT=1.
@MainActor
enum CrashReport {
    private static let seenKey = "lastCrashReportSeen"
    private static let issuesURL = "https://github.com/fabiogiolito/shift/issues/new"
    /// The window's `.task` runs again when it is reopened.
    private static var checked = false

    static func offerIfCrashed() {
        let env = ProcessInfo.processInfo.environment
        #if DEBUG
        guard env["SHIFT_CRASH_REPORT"] == "1" else { return }
        #endif
        guard !checked, env["SHIFT_PREVIEW"] == nil else { return }
        checked = true
        let seen = UserDefaults.standard.object(forKey: seenKey) as? Date ?? .distantPast
        guard let (file, date, report) = latest(after: seen) else { return }
        UserDefaults.standard.set(date, forKey: seenKey)

        let alert = NSAlert()
        alert.messageText = "Shift quit unexpectedly"
        alert.informativeText = "Report it on GitHub so it can be fixed. The issue opens in your browser for you to "
            + "review before submitting, and it will be public. The full report opens in Finder, to attach."
        alert.addButton(withTitle: "Report on GitHub")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let name = file.deletingPathExtension().lastPathComponent + ".txt"
        let copy = FileManager.default.temporaryDirectory.appendingPathComponent("Shift crash reports", isDirectory: true)
        try? FileManager.default.createDirectory(at: copy, withIntermediateDirectories: true)
        let txt = copy.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: txt)
        try? FileManager.default.copyItem(at: file, to: txt)
        NSWorkspace.shared.activateFileViewerSelecting([txt])

        guard let issue = CrashIssue(ips: report, attachment: name) else { return }
        var url = URLComponents(string: issuesURL)!
        url.queryItems = [URLQueryItem(name: "title", value: issue.title), URLQueryItem(name: "body", value: issue.body)]
        if let link = url.url { NSWorkspace.shared.open(link) }
    }

    /// The newest crash of this app written after `date`.
    private static func latest(after date: Date) -> (URL, Date, String)? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey])) ?? []
        let dated = files.filter { $0.pathExtension == "ips" }
            .compactMap { url in (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { (url, $0) } }
            .filter { $0.1 > date }
            .sorted { $0.1 > $1.1 }
        for (url, modified) in dated {
            guard let text = try? String(contentsOf: url, encoding: .utf8),
                  let issue = CrashIssue(ips: text, attachment: ""),
                  issue.bundleID == Bundle.main.bundleIdentifier else { continue }
            return (url, modified, text)
        }
        return nil
    }
}

/// A GitHub issue from a macOS crash report (.ips: a JSON header line, then the report as JSON). Small enough for a link:
/// versions, the exception, the error message and the crashed thread's top 25 frames (GitHub refuses links past ~8 KB).
struct CrashIssue {
    let bundleID: String?
    let title: String
    let body: String

    init?(ips: String, attachment: String) {
        let parts = ips.split(separator: "\n", maxSplits: 1)
        guard parts.count == 2,
              let header = try? JSONSerialization.jsonObject(with: Data(parts[0].utf8)) as? [String: Any],
              header["bug_type"] as? String == "309", // A crash, not a hang or a resource report.
              let report = try? JSONSerialization.jsonObject(with: Data(parts[1].utf8)) as? [String: Any] else { return nil }
        bundleID = report["codeSigningID"] as? String

        let exception = report["exception"] as? [String: Any]
        let type = [exception?["type"] as? String, (exception?["signal"] as? String).map { "(\($0))" }]
            .compactMap { $0 }.joined(separator: " ")
        // e.g. Swift's "Fatal error: Unexpectedly found nil…", or an Objective-C exception's reason.
        let messages = ((report["asi"] as? [String: [String]]) ?? [:]).values.flatMap { $0 }

        let images = (report["usedImages"] as? [[String: Any]] ?? []).map { $0["name"] as? String ?? "???" }
        let threads = report["threads"] as? [[String: Any]] ?? []
        let faulting = report["faultingThread"] as? Int ?? threads.firstIndex { $0["triggered"] as? Bool == true } ?? 0
        let frames = threads.indices.contains(faulting) ? threads[faulting]["frames"] as? [[String: Any]] ?? [] : []
        let appName = header["name"] as? String ?? "Shift"
        var firstOwn: String?
        let lines = frames.prefix(25).enumerated().map { i, frame in
            let index = frame["imageIndex"] as? Int ?? -1
            let image = images.indices.contains(index) ? images[index] : "???"
            var symbol = String((frame["symbol"] as? String ?? "0x\(String(frame["imageOffset"] as? Int ?? 0, radix: 16))").prefix(120))
            if let offset = frame["symbolLocation"] as? Int { symbol += " + \(offset)" }
            if let file = frame["sourceFile"] as? String { symbol += " (\(file):\(frame["sourceLine"] as? Int ?? 0))" }
            if image == appName, firstOwn == nil { firstOwn = frame["symbol"] as? String }
            return "\(i)".padding(toLength: 4, withPad: " ", startingAt: 0) + image + "  " + symbol
        }

        let build = (header["build_version"] as? String).flatMap { $0.isEmpty ? nil : "(\($0))" }
        let version = [header["app_version"] as? String, build].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " ")
        title = "Crash" + (firstOwn.map { " in \($0.prefix(80))" } ?? "") + (version.isEmpty ? "" : " — \(version)")
        let facts = [
            "\(appName) \(version)",
            [header["os_version"] as? String, report["modelCode"] as? String].compactMap { $0 }.joined(separator: ", "),
            type,
        ] + messages
        body = """
        **What were you doing when Shift quit?**


        **Full report:** drag `\(attachment)` here from the Finder window Shift opened.

        ### Crash
        \(facts.filter { !$0.isEmpty }.map { "- " + $0 }.joined(separator: "\n"))

        ### Crashed thread
        ```
        \(lines.joined(separator: "\n"))
        ```
        """
    }
}
