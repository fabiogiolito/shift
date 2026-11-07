import Foundation

// What the project chat's agent can do to its project, through `shiftctl` (see ControlServer).
// Every command is confined to the project the access was given for.

extension AppModel {
    private struct Refusal: Error {
        let text: String
        init(_ text: String) { self.text = text }
    }

    nonisolated static let controlUsage = """
    shiftctl commands (quote arguments; a prompt can span lines):
      tasks [--all]            the project's tasks, as JSON (--all: merged and archived ones too)
      task <id>                one task in full: prompts, changed files, conflicts
      log <id>                 the end of what its agent did
      create [--agent claudeCode|codex] "<prompt>"
                               start a task, and hear how it goes
      follow <id>              hear how a task you didn't start goes
      send <id> "<text>"       follow-up instructions, or the answer to its question
      stop <id>                stop its agent
      resume <id>              carry on with a stopped or interrupted task
      merge <id>               merge a task that isn't working into its base, and clean it up
      archive <id>             close a task without merging, keeping its record and its work on its branch; can't be reopened
      delete <id>              delete it and all its work, without merging
      resolve <id>             have its agent merge the base in and resolve the conflicts
      sync <id>                merge the latest of its base into it
      base <id> <branch>       move it onto another base branch
      rename <id> "<title>"    rename it
      push <id>                push its branch
      pr <id>                  push its branch and open a pull request, printing its URL
      project                  the project's settings, as JSON
      set <setting> "<value>"  change one: name, baseBranch, type, defaultAgent, model, serverCommand,
                               setupCommand, buildCommand, buildTargets, pushTaskBranches, takesScreenshots,
                               opensPullRequests. buildTargets is a JSON list of {"name", "command", "kind", "paths"};
                               kind is macApp, iOSSimulator, run or script. buildCommand is for a single target.

    Schedules start a task by themselves each time they come due (a "run"), from their own prompt, base branch,
    agent, model and permissions, and apply their finish action when it's done. <id> can be its first characters.
      schedules                the project's schedules, as JSON, with when each runs next
      schedule <id>            one in full, with its runs: when due, started, task, outcome and why
      schedule draft '<json>'  open the schedule form filled in with this, for the user to check and save
      schedule edit <id> '<json>'
                               change the fields given (a JSON merge patch: null clears one); applies from the next run
      schedule pause|resume|delete <id>
      schedule run <id>        start a run now, whatever its timing
    A schedule's JSON (only "prompt" and "timing.start" are required, but give a "title"; the rest default to the project's):
      {"title", "prompt", "baseBranch", "agent", "model", "permissions",
       "timing": {"start": "2026-11-07T09:00" (local time; the first run, or the only one),
                  "repeat": {"frequency": "hourly|daily|weekly|monthly", "interval": 1,
                             "weekdays": ["monday", "friday"] (weekly; default the start's),
                             "monthDays": [1, 15] (monthly; months without the day are skipped; default the start's),
                             "ordinal": {"week": "first|second|third|fourth|last", "day": "friday"}
                                        (monthly, instead of monthDays; without "day": that day of the month)},
                  "between": {"from": "13:00", "to": "17:00"} (only runs at these times of day),
                  "endAfter": 5 (runs), "endOn": "2026-12-31"},
       "finish": "review|archive|pullRequest|merge" (archive only without changes, merge only if clean),
       "wakeMac": false (wakes the Mac before each run; asks the user for their password)}
    No "repeat": it runs once. A run missed while the Mac slept or Shift was closed is logged, not caught up.
    """

    func handleControl(token: String, arguments: [String]) async -> ControlReply {
        if let reply = await handleTaskControl(token: token, arguments: arguments) { return reply }
        guard let projectID = controlTokens[token], project(projectID) != nil else {
            return ControlReply(ok: false, text: "Not allowed.")
        }
        do {
            return ControlReply(ok: true, text: try await control(projectID, arguments))
        } catch {
            return ControlReply(ok: false, text: (error as? Refusal)?.text ?? String(describing: error))
        }
    }

