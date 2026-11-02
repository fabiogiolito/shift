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
        XCTAssertEqual(vite.targets.first?.command, "pnpm run dev")
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: [], packageJSON: package(#""start": "electron-forge start""#)).targets.first?.command, "npm run start")
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: [], packageJSON: package("")).targets.first?.command, "node_modules/.bin/electron .")
    }

    func testTypeIsDetectedFromTheRepo() {
        let dev = Data(#"{"scripts": {"dev": "next dev"}}"#.utf8)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["package.json"], packageJSON: dev).type, .dynamicWebsite)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["App.xcodeproj"]).type, .nativeApp)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["project.yml"]).type, .nativeApp)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["index.html"]).type, .staticWebsite)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["index.html", "pnpm-lock.yaml"]).type, .other)
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: ["pnpm-lock.yaml", ".env"], as: .staticWebsite).setup, "")
        XCTAssertEqual(ProjectSetup.suggest(rootFiles: [], packageJSON: dev, as: .electronApp).targets.first?.command, "npm run dev")
    }

    // MARK: Build targets

    let twoApps = """
    name: Sample
    options:
      bundleIdPrefix: com.example
      # A comment
    targets:
      Sample:
        type: application
        platform: macOS
        sources: [App, "Shared/"]
        settings:
          base:
            type: framework
            platform: iOS
        dependencies:
          - target: Kit
      SampleTests:
        type: bundle.unit-test
        platform: macOS
        sources: Tests
      Kit:
        type: framework
        platform: iOS
      "Sample iOS": # the phone one
        platform: iOS
        type: application
        sources:
          - path: iOS
            excludes:
              - "**/*.md"
          - Shared
          - name: Named
            path: Extra
          - ./Resources/
      Watch:
        type: application
        platform: watchOS
        sources: [Watch]
      Sideways:
        type: application
        sources:
        - Flat
        platform: iOS
      Everywhere:
        type: application
        platform: [iOS, macOS]
    schemes:
      Other:
        build:
          targets:
            Sample: all
    """

    func testFindsTheApplicationsInProjectYML() {
        XCTAssertEqual(ProjectSetup.applications(projectYML: twoApps), [
            .init(name: "Sample", kind: .macApp, paths: ["App/", "Shared/"]),
            .init(name: "Sample iOS", kind: .iOSSimulator, paths: ["iOS/", "Shared/", "Extra/", "Resources/"]),
            .init(name: "Sideways", kind: .iOSSimulator, paths: ["Flat/"])])
        XCTAssertEqual(ProjectSetup.applications(projectYML: ""), [])
        XCTAssertEqual(ProjectSetup.applications(projectYML: "name: X\nschemes:\n  A:\n    targets:\n"), [])
    }

    func testEachApplicationBuildsItsOwnSchemeForItsDestination() {
        let targets = ProjectSetup.suggest(rootFiles: ["project.yml"], as: .nativeApp, projectYML: twoApps).targets
        XCTAssertEqual(targets.map(\.name), ["Sample", "Sample iOS", "Sideways"])
        XCTAssertEqual(targets.map(\.kind), [.macApp, .iOSSimulator, .iOSSimulator])
        XCTAssertEqual(targets[0].paths, ["App/", "Shared/"])
        XCTAssertEqual(targets[0].command, "mkdir -p build && /usr/bin/lockf -k build/.xcodegen.lock xcodegen --quiet --use-cache && "
            + #"xcodebuild -scheme 'Sample' -configuration Debug -derivedDataPath build/'Sample' -quiet build && ls -d "$PWD"/build/'Sample'/Build/Products/Debug/*.app | head -1"#)
        XCTAssertTrue(targets[1].command.contains(#"xcodebuild -scheme 'Sample iOS' -configuration Debug -destination 'generic/platform=iOS Simulator' -derivedDataPath build/'Sample iOS' "#))
        XCTAssertTrue(targets[1].command.hasSuffix(#"ls -d "$PWD"/build/'Sample iOS'/Build/Products/Debug-iphonesimulator/*.app | head -1"#))
        XCTAssertEqual(ProjectSetup.quoted("it's"), #"'it'\''s'"#)
    }

    func testBuildScriptBuildsTheFirstMacApp() {
        let targets = ProjectSetup.targets(apps: ProjectSetup.applications(projectYML: twoApps), xcodeGen: true, hasBuildScript: true)
        XCTAssertEqual(targets[0].command, "scripts/build.sh", "called with nothing: its first argument is its own business")
        XCTAssertEqual(targets[0].paths, ["App/", "Shared/"])
        XCTAssertTrue(targets[1].command.contains("-scheme 'Sample iOS'"))

        // Only the script.
        let alone = ProjectSetup.targets(apps: [], xcodeGen: false, hasBuildScript: true)
        XCTAssertEqual(alone.map(\.command), ["scripts/build.sh"])
        XCTAssertEqual(alone.first?.kind, .macApp)

        // No Mac app for it to build: still offered, as it would be today.
        let iOSOnly = ProjectSetup.targets(apps: [.init(name: "Phone", kind: .iOSSimulator)], xcodeGen: true, hasBuildScript: true)
        XCTAssertEqual(iOSOnly.map(\.name), ["App", "Phone"])
        XCTAssertEqual(iOSOnly.first?.command, "scripts/build.sh")
    }

    /// Shift's own repo: a build script, a Mac app, and a second application added to its real project.yml.
    func testShiftsOwnRepoWithASecondApplicationIsTwoTargets() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let yml = try String(contentsOf: root.appendingPathComponent("project.yml"), encoding: .utf8)
        XCTAssertEqual(ProjectSetup.applications(projectYML: yml), [.init(name: "Shift", kind: .macApp, paths: ["App/"])])

        // Added under targets:, which is the file's last section.
        let two = yml + """

          Shift iOS:
            type: application
            platform: iOS
            sources: [iOS]

        """
        let hasScript = FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("scripts/build.sh").path)
        XCTAssertTrue(hasScript)
        let targets = ProjectSetup.suggest(rootFiles: ["project.yml"], projectYML: two, hasBuildScript: hasScript).targets
        XCTAssertEqual(targets.map(\.name), ["Shift", "Shift iOS"])
        XCTAssertEqual(targets.map(\.kind), [.macApp, .iOSSimulator])
        XCTAssertEqual(targets.map(\.paths), [["App/"], ["iOS/"]])
        XCTAssertEqual(targets[0].command, "scripts/build.sh")
        XCTAssertTrue(targets[1].command.contains("-scheme 'Shift iOS'"))
    }

    func testReadsSchemesFromXcodebuild() {
        // Output as xcodebuild really prints it, warnings included.
        let list = """
        2026-11-02 13:30:40.794 xcodebuild[17216:2196992] [MT] IDERunDestination: Supported platforms is empty.
        {
          "project" : {
            "configurations" : ["Debug", "Release"],
            "name" : "Sample",
            "schemes" : ["Sample iOS", "SampleMac", "SampleTests"],
            "targets" : ["Sample iOS", "SampleMac", "SampleTests"]
          }
        }
        """
        XCTAssertEqual(ProjectSetup.schemes(listOutput: list), ["Sample iOS", "SampleMac", "SampleTests"])
        XCTAssertEqual(ProjectSetup.schemes(listOutput: #"{"workspace": {"name": "W", "schemes": ["W"]}}"#), ["W"])
        XCTAssertEqual(ProjectSetup.schemes(listOutput: "xcodebuild: error: nope"), [])

        func settings(_ entries: String...) -> String {
            "[" + entries.map { #"{"action": "build", "buildSettings": {\#($0)}, "target": "X"}"# }.joined(separator: ",") + "]"
        }
        let iOS = settings(#""WRAPPER_EXTENSION": "framework", "PLATFORM_NAME": "iphoneos""#,
                           #""WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "iphoneos""#)
        XCTAssertEqual(ProjectSetup.application(scheme: "Sample iOS", buildSettingsOutput: iOS), .init(name: "Sample iOS", kind: .iOSSimulator))
        let mac = settings(#""WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "macosx""#)
        XCTAssertEqual(ProjectSetup.application(scheme: "SampleMac", buildSettingsOutput: mac), .init(name: "SampleMac", kind: .macApp))
        let tests = settings(#""WRAPPER_EXTENSION": "xctest", "PLATFORM_NAME": "macosx""#)
        XCTAssertNil(ProjectSetup.application(scheme: "SampleTests", buildSettingsOutput: tests))
        let watch = settings(#""WRAPPER_EXTENSION": "app", "PLATFORM_NAME": "watchos""#)
        XCTAssertNil(ProjectSetup.application(scheme: "Watch", buildSettingsOutput: watch))
        XCTAssertNil(ProjectSetup.application(scheme: "Broken", buildSettingsOutput: ""))

        let targets = ProjectSetup.suggest(rootFiles: ["Sample.xcodeproj"], schemes: [.init(name: "SampleMac", kind: .macApp), .init(name: "Sample iOS", kind: .iOSSimulator)],
                                           xcodeProject: "Sample.xcodeproj").targets
        XCTAssertEqual(targets.map(\.kind), [.macApp, .iOSSimulator])
        XCTAssertTrue(targets[0].command.hasPrefix("xcodebuild -project 'Sample.xcodeproj' -scheme 'SampleMac' "), targets[0].command)
    }

    func testPicksASimulator() {
        func list(_ devices: String) -> Data { Data(#"{"devices": {\#(devices)}}"#.utf8) }
        let runtimes = list(#"""
        "com.apple.CoreSimulator.SimRuntime.iOS-9-3": [{"udid": "old", "name": "iPhone 6", "state": "Shutdown"}],
        "com.apple.CoreSimulator.SimRuntime.tvOS-27-0": [{"udid": "tv", "name": "Apple TV", "state": "Booted"}],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [
            {"udid": "pro", "name": "iPhone 17 Pro", "state": "Shutdown"},
            {"udid": "eleven", "name": "iPhone 11", "state": "Shutdown"},
            {"udid": "se", "name": "iPhone 16e", "state": "Shutdown"},
            {"udid": "ipad", "name": "iPad Pro", "state": "Shutdown"}],
        "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [{"udid": "seventeen", "name": "iPhone 15", "state": "Shutdown"}]
        """#)
        XCTAssertEqual(Simulators.pickDevice(listJSON: runtimes), .init(udid: "pro", isBooted: false), "newest runtime, newest iPhone; iOS 26 is not older than 9")
        let booted = list(#"""
        "com.apple.CoreSimulator.SimRuntime.iOS-26-3": [{"udid": "pro", "name": "iPhone 17 Pro", "state": "Shutdown"}],
        "com.apple.CoreSimulator.SimRuntime.iOS-17-0": [{"udid": "ipad", "name": "iPad", "state": "Booted"}]
        """#)
        XCTAssertEqual(Simulators.pickDevice(listJSON: booted), .init(udid: "ipad", isBooted: true), "whatever is booted already")
        XCTAssertNil(Simulators.pickDevice(listJSON: list(#""com.apple.CoreSimulator.SimRuntime.iOS-26-3": []"#)))
        XCTAssertNil(Simulators.pickDevice(listJSON: Data("nope".utf8)))
    }

    func testReadsTheBundleIDOfAnIOSApp() throws {
        let app = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".app")
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: app) }
        XCTAssertNil(Simulators.bundleID(ofApp: app))
        let plist = try PropertyListSerialization.data(fromPropertyList: ["CFBundleIdentifier": "com.example.a"], format: .binary, options: 0)
        try plist.write(to: app.appendingPathComponent("Info.plist"))
        XCTAssertEqual(Simulators.bundleID(ofApp: app), "com.example.a")
    }
}
