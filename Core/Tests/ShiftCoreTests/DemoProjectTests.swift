#if DEBUG
import XCTest
@testable import ShiftCore

final class DemoProjectTests: XCTestCase {
    func testSeedsOnceAndStartsOverWhenNoTaskIsOpen() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-demo-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let git = GitService(), store = JSONStateStore(root: root)
        // Whatever else the build's data holds stays.
        let other = Project(name: "Other", repoPath: "/tmp/other", baseBranch: "main")
        await store.save(AppState(projects: [other], nextTaskID: 3100))

        try await DemoProject.seed(root: root, git: git)
        var state = await store.load()
        XCTAssertEqual(state.projects.map(\.name), ["Other", "Shift Demo"])
        XCTAssertEqual(state.projects.last?.takesScreenshots, true, "the demo is there to try them")
        XCTAssertEqual(state.tasks.map(\.id), [3100, 3101, 3102, 3103])
        XCTAssertEqual(state.nextTaskID, 3104)
        XCTAssertEqual(state.tasks.map(\.status), [.completed, .completed, .completed, .merged])
        XCTAssertEqual(state.tasks.last?.mergedPullRequest, 3103)
        let repo = try XCTUnwrap(state.projects.last).repoURL
        let blue = try await git.diff(worktree: state.tasks[0].worktreeURL, base: "main")
        let red = try await git.diff(worktree: state.tasks[1].worktreeURL, base: "main")
        XCTAssertEqual(blue.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.map { $0.text.trimmingCharacters(in: .whitespaces) }, [#"background: "blue","#])
        XCTAssertEqual(red.flatMap(\.hunks).flatMap(\.lines).filter { $0.kind == .added }.map { $0.text.trimmingCharacters(in: .whitespaces) }, [#"color: "red","#])
        let remote = await git.remote(repo: repo, branch: "main")
        XCTAssertEqual(remote, "origin")
        let unpushed = try await git.unpushedCount(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(unpushed, 0, "starts in sync, so merging is what gives it something to push")
        let cleanBlue = try await git.canMergeCleanly(repo: repo, branch: state.tasks[0].branch, base: "main")
        XCTAssertTrue(cleanBlue)

        // Every task merges: the changes don't touch neighbouring lines.
        for task in state.tasks {
            let result = try await git.merge(repo: repo, branch: task.branch, into: "main", message: task.title)
            XCTAssertEqual(result, .merged)
        }

        // Still open: left as it is.
        try await DemoProject.seed(root: root, git: git)
        let again = await store.load()
        XCTAssertEqual(again, state)

        // Nothing open: starts over from a page with neither change.
        state.tasks = state.tasks.map { var task = $0; task.status = .merged; return task }
        await store.save(state)
        try await DemoProject.seed(root: root, git: git)
        state = await store.load()
        XCTAssertEqual(state.projects.count, 2)
        XCTAssertEqual(state.tasks.map(\.id), [3104, 3105, 3106, 3107])
        let page = try String(contentsOf: repo.appendingPathComponent(DemoProject.page), encoding: .utf8)
        XCTAssertTrue(page.contains(#"background: "white""#) && page.contains(#"color: "black""#))
    }
}
#endif
