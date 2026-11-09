import Foundation

// Plans: pre-tasks (docs/specs/plans.md). `/plan <idea>` makes a Markdown document that the agent drafts in the
// project's folder, reading the code but changing nothing else. The user edits it or asks for changes, then approves
// it: that starts a task with the plan attached, and the plan leaves the list.

extension AppModel {
    public func plan(_ id: Plan.ID) -> Plan? {
        plans.first { $0.id == id }
    }

    /// Newest first.
    public func plans(in projectID: Project.ID) -> [Plan] {
        plans.filter { $0.projectID == projectID }.sorted { $0.createdAt > $1.createdAt }
    }

    /// The agent is writing it.
    public func isWriting(planID: Plan.ID) -> Bool { planActivity[planID] != nil }

    /// `/plan <idea>`: a new document, drafted by the agent from the idea. No idea: a blank one for the user to write.
    @discardableResult
    public func createPlan(projectID: Project.ID, idea: String, attachments: [String] = [], createdBy: TaskItem.ID? = nil) -> Plan.ID? {
        let idea = idea.trimmingCharacters(in: .whitespacesAndNewlines)
        guard services != nil, let project = project(projectID) else { return nil }
        let drafts = !idea.isEmpty || !attachments.isEmpty
        let named = TaskItem.title(for: idea.isEmpty ? attachments.first.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "" : idea)
        let title = named.isEmpty ? "Untitled plan" : named
        let file: URL
        do {
            file = try newPlanFile(project, title: title)
            try Data("# \(title)\n\n\(idea)\n".utf8).write(to: file)
        } catch {
            lastError = "Couldn't write the plan: \(error.localizedDescription)"
            return nil
        }
        var plan = Plan(projectID: projectID, title: title, path: file.path)
        plan.createdBy = createdBy
        let first = Prompt(text: idea, attachments: attachments)
        if drafts { plan.prompts = [first] }
        plans.append(plan)
        changed()
        if drafts { startPlanRun(plan.id, prompt: "Write the plan for this idea:\n\n" + first.agentText) }
        return plan.id
    }

    /// The document as it is on disk now. Empty if it's gone.
    public func planText(_ id: Plan.ID) -> String {
        plan(id).flatMap { try? String(contentsOf: $0.url, encoding: .utf8) } ?? ""
    }

    /// The user's edits. Not while the agent writes: it would overwrite them, or they its work.
    public func savePlanText(_ id: Plan.ID, _ text: String) {
        guard let plan = plan(id), !isWriting(planID: id), text != planText(id) else { return }
        do {
            try Data(text.utf8).write(to: plan.url, options: .atomic)
        } catch {
            lastError = "Couldn't save the plan: \(error.localizedDescription)"
            return
        }
        refreshPlanTitle(id, from: text)
    }

    /// The Prompt button: the agent changes the document as asked, in the same session.
    public func revisePlan(_ id: Plan.ID, text: String, attachments: [String] = []) {
        let text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard plan(id) != nil, !isWriting(planID: id), !text.isEmpty || !attachments.isEmpty else { return }
        let prompt = Prompt(text: text, attachments: attachments)
        updatePlan(id) {
            $0.prompts.append(prompt)
            $0.error = nil
        }
        startPlanRun(id, prompt: prompt.agentText)
    }

    /// What the agent wrote so far stays.
    public func stopPlan(_ id: Plan.ID) {
        planRuns.removeValue(forKey: id)?.task.cancel()
        planActivity[id] = nil
    }

    /// Its file goes to the Trash.
    public func deletePlan(_ id: Plan.ID) {
        guard let plan = plan(id) else { return }
        stopPlan(id)
        try? FileManager.default.trashItem(at: plan.url, resultingItemURL: nil)
        plans.removeAll { $0.id == id }
        changed()
    }

    /// Starts a task that implements the plan, with the document attached and its summary as the prompt, named after it.
    /// The plan leaves the list. One committed to the repository, and not yet tracked, moves into Shift and the task adds
    /// it to its branch: left in the project's folder, it would stop the task's merge there.
    @discardableResult
    public func approvePlan(_ id: Plan.ID) async -> TaskItem.ID? {
        guard let services, let plan = plan(id), let project = project(plan.projectID), !isWriting(planID: id) else { return nil }
        let text = planText(id)
        let title = Plan.title(of: text) ?? plan.title
        var file = plan.url
        var addAs: String?
        let repo = project.repoURL.standardizedFileURL.path + "/"
        if project.planStorage == .repository, file.standardizedFileURL.path.hasPrefix(repo) {
            let relative = String(file.standardizedFileURL.path.dropFirst(repo.count))
            if await !services.git.isTracked(repo: project.repoURL, path: relative) {
                do {
                    let moved = try uniqueFile(in: plansRoot.appendingPathComponent(project.id.uuidString),
                                               name: file.deletingPathExtension().lastPathComponent)
                    try FileManager.default.moveItem(at: file, to: moved)
                    file = moved
                    addAs = relative
                } catch {
                    lastError = "Couldn't move the plan out of the project: \(error.localizedDescription)"
                    return nil
                }
            }
        }
        var prompt = "Implement this plan: \(title)"
        if let summary = Plan.summary(of: text) { prompt += "\n\n" + summary }
        prompt += "\n\nThe attached file is the whole plan, with every specification and decision. Read it first and follow it."
        if let addAs { prompt += " Also add it to the repository as `\(addAs)`, unchanged, as part of your work." }
        guard let taskID = createTask(projectID: project.id, prompt: prompt, attachments: [file.path]) else { return nil }
        rename(taskID: taskID, to: title)
        plans.removeAll { $0.id == id }
        changed()
        return taskID
    }

