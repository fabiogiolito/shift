import XCTest
@testable import ShiftCore

final class GitServiceTests: XCTestCase {
    let service = GitService()
    var root: URL!
    var repo: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("shift-git-tests-\(UUID().uuidString)")
            .resolvingSymlinksInPath()
        repo = root.appendingPathComponent("repo")
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try sh("init", "-b", "main")
        try sh("config", "user.name", "Test")
        try sh("config", "user.email", "test@example.com")
        try sh("config", "commit.gpgsign", "false")
        try write("a.txt", "one\ntwo\nthree\n")
        try write("b.txt", "bee\n")
        try write("old name.txt", "line 1\nline 2\nline 3\nline 4\n")
        try Data([0, 1, 2, 3, 0, 255]).write(to: repo.appendingPathComponent("image.bin"))
        try sh("add", "-A")
        try sh("commit", "-m", "initial")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Helpers

    @discardableResult
    func sh(_ args: String..., in dir: URL? = nil) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = args
        process.currentDirectoryURL = dir ?? repo
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        if process.terminationStatus != 0 {
            throw GitError(message: "git \(args): " + String(decoding: errData, as: UTF8.self))
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }

    func write(_ name: String, _ text: String, in dir: URL? = nil) throws {
        try text.write(to: (dir ?? repo).appendingPathComponent(name), atomically: true, encoding: .utf8)
    }

    func read(_ name: String, in dir: URL? = nil) -> String? {
        try? String(contentsOf: (dir ?? repo).appendingPathComponent(name), encoding: .utf8)
    }

    /// Creates a task worktree on `branch`, runs `edit` in it and commits.
    @discardableResult
    func task(_ branch: String, edit: (URL) throws -> Void) async throws -> URL {
        let path = root.appendingPathComponent("worktrees/\(branch)")
        try await service.createWorktree(repo: repo, branch: branch, base: "main", at: path)
        try edit(path)
        try await service.commitAll(worktree: path, message: "work on \(branch)")
        return path
    }

    /// Everything that must be identical before and after a failed merge.
    func snapshot() throws -> [String] {
        let gitDir = repo.appendingPathComponent(".git")
        return [
            try sh("rev-parse", "HEAD"),
            try sh("rev-parse", "main"),
            try sh("symbolic-ref", "HEAD"),
            try sh("status", "--porcelain=v1", "--untracked-files=all"),
            try sh("diff"),
            try sh("diff", "--cached"),
            try sh("stash", "list"),
            String(FileManager.default.fileExists(atPath: gitDir.appendingPathComponent("MERGE_HEAD").path)),
        ]
    }

    /// Uncommitted work in the main checkout: an unstaged edit, a staged edit and an untracked file.
    func makeMainDirty() throws {
        try write("b.txt", "bee\nuncommitted\n")
        try write("staged.txt", "staged\n")
        try sh("add", "staged.txt")
        try write("untracked.txt", "untracked\n")
    }

    func assertDirtyWorkSurvived(file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(read("b.txt"), "bee\nuncommitted\n", file: file, line: line)
        XCTAssertEqual(read("staged.txt"), "staged\n", file: file, line: line)
        XCTAssertEqual(read("untracked.txt"), "untracked\n", file: file, line: line)
        let status = try sh("status", "--porcelain=v1").components(separatedBy: "\n").sorted()
        XCTAssertEqual(status, [" M b.txt", "?? untracked.txt", "A  staged.txt"], file: file, line: line)
    }

    // MARK: - Setup exclusions

    func excludeFile() throws -> String {
        try String(contentsOf: repo.appendingPathComponent(".git/info/exclude"), encoding: .utf8)
    }

