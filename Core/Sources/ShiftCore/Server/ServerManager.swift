import Foundation

public actor ServerManager: ServerManaging {
    private let logDirectory: URL
    private let worktreesDirectory: URL
    /// taskID -> pid of the process group leader (pgid == pid). Always our own unreaped child,
    /// so the pid cannot have been reused by anything else.
    private var servers: [Int: pid_t] = [:]

    static let grace: TimeInterval = 2

    public init(logDirectory: URL = ShiftPaths.logs, worktreesDirectory: URL = ShiftPaths.worktrees) {
        self.logDirectory = logDirectory
        self.worktreesDirectory = worktreesDirectory
    }

    public func start(taskID: Int, command: String, directory: URL, port: Int) async throws -> Int32 {
        // Loop: another start for the same task may have slipped in while we awaited stop.
        while servers[taskID] != nil { await stop(taskID: taskID) }
        let pid = try spawn(taskID: taskID, command: command, directory: directory, port: port)
        servers[taskID] = pid
        return pid
    }

    public func stop(taskID: Int) async {
        guard let pid = servers.removeValue(forKey: taskID) else { return }
        await Self.terminate(group: pid, isChild: true)
    }

    public func stopAll() async {
        let pids = Array(servers.values)
        servers.removeAll()
        await withTaskGroup(of: Void.self) { group in
            for pid in pids { group.addTask { await Self.terminate(group: pid, isChild: true) } }
        }
    }

    public func isRunning(taskID: Int) async -> Bool {
        guard let pid = servers[taskID] else { return false }
        if !Self.hasExited(pid) { return true }
        // Leader is gone; anything left of its tree is not a working server. Clean up.
        servers[taskID] = nil
        Task.detached { await Self.terminate(group: pid, isChild: true) }
        return false
    }

    public nonisolated func log(taskID: Int, lines: Int) async -> String {
        guard let handle = FileHandle(forReadingAtPath: logPath(taskID)) else { return "" }
        defer { try? handle.close() }
        // ponytail: only the last 64 KB are read; plenty for a couple hundred lines.
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 65_536 ? size - 65_536 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        var all = text.components(separatedBy: "\n")
        if all.last == "" { all.removeLast() }
        return all.suffix(lines).joined(separator: "\n")
    }

    private nonisolated func logPath(_ taskID: Int) -> String {
        logDirectory.appendingPathComponent("server-\(taskID).log").path
    }

    public func stopOrphan(pid: Int32) async {
        // The pid comes from disk and may now belong to anything. Only kill if it is still a
        // process group whose leader (or, if the leader died, every member) runs under our
        // worktrees directory.
        guard pid > 1, pid != getpid(), pid != getpgrp(), !servers.values.contains(pid),
              let root = Self.realPath(worktreesDirectory.path) else { return }
        let members = Self.members(ofGroup: pid)
        let check = members.contains(pid) ? [pid] : members
        guard !check.isEmpty, check.allSatisfy({ member in
            guard let cwd = Self.cwd(of: member) else { return false }
            return cwd == root || cwd.hasPrefix(root + "/")
        }) else { return }
        await Self.terminate(group: pid, isChild: false)
    }

    public nonisolated func run(command: String, directory: URL,
                                environment: [String: String]) async throws -> CommandResult {
        try await runShellCommand(command, directory: directory, environment: environment, grace: Self.grace)
    }

    // MARK: - Process plumbing

    private func spawn(taskID: Int, command: String, directory: URL, port: Int) throws -> pid_t {
        try FileManager.default.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        // Each start gets a fresh log, so a restart shows only the new server's output.
        let log = logPath(taskID)

        var environment = ProcessInfo.processInfo.environment
        environment["PORT"] = String(port)
        let shell = environment["SHELL"] ?? "/bin/zsh"
        return try spawnProcessGroup(shell, ["-lc", command], environment: environment, directory: directory) {
            posix_spawn_file_actions_addopen(&$0, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_addopen(&$0, 1, log, O_WRONLY | O_CREAT | O_TRUNC, 0o644)
            posix_spawn_file_actions_adddup2(&$0, 1, 2)
        }
    }

    /// SIGTERM the group, SIGKILL whatever is left after the grace period.
    /// `isChild`: the leader is our own child, which we must reap (and whose zombie keeps the
    /// pid reserved until we do, so the signals cannot hit a recycled pid).
    private static func terminate(group pid: pid_t, isChild: Bool) async {
        killpg(pid, SIGTERM)
        let deadline = Date().addingTimeInterval(grace)
        while Date() < deadline, !isGone(group: pid, isChild: isChild) {
            guard (try? await Task.sleep(nanoseconds: 50_000_000)) != nil else { break }
        }
        killpg(pid, SIGKILL)
        if isChild {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
        }
    }

    private static func isGone(group pid: pid_t, isChild: Bool) -> Bool {
        guard members(ofGroup: pid).allSatisfy({ $0 == pid }) else { return false }
        return isChild ? hasExited(pid) : kill(pid, 0) != 0
    }

    /// True once our child has exited. Does not reap it.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = siginfo_t()
        let result = waitid(P_PID, id_t(pid), &info, WEXITED | WNOHANG | WNOWAIT)
        return result != 0 || info.si_pid == pid
    }

    private static func members(ofGroup pgid: pid_t) -> [pid_t] {
        var pids = [pid_t](repeating: 0, count: 1024)
        let count = proc_listpgrppids(pgid, &pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return count > 0 ? pids.prefix(Int(count)).filter { $0 > 0 } : []
    }

    private static func cwd(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: &info.pvi_cdir.vip_path) {
            $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }

    private static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}