    // MARK: Files

    /// The project's plans folder, created; an ignored one gets a `.gitignore` that ignores everything in it, itself too.
    func planFolder(_ project: Project) throws -> URL {
        let manager = FileManager.default
        var folder = plansRoot.appendingPathComponent(project.id.uuidString)
        if project.planStorage != .shift {
            let name = project.plansFolder.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: "/")))
            folder = project.repoURL.appendingPathComponent(name.isEmpty ? "plans" : name, isDirectory: true)
        }
        try manager.createDirectory(at: folder, withIntermediateDirectories: true)
        let ignore = folder.appendingPathComponent(".gitignore")
        if project.planStorage == .ignored, !manager.fileExists(atPath: ignore.path) {
            try Data("*\n".utf8).write(to: ignore)
        }
        return folder
    }

    private func newPlanFile(_ project: Project, title: String) throws -> URL {
        let slug = title.lowercased().map { $0.isLetter || $0.isNumber ? String($0) : "-" }.joined()
            .split(separator: "-").joined(separator: "-")
        return try uniqueFile(in: planFolder(project), name: slug.isEmpty ? "plan" : String(slug.prefix(60)))
    }

    /// `<name>.md` in `folder`, or `<name>-2.md` and so on if it's taken.
    private func uniqueFile(in folder: URL, name: String) throws -> URL {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var url = folder.appendingPathComponent(name + ".md"), number = 1
        while FileManager.default.fileExists(atPath: url.path) {
            number += 1
            url = folder.appendingPathComponent("\(name)-\(number).md")
        }
        return url
    }

    private func refreshPlanTitle(_ id: Plan.ID, from text: String? = nil) {
        guard let title = Plan.title(of: text ?? planText(id)), title != plan(id)?.title else { return }
        updatePlan(id) { $0.title = title }
    }

    private func updatePlan(_ id: Plan.ID, _ change: (inout Plan) -> Void) {
        guard let index = plans.firstIndex(where: { $0.id == id }) else { return }
        change(&plans[index])
        changed()
    }

    // MARK: Agent

    private func startPlanRun(_ id: Plan.ID, prompt: String) {
        let token = UUID()
        planActivity[id] = "Writing the plan…"
        planRuns[id] = (token, Task { [weak self] in await self?.runPlan(id, token: token, prompt: prompt) })
    }

    /// One agent turn in the project's folder, writing the plan's file. Its session carries over to the next change asked for.
    private func runPlan(_ id: Plan.ID, token: UUID, prompt: String) async {
        defer {
            if planRuns[id]?.id == token {
                planRuns[id] = nil
                planActivity[id] = nil
            }
            refreshPlanTitle(id)
        }
        guard let services, let plan = plan(id), let project = project(plan.projectID) else { return }
        let kind = project.defaultAgent
        guard installedAgents[kind] != nil, let adapter = services.agents[kind] else {
            updatePlan(id) { $0.error = "\(kind.displayName) is not installed." }
            return
        }
        // ponytail: a plan has nowhere to show approval requests, so Manual runs as Auto: the agent's own review still
        // blocks what's risky, and the instructions keep it to reading and the one file. Show approvals here if that's not enough.
        let request = AgentRequest(prompt: prompt, sessionID: plan.agent == kind ? plan.sessionID : nil, worktree: project.repoURL,
                                   permissions: project.permissions == .manual ? .auto : project.permissions,
                                   model: project.models[kind], needsDescription: false,
                                   instructions: Self.planInstructions(path: plan.path))
        for await event in adapter.run(request) {
            guard planRuns[id]?.id == token else { return }
            switch event {
            case .sessionStarted(let session):
                updatePlan(id) {
                    $0.agent = kind
                    $0.sessionID = session
                }
            case .activity(let line): planActivity[id] = line
            case .finished(.blocked(let reason, _)): updatePlan(id) { $0.error = reason }
            default: break
            }
        }
    }

    static func planInstructions(path: String) -> String {
        """
        You are writing a plan inside the app Shift, not doing the work. The user jotted down an idea for this project; \
        turn it into a document they can review before any code is written: what it is, how it should work, and how to \
        build it. Once they approve it, a coding agent that knows nothing of this conversation implements it from the \
        document alone, so it must say everything that agent needs.

        Read the code you need for the plan to fit this project, and its AGENTS.md or CLAUDE.md if it has one. Don't \
        change, create or delete any file other than the plan, and don't run anything that changes the project, Git or \
        the machine.

        The plan is this Markdown file. Write it there, replacing what it holds now: \(path)
        - Start with `# <title>`: what it accomplishes, at most about six words, sentence case, like a changelog entry.
        - Right under the title, one short paragraph summing up the plan.
        - Then the sections that fit, such as Goal, How it works (behavior, interface, edge cases), Implementation \
        (the parts of the code to change and how), Out of scope and Open questions. Be specific and leave out what \
        doesn't apply.

        The user may edit the file between your turns: read it again before changing it, and keep their edits unless \
        they ask otherwise. When they ask for changes, apply them to the file.

        When done, reply with a sentence or two on what you wrote or changed. Don't ask questions in the reply: put what \
        needs the user's decision under Open questions in the plan.
        """
    }
}
