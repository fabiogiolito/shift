import AppKit
import UserNotifications

/// What a new Mac needs for Shift, checked and installed for real. Used by the setup window and Settings › Setup.
/// Nothing needs Homebrew. Installers that need an administrator ask with the system's password dialog; sign-ins
/// open Terminal with the command ready. After an install, call `AppModel.reloadEnvironment()` so it's found.
public enum MacSetup {
    public struct Failure: LocalizedError {
        public let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }

    // MARK: - Checks

    public static func hasCommandLineTools() async -> Bool { await run(["/usr/bin/xcode-select", "-p"]).ok }

    public static func hasNode() async -> Bool { await run(["node", "--version"]).ok }

    public static func isInstalled(_ agent: AgentKind) async -> Bool {
        await Task.detached { AgentEnvironment.detect(agent) != nil }.value
    }

    public static func isSignedIn(_ agent: AgentKind) async -> Bool {
        switch agent {
        case .claudeCode: await run(["claude", "auth", "status"]).output.contains(#""loggedIn": true"#)
        case .codex: await run(["codex", "login", "status"]).output.contains("Logged in")
        }
    }

    /// The global Git name and email, "" when unset.
    public static func gitIdentity() async -> (name: String, email: String) {
        async let name = run(["git", "config", "--global", "user.name"]).output
        async let email = run(["git", "config", "--global", "user.email"]).output
        return await (name.trimmingCharacters(in: .whitespacesAndNewlines), email.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    public static func isGitHubConnected() async -> Bool { await run(["gh", "auth", "status"]).ok }

    public static func hasPackageManager(_ name: String) async -> Bool { await run([name, "--version"]).ok }

    public static func hasXcode() async -> Bool {
        guard FileManager.default.fileExists(atPath: xcode) else { return false }
        let environment = ["DEVELOPER_DIR": xcode + "/Contents/Developer"]
        async let license = run(["xcodebuild", "-license", "check"], environment: environment).ok
        async let firstLaunch = run(["xcodebuild", "-checkFirstLaunchStatus"], environment: environment).ok
        let (licensed, launched) = await (license, firstLaunch)
        return licensed && launched
    }

    public static func hasTailscaleApp() -> Bool { FileManager.default.fileExists(atPath: tailscaleApp) }

    /// Signed in and connected, with HTTPS certificates on: what pairing a phone and sharing servers need.
    public static func isTailscaleReady() async -> Bool {
        let status = await tailscaleStatus()
        return status?["BackendState"] as? String == "Running" && !(status?["CertDomains"] as? [String] ?? []).isEmpty
    }

    /// The package manager a JavaScript project uses, nil when it isn't one. Its `packageManager` field first.
    public static func packageManager(of project: URL) -> String? {
        guard let data = try? Data(contentsOf: project.appendingPathComponent("package.json")) else { return nil }
        if let package = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let field = package["packageManager"] as? String, let name = field.split(separator: "@").first {
            return String(name)
        }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        return ProjectSetup.lockfiles.first { files.contains($0.0) }?.1 ?? "npm"
    }

    /// A native app project, which needs Xcode to build.
    public static func needsXcode(_ project: URL) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: project.path)) ?? []
        return files.contains { $0 == "project.yml" || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }
    }

    // MARK: - Actions

    /// Opens macOS's own installer, then waits for the user to finish it.
    public static func installCommandLineTools() async throws {
        _ = await run(["/usr/bin/xcode-select", "--install"])
        try await wait(minutes: 120, "The Command Line Tools installer didn't finish.") { await hasCommandLineTools() }
    }

    /// The current LTS from nodejs.org, with its installer.
    public static func installNode() async throws {
        let (index, _) = try await URLSession.shared.data(from: URL(string: "https://nodejs.org/dist/index.json")!)
        let releases = try JSONSerialization.jsonObject(with: index) as? [[String: Any]] ?? []
        guard let version = releases.first(where: { $0["lts"] is String })?["version"] as? String else {
            throw Failure("Couldn't find the latest Node.js on nodejs.org.")
        }
        try await installPackage(from: URL(string: "https://nodejs.org/dist/\(version)/node-\(version).pkg")!)
        AgentEnvironment.reload()
        guard await hasNode() else { throw Failure("Node.js installed, but Shift can't find it.") }
    }

    /// Claude Code with its own installer (to ~/.local/bin); Codex with npm into ~/.local, installing Node first.
    public static func install(_ agent: AgentKind) async throws {
        switch agent {
        case .claudeCode:
            try await runOrFail(["/bin/bash", "-c", "curl -fsSL https://claude.ai/install.sh | bash"], minutes: 10)
        case .codex:
            if !(await hasNode()) { try await installNode() }
            try await runOrFail(["npm", "install", "--global", "--prefix", localPrefix, "@openai/codex"], minutes: 10)
        }
        AgentEnvironment.reload()
        guard await isInstalled(agent) else { throw Failure("\(agent.displayName) installed, but Shift can't find it.") }
    }

