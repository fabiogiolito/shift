import XCTest
@testable import ShiftCore

// Nothing here opens an application or posts a notification.
final class SystemTests: XCTestCase {
    func testInstalledEditorsAlwaysIncludesFinder() {
        let editors = ExternalApps().installedEditors()
        XCTAssertEqual(editors.last, .finder)
        XCTAssertEqual(Set(editors).count, editors.count)
    }

    func testTerminalIsDetected() {
        let terminals = ExternalApps().installedTerminals()
        XCTAssertTrue(terminals.contains { $0.lastPathComponent == "Terminal.app" }, "Terminal.app ships with macOS")
        XCTAssertEqual(Set(terminals).count, terminals.count)
        XCTAssertFalse(terminals.map(ExternalApps().name(of:)).contains { $0.isEmpty || $0.hasSuffix(".app") })
    }

    func testTerminalPreference() {
        let apple = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let iterm = URL(fileURLWithPath: "/Applications/iTerm.app")
        let kitty = URL(fileURLWithPath: "/Applications/kitty.app")
        let installed: (String) -> URL? = { ["com.googlecode.iterm2": iterm, "com.apple.Terminal": apple][$0] }

        // All installed known terminals, in list order.
        XCTAssertEqual(ExternalApps.terminals(commandHandler: (apple, "com.apple.Terminal"), installed: installed), [iterm, apple])
        XCTAssertEqual(ExternalApps.terminals(commandHandler: nil, installed: installed), [iterm, apple])
        // A handler the user chose goes first, even if we do not know it.
        XCTAssertEqual(ExternalApps.terminals(commandHandler: (kitty, "net.kovidgoyal.kitty"), installed: installed), [kitty, iterm, apple])
        // A known handler is not listed twice.
        XCTAssertEqual(ExternalApps.terminals(commandHandler: (iterm, "com.googlecode.iterm2"), installed: installed), [iterm, apple])
    }

    func testDisplayNames() {
        for app in ExternalApp.allCases { XCTAssertFalse(app.displayName.isEmpty) }
    }

    func testNotifierIsANoOpWithoutAppBundle() async {
        let notifier = SystemNotifier()
        await notifier.requestAuthorization()
        await notifier.notify(title: "Ready", body: "Task 3001", taskID: 3001)
        await notifier.setBadge(count: 2)
        await notifier.setBadge(count: 0)
    }
}

final class ProcessMemoryTests: XCTestCase {
    /// A shell with two children: the tree counts all three, and is attributed by folder or server pid.
    func testTreeFootprintCountsChildren() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 30 & sleep 30 & wait"]
        shell.currentDirectoryURL = folder
        try shell.run()
        defer { shell.terminate(); try? FileManager.default.removeItem(at: folder) }
        let pid = shell.processIdentifier
        let deadline = Date().addingTimeInterval(5)
        while ProcessMemory.children(of: pid).count < 2 && Date() < deadline { usleep(20_000) }

        XCTAssertEqual(ProcessMemory.children(of: pid).count, 2)
        let own = ProcessMemory.footprint(of: pid)
        let tree = ProcessMemory.treeFootprint(pid)
        XCTAssertGreaterThan(own, 0)
        XCTAssertGreaterThan(tree, own)

        let child = try XCTUnwrap(ProcessMemory.ownChildren().first { $0.pid == pid })
        let (asAgent, _) = AppModel.attribute([child], servers: [], worktrees: [(folder.path, 7)], chats: [], ignoring: [])
        XCTAssertEqual(asAgent[7], MemoryUse(agent: child.footprint))
        let (asServer, _) = AppModel.attribute([child], servers: [(pid, 7)], worktrees: [(folder.path, 7)], chats: [], ignoring: [])
        XCTAssertEqual(asServer[7], MemoryUse(server: child.footprint))
        let (none, chats) = AppModel.attribute([child], servers: [], worktrees: [], chats: [(folder.path, UUID())], ignoring: [pid])
        XCTAssertTrue(none.isEmpty && chats.isEmpty)
    }
}
