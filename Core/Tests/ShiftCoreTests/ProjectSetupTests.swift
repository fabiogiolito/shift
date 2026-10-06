import XCTest
@testable import ShiftCore

final class ProjectSetupTests: XCTestCase {
    let dev = Data(#"{"scripts": {"dev": "vite", "build": "vite build"}}"#.utf8)

    func testLockfilePicksThePackageManager() {
        for (lockfile, manager) in [("pnpm-lock.yaml", "pnpm"), ("yarn.lock", "yarn"), ("bun.lockb", "bun"),
                                    ("bun.lock", "bun"), ("package-lock.json", "npm")] {
            let suggestion = ProjectSetup.suggest(rootFiles: ["package.json", lockfile, "src"], packageJSON: dev)
            XCTAssertEqual(suggestion.setup, "\(manager) install")
            XCTAssertEqual(suggestion.server, "\(manager) run dev" + (manager == "npm" ? " -- --port $PORT" : " --port $PORT"))
        }
    }

    func testOnlyViteGetsAPortFlag() {
        let next = Data(#"{"scripts": {"dev": "next dev"}}"#.utf8)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["pnpm-lock.yaml"], packageJSON: next).server, "pnpm run dev")
    }

    func testUntrackedEnvFilesAreCopied() {
        let files = ["pnpm-lock.yaml", ".env", ".env.local", ".env.example"]
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: files).setup,
                       #"pnpm install && cp "$SHIFT_REPO/.env" . && cp "$SHIFT_REPO/.env.local" ."#)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: files, tracked: [".env"]).setup,
                       #"pnpm install && cp "$SHIFT_REPO/.env.local" ."#)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: [".env"]).setup, #"cp "$SHIFT_REPO/.env" ."#)
    }

    func testServerNeedsADevScript() {
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["yarn.lock", "package.json"],
                                            packageJSON: Data(#"{"scripts": {"build": "tsc"}}"#.utf8)).server, "")
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["yarn.lock"], packageJSON: Data("not json".utf8)).server, "")
        // No lockfile: nothing to install, npm runs the script.
        let bare = ProjectSetup.suggest(rootFiles: ["package.json"], packageJSON: dev)
        XCTAssertEqual(bare.setup, "")
        XCTAssertEqual(bare.server, "npm run dev -- --port $PORT")
    }

    func testServerCommandFallsBackToAStaticFileServer() {
        var project = Project(name: "Site", repoPath: "/tmp/site", baseBranch: "main", serverCommand: " pnpm dev\n")
        XCTAssertEqual(ProjectSetup.serverCommand(for: project), "pnpm dev")
        for empty in ["", "  \n"] {
            project.serverCommand = empty
            XCTAssertEqual(ProjectSetup.serverCommand(for: project), ProjectSetup.staticServer)
        }
    }

    func testOtherEcosystemsGetNothing() {
        let suggestion = ProjectSetup.suggest(rootFiles: ["Package.swift", "Cargo.lock", "README.md"])
        XCTAssertEqual(suggestion.setup, "")
        XCTAssertEqual(suggestion.server, "")
    }

    func testFailureKeepsTheLastLines() {
        XCTAssertEqual(ProjectSetup.failure(CommandResult(exitCode: 127, output: "")), "Setup failed (exit code 127).")
        XCTAssertEqual(ProjectSetup.failure(CommandResult(exitCode: 1, output: "a\nb\nc\nd\ne\nf\n")),
                       "Setup failed (exit code 1).\nb\nc\nd\ne\nf")
    }
}
