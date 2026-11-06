import AppKit
import XCTest
@testable import ShiftCore

@MainActor
final class ScreenshotTests: XCTestCase {
    var git: MockGit!
    var agent: MockAgent!
    var shots: MockScreenshots!
    var servers: MockServers!
    var model: AppModel!
    var project: Project!
    var temp: URL!

    override func setUp() async throws {
        git = MockGit()
        agent = MockAgent()
        shots = MockScreenshots()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("shift-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        project = Project(name: "Spot", repoPath: temp.path, baseBranch: "main", serverCommand: "pnpm dev", takesScreenshots: true)
        await startModel()
    }

    override func tearDown() async throws {
        try? FileManager.default.removeItem(at: temp)
    }

    func startModel() async {
        let store = MockStore()
        store.state = AppState(projects: [project])
        servers = MockServers()
        model = AppModel(services: Services(git: git, agents: [.claudeCode: agent], servers: servers, ports: MockPorts(),
                                            notifier: MockNotifier(), store: store, screenshots: shots),
                         worktrees: temp.appendingPathComponent("worktrees"))
        await model.start()
    }

    let change = DiffSummary(files: [FileChange(path: "a.html", kind: .modified, additions: 1)])

    /// One agent turn that names `page` first, then makes `changes`. `captures`: shots expected before the changes.
    func runTurn(page: String?, changes: DiffSummary?, captures: Int = 0, prompt: (String) -> Void) async {
        let gate = Gate()
        agent.scripts.append([.emit(.sessionStarted(id: "s1")), .emit(.screenshots(page.map { [ScreenshotTarget(page: $0)] } ?? [])), .pause(gate),
                              .emit(.finished(.completed(summary: "Done")))])
        prompt("Do it")
        await waitFor("the agent to pause") { gate.waiting == 1 && self.shots.captured.count == captures }
        if let changes { git.pendingChanges = changes }
        gate.open()
    }

    func firstTurn(page: String?, changes: DiffSummary?, captures: Int = 0) async -> Int {
        var id = 0
        await runTurn(page: page, changes: changes, captures: captures) { id = model.createTask(projectID: project.id, prompt: $0)! }
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        return id
    }

    func testFirstPromptTakesABeforeAndAnAfterOfTheNamedPage() async {
        let id = await firstTurn(page: "/pricing", changes: change, captures: 1)
        XCTAssertEqual(servers.starts.count, 1, "Started for the before, once the agent named a page")
        XCTAssertEqual(agent.requests[0].screenshots, .page)
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [true, false])
        XCTAssertEqual(shots.captured.map(\.path), ["/pricing", "/pricing"])
    }

