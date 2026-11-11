import XCTest
@testable import ShiftCore

final class ModelsTests: XCTestCase {
    func testStatusChangesThatNotify() {
        XCTAssertTrue(TaskStatus.completed.notifies(from: .working))
        XCTAssertTrue(TaskStatus.needsInput.notifies(from: .working))
        XCTAssertTrue(TaskStatus.conflict.notifies(from: .completed))
        XCTAssertFalse(TaskStatus.working.notifies(from: .working))
        XCTAssertFalse(TaskStatus.working.notifies(from: .completed))
        XCTAssertFalse(TaskStatus.merged.notifies(from: .completed))
        XCTAssertFalse(TaskStatus.conflict.notifies(from: .conflict))
    }

    func testSignedOutTasksResumeWithTheirLastPrompt() {
        var task = TaskItem(id: 1, projectID: UUID(), title: "T", agent: .claudeCode, branch: "b", worktreePath: "/w",
                            prompts: [Prompt(text: "Make it blue")])
        task.status = .blocked
        task.blockedReason = "Failed to authenticate: this login reached its time limit and cannot be renewed. Run claude auth login to sign in again"
        XCTAssertTrue(task.isSignedOut)
        XCTAssertTrue(task.canResume)
        XCTAssertEqual(AppModel.resumePrompt(task), "Make it blue", "no session: the prompt never got there")
        task.sessionID = "s"
        XCTAssertTrue(AppModel.resumePrompt(task).hasSuffix("Make it blue"))
        task.blockedReason = "The tests for the authentication middleware fail."
        XCTAssertFalse(task.isSignedOut)
        XCTAssertEqual(AppModel.resumePrompt(task), AppModel.continuePrompt)
    }

