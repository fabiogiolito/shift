import AppKit
import UniformTypeIdentifiers

public enum ExternalApp: String, CaseIterable, Identifiable, Sendable {
    case vscode, cursor, zed, finder, terminal

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .vscode: "VS Code"
        case .cursor: "Cursor"
        case .zed: "Zed"
        case .finder: "Finder"
        case .terminal: "Terminal"
        }
    }

    var bundleIdentifier: String? {
        switch self {
        case .vscode: "com.microsoft.VSCode"
        case .cursor: "com.todesktop.230313mzl4w4u92"
        case .zed: "dev.zed.Zed"
        case .finder: "com.apple.finder"
        case .terminal: nil
        }
    }
}

public struct ExternalApps: Sendable {
    static let appleTerminal = "com.apple.Terminal"
    // hmo.Vesper is Nyx.
    static let knownTerminals = ["hmo.Vesper", "com.mitchellh.ghostty", "com.googlecode.iterm2", "dev.warp.Warp-Stable", appleTerminal]

    public init() {}

    /// Editors that are installed, plus Finder. Detect by bundle identifier via NSWorkspace.
    public func installedEditors() -> [ExternalApp] {
        [.vscode, .cursor, .zed].filter { appURL($0) != nil } + [.finder]
    }

    /// Opens the directory in the app.
    public func open(_ directory: URL, in app: ExternalApp) {
        guard let appURL = appURL(app) else { return }
        NSWorkspace.shared.open([directory], withApplicationAt: appURL, configuration: NSWorkspace.OpenConfiguration())
    }

    /// Name of the terminal that `.terminal` will use, e.g. "Ghostty".
    public func terminalName() -> String {
        terminalURL().map { FileManager.default.displayName(atPath: $0.path).replacingOccurrences(of: ".app", with: "") }
            ?? "Terminal"
    }

    public func openInBrowser(_ url: URL) {
        NSWorkspace.shared.open(url)
    }

    /// Opens a freshly built app, first quitting the copy already running from the same place.
    /// A new instance even if another copy with the same bundle identifier (such as an installed one) runs.
    @MainActor
    public func relaunch(_ app: URL, environment: [String: String] = [:]) async {
        let running = NSWorkspace.shared.runningApplications
            .filter { $0.bundleURL?.standardizedFileURL == app.standardizedFileURL }
        running.forEach { $0.terminate() }
        var waited = 0
        while running.contains(where: { !$0.isTerminated }), waited < 50 {
            try? await Task.sleep(for: .milliseconds(100))
            waited += 1
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        configuration.environment = environment
        _ = try? await NSWorkspace.shared.openApplication(at: app, configuration: configuration)
    }

    func appURL(_ app: ExternalApp) -> URL? {
        guard let id = app.bundleIdentifier else { return terminalURL() }
        return NSWorkspace.shared.urlForApplication(withBundleIdentifier: id)
    }

    func terminalURL() -> URL? {
        let workspace = NSWorkspace.shared
        let handler = UTType(filenameExtension: "command").flatMap { workspace.urlForApplication(toOpen: $0) }
        return Self.pickTerminal(commandHandler: handler.map { ($0, Bundle(url: $0)?.bundleIdentifier) },
                                 installed: { workspace.urlForApplication(withBundleIdentifier: $0) })
    }

    /// Terminal.app handles `.command` by default, so that says nothing about preference.
    /// Any other handler is a deliberate choice by the user and wins; otherwise first installed known terminal.
    // ponytail: trusts that a non-default .command handler is a terminal; add an allow-list if someone maps it to an editor.
    static func pickTerminal(commandHandler: (url: URL, bundleID: String?)?, installed: (String) -> URL?) -> URL? {
        if let commandHandler, commandHandler.bundleID != appleTerminal { return commandHandler.url }
        return knownTerminals.lazy.compactMap(installed).first
    }
}
