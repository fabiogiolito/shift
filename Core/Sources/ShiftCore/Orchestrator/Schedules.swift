import AppKit

// Schedules: prompts that start tasks by themselves (docs/specs/scheduled-tasks.md). Each time one comes due it
// starts a run, a normal task; when that task finishes, the schedule's finish action is applied to it.

extension AppModel {
    static let missedAsleep = "Mac was asleep"
    static let missedNotRunning = "Shift wasn't running"
    /// How long before a run the Mac is woken.
    static let wakeLead: TimeInterval = 120

    public func schedule(_ id: Schedule.ID) -> Schedule? {
        schedules.first { $0.id == id }
    }

    public func schedules(in projectID: Project.ID) -> [Schedule] {
        schedules.filter { $0.projectID == projectID }
    }

    // MARK: Editing

    public func addSchedule(_ schedule: Schedule) {
        schedules.append(schedule)
        schedulesChanged(edited: true)
    }

    /// Saves its settings; its runs and how far it was checked are kept. A new timing starts from now: runs it
    /// would have had before now are not missed ones.
    public func updateSchedule(_ schedule: Schedule) {
        guard let index = schedules.firstIndex(where: { $0.id == schedule.id }) else { return }
        var schedule = schedule
        let old = schedules[index]
        schedule.runs = old.runs
        schedule.createdAt = old.createdAt
        schedule.checkedUntil = schedule.timing == old.timing ? old.checkedUntil : max(old.checkedUntil, Date().addingTimeInterval(-60))
        schedules[index] = schedule
        schedulesChanged(edited: true)
    }

    /// Its runs' tasks stay.
    public func deleteSchedule(_ id: Schedule.ID) {
        schedules.removeAll { $0.id == id }
        schedulesChanged(edited: true)
    }

    /// Runs that come due while paused are neither started nor logged.
    public func setSchedulePaused(_ id: Schedule.ID, _ paused: Bool) {
        guard let index = schedules.firstIndex(where: { $0.id == id }), schedules[index].paused != paused else { return }
        schedules[index].paused = paused
        if !paused { schedules[index].checkedUntil = Date() }
        schedulesChanged(edited: true)
    }

    /// Starts a run now, whatever its timing says; paused or not. Nil if it could not (the run log says why).
    @discardableResult
    public func runScheduleNow(_ id: Schedule.ID) -> TaskItem.ID? {
        let taskID = startScheduledRun(of: id, due: nil)
        schedulesChanged(edited: false)
        return taskID
    }

    /// `edited`: by the user (or the chat for them), who may be asked for the password to wake the Mac.
    func schedulesChanged(edited: Bool) {
        if edited { wakesDeclined = false }
        changed()
        // At once, for the power assertion and the wakes; then the timer for the new next run.
        checkSchedules(atLaunch: false)
        restartScheduleTimer()
    }

    // MARK: Timer

