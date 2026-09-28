import Foundation

/// posix_spawn rather than Foundation's Process: the child leads its own process group
/// (pgid == pid), so it can be signalled together with everything it started.
/// `files` wires up descriptors 0-2; every other descriptor is closed in the child.
func spawnProcessGroup(_ executable: String, _ arguments: [String], environment: [String: String],
                       directory: URL, files: (inout posix_spawn_file_actions_t?) -> Void) throws -> pid_t {
    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addchdir_np(&actions, directory.path)
    files(&actions)

    var attributes: posix_spawnattr_t?
    posix_spawnattr_init(&attributes)
    defer { posix_spawnattr_destroy(&attributes) }
    posix_spawnattr_setpgroup(&attributes, 0)
    // Default signal handling and an empty mask: whatever we ignore or block would be
    // inherited, and a child that inherits an ignored SIGTERM cannot be stopped politely.
    var allSignals = sigset_t(), noSignals = sigset_t()
    sigfillset(&allSignals)
    sigemptyset(&noSignals)
    posix_spawnattr_setsigdefault(&attributes, &allSignals)
    posix_spawnattr_setsigmask(&attributes, &noSignals)
    posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT
        | POSIX_SPAWN_SETSIGDEF | POSIX_SPAWN_SETSIGMASK))

    let argv: [UnsafeMutablePointer<CChar>?] = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp: [UnsafeMutablePointer<CChar>?] = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer { (argv + envp).forEach { free($0) } }

    var pid: pid_t = 0
    let result = posix_spawn(&pid, executable, &actions, &attributes, argv, envp)
    guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: result) ?? .EIO) }
    return pid
}

/// Tracks one spawned process group so that it can be killed from another thread.
final class RunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pid: pid_t = 0
    private var cancelled = false
    private var exited = false

    /// Returns false if the run was cancelled before the process started.
    func started(_ pid: pid_t) -> Bool {
        lock.withLock {
            self.pid = pid
            return !cancelled
        }
    }

    func markExited() { lock.withLock { exited = true } }

    /// Signals the whole process group (the process and everything it started).
    func cancel(_ signal: Int32 = SIGTERM) {
        lock.withLock {
            cancelled = true
            if pid > 0 && !exited { kill(-pid, signal) }
        }
    }
}

/// Runs `command` through the user's login shell, unsandboxed, and returns once it has exited.
/// Cancelling the calling task kills the command and its children.
/// ponytail: output is collected and returned at the end; stream it if setup logs need to be live.
func runShellCommand(_ command: String, directory: URL, environment: [String: String],
                     grace: TimeInterval = 2) async throws -> CommandResult {
    let control = RunControl()
    return try await withTaskCancellationHandler {
        try await withCheckedThrowingContinuation { continuation in
            Thread.detachNewThread {
                continuation.resume(with: Result {
                    try runShellCommand(command, directory: directory, environment: environment, control: control)
                })
            }
        }
    } onCancel: {
        control.cancel()
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { control.cancel(SIGKILL) }
    }
}

private func runShellCommand(_ command: String, directory: URL, environment: [String: String],
                             control: RunControl) throws -> CommandResult {
    let environment = AgentEnvironment.loginShell.merging(environment) { _, new in new }
    let shell = environment["SHELL"] ?? "/bin/zsh"
    let output = Pipe()
    let pid: pid_t
    do {
        pid = try spawnProcessGroup(shell, ["-lc", command], environment: environment, directory: directory) {
            posix_spawn_file_actions_addopen(&$0, 0, "/dev/null", O_RDONLY, 0)
            posix_spawn_file_actions_adddup2(&$0, output.fileHandleForWriting.fileDescriptor, 1)
            posix_spawn_file_actions_adddup2(&$0, 1, 2)
        }
    } catch {
        try? output.fileHandleForWriting.close()
        throw error
    }
    // Close our copy of the child's end, or the pipe never reaches end-of-file.
    try? output.fileHandleForWriting.close()
    guard control.started(pid) else {
        kill(-pid, SIGKILL)
        waitpid(pid, nil, 0)
        throw CancellationError()
    }

    let collected = Collected()
    let done = DispatchSemaphore(value: 0)
    Thread.detachNewThread {
        collected.data = output.fileHandleForReading.readDataToEndOfFile()
        done.signal()
    }
    var raw: Int32 = 0
    while waitpid(pid, &raw, 0) == -1 && errno == EINTR {}
    control.markExited()
    // Whatever the command left running goes too, which also guarantees end-of-file.
    kill(-pid, SIGKILL)
    done.wait()
    return CommandResult(exitCode: raw & 0x7f == 0 ? (raw >> 8) & 0xff : 128 + (raw & 0x7f),
                         output: String(decoding: collected.data, as: UTF8.self))
}

private final class Collected: @unchecked Sendable { var data = Data() }
