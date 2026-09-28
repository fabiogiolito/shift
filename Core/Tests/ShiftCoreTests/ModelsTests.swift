import XCTest
@testable import ShiftCore

final class ModelsTests: XCTestCase {
    func testAppStateRoundTrips() throws {
        let project = Project(name: "Spot", repoPath: "/tmp/spot", baseBranch: "main")
        let task = TaskItem(id: 3001, projectID: project.id, title: "Gap", agent: .codex,
                            branch: "shift/3001", worktreePath: "/tmp/wt/3001", prompts: [Prompt(text: "hi")])
        let state = AppState(projects: [project], tasks: [task], nextTaskID: 3002)
        let decoded = try JSONDecoder().decode(AppState.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
    }

    func testProjectSavedByAnEarlierBuildStillLoads() throws {
        let json = """
            {"id": "5B3C0E0A-5C0B-4B0E-9C62-0D7C1E1F2A3B", "name": "Spot", "repoPath": "/tmp/spot",
             "baseBranch": "main", "defaultAgent": "codex", "serverCommand": "pnpm dev"}
            """
        let project = try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        XCTAssertEqual(project.setupCommand, "")
        XCTAssertEqual(project.permissions, .bypass)
        XCTAssertEqual(project.serverCommand, "pnpm dev")
        XCTAssertEqual(project.defaultAgent, .codex)
    }

    func testDefaultBuildCommandComesFromTheRepo() throws {
        let repo = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: repo) }
        let project = Project(name: "App", repoPath: repo.path, baseBranch: "main")
        XCTAssertEqual(project.defaultBuildCommand, "")
        try FileManager.default.createDirectory(at: repo.appendingPathComponent("App.xcodeproj"), withIntermediateDirectories: true)
        XCTAssertTrue(project.defaultBuildCommand.hasPrefix("xcodebuild "))
        try Data().write(to: repo.appendingPathComponent("project.yml"))
        XCTAssertTrue(project.defaultBuildCommand.hasPrefix("xcodegen -q && xcodebuild "))
        let script = repo.appendingPathComponent("scripts/build.sh")
        try FileManager.default.createDirectory(at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: script.path, contents: Data(), attributes: [.posixPermissions: 0o755])
        XCTAssertEqual(project.defaultBuildCommand, "scripts/build.sh")
    }

    func testWorktreePathHasNoSpaces() {
        let project = Project(name: "UI Zen Garden", repoPath: "/tmp/x", baseBranch: "main")
        XCTAssertFalse(ShiftPaths.worktree(project: project, taskID: 3001).path.contains(" "))
    }

    func testPromptSavedBeforeIsPendingStillLoads() throws {
        let json = #"{"id":"5A1B2C3D-0000-0000-0000-000000000000","text":"Hi","date":0}"#
        let prompt = try JSONDecoder().decode(Prompt.self, from: Data(json.utf8))
        XCTAssertFalse(prompt.isPending)
    }
}
