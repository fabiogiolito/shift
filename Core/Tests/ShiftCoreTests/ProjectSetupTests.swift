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

    func testOnlyViteAndAstroGetAPortFlag() {
        let next = Data(#"{"scripts": {"dev": "next dev"}}"#.utf8)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["pnpm-lock.yaml"], packageJSON: next).server, "pnpm run dev")
        let astro = Data(#"{"scripts": {"dev": "astro dev"}}"#.utf8)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["yarn.lock"], packageJSON: astro).server, "yarn run dev --port $PORT")
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
        XCTAssertEqual(ProjectSetup.failure(CommandResult(exitCode: 1, output: "Packages: +372\n+++++++\n ERR_PNPM_NO_OFFLINE_TARBALL  missing\n")),
                       "Setup failed (exit code 1).\nPackages: +372\nERR_PNPM_NO_OFFLINE_TARBALL  missing")
    }

    func testElectronProjectRunsAnAppWithNoServer() {
        func package(_ scripts: String) -> Data { Data(#"{"devDependencies": {"electron": "44.0.0"}, "scripts": {\#(scripts)}}"#.utf8) }
        let vite = ProjectSetup.suggest(rootFiles: ["pnpm-lock.yaml", ".env"], packageJSON: package(#""dev": "electron-vite dev", "start": "electron-vite preview""#))
        XCTAssertEqual(vite.type, .electronApp)
        XCTAssertEqual(vite.setup, #"pnpm install && node node_modules/electron/install.js && cp "$SHIFT_REPO/.env" ."#)
        XCTAssertEqual(vite.server, "")
        XCTAssertEqual(vite.build, "pnpm run dev")
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: [], packageJSON: package(#""start": "electron-forge start""#)).build, "npm run start")
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: [], packageJSON: package("")).build, "node_modules/.bin/electron .")
    }

    func testTypeIsDetectedFromTheRepo() {
        let dev = Data(#"{"scripts": {"dev": "next dev"}}"#.utf8)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["package.json"], packageJSON: dev).type, .dynamicWebsite)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["App.xcodeproj"]).type, .nativeApp)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["project.yml"]).type, .nativeApp)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["index.html"]).type, .staticWebsite)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["index.html", "pnpm-lock.yaml"]).type, .other)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["pnpm-lock.yaml", ".env"], as: .staticWebsite).setup, "")
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: [], packageJSON: dev, as: .electronApp).build, "npm run dev")
    }
}