    /// Opens Terminal with the sign-in command, then waits for it.
    public static func signIn(_ agent: AgentKind) async throws {
        openInTerminal(path(of: agent.executableName) + (agent == .claudeCode ? " auth login" : " login"))
        try await wait(minutes: 15, "Sign-in didn't finish.") { await isSignedIn(agent) }
    }

    public static func setGitIdentity(name: String, email: String) async throws {
        try await runOrFail(["git", "config", "--global", "user.name", name])
        try await runOrFail(["git", "config", "--global", "user.email", email])
    }

    /// Installs the GitHub CLI if needed, then signs in in Terminal (browser) and sets it up as Git's credentials.
    public static func connectGitHub() async throws {
        if !(await run(["gh", "--version"]).ok) {
            let (data, _) = try await URLSession.shared.data(from: URL(string: "https://api.github.com/repos/cli/cli/releases/latest")!)
            let release = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            let assets = release?["assets"] as? [[String: Any]] ?? []
            guard let url = assets.compactMap({ $0["browser_download_url"] as? String })
                .first(where: { $0.hasSuffix("_macOS_universal.pkg") }).flatMap(URL.init(string:)) else {
                throw Failure("Couldn't find the GitHub CLI installer.")
            }
            try await installPackage(from: url)
            AgentEnvironment.reload()
        }
        let gh = path(of: "gh")
        openInTerminal("\(gh) auth login --web --git-protocol https && \(gh) auth setup-git")
        try await wait(minutes: 15, "GitHub sign-in didn't finish.") { await isGitHubConnected() }
    }

    /// pnpm, yarn or bun, with npm into ~/.local.
    public static func installPackageManager(_ name: String) async throws {
        if !(await hasNode()) { try await installNode() }
        try await runOrFail(["npm", "install", "--global", "--prefix", localPrefix, name], minutes: 10)
        AgentEnvironment.reload()
        guard await hasPackageManager(name) else { throw Failure("\(name) installed, but Shift can't find it.") }
    }

    /// Opens Xcode in the App Store and waits for it, then accepts its license and runs its first launch.
    public static func installXcode() async throws {
        if !FileManager.default.fileExists(atPath: xcode) {
            NSWorkspace.shared.open(URL(string: "macappstore://apps.apple.com/app/id497799835")!)
            try await wait(minutes: 240, "Xcode didn't finish installing.") { FileManager.default.fileExists(atPath: xcode) }
        }
        let developer = xcode + "/Contents/Developer"
        try await runAsAdministrator("/usr/bin/xcode-select -s '\(developer)' && '\(developer)/usr/bin/xcodebuild' -license accept"
            + " && '\(developer)/usr/bin/xcodebuild' -runFirstLaunch")
    }