    func testSetupFilesAreNotCommittedButLaterFilesAre() async throws {
        let path = root.appendingPathComponent("worktrees/t1")
        try await service.createWorktree(repo: repo, branch: "t1", base: "main", at: path)
        try write(".env", "SECRET=1\n", in: path)
        try FileManager.default.createDirectory(at: path.appendingPathComponent("node_modules/pkg"),
                                                withIntermediateDirectories: true)
        try write("node_modules/pkg/index.js", "x\n", in: path)
        try await service.excludeUntracked(worktree: path)

        let before = try await service.changes(worktree: path, base: "main")
        XCTAssertEqual(before.files, [])
        let nothing = try await service.commitAll(worktree: path, message: "nothing")
        XCTAssertFalse(nothing)

        try write("agent.txt", "work\n", in: path)
        try write("a.txt", "one\ntwo\nthree\nfour\n", in: path)
        let diff = try await service.diff(worktree: path, base: "main")
        XCTAssertEqual(diff.map(\.change.path).sorted(), ["a.txt", "agent.txt"])
        let committed = try await service.commitAll(worktree: path, message: "work")
        XCTAssertTrue(committed)
        XCTAssertEqual(try sh("ls-tree", "-r", "--name-only", "t1").components(separatedBy: "\n").sorted(),
                       ["a.txt", "agent.txt", "b.txt", "image.bin", "old name.txt"])
        XCTAssertEqual(read(".env", in: path), "SECRET=1\n")
    }

