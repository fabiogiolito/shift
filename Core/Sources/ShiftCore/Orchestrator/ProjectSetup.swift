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
    static func suggest(rootFiles: [String], packageJSON: Data? = nil,
                        tracked: Set<String> = []) -> (setup: String, server: String) {
        let manager = lockfiles.first { rootFiles.contains($0.0) }?.1
        var steps = manager.map { ["\($0) install"] } ?? []
        steps += envFiles.filter { rootFiles.contains($0) && !tracked.contains($0) }
            .map { "cp \"$SHIFT_REPO/\($0)\" ." }

        let package = packageJSON.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
        guard let dev = (package?["scripts"] as? [String: Any])?["dev"] as? String else {
            return (steps.joined(separator: " && "), "")
        }
        // Vite ignores $PORT, so pass it as a flag. npm needs `--` to forward it; the others
        // forward arguments as-is (and pnpm would hand a literal `--` on to vite).
        let runner = manager ?? "npm"
        var server = "\(runner) run dev"
        if dev.range(of: #"\bvite\b"#, options: .regularExpression) != nil {
            server += runner == "npm" ? " -- --port $PORT" : " --port $PORT"
        }
        return (steps.joined(separator: " && "), server)
    }

    static func suggest(repo: URL, git: GitServicing) async -> (setup: String, server: String) {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: repo.path)) ?? []
        var tracked: Set<String> = []
        for name in envFiles where files.contains(name) {
            if await git.isTracked(repo: repo, path: name) { tracked.insert(name) }
        }
        let package = FileManager.default.contents(atPath: repo.appendingPathComponent("package.json").path)
        return suggest(rootFiles: files, packageJSON: package, tracked: tracked)
    }

    /// What serves a task's worktree: the project's own server command, or a static file server.
    // ponytail: depends on python3 being installed (it ships with the Xcode command line tools);
    // replace with an in-process server if that becomes a problem.
    static func serverCommand(for project: Project) -> String {
        let command = project.serverCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        return command.isEmpty ? staticServer : command
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
    static func failure(_ result: CommandResult) -> String {
        let tail = result.output.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
            .suffix(5).joined(separator: "\n")
        let headline = "Setup failed (exit code \(result.exitCode))."
        return tail.isEmpty ? headline : headline + "\n" + String(tail.suffix(400))
    }
}