    /// At launch: missed runs are logged, then the timer starts and sleep and wake are watched.
    func startSchedules() {
        checkSchedules(atLaunch: true)
        let center = NSWorkspace.shared.notificationCenter
        sleepObservers = [
            center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.macWillSleep() }
            },
            center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.macDidWake() }
            },
        ]
        restartScheduleTimer()
    }

    func macWillSleep() {
        asleepSince = Date()
        lastAlive = asleepSince
        changed()
    }

    func macDidWake() {
        if let asleepSince { lastSleep = (asleepSince, Date()) }
        asleepSince = nil
        changed()
        restartScheduleTimer()
    }

    /// Checks now, then again when the next run is due (and at least every minute, for the heartbeat).
    func restartScheduleTimer() {
        scheduleTimer?.cancel()
        guard services != nil else { return }
        scheduleTimer = Task { [weak self] in
            while !Task.isCancelled, let self {
                self.checkSchedules(atLaunch: false)
                let next = self.schedules.compactMap { $0.nextRun() }.min()?.timeIntervalSinceNow ?? 60
                try? await Task.sleep(for: .seconds(min(60, max(0.05, next))))
            }
        }
    }

    /// Starts the runs that are due, logs the missed ones, keeps the heartbeat and the power assertion, and
    /// schedules wakes. Never awaits, so two checks can't start the same run.
    func checkSchedules(atLaunch: Bool) {
        let now = Date()
        var changes = false
        for index in schedules.indices where !schedules[index].paused {
            let schedule = schedules[index]
            let due = schedule.timing.occurrences(after: schedule.checkedUntil, through: now)
            schedules[index].checkedUntil = now
            guard !due.isEmpty else { continue }
            changes = true
            var missed: [(Date, String)] = []
            for date in due {
                if let reason = missedReason(date, atLaunch: atLaunch) { missed.append((date, reason)) } else { startScheduledRun(of: schedule.id, due: date) }
            }
            // ponytail: after a long time off, only the latest few missed runs are logged.
            for (date, reason) in missed.suffix(10) {
                schedules[index].runs.append(ScheduleRun(due: date, outcome: .missed, reason: reason))
            }
        }
        // A run whose task was deleted before it finished.
        for index in schedules.indices {
            for run in schedules[index].runs.indices where schedules[index].runs[run].outcome == .running {
                guard let taskID = schedules[index].runs[run].taskID, task(taskID) == nil else { continue }
                schedules[index].runs[run].outcome = .failed
                schedules[index].runs[run].reason = "Its task was deleted."
                changes = true
            }
        }
        if schedules.contains(where: { !$0.paused }), (lastAlive.map { now.timeIntervalSince($0) >= 55 } ?? true) {
            lastAlive = now
            changes = true
        }
        if changes { changed() }
        scheduleKeepAwake.set(schedules.contains { $0.keepAwake && $0.nextRun(after: now) != nil })
        updateWakes()
    }

    /// Why a run due at `date` wasn't started on time, nil if it can still start now.
    func missedReason(_ date: Date, atLaunch: Bool) -> String? {
        if atLaunch {
            // Shift was running when it was due (or saw the Mac go to sleep before), but the Mac was asleep.
            if let asleepSince, asleepSince <= date { return Self.missedAsleep }
            if let lastAlive, date <= lastAlive { return Self.missedAsleep }
            return Self.missedNotRunning
        }
        if let lastSleep, date >= lastSleep.from.addingTimeInterval(-1), date <= lastSleep.to { return Self.missedAsleep }
        return nil
    }

    // MARK: Runs

    /// Logs the run, and starts its task if it can. `due` nil: Run Now.
    @discardableResult
    func startScheduledRun(of id: Schedule.ID, due: Date?) -> TaskItem.ID? {
        guard let index = schedules.firstIndex(where: { $0.id == id }) else { return nil }
        let schedule = schedules[index]
        var run = ScheduleRun(due: due, started: Date(), outcome: .running)
        if project(schedule.projectID) == nil {
            run.outcome = .failed
            run.reason = "The project no longer exists."
        } else if installedAgents[schedule.agent] == nil {
            run.outcome = .failed
            run.reason = "\(schedule.agent.displayName) isn't installed."
        } else if let taskID = createTask(projectID: schedule.projectID, prompt: schedule.prompt, schedule: schedule) {
            run.taskID = taskID
            let project = project(schedule.projectID)?.name ?? ""
            if let services {
                enqueue { await services.notifier.notify(title: project, body: "\(schedule.title) is running.", taskID: taskID) }
            }
        } else {
            run.outcome = .failed
            run.reason = "Could not start the task."
        }
        schedules[index].runs.append(run)
        changed()
        return run.taskID
    }

    /// Whether the task just ending this way finishes a run that its finish action is still to be applied to.
    func scheduledRunFinishes(_ task: TaskItem, _ status: TaskStatus) -> Bool {
        guard status == .completed || status == .conflict, let run = run(ofTask: task) else { return false }
        return run.outcome == .running || run.outcome == .failed
    }

    /// A run's task stopped working: apply the finish action if it's done, note the failure if it's blocked.
    func scheduledTaskSettled(_ taskID: TaskItem.ID, _ status: TaskStatus, reason: String?, finishes: Bool) {
        if finishes {
            Task { await applyFinishAction(taskID) }
        } else if status == .blocked {
            updateRun(ofTask: taskID) {
                guard $0.outcome == .running else { return }
                $0.outcome = .failed
                $0.reason = reason
            }
        }
    }

    /// Merged or archived, by the finish action or by hand.
    func scheduledTaskClosed(_ taskID: TaskItem.ID, as status: TaskStatus) {
        updateRun(ofTask: taskID) { $0.outcome = status == .merged ? .merged : .archived }
    }

    private func applyFinishAction(_ taskID: TaskItem.ID) async {
        guard let task = task(taskID), let scheduleID = task.scheduleID, let schedule = schedule(scheduleID),
              let project = project(task.projectID) else { return }
        var outcome = ScheduleRun.Outcome.review
        var reason: String?
        var body = "\(task.title) is ready for review."
        let base = task.base(in: project)
        switch schedule.finish {
        case .review:
            break
        case .archive:
            guard let changes = await changes(taskID: taskID), changes.files.isEmpty else {
                reason = "It has changes, so it wasn't archived."
                break
            }
            let note = await collectingError { await archive(taskID: taskID) }
            if self.task(taskID)?.status == .archived {
                outcome = .archived
                body = "\(task.title) finished with no changes and was archived."
            } else {
                reason = note ?? "Could not archive it."
            }
        case .pullRequest:
            var opening: PullRequestOpening?
            let note = await collectingError { opening = await openPullRequest(taskID: taskID) }
            switch opening {
            case .created(let pullRequest):
                outcome = .pullRequest
                body = "\(task.title) is ready for review in pull request #\(pullRequest.number)."
            case .browser:
                // Nobody may be there to see a browser window: the user opens it from the task.
                reason = "No pull request was opened: " + (note ?? "the GitHub CLI isn't installed.")
            case nil:
                reason = note ?? "Could not open a pull request."
            }
        case .merge:
            guard task.status == .completed else {
                reason = "It doesn't merge cleanly into \(base), so it wasn't merged."
                break
            }
            let note = await collectingError { await merge(taskID: taskID) }
            if self.task(taskID)?.status == .merged {
                outcome = .merged
                body = "\(task.title) was merged into \(base)."
            } else {
                reason = note ?? "It doesn't merge cleanly into \(base), so it wasn't merged."
            }
        }
        if let reason, outcome == .review { body += " " + reason }
        let summary = self.task(taskID)?.description ?? task.summary
        updateRun(ofTask: taskID) {
            $0.outcome = outcome
            $0.reason = reason
            $0.summary = summary
        }
        if let services {
            let title = project.name
            enqueue { await services.notifier.notify(title: title, body: body, taskID: taskID) }
        }
    }

    private func run(ofTask task: TaskItem) -> ScheduleRun? {
        task.scheduleID.flatMap(schedule)?.runs.first { $0.taskID == task.id }
    }

    private func updateRun(ofTask taskID: TaskItem.ID, _ change: (inout ScheduleRun) -> Void) {
        guard let scheduleID = task(taskID)?.scheduleID,
              let index = schedules.firstIndex(where: { $0.id == scheduleID }),
              let run = schedules[index].runs.firstIndex(where: { $0.taskID == taskID }) else { return }
        change(&schedules[index].runs[run])
        changed()
    }

    // MARK: Waking the Mac

    /// The wakes the coming runs need: a little before each, for the next week, at most 24.
    func wantedWakes(now: Date = Date()) -> [Date] {
        let horizon = now.addingTimeInterval(7 * 24 * 3600)
        let runs = schedules.filter(\.wakeMac).flatMap { schedule -> [Date] in
            guard !schedule.paused else { return [] }
            return schedule.timing.occurrences(after: max(now, schedule.checkedUntil), through: horizon)
        }
        let wakes = Set(runs.map { Date(timeIntervalSince1970: ($0.timeIntervalSince1970 - Self.wakeLead).rounded(.down)) })
        return wakes.filter { $0 > now.addingTimeInterval(30) }.sorted().prefix(24).map { $0 }
    }

    /// Asks for the admin password only when the next wake isn't scheduled yet or a scheduled one is no longer
    /// wanted, and then schedules the whole batch at once.
    func updateWakes() {
        let now = Date()
        let scheduled = wakes.filter { $0 > now }
        if scheduled.count != wakes.count {
            wakes = scheduled
            changed()
        }
        let wanted = wantedWakes(now: now)
        let missing = wanted.first.map { !scheduled.contains($0) } ?? false
        let stale = scheduled.filter { !wanted.contains($0) }
        guard missing || !stale.isEmpty, !isSchedulingWakes, !wakesDeclined else { return }
        let added = wanted.filter { !scheduled.contains($0) }
        isSchedulingWakes = true
        Task {
            defer { isSchedulingWakes = false }
            do {
                try await runAsAdministrator(Self.pmsetScript(cancel: stale, schedule: added))
                wakes = wakes.filter { !stale.contains($0) } + added
            } catch {
                // Cancelled, or pmset failed: not asked again until a schedule is saved.
                wakesDeclined = true
                NSLog("Shift: could not schedule wakes: \(error.localizedDescription)")
            }
            changed()
        }
    }

    static func pmsetScript(cancel: [Date], schedule: [Date]) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "MM/dd/yy HH:mm:ss"
        // Cancelling one that already fired or was removed fails: never mind.
        let cancels = cancel.map { "/usr/bin/pmset schedule cancel wake '\(format.string(from: $0))' Shift || true" }
        let adds = schedule.map { "/usr/bin/pmset schedule wake '\(format.string(from: $0))' Shift" }
        return (cancels + [adds.isEmpty ? "true" : adds.joined(separator: " && ")]).joined(separator: "; ")
    }
}
