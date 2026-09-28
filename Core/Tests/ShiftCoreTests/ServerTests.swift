import XCTest
@testable import ShiftCore

final class ServerTests: XCTestCase {
    var temp: URL!
    var worktrees: URL!
    var manager: ServerManager!

    override func setUp() async throws {
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("shift-server-\(UUID().uuidString)")
        worktrees = temp.appendingPathComponent("worktrees")
        try FileManager.default.createDirectory(at: worktrees, withIntermediateDirectories: true)
        manager = makeManager()
    }

    override func tearDown() async throws {
        await manager.stopAll()
        try? FileManager.default.removeItem(at: temp)
    }

    func makeManager() -> ServerManager {
        ServerManager(logDirectory: temp.appendingPathComponent("logs"), worktreesDirectory: worktrees)
    }

    func alive(_ pid: pid_t) -> Bool { kill(pid, 0) == 0 }

    func eventually(timeout: TimeInterval = 5, _ condition: @escaping () -> Bool) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return condition()
    }

    /// Starts a server that backgrounds a child, and returns (leader pid, child pid).
    func startTree(_ manager: ServerManager, taskID: Int, in directory: URL) async throws -> (pid_t, pid_t) {
        let pidFile = directory.appendingPathComponent("child-\(taskID).pid")
        try? FileManager.default.removeItem(at: pidFile)
        let pid = try await manager.start(
            taskID: taskID, command: "sleep 31337 & echo $! > child-\(taskID).pid; sleep 31337",
            directory: directory, port: 4000)
        var child: pid_t = 0
        let found = await eventually {
            child = (try? String(contentsOf: pidFile, encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            return child > 0
        }
        XCTAssertTrue(found, "child pid file never appeared")
        return (pid, child)
    }

    // MARK: - Ports

    func testAllocatorSkipsUsedAndReservedPorts() async throws {
        let allocator = PortAllocator()
        let port = await allocator.allocate(preferred: 41000, reserved: [])

        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bound, 0)
        XCTAssertEqual(listen(fd, 1), 0)

        let next = await allocator.allocate(preferred: port, reserved: [port + 1])
        XCTAssertGreaterThanOrEqual(next, port + 2)
        let free = await allocator.allocate(preferred: next, reserved: [])
        XCTAssertEqual(free, next)
    }

    /// Found end to end: after a dev server stopped, its port read as busy for half a minute.
    func testPortOfStoppedServerIsFree() async throws {
        let port = await PortAllocator().allocate(preferred: 41100, reserved: [])
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(port).bigEndian
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let size = socklen_t(MemoryLayout<sockaddr_in>.size)

        let server = socket(AF_INET, SOCK_STREAM, 0), client = socket(AF_INET, SOCK_STREAM, 0)
        try withUnsafePointer(to: &address) {
            try $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                XCTAssertEqual(Darwin.bind(server, $0, size), 0)
                XCTAssertEqual(listen(server, 1), 0)
                XCTAssertEqual(connect(client, $0, size), 0)
            }
        }
        XCTAssertFalse(PortAllocator.isFree(port))
        let accepted = accept(server, nil, nil)
        // The server closes first, which leaves its side of the connection in TIME_WAIT.
        close(accepted)
        close(client)
        close(server)
        XCTAssertTrue(PortAllocator.isFree(port))
    }

    // MARK: - Servers

    func testStopKillsWholeTree() async throws {
        let (pid, child) = try await startTree(manager, taskID: 1, in: temp)
        XCTAssertEqual(getpgid(pid), pid, "server must lead its own process group")
        XCTAssertEqual(getpgid(child), pid)
        XCTAssertNotEqual(getpgrp(), pid)
        let running = await manager.isRunning(taskID: 1)
        XCTAssertTrue(running)

        await manager.stop(taskID: 1)
        let stillRunning = await manager.isRunning(taskID: 1)
        XCTAssertFalse(stillRunning)
        XCTAssertFalse(alive(pid))
        let childDead = await eventually { !self.alive(child) }
        XCTAssertTrue(childDead, "grandchild survived stop")
        await manager.stop(taskID: 1) // nothing running: must be a no-op
    }

    func testStopKillsProcessesThatIgnoreSIGTERM() async throws {
        let pid = try await manager.start(
            taskID: 2, command: "trap '' TERM; sh -c 'trap \"\" TERM; sleep 31337; sleep 31337' & echo $! > stubborn.pid; while true; do sleep 1; done",
            directory: temp, port: 4000)
        var child: pid_t = 0
        let found = await eventually {
            child = (try? String(contentsOf: self.temp.appendingPathComponent("stubborn.pid"), encoding: .utf8))
                .flatMap { pid_t($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
            return child > 0
        }
        XCTAssertTrue(found)
        await manager.stop(taskID: 2)
        XCTAssertFalse(alive(pid))
        let childDead = await eventually { !self.alive(child) }
        XCTAssertTrue(childDead)
        // The sleeps under the stubborn shells were in the group too.
        let members = await eventually { getpgid(child) == -1 }
        XCTAssertTrue(members)
    }

    func testPortAndOutputReachLog() async throws {
        _ = try await manager.start(taskID: 3, command: "echo port=$PORT; pwd; echo oops >&2; sleep 31337",
                                    directory: worktrees, port: 4321)
        let log = temp.appendingPathComponent("logs/server-3.log")
        var text = ""
        let written = await eventually {
            text = (try? String(contentsOf: log, encoding: .utf8)) ?? ""
            return text.contains("oops")
        }
        XCTAssertTrue(written, "log was: \(text)")
        XCTAssertTrue(text.contains("port=4321"))
        XCTAssertTrue(text.contains(worktrees.lastPathComponent))
    }

    func testLogIsTheTailOfTheServersOutput() async throws {
        let empty = await manager.log(taskID: 8, lines: 200)
        XCTAssertEqual(empty, "")
        _ = try await manager.start(taskID: 8, command: "seq 1 300; sleep 31337", directory: worktrees, port: 4322)
        var log = ""
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !log.hasSuffix("300") {
            try await Task.sleep(nanoseconds: 50_000_000)
            log = await manager.log(taskID: 8, lines: 200)
        }
        let written = log.hasSuffix("300")
        XCTAssertTrue(written, "log was: \(log)")
        XCTAssertEqual(log.components(separatedBy: "\n").first, "101")
        XCTAssertEqual(log.components(separatedBy: "\n").count, 200)
    }

    func testRestartReplacesOldProcess() async throws {
        let (first, firstChild) = try await startTree(manager, taskID: 4, in: temp)
        let (second, _) = try await startTree(manager, taskID: 4, in: temp)
        XCTAssertNotEqual(first, second)
        XCTAssertFalse(alive(first))
        let childDead = await eventually { !self.alive(firstChild) }
        XCTAssertTrue(childDead)
        let running = await manager.isRunning(taskID: 4)
        XCTAssertTrue(running)
    }

    func testIsRunningFalseAfterExit() async throws {
        _ = try await manager.start(taskID: 5, command: "true", directory: temp, port: 4000)
        var running = true
        for _ in 0..<100 where running {
            running = await manager.isRunning(taskID: 5)
            if running { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        XCTAssertFalse(running)
    }

    func testStartThrowsForMissingDirectory() async {
        do {
            _ = try await manager.start(taskID: 6, command: "sleep 31337",
                                        directory: temp.appendingPathComponent("nope"), port: 4000)
            XCTFail("expected an error")
        } catch {}
    }

    func testStopAll() async throws {
        let (a, aChild) = try await startTree(manager, taskID: 7, in: temp)
        let (b, bChild) = try await startTree(manager, taskID: 8, in: temp)
        await manager.stopAll()
        XCTAssertFalse(alive(a))
        XCTAssertFalse(alive(b))
        let dead = await eventually { !self.alive(aChild) && !self.alive(bChild) }
        XCTAssertTrue(dead)
    }

    // MARK: - Orphans

    func testStopOrphanKillsLeftoverTree() async throws {
        // `previous` stands in for an earlier app launch.
        let previous = makeManager()
        let (pid, child) = try await startTree(previous, taskID: 9, in: worktrees)

        await manager.stopOrphan(pid: pid)
        let dead = await eventually { !self.alive(child) }
        XCTAssertTrue(dead, "orphan's child survived")
        let running = await previous.isRunning(taskID: 9)
        XCTAssertFalse(running)
        // isRunning noticed the exit and reaps the zombie in the background.
        let reaped = await eventually { !self.alive(pid) }
        XCTAssertTrue(reaped)
    }

    func testStopOrphanLeavesUnrelatedProcessesAlone() async throws {
        let previous = makeManager()
        // cwd outside the worktrees directory: not plausibly ours.
        let (pid, child) = try await startTree(previous, taskID: 10, in: temp)
        await manager.stopOrphan(pid: pid)
        // A member of a group, but not its leader.
        await manager.stopOrphan(pid: child)
        await manager.stopOrphan(pid: getpid())
        await manager.stopOrphan(pid: 0)
        await manager.stopOrphan(pid: 1)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(alive(pid))
        XCTAssertTrue(alive(child))

        // Same for a non-leader whose cwd is under worktrees.
        let (pid2, child2) = try await startTree(previous, taskID: 11, in: worktrees)
        await manager.stopOrphan(pid: child2)
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertTrue(alive(pid2))
        XCTAssertTrue(alive(child2))

        await previous.stopAll()
        let dead = await eventually { !self.alive(child) && !self.alive(child2) }
        XCTAssertTrue(dead)
    }

    // MARK: - Setup command

    func testRunReturnsOutputAndExitCodeWithTheEnvironment() async throws {
        let result = try await manager.run(command: "echo \"$SHIFT_REPO:$PORT\"; pwd; echo oops >&2; exit 3",
                                           directory: worktrees, environment: ["SHIFT_REPO": "/repo", "PORT": "3001"])
        XCTAssertEqual(result.exitCode, 3)
        let lines = result.output.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.first, "/repo:3001")
        XCTAssertEqual(lines.dropFirst().first.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path },
                       worktrees.resolvingSymlinksInPath().path)
        XCTAssertEqual(lines.last, "oops")
    }

    func testFallbackServerServesTheDirectory() async throws {
        try Data("<h1>Hello from the worktree</h1>".utf8).write(to: worktrees.appendingPathComponent("index.html"))
        let port = await PortAllocator().allocate(preferred: 41500, reserved: [])
        let command = ProjectSetup.serverCommand(for: Project(name: "Site", repoPath: temp.path, baseBranch: "main"))
        _ = try await manager.start(taskID: 9, command: command, directory: worktrees, port: port)

        // Browsers may resolve localhost to either family, so both must answer.
        for host in ["127.0.0.1", "[::1]"] {
            let url = URL(string: "http://\(host):\(port)/")!
            var response: HTTPURLResponse?
            var body: String?
            let deadline = Date().addingTimeInterval(15)
            while body == nil, Date() < deadline {
                if let (data, r) = try? await URLSession.shared.data(from: url), (r as? HTTPURLResponse)?.statusCode == 200 {
                    response = r as? HTTPURLResponse
                    body = String(decoding: data, as: UTF8.self)
                } else {
                    try await Task.sleep(nanoseconds: 100_000_000)
                }
            }
            XCTAssertEqual(body, "<h1>Hello from the worktree</h1>", host)
            XCTAssertEqual(response?.value(forHTTPHeaderField: "Cache-Control"), "no-store", host)
        }
        // The allocator must see the port as taken now.
        XCTAssertFalse(PortAllocator.isFree(port))
    }

    func testAllocatorSkipsAPortHeldOnlyOnIPv6() throws {
        // A wildcard IPv6 listener (like `python3 -m http.server`) must make the port busy
        // even though 127.0.0.1 is still bindable.
        let fd = socket(AF_INET6, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(fd, 0)
        defer { close(fd) }
        var on: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_in6()
        address.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        address.sin6_family = sa_family_t(AF_INET6)
        address.sin6_addr = in6addr_any
        var port: Int = 0
        for candidate in 41600...41700 {
            address.sin6_port = in_port_t(candidate).bigEndian
            let bound = withUnsafePointer(to: &address) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) == 0 }
            }
            if bound { port = candidate; break }
        }
        XCTAssertNotEqual(port, 0)
        XCTAssertEqual(listen(fd, 8), 0)
        XCTAssertFalse(PortAllocator.isFree(port))
    }

    func testCancellingRunKillsTheCommandAndItsChildren() async throws {
        let pidFile = temp.appendingPathComponent("setup-child.pid")
        let manager = manager!, directory = worktrees!
        let run = Task {
            try await manager.run(command: "sleep 60 & echo $! > '\(pidFile.path)'; wait",
                                  directory: directory, environment: [:])
        }
        let started = await eventually { (try? String(contentsOf: pidFile, encoding: .utf8))?.isEmpty == false }
        XCTAssertTrue(started)
        let child = pid_t(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertTrue(alive(child))

        let begun = Date()
        run.cancel()
        let result = try await run.value
        XCTAssertNotEqual(result.exitCode, 0)
        XCTAssertLessThan(Date().timeIntervalSince(begun), 10)
        let gone = await eventually { !self.alive(child) }
        XCTAssertTrue(gone)
    }
}