    func testOddPathsAreExcludedExactly() async throws {
        let path = root.appendingPathComponent("worktrees/t1")
        try await service.createWorktree(repo: repo, branch: "t1", base: "main", at: path)
        let setup = ["my file.txt", "trailing ", "*.log", "[ab].txt", "#notes", "!bang", "back\\slash", "what?.txt",
                     "two\nlines", "dir with space/in side.txt"]
        for name in setup {
            try FileManager.default.createDirectory(at: path.appendingPathComponent(name).deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try write(name, "setup\n", in: path)
        }
        try await service.excludeUntracked(worktree: path)
        let none = try await service.changes(worktree: path, base: "main")
        XCTAssertEqual(none.files, [])

        // Names the patterns would also match if they were globs, comments or unanchored.
        let agent = ["x.log", "a.txt.bak", "b.txt2", "notes", "bang", "whatX.txt", "my file.txt2", "trailing",
                     "sub/my file.txt", "sub/#notes", "sub/*.log"]
        try FileManager.default.createDirectory(at: path.appendingPathComponent("sub"), withIntermediateDirectories: true)
        for name in agent { try write(name, "agent\n", in: path) }
        try write("a.txt", "changed\n", in: path) // "[ab].txt" as a glob would be a.txt: tracked, but check the diff
        let changes = try await service.changes(worktree: path, base: "main")
        XCTAssertEqual(changes.files.map(\.path).sorted(), (agent + ["a.txt"]).sorted())
        try await service.commitAll(worktree: path, message: "work")
        XCTAssertEqual(try sh("status", "--porcelain=v1", in: path), "")
    }

    func testExcludingTwiceKeepsOneEntryAndTheUsersLines() async throws {
        let info = repo.appendingPathComponent(".git/info")
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let users = "# mine\n*.secret\n/.env.local" // no newline at the end
        try users.write(to: info.appendingPathComponent("exclude"), atomically: true, encoding: .utf8)

        for branch in ["t1", "t2"] {
            let path = root.appendingPathComponent("worktrees/\(branch)")
            try await service.createWorktree(repo: repo, branch: branch, base: "main", at: path)
            try write(".env", "SECRET=1\n", in: path)
            try write(".env.local", "already ignored by the user\n", in: path)
            if branch == "t2" { try write("extra.txt", "x\n", in: path) }
            try await service.excludeUntracked(worktree: path)
            try await service.excludeUntracked(worktree: path)
        }
        XCTAssertEqual(try excludeFile(), users + "\n" + GitService.excludeMarker + "\n/.env\n/extra.txt\n")
    }

    func testParallelSetupsDoNotLoseOrDuplicateEntries() async throws {
        var paths: [URL] = []
        for index in 0..<8 {
            let path = root.appendingPathComponent("worktrees/p\(index)")
            try await service.createWorktree(repo: repo, branch: "p\(index)", base: "main", at: path)
            try write(".env", "SECRET=1\n", in: path)
            try write("only-\(index).txt", "x\n", in: path)
            paths.append(path)
        }
        let service = self.service
        try await withThrowingTaskGroup(of: Void.self) { group in
            for path in paths { group.addTask { try await service.excludeUntracked(worktree: path) } }
            try await group.waitForAll()
        }
        let lines = try excludeFile().components(separatedBy: "\n").filter { !$0.hasPrefix("#") && !$0.isEmpty }
        XCTAssertEqual(lines.sorted(), (["/.env"] + (0..<8).map { "/only-\($0).txt" }).sorted())
        XCTAssertEqual(try excludeFile().components(separatedBy: "\n").filter { $0 == GitService.excludeMarker }.count, 1)
    }

    func testNothingUntrackedLeavesTheExcludeFileAlone() async throws {
        let before = try? excludeFile()
        let path = root.appendingPathComponent("worktrees/t1")
        try await service.createWorktree(repo: repo, branch: "t1", base: "main", at: path)
        try write("a.txt", "modified by setup\n", in: path)
        try await service.excludeUntracked(worktree: path)
        XCTAssertEqual(try? excludeFile(), before)
        // Tracked files that setup modified are not covered.
        let changes = try await service.changes(worktree: path, base: "main")
        XCTAssertEqual(changes.files.map(\.path), ["a.txt"])
    }

    // MARK: - Basics

    func testRepositoryAndBranches() async throws {
        let isRepo = await service.isRepository(repo)
        let isNotRepo = await service.isRepository(root)
        XCTAssertTrue(isRepo)
        XCTAssertFalse(isNotRepo)
        try sh("branch", "other")
        let branches = try await service.branches(repo: repo)
        XCTAssertEqual(branches, ["main", "other"])
        let current = try await service.currentBranch(repo: repo)
        XCTAssertEqual(current, "main")
        let exists = await service.branchExists(repo: repo, branch: "other")
        let missing = await service.branchExists(repo: repo, branch: "nope")
        XCTAssertTrue(exists)
        XCTAssertFalse(missing)
    }

    func testWorktreeCreateAndRemove() async throws {
        let path = root.appendingPathComponent("deep/nested/3001")
        try await service.createWorktree(repo: repo, branch: "task/3001", base: "main", at: path)
        XCTAssertEqual(read("a.txt", in: path), "one\ntwo\nthree\n")
        let branch = try await service.currentBranch(repo: path)
        XCTAssertEqual(branch, "task/3001")
        XCTAssertEqual(try sh("rev-parse", "task/3001"), try sh("rev-parse", "main"))

        try write("junk.txt", "uncommitted", in: path) // forced removal must not care
        try await service.removeWorktree(repo: repo, path: path, deleteBranch: "task/3001")
        XCTAssertFalse(FileManager.default.fileExists(atPath: path.path))
        let exists = await service.branchExists(repo: repo, branch: "task/3001")
        XCTAssertFalse(exists)
        XCTAssertFalse(try sh("worktree", "list").contains("3001"))

        // Already gone: silent.
        try await service.removeWorktree(repo: repo, path: path, deleteBranch: "task/3001")
        try await service.removeWorktree(repo: repo, path: path, deleteBranch: nil)
    }

    func testRemoveWorktreeDeletedBehindGitsBack() async throws {
        let path = try await task("t") { _ in }
        try FileManager.default.removeItem(at: path)
        try await service.removeWorktree(repo: repo, path: path, deleteBranch: "t")
        let exists = await service.branchExists(repo: repo, branch: "t")
        XCTAssertFalse(exists)
        XCTAssertFalse(try sh("worktree", "list", "--porcelain").contains("refs/heads/t"))
    }

    func testCommitAll() async throws {
        let path = root.appendingPathComponent("wt")
        try await service.createWorktree(repo: repo, branch: "t", base: "main", at: path)
        let nothing = try await service.commitAll(worktree: path, message: "nothing")
        XCTAssertFalse(nothing)
        try write("new.txt", "new\n", in: path)
        try FileManager.default.removeItem(at: path.appendingPathComponent("b.txt"))
        let committed = try await service.commitAll(worktree: path, message: "something")
        XCTAssertTrue(committed)
        XCTAssertEqual(try sh("status", "--porcelain", in: path), "")
        XCTAssertEqual(try sh("log", "-1", "--format=%s", in: path), "something")
    }

    // MARK: - Diff

    func testChangesIncludeCommittedUncommittedAndUntracked() async throws {
        // Committed by the agent: a modification and a rename.
        let path = try await task("t") { wt in
            try write("a.txt", "one\n2\nthree\nfour\n", in: wt)
            try sh("mv", "old name.txt", "new name.txt", in: wt)
        }
        // Not committed: untracked text, untracked binary, modified binary, deletion.
        try write("untracked.txt", "x\ny\n", in: path)
        try Data([9, 0, 9, 0]).write(to: path.appendingPathComponent("new.bin"))
        try Data([0, 1, 2, 3, 0, 254, 7]).write(to: path.appendingPathComponent("image.bin"))
        try FileManager.default.removeItem(at: path.appendingPathComponent("b.txt"))
        // Base moving on must not show up as the task's change.
        try write("base-only.txt", "base\n")
        try sh("add", "-A")
        try sh("commit", "-m", "base moves on")

        let indexBefore = try sh("status", "--porcelain=v1", in: path)
        let summary = try await service.changes(worktree: path, base: "main")
        XCTAssertEqual(try sh("status", "--porcelain=v1", in: path), indexBefore, "real index must not be touched")

        let byPath = Dictionary(uniqueKeysWithValues: summary.files.map { ($0.path, $0) })
        XCTAssertEqual(Set(byPath.keys), ["a.txt", "new name.txt", "untracked.txt", "new.bin", "image.bin", "b.txt"])
        XCTAssertEqual(byPath["a.txt"], FileChange(path: "a.txt", kind: .modified, additions: 2, deletions: 1))
        XCTAssertEqual(byPath["new name.txt"], FileChange(path: "new name.txt", oldPath: "old name.txt", kind: .renamed))
        XCTAssertEqual(byPath["untracked.txt"], FileChange(path: "untracked.txt", kind: .added, additions: 2))
        XCTAssertEqual(byPath["new.bin"], FileChange(path: "new.bin", kind: .added, isBinary: true))
        XCTAssertEqual(byPath["image.bin"], FileChange(path: "image.bin", kind: .modified, isBinary: true))
        XCTAssertEqual(byPath["b.txt"], FileChange(path: "b.txt", kind: .deleted, deletions: 1))
        XCTAssertEqual(summary.additions, 4)
        XCTAssertEqual(summary.deletions, 2)
    }

    func testDiffHunksAndLineNumbers() async throws {
        let path = try await task("t") { wt in
            try write("a.txt", "one\n2\nthree\nfour\n", in: wt)
            try Data([1, 0, 1]).write(to: wt.appendingPathComponent("image.bin"))
        }
        let diffs = try await service.diff(worktree: path, base: "main")
        XCTAssertEqual(diffs.map(\.change.path), ["a.txt", "image.bin"])
        XCTAssertTrue(diffs[1].change.isBinary)
        XCTAssertTrue(diffs[1].hunks.isEmpty)

        XCTAssertEqual(diffs[0].hunks.count, 1)
        XCTAssertTrue(diffs[0].hunks[0].header.hasPrefix("@@ -1,3 +1,4 @@"))
        XCTAssertEqual(diffs[0].hunks[0].lines, [
            DiffLine(kind: .context, text: "one", oldNumber: 1, newNumber: 1),
            DiffLine(kind: .removed, text: "two", oldNumber: 2),
            DiffLine(kind: .added, text: "2", newNumber: 2),
            DiffLine(kind: .context, text: "three", oldNumber: 3, newNumber: 3),
            DiffLine(kind: .added, text: "four", newNumber: 4),
        ])
    }

    func testNoChanges() async throws {
        let path = try await task("t") { _ in }
        let summary = try await service.changes(worktree: path, base: "main")
        XCTAssertEqual(summary.files, [])
    }

    // MARK: - Mergeability

    func testCanMergeCleanlyAndIsMerged() async throws {
        try await task("clean") { try write("new.txt", "new\n", in: $0) }
        try await task("clash") { try write("a.txt", "theirs\n", in: $0) }
        try write("a.txt", "ours\n")
        try sh("commit", "-am", "base edits a")
        try makeMainDirty()
        let before = try snapshot()

        let clean = try await service.canMergeCleanly(repo: repo, branch: "clean", base: "main")
        let clash = try await service.canMergeCleanly(repo: repo, branch: "clash", base: "main")
        XCTAssertTrue(clean)
        XCTAssertFalse(clash)
        XCTAssertEqual(try snapshot(), before)

        let notYet = try await service.isMerged(repo: repo, branch: "clean", base: "main")
        XCTAssertFalse(notYet)
        let result = try await service.merge(repo: repo, branch: "clean", into: "main", message: "m")
        XCTAssertEqual(result, .merged)
        let merged = try await service.isMerged(repo: repo, branch: "clean", base: "main")
        XCTAssertTrue(merged)
    }

    /// Found end to end: after a restart, a finished task that had changed nothing was taken for
    /// one that had been merged outside the app, and cleaned up.
    func testBranchWithoutCommitsIsNotMerged() async throws {
        let worktree = root.appendingPathComponent("untouched")
        try await service.createWorktree(repo: repo, branch: "untouched", base: "main", at: worktree)
        let fresh = try await service.isMerged(repo: repo, branch: "untouched", base: "main")
        XCTAssertFalse(fresh)
        let result = try await service.merge(repo: repo, branch: "untouched", into: "main", message: "m")
        XCTAssertEqual(result, .merged, "merging nothing is still fine")

        try write("new.txt", "new\n", in: worktree)
        try await service.commitAll(worktree: worktree, message: "c")
        try sh("merge", "--ff-only", "untouched")
        let merged = try await service.isMerged(repo: repo, branch: "untouched", base: "main")
        XCTAssertTrue(merged, "fast-forwarded outside the app")
    }

    // MARK: - Merge

    func testCleanMergeWithBaseCheckedOutKeepsUncommittedChanges() async throws {
        try await task("t") { try write("new.txt", "new\n", in: $0) }
        try makeMainDirty()
        let tip = try sh("rev-parse", "main")

        let result = try await service.merge(repo: repo, branch: "t", into: "main", message: "Merge task 3001")
        XCTAssertEqual(result, .merged)

        XCTAssertEqual(read("new.txt"), "new\n", "merged work must be in the working tree")
        try assertDirtyWorkSurvived()
        XCTAssertEqual(try sh("log", "-1", "--format=%s", "main"), "Merge task 3001")
        XCTAssertEqual(try sh("rev-parse", "main^1"), tip)
        XCTAssertEqual(try sh("rev-parse", "main^2"), try sh("rev-parse", "t"))
        XCTAssertEqual(try sh("symbolic-ref", "--short", "HEAD"), "main")
    }

    func testCleanMergeWithBaseNotCheckedOut() async throws {
        try await task("t") { try write("new.txt", "new\n", in: $0) }
        try sh("checkout", "-b", "elsewhere")
        try makeMainDirty()
        let tip = try sh("rev-parse", "main")
        let head = try sh("rev-parse", "HEAD")

        let result = try await service.merge(repo: repo, branch: "t", into: "main", message: "Merge task")
        XCTAssertEqual(result, .merged)

        XCTAssertEqual(try sh("rev-parse", "main^1"), tip)
        XCTAssertEqual(try sh("rev-parse", "main^2"), try sh("rev-parse", "t"))
        XCTAssertEqual(try sh("show", "main:new.txt"), "new")
        XCTAssertEqual(try sh("log", "-1", "--format=%s", "main"), "Merge task")
        // The user's checkout is not involved at all.
        XCTAssertEqual(try sh("symbolic-ref", "--short", "HEAD"), "elsewhere")
        XCTAssertEqual(try sh("rev-parse", "HEAD"), head)
        XCTAssertNil(read("new.txt"))
        try assertDirtyWorkSurvived()
    }

    func testConflictLeavesRepoUntouched() async throws {
        try await task("t") { try write("a.txt", "theirs\n", in: $0) }
        try write("a.txt", "ours\n")
        try sh("commit", "-am", "base edits a")
        try makeMainDirty()
        let before = try snapshot()

        let result = try await service.merge(repo: repo, branch: "t", into: "main", message: "m")
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(try snapshot(), before)
        XCTAssertEqual(read("a.txt"), "ours\n")
        try assertDirtyWorkSurvived()
    }

    func testConflictWithBaseNotCheckedOutLeavesRepoUntouched() async throws {
        try await task("t") { try write("a.txt", "theirs\n", in: $0) }
        try write("a.txt", "ours\n")
        try sh("commit", "-am", "base edits a")
        try sh("checkout", "-b", "elsewhere")
        try makeMainDirty()
        let before = try snapshot()

        let result = try await service.merge(repo: repo, branch: "t", into: "main", message: "m")
        XCTAssertEqual(result, .conflict)
        XCTAssertEqual(try snapshot(), before)
        try assertDirtyWorkSurvived()
    }

    /// The branch merges cleanly into base, but the user has uncommitted edits to a file it changes.
    func testUncommittedChangesInTheWayThrowAndAreKept() async throws {
        try await task("t") {
            try write("b.txt", "bee\nfrom the task\n", in: $0)
            try write("untracked.txt", "from the task\n", in: $0)
            try write("other.txt", "other\n", in: $0)
        }
        try makeMainDirty()
        let before = try snapshot()

        do {
            _ = try await service.merge(repo: repo, branch: "t", into: "main", message: "m")
            XCTFail("expected the merge to be refused")
        } catch let error as GitError {
            XCTAssertEqual(error.message, "Uncommitted changes to b.txt would be overwritten. "
                           + "Commit or stash your changes in repo on main first, then merge again.")
        }
        XCTAssertEqual(try snapshot(), before)
        XCTAssertNil(read("other.txt"), "no part of the merge may be applied")
        try assertDirtyWorkSurvived()
        let merged = try await service.isMerged(repo: repo, branch: "t", base: "main")
        XCTAssertFalse(merged)
    }

    func testMergeWhenBaseIsCheckedOutInALinkedWorktree() async throws {
        try await task("t") { try write("new.txt", "new\n", in: $0) }
        try sh("checkout", "-b", "elsewhere")
        let mainCheckout = root.appendingPathComponent("main-checkout")
        try sh("worktree", "add", mainCheckout.path, "main")
        try write("b.txt", "bee\nuncommitted\n", in: mainCheckout)

        let result = try await service.merge(repo: repo, branch: "t", into: "main", message: "m")
        XCTAssertEqual(result, .merged)
        XCTAssertEqual(read("new.txt", in: mainCheckout), "new\n")
        XCTAssertEqual(read("b.txt", in: mainCheckout), "bee\nuncommitted\n")
        XCTAssertEqual(try sh("status", "--porcelain", in: mainCheckout), " M b.txt")
    }

    func testMergingAnAlreadyMergedBranchDoesNothing() async throws {
        try await task("t") { try write("new.txt", "new\n", in: $0) }
        _ = try await service.merge(repo: repo, branch: "t", into: "main", message: "m")
        let tip = try sh("rev-parse", "main")
        let result = try await service.merge(repo: repo, branch: "t", into: "main", message: "again")
        XCTAssertEqual(result, .merged)
        XCTAssertEqual(try sh("rev-parse", "main"), tip)
    }

    func testMergeOfMissingBranchThrows() async throws {
        let before = try snapshot()
        do {
            _ = try await service.merge(repo: repo, branch: "nope", into: "main", message: "m")
            XCTFail("expected an error")
        } catch let error as GitError {
            XCTAssertEqual(error.message, "The task's branch nope no longer exists.")
        }
        XCTAssertEqual(try snapshot(), before)
    }

    func testMergeIntoMissingBaseThrows() async throws {
        try await task("t") { try write("new.txt", "new\n", in: $0) }
        do {
            _ = try await service.merge(repo: repo, branch: "t", into: "gone", message: "m")
            XCTFail("expected an error")
        } catch let error as GitError {
            XCTAssertEqual(error.message, "The branch gone no longer exists in repo.")
        }
    }

    func testMergeFailureMessages() {
        let checkout = URL(fileURLWithPath: "/Users/me/Sites/spot")
        let many = "error: Your local changes to the following files would be overwritten by merge:\n"
            + (1...7).map { "\tf\($0).txt" }.joined(separator: "\n")
            + "\nPlease commit your changes or stash them before you merge.\nAborting"
        XCTAssertEqual(GitService.mergeFailure(many, checkout: checkout, base: "main"),
                       "Uncommitted changes to f1.txt, f2.txt, f3.txt, f4.txt, f5.txt and 2 more would be overwritten. "
                       + "Commit or stash your changes in spot on main first, then merge again.")
        let untracked = "error: The following untracked working tree files would be overwritten by merge:\n\tnew.txt\nPlease move or remove them before you merge.\nAborting"
        XCTAssertEqual(GitService.mergeFailure(untracked, checkout: checkout, base: "main"),
                       "Uncommitted changes to new.txt would be overwritten. Commit or stash your changes in spot on main first, then merge again.")
        XCTAssertEqual(GitService.mergeFailure("\nfatal: something odd\nhint: more", checkout: checkout, base: "main"),
                       "something odd")
    }

    // MARK: - Push

    /// A bare repo in the temp dir as `name`'s remote.
    @discardableResult
    func addRemote(_ name: String = "origin") throws -> URL {
        let bare = root.appendingPathComponent("\(name).git")
        try sh("init", "--bare", "-b", "main", bare.path, in: root)
        try sh("remote", "add", name, bare.path)
        return bare
    }

    func commit(_ message: String, in dir: URL? = nil) throws {
        try write("\(UUID().uuidString).txt", message, in: dir)
        try sh("add", "-A", in: dir)
        try sh("commit", "-m", message, in: dir)
    }

    func pushError(_ branch: String = "main", remote: String = "origin") async -> String? {
        do { try await service.push(repo: repo, branch: branch, remote: remote); return nil } catch {
            return (error as? GitError)?.message ?? "\(error)"
        }
    }

    func testNoRemote() async {
        let remote = await service.remote(repo: repo, branch: "main")
        XCTAssertNil(remote)
    }

    func testRemotePrefersUpstreamThenOriginThenFirst() async throws {
        try addRemote("backup")
        var remote = await service.remote(repo: repo, branch: "main")
        XCTAssertEqual(remote, "backup")
        try addRemote("origin")
        remote = await service.remote(repo: repo, branch: "main")
        XCTAssertEqual(remote, "origin")
        try sh("config", "branch.main.remote", "backup")
        remote = await service.remote(repo: repo, branch: "main")
        XCTAssertEqual(remote, "backup")
    }

    func testPublishAheadAndUpToDate() async throws {
        let bare = try addRemote()
        // The remote does not have main yet: every commit counts, and pushing publishes it.
        var count = try await service.unpushedCount(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(count, 1)
        try await service.push(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(try sh("rev-parse", "main", in: bare), try sh("rev-parse", "main"))
        XCTAssertEqual(try sh("config", "branch.main.remote"), "origin")
        count = try await service.unpushedCount(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(count, 0)

        try commit("two")
        try commit("three")
        count = try await service.unpushedCount(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(count, 2)
        try await service.push(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(try sh("rev-parse", "main", in: bare), try sh("rev-parse", "main"))
        count = try await service.unpushedCount(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(count, 0)
    }

    func testRejectedPushSaysToPullFirst() async throws {
        let bare = try addRemote()
        try await service.push(repo: repo, branch: "main", remote: "origin")
        // Someone else pushes first.
        let other = root.appendingPathComponent("other")
        try sh("clone", bare.path, other.path, in: root)
        try sh("config", "user.name", "Other", in: other)
        try sh("config", "user.email", "other@example.com", in: other)
        try commit("theirs", in: other)
        try sh("push", "origin", "main", in: other)

        try commit("mine")
        let count = try await service.unpushedCount(repo: repo, branch: "main", remote: "origin")
        XCTAssertEqual(count, 1)
        let message = await pushError()
        XCTAssertEqual(message, "The remote has changes that aren't in your main. Pull them in your usual Git tool, then push again.")
        XCTAssertNotEqual(try sh("rev-parse", "main", in: bare), try sh("rev-parse", "main"))
    }

    func testMissingRemoteFailsWithoutHanging() async throws {
        try sh("remote", "add", "origin", root.appendingPathComponent("nowhere.git").path)
        let message = await pushError()
        XCTAssertEqual(message?.hasPrefix("Could not push to origin: "), true, message ?? "")
        XCTAssertEqual(message?.contains("does not appear to be a git repository"), true, message ?? "")
    }

    func testPushThatHangsIsStopped() async throws {
        try sh("config", "protocol.ext.allow", "always")
        try sh("remote", "add", "origin", "ext::sleep 30")
        var service = GitService()
        service.pushTimeout = 1
        let start = Date()
        do {
            try await service.push(repo: repo, branch: "main", remote: "origin")
            XCTFail("push should fail")
        } catch {
            XCTAssertEqual((error as? GitError)?.message, "Pushing to origin took too long and was stopped. Try again.")
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 10)
    }

    func testPushFailureMessages() {
        func message(_ output: String, url: String = "git@github.com:me/spot.git") -> String {
            GitService.pushFailure(output, remote: "origin", url: url, branch: "main")
        }
        XCTAssertEqual(message("git@github.com: Permission denied (publickey).\nfatal: Could not read from remote repository."),
                       "Couldn't sign in to github.com. Check your Git credentials.")
        XCTAssertEqual(message("fatal: could not read Username for 'https://github.com': terminal prompts disabled",
                               url: "https://github.com/me/spot.git"),
                       "Couldn't sign in to github.com. Check your Git credentials.")
        XCTAssertEqual(message("ssh: Could not resolve hostname github.com: nodename nor servname provided"),
                       "Couldn't reach github.com. Check your internet connection and try again.")
        XCTAssertEqual(message("To github.com:me/spot.git\n ! [rejected]        main -> main (fetch first)\nerror: failed to push some refs"),
                       "The remote has changes that aren't in your main. Pull them in your usual Git tool, then push again.")
        XCTAssertEqual(message("Welcome!\nerror: src refspec main does not match any"),
                       "Could not push to origin: src refspec main does not match any")
        XCTAssertEqual(GitService.host(of: "ssh://git@example.com:2222/x.git"), "example.com")
        XCTAssertEqual(GitService.host(of: "/tmp/remote.git"), "/tmp/remote.git")
    }

    func testAddWorktreeBringsBackADeletedWorktreeFolder() async throws {
        let path = try await task("t") { try write("work.txt", "work\n", in: $0) }
        try FileManager.default.removeItem(at: path)
        try await service.addWorktree(repo: repo, branch: "t", at: path)
        XCTAssertEqual(read("work.txt", in: path), "work\n")
        let branch = try await service.currentBranch(repo: path)
        XCTAssertEqual(branch, "t")

        // A new branch at a path whose old worktree was deleted by hand.
        let other = try await task("u") { _ in }
        try FileManager.default.removeItem(at: other)
        try sh("worktree", "prune")
        try sh("branch", "-D", "u")
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: other)
        try await service.createWorktree(repo: repo, branch: "u", base: "main", at: other)
        XCTAssertEqual(read("a.txt", in: other), "one\ntwo\nthree\n")
    }
}