    private func control(_ projectID: Project.ID, _ arguments: [String]) async throws -> String {
        var rest = arguments[...]
        let command = rest.popFirst() ?? "help"

        func taskArgument() throws -> TaskItem {
            guard let word = rest.popFirst(), let id = Int(word), let task = task(id), task.projectID == projectID else {
                throw Refusal("No such task in this project. Run `tasks`.")
            }
            return task
        }
        func textArgument(_ name: String) throws -> String {
            let text = rest.joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Refusal("Missing \(name).") }
            return text
        }

        switch command {
        case "help":
            return Self.controlUsage
        case "tasks":
            return json(tasks(in: projectID).filter { rest.first == "--all" || !$0.status.isClosed }.map(ControlTask.init))
        case "task":
            let task = try taskArgument()
            var detail = ControlTask(task)
            detail.prompts = task.prompts.map(\.agentText)
            if case .success(let changes) = await loadChanges(taskID: task.id) {
                detail.changes = changes.files.map { "\($0.kind.rawValue) \($0.path) +\($0.additions) -\($0.deletions)" }
            }
            let conflicts = await conflictedFiles(taskID: task.id)
            detail.conflicts = conflicts.isEmpty ? nil : conflicts
            return json(detail)
        case "log":
            let task = try taskArgument()
            let output = Transcript.readable(await rawOutput(taskID: task.id), agent: task.agent)
            return output.isEmpty ? "Nothing yet." : String(output.suffix(8000))
        case "create":
            var agent: AgentKind?
            if rest.first == "--agent" {
                rest.removeFirst()
                guard let word = rest.popFirst(), let kind = AgentKind(rawValue: word), installedAgents[kind] != nil else {
                    throw Refusal("Pick an installed agent: \(installedAgents.keys.map(\.rawValue).sorted().joined(separator: ", ")).")
                }
                agent = kind
            }
            guard let id = createTask(projectID: projectID, prompt: try textArgument("the prompt"), agent: agent) else {
                throw Refusal("Could not start the task.")
            }
            follow(taskID: id)
            return "Started task \(id). Shift will tell you how it goes."
        case "follow":
            let task = try taskArgument()
            guard !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            follow(taskID: task.id)
            return "Following task \(task.id)."
        case "send":
            let task = try taskArgument()
            guard !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            let count = task.prompts.count
            sendPrompt(taskID: task.id, text: try textArgument("the text"))
            guard self.task(task.id)?.prompts.count != count else { throw Refusal("Task \(task.id) is busy. Try again in a moment.") }
            return "Sent to task \(task.id)."
        case "stop":
            let task = try taskArgument()
            guard task.status == .working || task.approvalRequest != nil else { throw Refusal("Task \(task.id) isn't working.") }
            stop(taskID: task.id)
            return "Stopped task \(task.id)."
        case "resume":
            let task = try taskArgument()
            guard task.canResume else { throw Refusal("Task \(task.id) wasn't stopped or interrupted. Use `send`.") }
            resume(taskID: task.id)
            return "Resumed task \(task.id)."
        case "merge":
            let task = try taskArgument()
            // Merging stops the agent: that takes the user's "stop".
            guard task.status != .working, !task.status.isClosed else {
                throw Refusal("Task \(task.id) is \(task.status.rawValue). Merge a task once it has stopped working.")
            }
            let note = await collectingError { await merge(taskID: task.id) }
            switch self.task(task.id)?.status {
            case .merged:
                return ["Merged task \(task.id) into \(baseName(task)).", note]
                    .compactMap { $0 }.joined(separator: " ")
            case .conflict:
                let files = await conflictedFiles(taskID: task.id)
                throw Refusal("Task \(task.id) conflicts with \(baseName(task)), nothing was merged: \(files.joined(separator: ", ")). Use `resolve`.")
            default:
                throw Refusal(note ?? "Could not merge task \(task.id).")
            }
        case "archive":
            let task = try taskArgument()
            guard !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            let note = await collectingError { await archive(taskID: task.id) }
            guard self.task(task.id)?.status == .archived else { throw Refusal(note ?? "Task \(task.id) is busy. Try again in a moment.") }
            return ["Archived task \(task.id).", note].compactMap { $0 }.joined(separator: " ")
        case "delete":
            let task = try taskArgument()
            let note = await collectingError { await delete(taskID: task.id) }
            guard self.task(task.id) == nil else { throw Refusal(note ?? "Task \(task.id) is busy. Try again in a moment.") }
            return ["Deleted task \(task.id).", note].compactMap { $0 }.joined(separator: " ")
        case "resolve":
            let task = try taskArgument()
            guard task.status != .working, !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            if task.status == .conflict { resolveConflict(taskID: task.id) } else { fixSyncConflict(taskID: task.id) }
            return "Task \(task.id) is resolving the conflicts."
        case "sync":
            let task = try taskArgument()
            guard task.status != .working, !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            var conflicts: [String] = []
            let note = await collectingError { conflicts = await syncBase(taskID: task.id) }
            if let note { throw Refusal(note) }
            guard conflicts.isEmpty else {
                throw Refusal("Nothing changed: it would conflict in \(conflicts.joined(separator: ", ")). Use `resolve` to have its agent do it.")
            }
            return "Task \(task.id) has the latest of \(baseName(task))."
        case "base":
            let task = try taskArgument()
            guard task.status != .working, !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            let base = try textArgument("the branch")
            guard await branches(for: projectID).contains(base) else { throw Refusal("No branch \(base) that can be a base.") }
            let note = await collectingError { await changeBase(taskID: task.id, to: base) }
            if let note { throw Refusal(note) }
            return "Task \(task.id) is now based on \(base)."
        case "rename":
            let task = try taskArgument()
            rename(taskID: task.id, to: try textArgument("the title"))
            return "Renamed task \(task.id)."
        case "push":
            let task = try taskArgument()
            guard !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            let note = await collectingError { await pushBranch(taskID: task.id) }
            if let note { throw Refusal(note) }
            return "Pushed \(task.branch)."
        case "pr":
            let task = try taskArgument()
            guard !task.status.isClosed else { throw Refusal("Task \(task.id) is \(task.status.rawValue).") }
            var opening: PullRequestOpening?
            let note = await collectingError { opening = await openPullRequest(taskID: task.id) }
            switch opening {
            case .created(let pullRequest)?: return "Pull request #\(pullRequest.number) is open: \(pullRequest.url.absoluteString)"
            case .browser(let url)?: return [note, "Open it here: \(url.absoluteString)"].compactMap { $0 }.joined(separator: " ")
            case nil: throw Refusal(note ?? "Could not open a pull request.")
            }
        case "schedules":
            return try controlJSON(schedules(in: projectID).map { schedule -> [String: Any] in
                var object = try scheduleObject(schedule)
                object["runs"] = schedule.runs.count
                object["next"] = schedule.nextRun().map(Self.controlDateFormatter.string(from:)) ?? NSNull()
                return object
            })
        case "schedule":
            return try await scheduleControl(projectID, &rest)
        case "project":
            return json(project(projectID))
        case "set":
            guard let setting = rest.popFirst() else { throw Refusal("Missing the setting.") }
            return try await set(setting, to: rest.joined(separator: " "), in: projectID)
        default:
            throw Refusal("Unknown command \(command).\n\n\(Self.controlUsage)")
        }
    }

    private func scheduleControl(_ projectID: Project.ID, _ rest: inout ArraySlice<String>) async throws -> String {
        func scheduleArgument() throws -> Schedule {
            let word = rest.popFirst()?.lowercased() ?? ""
            let found = schedules(in: projectID).filter { $0.id.uuidString.lowercased().hasPrefix(word) }
            guard !word.isEmpty, found.count == 1 else { throw Refusal("No such schedule in this project. Run `schedules`.") }
            return found[0]
        }
        func jsonArgument() throws -> [String: Any] {
            let text = rest.joined(separator: " ")
            guard let object = try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any] else {
                throw Refusal("Give the schedule's fields as a JSON object.")
            }
            return object
        }
        switch rest.popFirst() {
        case "create":
            guard let project = project(projectID) else { throw Refusal("The project no longer exists.") }
            let fields = try jsonArgument()
            let defaults = Schedule(projectID: projectID, title: "", prompt: "", baseBranch: project.baseBranch,
                                    agent: project.defaultAgent, model: project.models[project.defaultAgent],
                                    permissions: project.permissions, timing: ScheduleTiming(start: Date()))
            guard (fields["timing"] as? [String: Any])?["start"] != nil else { throw Refusal("Missing timing.start.") }
            let schedule = try await validSchedule(patching: defaults, with: fields)
            addSchedule(schedule)
            let next = schedule.nextRun().map { "Next run: \(Self.controlDateFormatter.string(from: $0))." } ?? "It has no runs to come."
            return "Created schedule \(schedule.id.uuidString). \(next)"
        case "draft":
            guard let defaults = newSchedule(projectID: projectID) else {
                throw Refusal("The project no longer exists.")
            }
            let fields = try jsonArgument()
            guard (fields["timing"] as? [String: Any])?["start"] != nil else { throw Refusal("Missing timing.start.") }
            scheduleDraft = try await validSchedule(patching: defaults, with: fields)
            return "The schedule form is open in Shift for the user, filled in. Nothing is created until they save it "
                + "(then `schedules` lists it). It runs: \(scheduleDraft?.timing.summary() ?? "")"
        case "edit":
            let old = try scheduleArgument()
            let schedule = try await validSchedule(patching: old, with: try jsonArgument())
            updateSchedule(schedule)
            let next = self.schedule(schedule.id)?.nextRun().map { "Next run: \(Self.controlDateFormatter.string(from: $0))." } ?? "It has no runs to come."
            return "Saved. \(next)"
        case "pause":
            let schedule = try scheduleArgument()
            setSchedulePaused(schedule.id, true)
            return "Paused \(schedule.title)."
        case "resume":
            let schedule = try scheduleArgument()
            setSchedulePaused(schedule.id, false)
            let next = self.schedule(schedule.id)?.nextRun().map { "Next run: \(Self.controlDateFormatter.string(from: $0))." } ?? "It has no runs to come."
            return "Resumed \(schedule.title). \(next)"
        case "delete":
            let schedule = try scheduleArgument()
            deleteSchedule(schedule.id)
            return "Deleted \(schedule.title). Its runs' tasks stay."
        case "run":
            let schedule = try scheduleArgument()
            guard let taskID = runScheduleNow(schedule.id) else {
                throw Refusal(self.schedule(schedule.id)?.runs.last?.reason ?? "Could not start a run.")
            }
            return "Started task \(taskID)."
        case let word?:
            rest.insert(word, at: rest.startIndex)
            let schedule = try scheduleArgument()
            var object = try scheduleObject(schedule)
            object["next"] = schedule.nextRun().map(Self.controlDateFormatter.string(from:)) ?? NSNull()
            return try controlJSON(object)
        case nil:
            throw Refusal("Missing the schedule.\n\n\(Self.controlUsage)")
        }
    }

    /// `schedule` with `fields` merged in, checked: what the chat can't set is refused with why.
    private func validSchedule(patching schedule: Schedule, with fields: [String: Any]) async throws -> Schedule {
        guard let project = project(schedule.projectID) else { throw Refusal("The project no longer exists.") }
        var fields = fields
        // keepAwake: the form no longer offers it, so the chat doesn't either; saved values are kept.
        for key in ["id", "projectID", "runs", "createdAt", "checkedUntil", "next", "keepAwake"] { fields[key] = nil }
        let merged = Self.mergePatch(try controlObject(schedule), fields)
        var result: Schedule
        do {
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .custom { decoder in
                let container = try decoder.singleValueContainer()
                let text = try container.decode(String.self)
                guard let date = Self.controlDate(text) else {
                    throw DecodingError.dataCorruptedError(in: container, debugDescription: "\(text) isn't a date like 2026-11-07T09:00.")
                }
                return date
            }
            result = try decoder.decode(Schedule.self, from: JSONSerialization.data(withJSONObject: merged))
        } catch let DecodingError.dataCorrupted(context) {
            throw Refusal("Invalid schedule: \(context.codingPath.map(\.stringValue).joined(separator: ".")) \(context.debugDescription)")
        } catch let DecodingError.keyNotFound(key, context) {
            throw Refusal("Invalid schedule: missing \((context.codingPath + [key]).map(\.stringValue).joined(separator: ".")).")
        } catch let DecodingError.typeMismatch(_, context), let DecodingError.valueNotFound(_, context) {
            throw Refusal("Invalid schedule: \(context.codingPath.map(\.stringValue).joined(separator: ".")) has the wrong type.")
        }
        // Another agent: its model, unless one was given.
        if result.agent != schedule.agent && fields["model"] == nil { result.model = project.models[result.agent] }
        result.title = result.title.trimmingCharacters(in: .whitespacesAndNewlines)
        result.prompt = result.prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.prompt.isEmpty else { throw Refusal("Missing the prompt.") }
        if result.title.isEmpty { result.title = TaskItem.title(for: result.prompt) }
        guard installedAgents[result.agent] != nil else {
            throw Refusal("Pick an installed agent: \(installedAgents.keys.map(\.rawValue).sorted().joined(separator: ", ")).")
        }
        if let model = result.model, !(models[result.agent] ?? []).contains(where: { $0.id == model }) {
            throw Refusal("\(result.agent.displayName) offers: \((models[result.agent] ?? []).map(\.id).joined(separator: ", ")); leave model out for its default.")
        }
        let rank: [AgentPermissions: Int] = [.manual: 0, .auto: 1, .bypass: 2]
        if result.permissions != schedule.permissions, rank[result.permissions]! > rank[project.permissions]! {
            throw Refusal("Only the user can give a schedule more permissions than the project's (\(project.permissions.rawValue)).")
        }
        if result.baseBranch != schedule.baseBranch || schedule.runs.isEmpty,
           !(await branches(for: project.id)).contains(result.baseBranch) {
            throw Refusal("No branch \(result.baseBranch) that can be a base.")
        }
        if let rule = result.timing.repeat {
            guard rule.interval >= 1 else { throw Refusal("repeat.interval is 1 or more.") }
            guard rule.monthDays.allSatisfy((1...31).contains) else { throw Refusal("repeat.monthDays are 1 to 31.") }
        }
        if let count = result.timing.endAfter, count < 1 { throw Refusal("endAfter is 1 or more.") }
        return result
    }

    /// RFC 7396: `patch`'s values replace `target`'s, objects merge, null removes.
    nonisolated static func mergePatch(_ target: [String: Any], _ patch: [String: Any]) -> [String: Any] {
        var result = target
        for (key, value) in patch {
            if value is NSNull {
                result[key] = nil
            } else if let object = value as? [String: Any], let existing = result[key] as? [String: Any] {
                result[key] = mergePatch(existing, object)
            } else {
                result[key] = value
            }
        }
        return result
    }

    /// Local time with its offset, which is how the chat's agent reads dates.
    nonisolated(unsafe) static let controlDateFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.timeZone = .current
        return formatter
    }()

    /// A full ISO 8601 date, or a local "2026-11-07T09:00", "2026-11-07 09:00:00" or "2026-11-07".
    nonisolated static func controlDate(_ text: String) -> Date? {
        if let date = controlDateFormatter.date(from: text) { return date }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        for format in ["yyyy-MM-dd'T'HH:mm:ss", "yyyy-MM-dd'T'HH:mm", "yyyy-MM-dd HH:mm:ss", "yyyy-MM-dd HH:mm", "yyyy-MM-dd"] {
            formatter.dateFormat = format
            if let date = formatter.date(from: text) { return date }
        }
        return nil
    }

    /// What the chat sees of a schedule: without keepAwake, which it can't set.
    private func scheduleObject(_ schedule: Schedule) throws -> [String: Any] {
        var object = try controlObject(schedule)
        object["keepAwake"] = nil
        return object
    }

    private func controlObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(Self.controlDateFormatter.string(from: date))
        }
        return try JSONSerialization.jsonObject(with: encoder.encode(value)) as? [String: Any] ?? [:]
    }

    private func controlJSON(_ object: Any) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]),
               as: UTF8.self)
    }

    private func set(_ setting: String, to value: String, in projectID: Project.ID) async throws -> String {
        guard var project = project(projectID) else { throw Refusal("The project no longer exists.") }
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        var note = ""
        func flag() throws -> Bool {
            guard let flag = Bool(value) else { throw Refusal("\(setting) is true or false.") }
            return flag
        }
        switch setting {
        case "name":
            guard !value.isEmpty else { throw Refusal("Missing the name.") }
            project.name = value
        case "baseBranch":
            guard await branches(for: projectID).contains(value) else { throw Refusal("No branch \(value) that can be a base.") }
            project.baseBranch = value
        case "type":
            guard let type = ProjectType(rawValue: value) else {
                throw Refusal("type is one of: \(ProjectType.allCases.map(\.rawValue).joined(separator: ", ")).")
            }
            project = await self.project(project, as: type)
        case "defaultAgent":
            guard let kind = AgentKind(rawValue: value), installedAgents[kind] != nil else {
                throw Refusal("Pick an installed agent: \(installedAgents.keys.map(\.rawValue).sorted().joined(separator: ", ")).")
            }
            project.defaultAgent = kind
            if kind != self.project(projectID)?.defaultAgent {
                note = " This chat runs on that agent too: your next turn is a new session that doesn't remember this conversation."
            }
        case "model":
            let kind = project.defaultAgent, offered = models[kind] ?? []
            guard value == "default" || offered.contains(where: { $0.id == value }) else {
                throw Refusal("\(kind.displayName) offers: default, \(offered.map(\.id).joined(separator: ", ")).")
            }
            project.models[kind] = value == "default" ? nil : value
        case "serverCommand", "setupCommand", "buildCommand", "buildTargets":
            // These run outside any sandbox and unasked, so with less than Bypass they'd be a way around the permissions.
            guard project.permissions == .bypass else {
                throw Refusal("With \(project.permissions.displayName) permissions only the user can change commands, in the project's settings.")
            }
            switch setting {
            case "serverCommand": project.serverCommand = value
            case "setupCommand": project.setupCommand = value
            case "buildCommand":
                guard project.buildTargets.count <= 1 else {
                    throw Refusal("This project has several build targets. Change them with buildTargets.")
                }
                project.buildCommand = value
            default:
                guard let targets = try? JSONDecoder().decode([BuildTarget].self, from: Data(value.utf8)) else {
                    throw Refusal(#"buildTargets takes a JSON list of {"name", "command", "kind", "paths"}."#)
                }
                project.buildTargets = targets
            }
        case "pushTaskBranches": project.pushTaskBranches = try flag()
        case "takesScreenshots": project.takesScreenshots = try flag()
        case "opensPullRequests": project.opensPullRequests = try flag()
        case "permissions":
            throw Refusal("Only the user can change the project's permissions, in its settings: they limit what you can do.")
        default:
            throw Refusal("Unknown setting \(setting).\n\n\(Self.controlUsage)")
        }
        updateProject(project)
        return "Set \(setting)." + note
    }

    /// What `operation` put in `lastError`, for the agent instead of an alert for the user.
    func collectingError(_ operation: () async -> Void) async -> String? {
        let before = lastError
        lastError = nil
        await operation()
        defer { lastError = before }
        return lastError
    }

    private func baseName(_ task: TaskItem) -> String {
        project(task.projectID).map(task.base(in:)) ?? task.baseBranch ?? "its base"
    }

    private func json<T: Encodable>(_ value: T) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return (try? encoder.encode(value)).map { String(decoding: $0, as: UTF8.self) } ?? "null"
    }
}

/// A task as the chat's agent reads it.
private struct ControlTask: Encodable {
    var id: Int
    var title: String
    var status: TaskStatus
    var agent: AgentKind
    var branch: String
    var base: String?
    /// Its worktree, where the agent can read the code and the diff.
    var folder: String
    var url: String?
    var following: Bool
    var description, summary, question, blockedReason, waitingForApproval, activity: String?
    var options: [String]?
    var prompts: [String]?
    var changes: [String]?
    var conflicts: [String]?

    init(_ task: TaskItem) {
        id = task.id
        title = task.title
        status = task.status
        agent = task.agent
        branch = task.branch
        base = task.baseBranch
        folder = task.worktreePath
        url = task.serverURL?.absoluteString
        following = task.chatID != nil
        description = task.description
        summary = task.summary
        question = task.question
        blockedReason = task.blockedReason
        waitingForApproval = task.approvalRequest
        activity = task.activity
        options = task.options
    }
}
