import Foundation

public struct GitError: LocalizedError, Equatable, Sendable {
    public var message: String
    public var errorDescription: String? { message }
}

public struct GitService: GitServicing {
    public init() {}

    /// How long a push may take before it is stopped.
    var pushTimeout: TimeInterval = 60

    // MARK: - Basics

    public func isRepository(_ url: URL) async -> Bool {
        (try? await run(["rev-parse", "--git-dir"], in: url))?.status == 0
    }

    public func branches(repo: URL) async throws -> [String] {
        try await git(["for-each-ref", "--format=%(refname:short)", "refs/heads"], in: repo)
            .split(separator: "\n").map(String.init)
    }

    public func currentBranch(repo: URL) async throws -> String {
        try await git(["symbolic-ref", "--short", "HEAD"], in: repo)
    }

    public func branchExists(repo: URL, branch: String) async -> Bool {
        (try? await run(["show-ref", "--verify", "--quiet", "refs/heads/\(branch)"], in: repo))?.status == 0
    }

    public func isTracked(repo: URL, path: String) async -> Bool {
        (try? await run(["ls-files", "--error-unmatch", "--", path], in: repo))?.status == 0
    }

    // MARK: - Worktrees

    public func createWorktree(repo: URL, branch: String, base: String, at path: URL) async throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A worktree that used to be at `path` and was deleted by hand still blocks the path until pruned.
        _ = try await run(["worktree", "prune"], in: repo)
        try await git(["worktree", "add", "-b", branch, path.path, base], in: repo)
    }

    public func addWorktree(repo: URL, branch: String, at path: URL) async throws {
        try FileManager.default.createDirectory(at: path.deletingLastPathComponent(), withIntermediateDirectories: true)
        _ = try await run(["worktree", "prune"], in: repo)
        try await git(["worktree", "add", path.path, branch], in: repo)
    }

    public func removeWorktree(repo: URL, path: URL, deleteBranch: String?) async throws {
        _ = try await run(["worktree", "remove", "--force", path.path], in: repo)
        // Git refuses when it no longer knows the worktree; the directory may still be there.
        if FileManager.default.fileExists(atPath: path.path) {
            try FileManager.default.removeItem(at: path)
        }
        _ = try await run(["worktree", "prune"], in: repo)
        if let branch = deleteBranch, await branchExists(repo: repo, branch: branch) {
            try await git(["branch", "-D", branch], in: repo)
        }
    }

    @discardableResult
    public func commitAll(worktree: URL, message: String) async throws -> Bool {
        try await git(["add", "-A"], in: worktree)
        if try await run(["diff", "--cached", "--quiet"], in: worktree).status == 0 { return false }
        // --no-verify: this is the app snapshotting the task, the project's hooks must not block it.
        try await git(["commit", "--no-verify", "-m", message], in: worktree)
        return true
    }

    // MARK: - Setup exclusions

    static let excludeMarker = "# Added by Shift: files created by project setup commands. Shift only appends below this line."
    /// One app process, one writer at a time: tasks set up in parallel share the file.
    private static let excludeLock = NSLock()

    /// Append only: never rewrites or removes a line, whoever wrote it.
    /// ponytail: entries are never removed and apply to every checkout of the repo; keep a
    /// per-worktree list and pass it as exclude pathspecs if that turns out to hide real work.
    public func excludeUntracked(worktree: URL) async throws {
        // --directory: one entry for node_modules, not one per file in it.
        let listed = try await git(["ls-files", "--others", "--exclude-standard", "--directory",
                                    "--no-empty-directory", "-z"], in: worktree, trim: false)
        let patterns = listed.components(separatedBy: "\0").filter { !$0.isEmpty }.map(Self.excludePattern)
        guard !patterns.isEmpty else { return }
        let file = URL(fileURLWithPath: try await git(
            ["rev-parse", "--path-format=absolute", "--git-path", "info/exclude"], in: worktree))

        try Self.excludeLock.withLock {
            let existing = String(decoding: (try? Data(contentsOf: file)) ?? Data(), as: UTF8.self)
            var known = Set(existing.components(separatedBy: "\n"))
            var lines = known.contains(Self.excludeMarker) ? [] : [Self.excludeMarker]
            for pattern in patterns where known.insert(pattern).inserted { lines.append(pattern) }
            guard lines.last != Self.excludeMarker else { return }

            let text = (existing.isEmpty || existing.hasSuffix("\n") ? "" : "\n") + lines.joined(separator: "\n") + "\n"
            let manager = FileManager.default
            try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !manager.fileExists(atPath: file.path) { manager.createFile(atPath: file.path, contents: nil) }
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(text.utf8))
        }
    }

    /// Anchored gitignore pattern that matches exactly `path` (relative to the worktree root, a
    /// directory ends in "/"). The leading "/" also takes care of a leading "#" or "!".
    static func excludePattern(for path: String) -> String {
        var pattern = "/"
        for scalar in path.unicodeScalars {
            switch scalar {
            case "\\", "*", "?", "[": pattern += "\\\(scalar)"
            // A line cannot hold these, and U+FFFD is a byte that was not UTF-8: match them with a wildcard.
            case "\n", "\r": pattern += "?"
            case "\u{FFFD}": pattern += "*"
            default: pattern.unicodeScalars.append(scalar)
            }
        }
        // Git drops trailing spaces unless they are escaped.
        if pattern.unicodeScalars.last == " " { pattern = String(pattern.dropLast()) + "\\ " }
        return pattern
    }

    // MARK: - Diff

    public func changes(worktree: URL, base: String) async throws -> DiffSummary {
        DiffSummary(files: try await diff(worktree: worktree, base: base).map(\.change))
    }

    public func diff(worktree: URL, base: String) async throws -> [FileDiff] {
        let mergeBase = try await git(["merge-base", base, "HEAD"], in: worktree)

        // Stage everything into a throwaway index so untracked and uncommitted files are
        // included without touching the worktree's real index.
        let index = FileManager.default.temporaryDirectory.appendingPathComponent("shift-index-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: index)
            try? FileManager.default.removeItem(atPath: index.path + ".lock")
        }
        let realIndex = try await git(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: worktree)
        try? FileManager.default.copyItem(atPath: realIndex, toPath: index.path) // keeps the stat cache: fast add
        let env = ["GIT_INDEX_FILE": index.path]
        try await git(["add", "-A"], in: worktree, env: env)

        let diffArgs = ["diff", "--cached", "-M", "--no-color", "--no-ext-diff", "--no-textconv"]
        let status = try await git(diffArgs + ["--name-status", "-z", mergeBase], in: worktree, env: env)
        let patch = try await git(diffArgs + ["--patch", mergeBase], in: worktree, env: env, trim: false)
        return Self.parse(nameStatus: status, patch: patch)
    }

    /// `nameStatus` is `git diff --name-status -z`, `patch` is `git diff --patch` of the same diff.
    /// Paths come from the -z output (never quoted); the patch sections are in the same order.
    static func parse(nameStatus: String, patch: String) -> [FileDiff] {
        // A line starting with "diff --git " is always a file header: hunk lines start with " ", "+", "-" or "\".
        var sections: [[String]] = []
        for line in patch.components(separatedBy: "\n") {
            if line.hasPrefix("diff --git ") { sections.append([]) } else if !sections.isEmpty { sections[sections.count - 1].append(line) }
        }
        var nextSection = 0
        func takeSection() -> [String] {
            defer { nextSection += 1 }
            return nextSection < sections.count ? sections[nextSection] : []
        }

        var result: [FileDiff] = []
        var tokens = nameStatus.components(separatedBy: "\0").makeIterator()
        while let status = tokens.next(), let letter = status.first, let first = tokens.next() {
            var change: FileChange
            switch letter {
            case "A": change = FileChange(path: first, kind: .added)
            case "D": change = FileChange(path: first, kind: .deleted)
            case "R", "C":
                guard let newPath = tokens.next() else { return result }
                change = FileChange(path: newPath, oldPath: first, kind: .renamed)
            default: change = FileChange(path: first, kind: .modified)
            }
            var lines = takeSection()
            // A type change (file <-> symlink) is printed as a delete followed by an add.
            if letter == "T" { lines += takeSection() }

            var hunks: [DiffHunk] = []
            var old = 0, new = 0
            for line in lines {
                if line.hasPrefix("@@") {
                    let parts = line.split(separator: " ")
                    guard parts.count >= 3 else { continue }
                    old = Int(parts[1].dropFirst().split(separator: ",")[0]) ?? 0
                    new = Int(parts[2].dropFirst().split(separator: ",")[0]) ?? 0
                    hunks.append(DiffHunk(header: line, lines: []))
                } else if hunks.isEmpty {
                    if line.hasPrefix("Binary files ") || line.hasPrefix("GIT binary patch") { change.isBinary = true }
                } else if let marker = line.unicodeScalars.first {
                    // unicodeScalars: a lone "\r" line from a CRLF file must not be merged into the marker.
                    let text = String(String.UnicodeScalarView(line.unicodeScalars.dropFirst()))
                    switch marker {
                    case " ":
                        hunks[hunks.count - 1].lines.append(DiffLine(kind: .context, text: text, oldNumber: old, newNumber: new))
                        old += 1; new += 1
                    case "+":
                        hunks[hunks.count - 1].lines.append(DiffLine(kind: .added, text: text, newNumber: new))
                        new += 1; change.additions += 1
                    case "-":
                        hunks[hunks.count - 1].lines.append(DiffLine(kind: .removed, text: text, oldNumber: old))
                        old += 1; change.deletions += 1
                    default: break // "\ No newline at end of file"
                    }
                }
            }
            result.append(FileDiff(change: change, hunks: hunks))
        }
        return result
    }

    // MARK: - Merge

    public func canMergeCleanly(repo: URL, branch: String, base: String) async throws -> Bool {
        try await mergedTree(repo: repo, branch: branch, base: base) != nil
    }

    /// A branch that never got a commit of its own is contained in base too, but nobody merged it.
    /// ponytail: "commits of its own" is read from the branch's reflog (more than the entry for its
    /// creation); record the starting commit on the task if reflogs turn out not to be reliable.
    public func isMerged(repo: URL, branch: String, base: String) async throws -> Bool {
        guard try await isAncestor(repo: repo, branch: branch, of: base) else { return false }
        let moves = try await git(["reflog", "show", "--format=%H", "refs/heads/\(branch)"], in: repo)
        return moves.split(separator: "\n").count > 1
    }

    private func isAncestor(repo: URL, branch: String, of base: String) async throws -> Bool {
        let out = try await run(["merge-base", "--is-ancestor", branch, base], in: repo)
        if out.status > 1 { throw GitError(message: out.stderr) }
        return out.status == 0
    }

    /// The merge is computed entirely in the object database (merge-tree + commit-tree), so a
    /// conflict is known before anything is touched and no working tree is ever half-merged.
    /// Only then is `base` moved: by a fast-forward where it is checked out (which keeps
    /// uncommitted changes, or refuses without touching anything), by update-ref otherwise.
    public func merge(repo: URL, branch: String, into base: String, message: String) async throws -> MergeResult {
        // Merged into itself it would count as merged, and cleaning up would delete it with its work.
        guard branch != base else {
            throw GitError(message: "\(branch) is the base branch itself. Pick another base branch to merge into.")
        }
        guard await branchExists(repo: repo, branch: base) else {
            throw GitError(message: "The branch \(base) no longer exists in \(repo.lastPathComponent).")
        }
        guard await branchExists(repo: repo, branch: branch) else {
            throw GitError(message: "The task's branch \(branch) no longer exists.")
        }
        if try await isAncestor(repo: repo, branch: branch, of: base) { return .merged }
        guard let tree = try await mergedTree(repo: repo, branch: branch, base: base) else { return .conflict }

        let baseTip = try await git(["rev-parse", "--verify", "refs/heads/\(base)^{commit}"], in: repo)
        let branchTip = try await git(["rev-parse", "--verify", "\(branch)^{commit}"], in: repo)
        let commit = try await git(["commit-tree", tree, "-p", baseTip, "-p", branchTip, "-m", message], in: repo)

        if let checkout = try await worktree(of: base, repo: repo) {
            guard try await git(["rev-parse", "HEAD"], in: checkout) == baseTip else {
                throw GitError(message: "\(base) changed while merging. Try again.")
            }
            let out = try await run(["merge", "--ff-only", "--no-stat", commit], in: checkout)
            guard out.status == 0 else {
                throw GitError(message: Self.mergeFailure(out.stderr, checkout: checkout, base: base))
            }
        } else {
            try await git(["update-ref", "-m", "merge \(branch): \(message)", "refs/heads/\(base)", commit, baseTip], in: repo)
        }
        return .merged
    }

    /// Plain language for git refusing to fast-forward the checkout of `base`: usually uncommitted
    /// changes there that the merge would overwrite. Anything else: git's first line.
    static func mergeFailure(_ stderr: String, checkout: URL, base: String) -> String {
        let lines = stderr.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0.contains("would be overwritten by merge") }) else {
            let first = lines.first { !$0.trimmingCharacters(in: .whitespaces).isEmpty } ?? "git merge failed"
            return first.replacingOccurrences(of: #"^(error|fatal): "#, with: "", options: .regularExpression)
        }
        // The files are listed one per line, indented with a tab, right after that line.
        let files = lines[(start + 1)...].prefix { $0.hasPrefix("\t") }.map { $0.trimmingCharacters(in: .whitespaces) }
        var named = files.prefix(5).joined(separator: ", ")
        if files.count > 5 { named += " and \(files.count - 5) more" }
        return (files.isEmpty ? "" : "Uncommitted changes to \(named) would be overwritten. ")
            + "Commit or stash your changes in \(checkout.lastPathComponent) on \(base) first, then merge again."
    }

    /// Tree of merging `branch` into `base`, nil if they conflict. Touches no working tree or index.
    private func mergedTree(repo: URL, branch: String, base: String) async throws -> String? {
        let out = try await run(["merge-tree", "--write-tree", "--no-messages", base, branch], in: repo)
        switch out.status {
        case 0: return out.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        case 1: return nil
        default: throw GitError(message: out.stderr)
        }
    }

    /// The worktree (main or linked) that has `branch` checked out, if any.
    private func worktree(of branch: String, repo: URL) async throws -> URL? {
        var path: String?
        for line in try await git(["worktree", "list", "--porcelain"], in: repo).components(separatedBy: "\n") {
            if line.hasPrefix("worktree ") { path = String(line.dropFirst("worktree ".count)) }
            if line == "branch refs/heads/\(branch)", let path { return URL(fileURLWithPath: path) }
        }
        return nil
    }

    // MARK: - Push

    public func remote(repo: URL, branch: String) async -> String? {
        if let upstream = try? await git(["config", "--get", "branch.\(branch).remote"], in: repo),
           !upstream.isEmpty, upstream != "." { return upstream }
        let remotes = ((try? await git(["remote"], in: repo)) ?? "").split(separator: "\n").map(String.init)
        return remotes.contains("origin") ? "origin" : remotes.first
    }

    public func unpushedCount(repo: URL, branch: String, remote: String) async throws -> Int {
        let range = await remoteHasBranch(repo: repo, branch: branch, remote: remote)
            ? "refs/remotes/\(remote)/\(branch)..refs/heads/\(branch)" : "refs/heads/\(branch)"
        return Int(try await git(["rev-list", "--count", range], in: repo)) ?? 0
    }

    public func push(repo: URL, branch: String, remote: String) async throws {
        let publish = await !remoteHasBranch(repo: repo, branch: branch, remote: remote)
        let args = ["env", "-u", "GIT_DIR", "-u", "GIT_WORK_TREE", "-u", "GIT_INDEX_FILE", "/usr/bin/git",
                    "push"] + (publish ? ["-u"] : []) + [remote, branch]
        let command = args.map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
        // Through the login shell like the agents: credential helpers and SSH agents set up there (gh, a
        // Homebrew PATH, a custom SSH_AUTH_SOCK) must work from the app too. Nothing may ask for a password:
        // an empty GIT_ASKPASS also overrides core.askPass and SSH_ASKPASS.
        let env = ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "", "SSH_ASKPASS": "", "SSH_ASKPASS_REQUIRE": "never",
                   "LC_ALL": "C"]
        let work = Task { try await runShellCommand(command, directory: repo, environment: env) }
        let timeout = pushTimeout
        let timer = Task {
            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
            work.cancel()
        }
        defer { timer.cancel() }
        let result = try await work.value
        guard result.exitCode != 0 else { return }
        if work.isCancelled { throw GitError(message: "Pushing to \(remote) took too long and was stopped. Try again.") }
        let url = (try? await git(["remote", "get-url", remote], in: repo)) ?? remote
        throw GitError(message: Self.pushFailure(result.output, remote: remote, url: url, branch: branch))
    }

    private func remoteHasBranch(repo: URL, branch: String, remote: String) async -> Bool {
        (try? await run(["show-ref", "--verify", "--quiet", "refs/remotes/\(remote)/\(branch)"], in: repo))?.status == 0
    }

    /// Plain language for the usual ways a push fails; anything else: git's first line.
    static func pushFailure(_ output: String, remote: String, url: String, branch: String) -> String {
        func has(_ needles: String...) -> Bool { needles.contains { output.localizedCaseInsensitiveContains($0) } }
        if has("[rejected]", "non-fast-forward", "fetch first") {
            return "The remote has changes that aren't in your \(branch). Pull them in your usual Git tool, then push again."
        }
        if has("Authentication failed", "could not read Username", "could not read Password", "Permission denied (",
               "terminal prompts disabled", "Invalid username or password", "returned error: 403", "returned error: 401") {
            return "Couldn't sign in to \(host(of: url)). Check your Git credentials."
        }
        if has("Could not resolve host", "Could not resolve hostname", "Connection refused", "Connection timed out",
               "Operation timed out", "Network is unreachable", "Failed to connect", "Connection reset", "unable to access") {
            return "Couldn't reach \(host(of: url)). Check your internet connection and try again."
        }
        // The login shell's own output may come first: git's error line, if there is one, says the most.
        let lines = output.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let line = lines.first { $0.hasPrefix("fatal: ") || $0.hasPrefix("error: ") } ?? lines.first ?? "git push failed"
        return "Could not push to \(remote): "
            + line.trimmingCharacters(in: .whitespaces)
                .replacingOccurrences(of: #"^(error|fatal): "#, with: "", options: .regularExpression)
    }

    /// "github.com" for https://github.com/a/b.git, ssh://git@host:22/x and git@github.com:a/b.git; else the URL.
    static func host(of url: String) -> String {
        if url.contains("://") { return URL(string: url)?.host ?? url }
        if let colon = url.firstIndex(of: ":"), !url[..<colon].contains("/") {
            return String(url[..<colon].split(separator: "@").last ?? Substring(url))
        }
        return url
    }

    // MARK: - Process

    private struct Output { var status: Int32; var stdout: String; var stderr: String }

    /// Runs git and throws git's stderr on a non-zero exit. Returns trimmed stdout.
    @discardableResult
    private func git(_ args: [String], in dir: URL, env: [String: String] = [:], trim: Bool = true) async throws -> String {
        let out = try await run(args, in: dir, env: env)
        guard out.status == 0 else {
            throw GitError(message: out.stderr.isEmpty ? "git \(args.first ?? "") failed (\(out.status))" : out.stderr)
        }
        return trim ? out.stdout.trimmingCharacters(in: .whitespacesAndNewlines) : out.stdout
    }

    private func run(_ args: [String], in dir: URL, env: [String: String] = [:]) async throws -> Output {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global().async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
                process.arguments = args
                process.currentDirectoryURL = dir
                var environment = ProcessInfo.processInfo.environment
                for key in ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE"] { environment[key] = nil }
                environment["GIT_TERMINAL_PROMPT"] = "0"
                environment["LC_ALL"] = "C"
                process.environment = environment.merging(env) { $1 }
                let out = Pipe(), err = Pipe()
                process.standardOutput = out
                process.standardError = err
                process.standardInput = FileHandle.nullDevice
                do { try process.run() } catch { return continuation.resume(throwing: error) }

                // Drain both pipes at once, or a chatty git blocks on the one nobody reads.
                var errData = Data()
                let group = DispatchGroup()
                DispatchQueue.global().async(group: group) { errData = err.fileHandleForReading.readDataToEndOfFile() }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                process.waitUntilExit()
                continuation.resume(returning: Output(
                    status: process.terminationStatus,
                    stdout: String(decoding: outData, as: UTF8.self),
                    stderr: String(decoding: errData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)))
            }
        }
    }
}
