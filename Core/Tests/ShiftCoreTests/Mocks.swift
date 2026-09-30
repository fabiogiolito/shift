import Foundation
import Observation
import XCTest
@testable import ShiftCore

// Mocks for every service protocol. All main-actor and @Observable, so tests can read them
// directly and `waitFor` can wait on them.

struct MockError: LocalizedError {
    var message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// Holds whoever waits on it until the test opens it. Deliberately ignores cancellation, to stand in
/// for work that finishes late, after the orchestrator has moved on.
@MainActor @Observable
final class Gate {
    private(set) var waiting = 0
    /// How many waiters had their task cancelled while held here.
    private(set) var cancellations = 0
    private var isOpen = false
    @ObservationIgnored private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        waiting += 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: {
            Task { @MainActor in self.cancellations += 1 }
        }
    }

    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

@MainActor @Observable
final class MockGit: GitServicing {
    var isRepo = true
    var branchList = ["main"]
    var current = "main"
    var existingBranches: Set<String> = []
    var canMerge = true
    var mergeResult = MergeResult.merged
    var merged = false
    var pendingChanges = DiffSummary()
    var createError: Error?
    var commitError: Error?
    var excludeError: Error?
    var mergeError: Error?
    var createGate: Gate?
    var trackedPaths: Set<String> = []
    var canMergeGate: Gate?
    /// Every mutating call in order, e.g. "create shift/3001", "remove shift/3001".
    private(set) var calls: [String] = []

    func isRepository(_ url: URL) async -> Bool { isRepo }
    func branches(repo: URL) async throws -> [String] { branchList }
    func currentBranch(repo: URL) async throws -> String { current }

    var createBranchError: Error?
    func createBranch(repo: URL, name: String, from source: String) async throws {
        if let createBranchError { throw createBranchError }
        branchList.append(name)
        calls.append("branch \(name) from \(source)")
    }

    // Worktree folders are real (the orchestrator checks for them), so tests keep them in a temp directory.
    func createWorktree(repo: URL, branch: String, base: String, at path: URL) async throws {
        await createGate?.wait()
        if let createError { throw createError }
        existingBranches.insert(branch)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        calls.append("create \(branch) from \(base)")
    }

    func addWorktree(repo: URL, branch: String, at path: URL) async throws {
        if let createError { throw createError }
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: true)
        calls.append("add \(branch)")
    }

    func removeWorktree(repo: URL, path: URL, deleteBranch: String?) async throws {
        if let deleteBranch { existingBranches.remove(deleteBranch) }
        try? FileManager.default.removeItem(at: path)
        calls.append("remove \(deleteBranch ?? path.lastPathComponent)")
    }

    func commitAll(worktree: URL, message: String) async throws -> Bool {
        if let commitError { throw commitError }
        calls.append("commit \(worktree.lastPathComponent)")
        return true
    }

    func excludeUntracked(worktree: URL) async throws {
        if let excludeError { throw excludeError }
        calls.append("exclude \(worktree.lastPathComponent)")
    }

    var diffError: Error?

    func changes(worktree: URL, base: String) async throws -> DiffSummary {
        if let diffError { throw diffError }
        return pendingChanges
    }
    func diff(worktree: URL, base: String) async throws -> [FileDiff] {
        if let diffError { throw diffError }
        return pendingChanges.files.map { FileDiff(change: $0, hunks: []) }
    }

    func canMergeCleanly(repo: URL, branch: String, base: String) async throws -> Bool {
        await canMergeGate?.wait()
        return canMerge
    }

    func merge(repo: URL, branch: String, into base: String, message: String) async throws -> MergeResult {
        if let mergeError { throw mergeError }
        calls.append("merge \(branch) into \(base)")
        return mergeResult
    }

    func isTracked(repo: URL, path: String) async -> Bool { trackedPaths.contains(path) }

    var contained = true
    func isContained(repo: URL, branch: String, in base: String) async throws -> Bool { contained }