    /// Installs Tailscale if needed and opens it to sign in, then waits for it; then for HTTPS certificates, turned on
    /// in its admin console.
    public static func setUpTailscale() async throws {
        if !hasTailscaleApp() {
            try await installPackage(from: URL(string: "https://pkgs.tailscale.com/stable/Tailscale-latest-macos.pkg")!)
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: tailscaleApp))
        // Signed in but turned off: turn it back on.
        if await tailscaleState() == "Stopped", let cli = tailscaleCLI { _ = await run([cli, "up"]) }
        try await wait(minutes: 15, "Tailscale didn't connect. Sign in from its menu bar icon and try again.") {
            await tailscaleState() == "Running"
        }
        guard !(await isTailscaleReady()) else { return }
        NSWorkspace.shared.open(URL(string: "https://login.tailscale.com/admin/dns")!)
        try await wait(minutes: 15, "HTTPS certificates are off. Turn them on in Tailscale's admin console, under DNS.") {
            await isTailscaleReady()
        }
    }

    // MARK: - Permissions

    /// nil until the user has answered the system's question.
    public static func notificationsAllowed() async -> Bool? {
        switch await UNUserNotificationCenter.current().notificationSettings().authorizationStatus {
        case .notDetermined: nil
        case .denied: false
        default: true
        }
    }

    /// Asks the first time. Once turned off, macOS won't ask again: opens System Settings › Notifications instead.
    public static func allowNotifications() async -> Bool {
        if await notificationsAllowed() == false {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension")!)
            return false
        }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// The folder macOS asks about before an app reads anything in it (Desktop, Documents, Downloads, iCloud Drive,
    /// another disk), if `project` is in one. The agents, Git and servers all run as Shift, so they all need it.
    public static func protectedFolder(containing project: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL? {
        let path = project.standardizedFileURL.path
        let roots = ["Desktop", "Documents", "Downloads", "Library/Mobile Documents"].map { home.appendingPathComponent($0).standardizedFileURL }
        if let root = roots.first(where: { path == $0.path || path.hasPrefix($0.path + "/") }) { return root }
        let parts = project.standardizedFileURL.pathComponents
        if parts.count > 2, parts[1] == "Volumes" { return URL(fileURLWithPath: "/Volumes/\(parts[2])") }
        return nil
    }

    /// What macOS calls it in its question.
    public static func displayName(ofProtected folder: URL) -> String {
        folder.lastPathComponent == "Mobile Documents" ? "iCloud Drive" : folder.lastPathComponent
    }

    /// Reads the folder, which makes macOS ask the first time. If it was turned off, opens Files & Folders in System
    /// Settings and fails.
    public static func allowAccess(to folder: URL) async throws {
        do {
            _ = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        } catch {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders")!)
            throw Failure("Shift can't open \(displayName(ofProtected: folder)). Turn it on for Shift in System Settings › Privacy & Security › Files & Folders, then try again.")
        }
    }

    /// Terminal with `agent` asked to fix `problem`, for "Help Me Fix This".
    public static func askForHelp(_ agent: AgentKind, with problem: String) {
        let prompt = "I'm setting up Shift on this Mac and this step failed: \(problem) Please help me fix it."
        openInTerminal("\(path(of: agent.executableName)) \(shellQuoted(prompt))")
    }

    /// Runs `command` in a new Terminal window, in a login shell.
    public static func openInTerminal(_ command: String) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("Shift Setup", isDirectory: true)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let file = folder.appendingPathComponent(UUID().uuidString + ".command")
        try? "#!/bin/zsh -l\n\(command)\n".write(to: file, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal", file.path]
        try? process.run()
    }

    // MARK: - Helpers

    /// The tool's full path on Shift's PATH, quoted, for Terminal: a new Mac's shell doesn't have ~/.local/bin, where
    /// Claude Code and Codex are installed. The bare name when it isn't found.
    static func path(of tool: String) -> String {
        let directories = (AgentEnvironment.loginShell["PATH"] ?? "").split(separator: ":")
        let found = directories.map { "\($0)/\(tool)" }.first(where: FileManager.default.isExecutableFile(atPath:))
        return found.map(shellQuoted) ?? tool
    }

    private static let xcode = "/Applications/Xcode.app"
    private static let tailscaleApp = "/Applications/Tailscale.app"

    /// Tailscale's BackendState: "Running" when connected, "Stopped" when turned off, "NeedsLogin"; nil without it.
    public static func tailscaleState() async -> String? { await tailscaleStatus()?["BackendState"] as? String }

    private static var tailscaleCLI: String? { Tailscale.candidates.first(where: FileManager.default.isExecutableFile(atPath:)) }

    private static func tailscaleStatus() async -> [String: Any]? {
        guard let cli = tailscaleCLI else { return nil }
        let output = await run([cli, "status", "--json"]).output
        // From the JSON on: a version warning can come first.
        guard let start = output.firstIndex(of: "{") else { return nil }
        return try? JSONSerialization.jsonObject(with: Data(output[start...].utf8)) as? [String: Any]
    }
    /// Where Shift installs npm tools: its bin is on Shift's PATH, and no administrator is needed.
    private static let localPrefix = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local").path

    /// Runs `command` (looked up on the login shell's PATH) and returns whether it succeeded, with stdout and stderr.
    static func run(_ command: [String], environment extra: [String: String] = [:],
                    minutes: Double = 0.5) async -> (ok: Bool, output: String) {
        await Task.detached {
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            process.arguments = command
            process.environment = AgentEnvironment.loginShell.merging(extra) { _, new in new }
            let pipe = Pipe()
            process.standardOutput = pipe
            process.standardError = pipe
            process.standardInput = FileHandle.nullDevice
            guard (try? process.run()) != nil else { return (false, "") }
            DispatchQueue.global().asyncAfter(deadline: .now() + minutes * 60) {
                if process.isRunning { process.terminate() }
            }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return (process.terminationStatus == 0, String(decoding: data, as: UTF8.self))
        }.value
    }

    /// `run`, throwing the command's last output line when it fails.
    private static func runOrFail(_ command: [String], minutes: Double = 0.5) async throws {
        let result = await run(command, minutes: minutes)
        guard !result.ok else { return }
        let line = result.output.split(separator: "\n").last.map(String.init) ?? ""
        throw Failure(line.isEmpty ? "\(command.first ?? "The command") failed." : line)
    }

    private static func installPackage(from url: URL) async throws {
        let (download, _) = try await URLSession.shared.download(from: url)
        let package = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: package)
        try FileManager.default.moveItem(at: download, to: package)
        defer { try? FileManager.default.removeItem(at: package) }
        try await runAsAdministrator("/usr/sbin/installer -pkg '\(package.path)' -target /")
    }

    /// With the system's administrator password dialog. `script` must quote its own paths.
    static func runAsAdministrator(_ script: String) async throws {
        let escaped = script.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let result = await run(["/usr/bin/osascript", "-e", "do shell script \"\(escaped)\" with administrator privileges"],
                               minutes: 30)
        guard !result.ok else { return }
        throw Failure(result.output.contains("-128") ? "Cancelled." : result.output.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// Checks `done` every 2 seconds until it's true, or fails with `message` after `minutes`.
    private static func wait(minutes: Double, _ message: String, until done: () async -> Bool) async throws {
        let deadline = Date().addingTimeInterval(minutes * 60)
        while !(await done()) {
            guard Date() < deadline else { throw Failure(message) }
            try await Task.sleep(for: .seconds(2))
        }
    }

    static func shellQuoted(_ text: String) -> String { "'" + text.replacingOccurrences(of: "'", with: "'\\''") + "'" }
}