    func testLaterPromptsTakeOnlyAnAfterAndOnlyIfSomethingChanged() async {
        let id = await firstTurn(page: "/", changes: change, captures: 1)
        await runTurn(page: "/", changes: nil, captures: 2) { model.sendPrompt(taskID: id, text: $0) }
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        XCTAssertEqual(model.task(id)?.screenshots?.count, 2, "nothing changed")

        await runTurn(page: "/", changes: DiffSummary(files: change.files + [FileChange(path: "b", kind: .added)]), captures: 2) {
            model.sendPrompt(taskID: id, text: $0)
        }
        await waitFor("an after") { self.model.task(id)?.screenshots?.count == 3 }
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [true, false, false])
    }

    /// The final message's lines replace the first: each is a shot, and only those run scripts, not the "before".
    func testTheFinalMessageAsksForTheStatesThatShowTheChange() async {
        let gate = Gate()
        let final = [ScreenshotTarget(page: "/", script: "open()"), ScreenshotTarget(page: "/b")]
        agent.scripts.append([.emit(.screenshots([ScreenshotTarget(page: "/", script: "tooSoon()")])), .pause(gate),
                              .emit(.screenshots(final)), .emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "x")!
        await waitFor("the before") { gate.waiting == 1 && self.shots.captured.count == 1 }
        git.pendingChanges = change
        gate.open()
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [true, false, false])
        XCTAssertEqual(shots.captured.map(\.path), ["/", "/", "/b"])
        XCTAssertEqual(shots.scripts, [nil, "open()", nil])
    }

    func testNothingVisibleTakesNoScreenshots() async {
        let id = await firstTurn(page: nil, changes: change)
        XCTAssertNil(model.task(id)?.screenshots)
        XCTAssertTrue(servers.starts.isEmpty, "Nothing to show: no server")
    }

    func testAPageNamedAfterTheFirstEditGetsNoBefore() async {
        let gate = Gate()
        agent.scripts.append([.pause(gate), .emit(.screenshots([ScreenshotTarget(page: "/a")])), .emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "x")!
        await waitFor("the agent to pause") { gate.waiting == 1 }
        git.pendingChanges = change
        gate.open()
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [false])
    }

    func testATaskThatAlreadyChangedGetsNoBefore() async {
        git.pendingChanges = change
        let id = await firstTurn(page: "/", changes: DiffSummary(files: change.files + [FileChange(path: "b", kind: .added)]))
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [false])
    }

    func testDisabledAsksNothingAndTakesNothing() async {
        project.takesScreenshots = false
        await startModel()
        let id = await firstTurn(page: "/", changes: change)
        XCTAssertNil(agent.requests[0].screenshots)
        XCTAssertNil(model.task(id)?.screenshots)
        XCTAssertTrue(shots.captured.isEmpty)
    }

    func testAFailedCaptureDoesNotAffectTheTask() async {
        shots.fails = true
        let id = await firstTurn(page: "/", changes: change)
        XCTAssertNil(model.task(id)?.screenshots)
        XCTAssertEqual(model.task(id)?.status, .completed)
    }

    func testDeletingATaskDeletesItsScreenshots() async throws {
        let id = await firstTurn(page: "/", changes: change, captures: 1)
        let shot = try XCTUnwrap(model.task(id)?.screenshots?.first)
        // The mock writes nothing. A unique name in the real folder, gone by the end of the test.
        try FileManager.default.createDirectory(at: shot.url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data().write(to: shot.url)
        await model.delete(taskID: id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: shot.path))
    }

    func testThePageNamedStaysOnTheTasksServer() {
        let server = URL(string: "http://localhost:3158")!
        func url(_ page: String) -> String { AppModel.screenshotURL(page: page, server: server).absoluteString }
        XCTAssertEqual(url("/pricing?a=1"), "http://localhost:3158/pricing?a=1")
        XCTAssertEqual(url("pricing"), "http://localhost:3158/pricing")
        XCTAssertEqual(url("http://localhost:3158/a"), "http://localhost:3158/a")
        for elsewhere in ["https://example.com/", "//example.com/a", "http://localhost:4000/", "file:///etc/hosts"] {
            XCTAssertEqual(url(elsewhere), "http://localhost:3158", elsewhere)
        }
    }

    func testAgentMessagesNameThePage() {
        XCTAssertEqual(OutcomeProtocol.screenshots(in: "SHIFT_SCREENSHOT: `/pricing`\nOn it."),
                       .screenshots([ScreenshotTarget(page: "/pricing")]))
        XCTAssertEqual(OutcomeProtocol.screenshots(in: "**SHIFT_SCREENSHOT:** none"), .screenshots([]))
        XCTAssertNil(OutcomeProtocol.screenshots(in: "Reading the code."))
        XCTAssertEqual(OutcomeProtocol.screenshots(in: """
            SHIFT_SCREENSHOT: / document.querySelector('main button').click()
            Text in between.
            SHIFT_SCREENSHOT: `/b` `go()`
            """), .screenshots([ScreenshotTarget(page: "/", script: "document.querySelector('main button').click()"),
                                ScreenshotTarget(page: "/b", script: "go()")]))
        let many = String(repeating: "SHIFT_SCREENSHOT: /a\n", count: 9)
        XCTAssertEqual(OutcomeProtocol.screenshots(in: many), .screenshots(Array(repeating: ScreenshotTarget(page: "/a"), count: 4)))
        XCTAssertEqual(OutcomeProtocol.parse(finalMessage: "SHIFT_SCREENSHOT: /a\nSHIFT_STATUS: completed\nDone.", exitCode: 0),
                       .completed(summary: "Done."))
        XCTAssertTrue(OutcomeProtocol.instructions(firstTurn: false, screenshots: .page).contains("SHIFT_SCREENSHOT: <path>"))
        XCTAssertFalse(OutcomeProtocol.instructions(firstTurn: false).contains("SHIFT_SCREENSHOT"))
        XCTAssertTrue(OutcomeProtocol.instructions(firstTurn: false, server: true).contains("shiftctl server"))
        XCTAssertFalse(OutcomeProtocol.instructions(firstTurn: false).contains("shiftctl server"))
    }

    // MARK: Apps

    func startAppModel() async {
        project.type = .nativeApp
        await startModel()
    }

    func testAnAppsAgentTakesItsOwnBeforeAndAfter() async {
        await startAppModel()
        let gate = Gate()
        agent.scripts.append([.emit(.screenshots([ScreenshotTarget(page: "/tmp/settings.png")])), .pause(gate),
                              .emit(.screenshots([ScreenshotTarget(page: "relative/after.png")])), .emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "x")!
        await waitFor("the before") { gate.waiting == 1 && self.shots.captured.count == 1 }
        git.pendingChanges = change
        gate.open()
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        XCTAssertEqual(agent.requests[0].screenshots, .app(wantsBefore: true))
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [true, false])
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.page), ["settings", "after"])
        XCTAssertEqual(shots.captured[0].path, "/tmp/settings.png")
        XCTAssertTrue(shots.captured[1].path.hasSuffix("/relative/after.png"), shots.captured[1].path)

        // Later prompts have changes to start from, so there is no before to ask for.
        await runTurn(page: "/tmp/b.png", changes: DiffSummary(files: change.files + [FileChange(path: "b", kind: .added)]), captures: 2) {
            model.sendPrompt(taskID: id, text: $0)
        }
        await waitFor("an after") { self.model.task(id)?.screenshots?.count == 3 }
        XCTAssertEqual(agent.requests[1].screenshots, .app(wantsBefore: false))
    }

    func testAnAppsImagePathCanHaveSpaces() async {
        await startAppModel()
        let gate = Gate()
        let line = "SHIFT_SCREENSHOT: /tmp/my shots/after.png"
        agent.scripts.append([.pause(gate), .emit(OutcomeProtocol.screenshots(in: line)!), .emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "x")!
        await waitFor("the agent to pause") { gate.waiting == 1 }
        git.pendingChanges = change
        gate.open()
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        XCTAssertEqual(shots.captured.map(\.path), ["/tmp/my shots/after.png"])
    }

    func testAnAppsBeforeIsNeverAlsoItsAfter() async {
        await startAppModel()
        let id = await firstTurn(page: "/tmp/before.png", changes: change, captures: 1)
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [true])
    }

    func testAnAppImageNamedOnlyAtTheEndIsTheAfter() async {
        await startAppModel()
        let gate = Gate()
        agent.scripts.append([.pause(gate), .emit(.screenshots([ScreenshotTarget(page: "/tmp/a.png")])), .emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "x")!
        await waitFor("the agent to pause") { gate.waiting == 1 }
        git.pendingChanges = change
        gate.open()
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        XCTAssertEqual(model.task(id)?.screenshots?.map(\.isBefore), [false])
    }

    func testAnAppAgentThatNamesNothingGetsNoScreenshots() async {
        await startAppModel()
        agent.scripts.append([.emit(.finished(.completed(summary: "Done")))])
        let id = model.createTask(projectID: project.id, prompt: "x")!
        git.pendingChanges = change
        await waitFor("completed") { self.model.task(id)?.status == .completed }
        XCTAssertNil(model.task(id)?.screenshots)
        XCTAssertTrue(shots.captured.isEmpty)
    }

    func testAppInstructionsTellTheAgentToCapture() {
        let first = OutcomeProtocol.instructions(firstTurn: false, screenshots: .app(wantsBefore: true))
        XCTAssertTrue(first.contains("SHIFT_SCREENSHOT: <absolute path"))
        XCTAssertTrue(first.contains("Before your first edit"))
        XCTAssertFalse(OutcomeProtocol.instructions(firstTurn: false, screenshots: .app(wantsBefore: false)).contains("Before your first edit"))
    }

    func testCopyingAnImageMakesAPNGAndRefusesAnythingElse() async throws {
        let shooter = WebScreenshotter()
        let rep = try XCTUnwrap(NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 2, pixelsHigh: 2, bitsPerSample: 8, samplesPerPixel: 3,
                                                 hasAlpha: false, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0))
        let source = temp.appendingPathComponent("shot.jpg")
        try XCTUnwrap(rep.representation(using: .jpeg, properties: [:])).write(to: source)
        let file = temp.appendingPathComponent("folder/copy.png")
        let copied = await shooter.copyImage(at: source, to: file)
        XCTAssertTrue(copied)
        XCTAssertEqual(try Data(contentsOf: file).prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))

        let text = temp.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: text)
        let notAnImage = temp.appendingPathComponent("no.png")
        var refused = await shooter.copyImage(at: text, to: notAnImage)
        XCTAssertFalse(refused)
        refused = await shooter.copyImage(at: temp, to: notAnImage)
        XCTAssertFalse(refused, "a folder")
        refused = await shooter.copyImage(at: URL(fileURLWithPath: "/dev/zero"), to: notAnImage)
        XCTAssertFalse(refused, "never finishes reading")
        XCTAssertFalse(FileManager.default.fileExists(atPath: notAnImage.path))
    }

    /// The real browser view: a red page has to come out red, not as an empty window.
    func testWebScreenshotterCapturesThePage() async throws {
        let file = temp.appendingPathComponent("folder/shot.png")
        let page = try XCTUnwrap(URL(string: "data:text/html,<body style='background:rgb(255,0,0)'></body>"))
        let captured = await WebScreenshotter().capture(url: page, script: nil, to: file)
        XCTAssertTrue(captured)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        XCTAssertGreaterThanOrEqual(image.pixelsWide, 1280)
        let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.redComponent, 0.9)
        XCTAssertLessThan(color.greenComponent, 0.2)
    }

    /// A page that turns green for a moment on a click, as in the request this came from: the shot has to catch it.
    func testAScriptGetsThePageToTheStateThatShowsTheChange() async throws {
        let html = "<html style='height:100%'><body style='height:100%;background:rgb(0,0,255)' "
            + "onclick=\"this.style.background='rgb(0,255,0)';setTimeout(()=>this.style.background='rgb(0,0,255)',1000)\"></body></html>"
        let page = try XCTUnwrap(URL(string: "data:text/html," + html.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!))
        let file = temp.appendingPathComponent("green.png")
        let captured = await WebScreenshotter().capture(url: page, script: "document.body.click()", to: file)
        XCTAssertTrue(captured)
        let image = try XCTUnwrap(NSBitmapImageRep(data: Data(contentsOf: file)))
        let color = try XCTUnwrap(image.colorAt(x: image.pixelsWide / 2, y: image.pixelsHigh / 2)?.usingColorSpace(.sRGB))
        XCTAssertGreaterThan(color.greenComponent, 0.8)
        XCTAssertLessThan(color.blueComponent, 0.3)

        let failed = await WebScreenshotter().capture(url: page, script: "document.querySelector('#nope').click()",
                                                      to: temp.appendingPathComponent("no.png"))
        XCTAssertFalse(failed, "a script that fails shows nothing of what was asked")
    }

    func testAPageThatDoesNotLoadIsNoScreenshot() async {
        let closed = URL(string: "http://localhost:1")!
        let captured = await WebScreenshotter().capture(url: closed, script: nil, to: temp.appendingPathComponent("no.png"))
        XCTAssertFalse(captured)
    }
}
