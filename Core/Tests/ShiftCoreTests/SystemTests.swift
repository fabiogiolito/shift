import XCTest
@testable import ShiftCore

// Nothing here opens an application or posts a notification.
final class SystemTests: XCTestCase {
    func testInstalledEditorsAlwaysIncludesFinder() {
        let editors = ExternalApps().installedEditors()
        XCTAssertEqual(editors.last, .finder)
        XCTAssertFalse(editors.contains(.terminal))
        XCTAssertEqual(Set(editors).count, editors.count)
    }

    func testTerminalIsDetected() {
        XCTAssertFalse(ExternalApps().terminalName().isEmpty)
        XCTAssertFalse(ExternalApps().terminalName().hasSuffix(".app"))
        XCTAssertNotNil(ExternalApps().terminalURL(), "Terminal.app ships with macOS")
    }

    func testTerminalPreference() {
        let apple = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
        let iterm = URL(fileURLWithPath: "/Applications/iTerm.app")
        let kitty = URL(fileURLWithPath: "/Applications/kitty.app")
        let installed: (String) -> URL? = { ["com.googlecode.iterm2": iterm, "com.apple.Terminal": apple][$0] }

        // Default handler says nothing: first installed known terminal wins.
        XCTAssertEqual(ExternalApps.pickTerminal(commandHandler: (apple, "com.apple.Terminal"), installed: installed), iterm)
        XCTAssertEqual(ExternalApps.pickTerminal(commandHandler: nil, installed: installed), iterm)
        // A handler the user chose wins, even if we do not know it.
        XCTAssertEqual(ExternalApps.pickTerminal(commandHandler: (kitty, "net.kovidgoyal.kitty"), installed: installed), kitty)
        // Only Terminal.app installed.
        XCTAssertEqual(ExternalApps.pickTerminal(commandHandler: nil, installed: { $0 == "com.apple.Terminal" ? apple : nil }), apple)
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
