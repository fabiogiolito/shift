import XCTest
@testable import ShiftCore

final class MacSetupTests: XCTestCase {
    func testProjectNeeds() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        XCTAssertNil(MacSetup.packageManager(of: folder))
        XCTAssertFalse(MacSetup.needsXcode(folder))

        try Data("{}".utf8).write(to: folder.appendingPathComponent("package.json"))
        XCTAssertEqual(MacSetup.packageManager(of: folder), "npm")
        try Data().write(to: folder.appendingPathComponent("yarn.lock"))
        XCTAssertEqual(MacSetup.packageManager(of: folder), "yarn")
        try Data(#"{"packageManager": "pnpm@9.1.0"}"#.utf8).write(to: folder.appendingPathComponent("package.json"))
        XCTAssertEqual(MacSetup.packageManager(of: folder), "pnpm")

        try FileManager.default.createDirectory(at: folder.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        XCTAssertTrue(MacSetup.needsXcode(folder))
    }

    func testToolPathForTerminal() {
        XCTAssertEqual(MacSetup.path(of: "git"), "'/usr/bin/git'")
        XCTAssertEqual(MacSetup.path(of: "no-such-tool-here"), "no-such-tool-here")
    }

    func testShellQuoting() {
        XCTAssertEqual(MacSetup.shellQuoted("it's"), #"'it'\''s'"#)
    }
}

/// Real git, with HOME in a temporary folder so the user's own ~/.gitconfig is untouched.
final class MacSetupGitTests: XCTestCase {
    func testSetsGitIdentity() async throws {
        let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let original = ProcessInfo.processInfo.environment["HOME"]
        setenv("HOME", home.path, 1)
        AgentEnvironment.reload()
        defer {
            if let original { setenv("HOME", original, 1) }
            AgentEnvironment.reload()
            try? FileManager.default.removeItem(at: home)
        }
        let empty = await MacSetup.gitIdentity()
        XCTAssertEqual(empty.name, "")
        try await MacSetup.setGitIdentity(name: "Jane Appleseed", email: "jane@example.com")
        let saved = await MacSetup.gitIdentity()
        XCTAssertEqual(saved.name, "Jane Appleseed")
        XCTAssertEqual(saved.email, "jane@example.com")
        XCTAssertTrue(FileManager.default.fileExists(atPath: home.appendingPathComponent(".gitconfig").path))
    }
}