    var rebaseClean = true
    func rebase(worktree: URL, from oldBase: String, onto newBase: String) async throws -> Bool {
        calls.append("rebase \(worktree.lastPathComponent) from \(oldBase) onto \(newBase)")
        return rebaseClean
    }
    func isMerged(repo: URL, branch: String, base: String) async throws -> Bool { merged }
    func branchExists(repo: URL, branch: String) async -> Bool { existingBranches.contains(branch) || branchList.contains(branch) }

    var remoteName: String? = "origin"
    var unpushed = 0
    var pushError: Error?
    var pushGate: Gate?

    func remote(repo: URL, branch: String) async -> String? { remoteName }
    func unpushedCount(repo: URL, branch: String, remote: String) async throws -> Int { unpushed }
    func push(repo: URL, branch: String, remote: String) async throws {
        await pushGate?.wait()
        if let pushError { throw pushError }
        calls.append("push \(branch) to \(remote)")
        unpushed = 0
    }
}

/// Scriptable agent: each run plays the next script. With no script left it completes at once.
@MainActor @Observable
final class MockAgent: AgentAdapter {
    enum Step {
        case emit(AgentEvent)
        /// Pause until the test opens the gate.
        case pause(Gate)
        /// Emit `.approvalRequested` and wait for its answer.
        case ask(id: String, summary: String)
        /// From here on, take follow-ups into this run.
        case listen
    }

    struct Answer: Equatable {
        var id: String
        var allow: Bool
        var message: String?
    }

    nonisolated let kind: AgentKind
    /// Whether a denial's message reaches the agent (Claude Code: yes, Codex: no).
    nonisolated let takesMessages: Bool
    /// Whether follow-up instructions reach the running session.
    var takesFollowUps = false
    /// Follow-ups received while running, in order.
    private(set) var followUps: [String] = []
    var installation: AgentInstallation? = AgentInstallation(path: "/usr/local/bin/agent")
    var scripts: [[Step]]
    private(set) var requests: [AgentRequest] = []
    private(set) var answers: [Answer] = []
    /// Runs whose consumer went away (cancelled or finished reading).
    private(set) var terminated = 0

    init(kind: AgentKind = .claudeCode, takesMessages: Bool = true, scripts: [[Step]] = []) {
        self.kind = kind
        self.takesMessages = takesMessages
        self.scripts = scripts
    }

    func detect() async -> AgentInstallation? { installation }

    nonisolated func run(_ request: AgentRequest) -> AsyncStream<AgentEvent> {
        AsyncStream { continuation in
            continuation.onTermination = { _ in Task { @MainActor in self.terminated += 1 } }
            Task { @MainActor in
                self.requests.append(request)
                let script = self.scripts.isEmpty
                    ? [.emit(.finished(.completed(summary: "Done")))] : self.scripts.removeFirst()
                func listen() {
                    request.approvals.onMessage { text in
                        MainActor.assumeIsolated { self.followUps.append(text) }
                        return true
                    }
                }
                if self.takesFollowUps { listen() }
                defer { request.approvals.onMessage(nil) }
                for step in script {
                    switch step {
                    case .emit(let event): continuation.yield(event)
                    case .pause(let gate): await gate.wait()
                    case .listen: listen()
                    case .ask(let id, let summary):
                        let takesMessages = self.takesMessages
                        await withCheckedContinuation { (answered: CheckedContinuation<Void, Never>) in
                            request.approvals.onAnswer { answerID, allow, message in
                                guard answerID == id else { return false }
                                request.approvals.onAnswer(nil)
                                Task { @MainActor in
                                    self.answers.append(Answer(id: answerID, allow: allow, message: message))
                                    answered.resume()
                                }
                                return takesMessages && message != nil
                            }
                            continuation.yield(.approvalRequested(id: id, summary: summary))
                        }
                    }
                }
                continuation.finish()
            }
        }
    }
}

@MainActor @Observable
final class MockServers: ServerManaging {
    struct Start: Equatable { var taskID: Int; var command: String; var port: Int }

    struct Run: Equatable { var command: String; var directory: String; var environment: [String: String] }

    var startError: Error?
    var runResult = CommandResult(exitCode: 0)
    var runGate: Gate?
    private(set) var runs: [Run] = []
    private(set) var starts: [Start] = []
    private(set) var running: [Int: Int32] = [:]
    private(set) var stoppedOrphans: [Int32] = []
    private(set) var stoppedAll = false
    private var nextPID: Int32 = 500