    func testUnknownStatusDecodesAsClosed() throws {
        let decoded = try JSONDecoder().decode([TaskStatus].self, from: Data(#"["archived", "scheduled", "working"]"#.utf8))
        XCTAssertEqual(decoded, [.archived, .merged, .working])
        XCTAssertTrue(decoded[1].isClosed)
        XCTAssertEqual(String(data: try JSONEncoder().encode(TaskStatus.archived), encoding: .utf8), #""archived""#)
    }

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
        XCTAssertFalse(project.opensPullRequests)
        XCTAssertEqual(project.serverCommand, "pnpm dev")
        XCTAssertEqual(project.defaultAgent, .codex)
    }

    func testTypeOfAProjectSavedBeforeThereWereTypes() throws {
        func decoded(_ commands: String) throws -> ProjectType {
            let json = #"{"id": "00000000-0000-0000-0000-000000000000", "name": "A", "repoPath": "/a", "baseBranch": "main", "defaultAgent": "codex", \#(commands)}"#
            return try JSONDecoder().decode(Project.self, from: Data(json.utf8)).type
        }
        XCTAssertEqual(try decoded(#""serverCommand": """#), .staticWebsite)
        XCTAssertEqual(try decoded(#""serverCommand": "pnpm dev""#), .dynamicWebsite)
        XCTAssertEqual(try decoded(#""serverCommand": "", "buildCommand": "make""#), .nativeApp)
        XCTAssertEqual(try decoded(#""serverCommand": "", "setupCommand": "pnpm install""#), .other)
    }

    func testSavedBuildCommandBecomesASingleTarget() throws {
        func decoded(_ fields: String) throws -> Project {
            let json = #"{"id": "00000000-0000-0000-0000-000000000000", "name": "A", "repoPath": "/a", "baseBranch": "main", "defaultAgent": "codex", "serverCommand": "", \#(fields)}"#
            return try JSONDecoder().decode(Project.self, from: Data(json.utf8))
        }
        let native = try decoded(#""type": "nativeApp", "buildCommand": "scripts/build.sh""#)
        XCTAssertEqual(native.buildTargets.map(\.command), ["scripts/build.sh"])
        XCTAssertEqual(native.buildTargets.first?.kind, .macApp)
        XCTAssertTrue(native.isApp)
        XCTAssertFalse(native.runsApp)

        let electron = try decoded(#""type": "electronApp", "buildCommand": "pnpm run dev""#)
        XCTAssertEqual(electron.buildTargets.first?.kind, .run)
        XCTAssertTrue(electron.runsApp)

        // An app because of its command alone, with no type saved.
        let untyped = try decoded(#""buildCommand": "make""#)
        XCTAssertEqual(untyped.type, .nativeApp)
        XCTAssertEqual(untyped.targets.map(\.command), ["make"])

        // Nothing to migrate: a web project stays one; a native app detects its command when it builds.
        for blank in [#""type": "other", "buildCommand": "  ""#, #""type": "other""#] {
            let web = try decoded(blank)
            XCTAssertEqual(web.buildTargets, [])
            XCTAssertFalse(web.isApp)
        }
        let detecting = try decoded(#""type": "nativeApp", "buildCommand": """#)
        XCTAssertEqual(detecting.buildTargets, [])
        XCTAssertTrue(detecting.isApp)
        XCTAssertEqual(detecting.targets, [.detected])
        // An Electron app without its command is not an app yet, but its settings still ask for what it runs.
        let electronWithout = try decoded(#""type": "electronApp""#)
        XCTAssertFalse(electronWithout.isApp)
        XCTAssertTrue(electronWithout.runsApp)

        // What's saved from now on comes back the same, keeping its ids.
        let roundTripped = try JSONDecoder().decode(Project.self, from: JSONEncoder().encode(native))
        XCTAssertEqual(roundTripped, native)
        // New state wins over a leftover old command.
        let both = try decoded(#""buildCommand": "old", "buildTargets": [{"name": "iOS", "command": "new", "kind": "iOSSimulator", "paths": ["iOS/"]}]"#)
        XCTAssertEqual(both.buildTargets.map(\.command), ["new"])
        XCTAssertEqual(both.buildTargets.first?.paths, ["iOS/"])
    }

    func testBuildCommandEditsASingleTarget() {
        var project = Project(name: "A", repoPath: "/a", baseBranch: "main", type: .electronApp)
        project.buildCommand = "pnpm dev"
        XCTAssertEqual(project.buildTargets.first?.kind, .run)
        let id = project.buildTargets[0].id
        project.buildCommand = "pnpm start"
        XCTAssertEqual(project.buildTargets.map(\.id), [id])
        project.buildCommand = " "
        XCTAssertEqual(project.buildTargets, [])
    }

    func testTargetPathsAndSuggestion() {
        let mac = BuildTarget(name: "Mac", command: "m", paths: ["App/", " Shared"])
        XCTAssertTrue(mac.matches(path: "App/A.swift"))
        XCTAssertTrue(mac.matches(path: "Shared/A.swift"))
        XCTAssertTrue(mac.matches(path: "Shared"))
        XCTAssertFalse(mac.matches(path: "AppTests/A.swift"))
        XCTAssertFalse(mac.matches(path: "SharedKit/A.swift"))
        let empty = BuildTarget(name: "E", command: "e", paths: ["", " "])
        XCTAssertFalse(empty.matches(path: "App/A.swift"))

        let iOS = BuildTarget(name: "iOS", command: "i", paths: ["iOS/"])
        let targets = [mac, iOS]
        func suggested(_ changed: [String], lastBuilt: UUID? = nil) -> String? {
            BuildTarget.suggested(among: targets, changed: changed, lastBuilt: lastBuilt)?.name
        }
        XCTAssertEqual(suggested(["iOS/a", "iOS/b", "App/c"]), "iOS")
        XCTAssertEqual(suggested(["iOS/a", "App/c"], lastBuilt: iOS.id), "Mac", "a tie goes to the first")
        XCTAssertEqual(suggested(["README.md"], lastBuilt: iOS.id), "iOS")
        XCTAssertEqual(suggested(["README.md"], lastBuilt: UUID()), "Mac", "a removed target is forgotten")
        XCTAssertNil(BuildTarget.suggested(among: [], changed: [], lastBuilt: nil))
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

    func testTaskSearchMatches() {
        var task = TaskItem(id: 3001, projectID: UUID(), title: "Make the button blue", agent: .claudeCode, branch: "b",
                            worktreePath: "/tmp", prompts: [Prompt(text: "Use the brand colour")], description: "Restyles the café page")
        task.tags = ["Design"]
        for query in ["", "BUTTON", "cafe", "design", "brand"] {
            XCTAssertTrue(task.matches(query), query)
        }
        XCTAssertTrue(task.matches("blue make"))
        XCTAssertFalse(task.matches("blue red"))
        XCTAssertFalse(task.matches("page.js"))
        XCTAssertTrue(task.matches("page.js", extra: "Done.\napp/page.js"))
    }
}
