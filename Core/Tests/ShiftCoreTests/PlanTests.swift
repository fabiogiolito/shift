import XCTest
@testable import ShiftCore

extension AppModelTests {
    func testPlanIsDraftedByTheAgentInTheProjectFolderAndApprovedIntoATask() async throws {
        let id = try XCTUnwrap(model.createPlan(projectID: project.id, idea: "Dark mode for the settings page"))
        let plan = try XCTUnwrap(model.plan(id))
        XCTAssertTrue(plan.path.hasPrefix(temp.appendingPathComponent("plans").path), "stored in Shift by default")
        XCTAssertTrue(model.tasks.isEmpty, "no task, worktree or server")
        await waitFor("the agent to finish") { !self.model.isWriting(planID: id) }
        let request = try XCTUnwrap(agent.requests.last)
        XCTAssertEqual(request.worktree, project.repoURL)
        XCTAssertTrue(request.instructions?.contains(plan.path) == true)
        XCTAssertTrue(request.prompt.contains("Dark mode for the settings page"))

        // What the agent would have written, then the user's edit.
        model.savePlanText(id, "# Settings dark mode\n\nA dark theme for settings.\n\n## How it works\n\nToggle.\n")
        XCTAssertEqual(model.plan(id)?.title, "Settings dark mode")

        let taskID = await model.approvePlan(id)
        let task = try XCTUnwrap(taskID.flatMap(model.task))
        XCTAssertNil(model.plan(id))
        XCTAssertEqual(task.title, "Settings dark mode")
        XCTAssertEqual(task.prompts.first?.attachments, [plan.path])
        XCTAssertTrue(task.prompts.first?.text.contains("A dark theme for settings.") == true)
    }

    func testPlanTagsAreSharedWithTasksAndGoToItsTask() async throws {
        let id = try XCTUnwrap(model.createPlan(projectID: project.id, idea: ""))
        model.revisePlan(id, text: "/tag Auth, theme")
        XCTAssertEqual(model.plan(id)?.tags, ["Auth", "theme"])
        XCTAssertFalse(model.isWriting(planID: id), "a tag command isn't a prompt")
        let other = try XCTUnwrap(model.createPlan(projectID: project.id, idea: ""))
        model.addTags(planID: other, "auth")
        XCTAssertTrue(model.tagIsShared(planID: id, "AUTH"))
        XCTAssertFalse(model.tagIsShared(planID: id, "theme"))
        model.renameTag(projectID: project.id, "auth", to: "login")
        XCTAssertEqual(model.plan(id)?.tags, ["login", "theme"])
        model.removeTag(planID: other, "login")
        XCTAssertEqual(model.project(project.id)?.tagNames, ["login", "theme"], "still on the first plan")
        model.deletePlan(other)

        let taskID = await model.approvePlan(id)
        XCTAssertEqual(taskID.flatMap(model.task)?.tags, ["login", "theme"])
        XCTAssertEqual(model.project(project.id)?.tagNames, ["login", "theme"], "the task has them now")
    }

    func testBlankPlanHasNoAgentRun() throws {
        let id = try XCTUnwrap(model.createPlan(projectID: project.id, idea: ""))
        XCTAssertFalse(model.isWriting(planID: id))
        XCTAssertEqual(model.planText(id), "# Untitled plan\n\n\n")
    }

    func testIgnoredPlansFolderIgnoresItself() throws {
        project.planStorage = .ignored
        project.plansFolder = "docs/plans/"
        model.updateProject(project)
        let id = try XCTUnwrap(model.createPlan(projectID: project.id, idea: ""))
        let folder = temp.appendingPathComponent("docs/plans")
        XCTAssertEqual(model.plan(id)?.url.deletingLastPathComponent().standardizedFileURL, folder.standardizedFileURL)
        XCTAssertEqual(try String(contentsOf: folder.appendingPathComponent(".gitignore"), encoding: .utf8), "*\n")
    }

    func testApprovedCommittedPlanLeavesTheCheckoutForTheTaskToAdd() async throws {
        project.planStorage = .repository
        model.updateProject(project)
        let id = try XCTUnwrap(model.createPlan(projectID: project.id, idea: ""))
        let original = try XCTUnwrap(model.plan(id)).url
        let taskID = await model.approvePlan(id)
        let task = try XCTUnwrap(taskID.flatMap(model.task))
        XCTAssertFalse(FileManager.default.fileExists(atPath: original.path), "it would stop the merge into the checkout")
        let attached = try XCTUnwrap(task.prompts.first?.attachments.first)
        XCTAssertTrue(FileManager.default.fileExists(atPath: attached))
        XCTAssertTrue(task.prompts.first?.text.contains("`plans/untitled-plan.md`") == true)
    }

    func testPlanSummaryAndTitle() {
        let text = "# Title here\nFirst paragraph\nstill.\n\n## Goal\n\nMore."
        XCTAssertEqual(Plan.title(of: text), "Title here")
        XCTAssertEqual(Plan.summary(of: text), "First paragraph\nstill.")
    }
}
