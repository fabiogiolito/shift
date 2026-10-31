import Foundation

/// Defaults suggested when a project is added, and the wording of a failed setup.
/// ponytail: JavaScript package managers only; add other ecosystems when someone needs them.
enum ProjectSetup {
    static let envFiles = [".env", ".env.local"]

    /// lockfile -> package manager, in order of precedence.
    private static let lockfiles = [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"),
                                    ("bun.lock", "bun"), ("package-lock.json", "npm")]

    /// - Parameters:
    ///   - rootFiles: names of the entries in the repository root.
    ///   - packageJSON: contents of the root package.json, if there is one.
    ///   - tracked: the env files that are tracked by git (those are in the worktree already).
    ///   - forced: the type to suggest commands for. Nil: the type the repo looks like.
    // ponytail: only looks at the repo root; an Electron app in a monorepo package needs Other.
    static func suggest(rootFiles: [String], packageJSON: Data? = nil, tracked: Set<String> = [],
                        as forced: ProjectType? = nil) -> (type: ProjectType, setup: String, server: String, build: String) {
        let manager = lockfiles.first { rootFiles.contains($0.0) }?.1
        let runner = manager ?? "npm"
        let copies = envFiles.filter { rootFiles.contains($0) && !tracked.contains($0) }
            .map { "cp \"$SHIFT_REPO/\($0)\" ." }
        let steps = (manager.map { ["\($0) install"] } ?? []) + copies
        let setup = steps.joined(separator: " && ")

        let package = packageJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        let scripts = package?["scripts"] as? [String: Any] ?? [:]
        let dependencies = ["dependencies", "devDependencies"].compactMap { package?[$0] as? [String: Any] }
        let dev = scripts["dev"] as? String

        let type = forced ?? {
            if dependencies.contains(where: { $0["electron"] != nil }) { return .electronApp }
            if dev != nil { return .dynamicWebsite }
            if rootFiles.contains(where: { $0 == "project.yml" || $0.hasSuffix(".xcodeproj") }) { return .nativeApp }
            // Static has no setup, so a repo that needs one is not static.
            return steps.isEmpty ? .staticWebsite : .other
        }()
        switch type {
        case .electronApp:
            // A package manager may skip Electron's install script (pnpm does), leaving no binary to run.
            let install = ["\(runner) install", "node node_modules/electron/install.js"] + copies
            let run = dev != nil ? "\(runner) run dev" : scripts["start"] != nil ? "\(runner) run start" : "node_modules/.bin/electron ."
            return (type, install.joined(separator: " && "), "", run)
        case .dynamicWebsite:
            guard let dev else { return (type, setup, "", "") }
            // Vite and Astro ignore $PORT, so pass it as a flag. npm needs `--` to forward it; the others
            // forward arguments as-is (and pnpm would hand a literal `--` on to vite).
            var server = "\(runner) run dev"
            if dev.range(of: #"\b(vite|astro)\b"#, options: .regularExpression) != nil {
                server += runner == "npm" ? " -- --port $PORT" : " --port $PORT"
            }
            return (type, setup, server, "")
        case .staticWebsite:
            return (type, "", "", "")
        case .nativeApp, .other:
            return (type, setup, "", "")
        }
    }

    static func suggest(repo: URL, git: GitServicing,
                        as forced: ProjectType? = nil) async -> (type: ProjectType, setup: String, server: String, build: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        var tracked: Set<String> = []
        for name in envFiles where files.contains(name) {
            if await git.isTracked(repo: repo, path: name) { tracked.insert(name) }
        }
        let package = FileManager.default.contents(atPath: repo.appendingPathComponent("package.json").path)
        var suggested = suggest(rootFiles: files, packageJSON: package, tracked: tracked, as: forced)
        if suggested.type == .nativeApp {
            suggested.build = Project(name: "", repoPath: repo.path, baseBranch: "").defaultBuildCommand
        }
        return suggested
    }

    /// What serves a task's worktree: the project's own server command, else the dev script found in
    /// `directory` (a project the agent created after it was added), else a static file server.
    // ponytail: depends on python3 being installed (it ships with the Xcode command line tools);
    // replace with an in-process server if that becomes a problem.
    static func serverCommand(for project: Project, in directory: URL? = nil) -> String {
        let command = project.serverCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        if !command.isEmpty { return command }
        guard let directory else { return staticServer }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        let package = FileManager.default.contents(atPath: directory.appendingPathComponent("package.json").path)
        let detected = suggest(rootFiles: files, packageJSON: package).server
        return detected.isEmpty ? staticServer : detected
    }

    /// What builds a task's worktree: the project's own build command, else the one guessed from `directory`
    /// (an app the agent created after the project was added). Empty when there is nothing to build yet.
    static func buildCommand(for project: Project, in directory: URL) -> String {
        guard project.buildCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return project.buildCommand }
        return Project(name: "", repoPath: directory.path, baseBranch: "").defaultBuildCommand
    }

    /// The install to run before a detected dev script when the project has no commands of its own
    /// (it was empty when added) and nothing installed its dependencies yet.
    static func installStep(for project: Project, in directory: URL) -> String? {
        guard project.serverCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              project.setupCommand.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        guard files.contains("package.json"), !files.contains("node_modules") else { return nil }
        return "\(lockfiles.first { files.contains($0.0) }?.1 ?? "npm") install"
    }

    /// Serves the worktree on both 127.0.0.1 and ::1, since browsers may resolve `localhost` to either,
    /// and never binds beyond loopback. No-cache so a refresh always shows the agent's latest edits.
    static let staticServer = "python3 -c '" + """
        import http.server as h, os, socket, threading
        class Handler(h.SimpleHTTPRequestHandler):
            def end_headers(self):
                self.send_header("Cache-Control", "no-store")
                super().end_headers()
        class V6(h.ThreadingHTTPServer):
            address_family = socket.AF_INET6
        port = int(os.environ["PORT"])
        v4 = h.ThreadingHTTPServer(("127.0.0.1", port), Handler)
        try:
            v6 = V6(("::1", port), Handler)
            threading.Thread(target=v6.serve_forever, daemon=True).start()
        except OSError:
            pass
        v4.serve_forever()
        """ + "'"

    /// Short reason for a blocked task: the exit code and the last few lines of output.
    /// Progress bars (lines with no letters or digits, like pnpm's `+++++`) are dropped so they don't bury the error.
    static func failure(_ result: CommandResult) -> String {
        let tail = result.output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.unicodeScalars.contains(where: CharacterSet.alphanumerics.contains) }
            .suffix(5).joined(separator: "\n")
        let headline = "Setup failed (exit code \(result.exitCode))."
        return tail.isEmpty ? headline : headline + "\n" + String(tail.suffix(400))
    }
}