    /// Projects' base servers (negative IDs), kept apart so the task assertions above stay exact.
    private(set) var baseStarts: [Start] = []
    private(set) var baseRunning: Set<Int> = []
    /// Base servers quit as soon as they start.
    var exitOnStart = false

    func start(taskID: Int, command: String, directory: URL, port: Int) async throws -> Int32 {
        if taskID < 0 {
            baseStarts.append(Start(taskID: taskID, command: command, port: port))
            if !exitOnStart { baseRunning.insert(taskID) }
            return 1
        }
        if let startError { throw startError }
        nextPID += 1
        starts.append(Start(taskID: taskID, command: command, port: port))
        running[taskID] = nextPID
        return nextPID
    }

    func run(command: String, directory: URL, environment: [String: String]) async throws -> CommandResult {
        runs.append(Run(command: command, directory: directory.path, environment: environment))
        await runGate?.wait()
        return runResult
    }

    var logs: [Int: String] = [:]

    func log(taskID: Int, lines: Int) async -> String { logs[taskID] ?? "" }
    func stop(taskID: Int) async { running[taskID] = nil; baseRunning.remove(taskID) }
    /// A server that died on its own.
    func crash(taskID: Int) { running[taskID] = nil; baseRunning.remove(taskID) }
    func stopOrphan(pid: Int32) async { stoppedOrphans.append(pid) }
    func isRunning(taskID: Int) async -> Bool { running[taskID] != nil || baseRunning.contains(taskID) }
    func stopAll() async {
        running = [:]
        baseRunning = []
        stoppedAll = true
    }
}

@MainActor
final class MockPorts: PortAllocating {
    var taken: Set<Int> = []

    func allocate(preferred: Int, reserved: Set<Int>) async -> Int {
        var port = preferred
        while taken.contains(port) || reserved.contains(port) { port += 1 }
        return port
    }
}

@MainActor @Observable
final class MockNotifier: Notifying {
    struct Notification: Equatable { var title: String; var body: String; var taskID: Int }

    private(set) var notifications: [Notification] = []
    private(set) var badges: [Int] = []

    func requestAuthorization() async {}
    func notify(title: String, body: String, taskID: Int) async {
        notifications.append(Notification(title: title, body: body, taskID: taskID))
    }
    func setBadge(count: Int) async { badges.append(count) }
}

@MainActor @Observable
final class MockStore: StateStoring {
    var state = AppState()
    private(set) var saves = 0
    private(set) var logs: [Int: String] = [:]

    func load() async -> AppState { state }
    func save(_ state: AppState) async {
        self.state = state
        saves += 1
    }
    func appendLog(taskID: Int, text: String) async { logs[taskID, default: ""] += text }
    func readLog(taskID: Int) async -> String { logs[taskID] ?? "" }
    func deleteLog(taskID: Int) async { logs[taskID] = nil }
}

// MARK: - Waiting

/// Suspends until `condition` holds, woken by Observation when something it read changes.
/// No polling and no sleeping; the timeout only exists so a broken test fails instead of hanging.
@MainActor
func waitFor(_ what: String, timeout: TimeInterval = 5, file: StaticString = #filePath, line: UInt = #line,
             _ condition: @escaping @MainActor () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition() {
        guard Date() < deadline else {
            XCTFail("Timed out waiting for \(what)", file: file, line: line)
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            let wake = Wake(continuation)
            wake.watchdog = Task { @MainActor in
                try? await Task.sleep(for: .seconds(timeout))
                wake.fire()
            }
            withObservationTracking { _ = condition() } onChange: {
                Task { @MainActor in wake.fire() }
            }
        }
    }
}

@MainActor
private final class Wake {
    private var continuation: CheckedContinuation<Void, Never>?
    var watchdog: Task<Void, Never>?

    init(_ continuation: CheckedContinuation<Void, Never>) { self.continuation = continuation }

    func fire() {
        continuation?.resume()
        continuation = nil
        watchdog?.cancel()
    }
}
