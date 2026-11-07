import XCTest
@testable import ShiftCore

/// The next-run math, in New York time so DST changes can be tested (2026: Mar 8 springs forward, Nov 1 falls back).
final class ScheduleTimingTests: XCTestCase {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        calendar.firstWeekday = 1
        return calendar
    }()

    func d(_ text: String) -> Date {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        return formatter.date(from: text)!
    }

    func text(_ date: Date?) -> String {
        guard let date else { return "nil" }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm zzz"
        return formatter.string(from: date)
    }

    /// The first `count` runs after `after` (default: just before the start).
    func runs(_ timing: ScheduleTiming, _ count: Int, after: Date? = nil) -> [String] {
        var found: [String] = []
        var date = after ?? timing.start.addingTimeInterval(-1)
        while found.count < count, let next = timing.nextOccurrence(after: date, calendar: calendar) {
            found.append(text(next))
            date = next
        }
        return found
    }

    func timing(_ start: String, _ rule: ScheduleTiming.Recurrence? = nil, between: (Int, Int)? = nil,
                endAfter: Int? = nil, endOn: String? = nil) -> ScheduleTiming {
        ScheduleTiming(start: d(start), repeat: rule,
                       between: between.map { .init(from: .init($0.0), to: .init($0.1)) },
                       endAfter: endAfter, endOn: endOn.map(d))
    }

    // MARK: Never

    func testNeverRunsOnceAtTheStart() {
        let once = timing("2026-01-05 09:00")
        XCTAssertEqual(runs(once, 5), ["2026-01-05 09:00 EST"])
        XCTAssertNil(once.nextOccurrence(after: d("2026-01-05 09:00"), calendar: calendar))
        XCTAssertEqual(text(once.nextOccurrence(after: d("2025-01-01 00:00"), calendar: calendar)), "2026-01-05 09:00 EST")
    }

    func testOnceOutsideTheWindowNeverRuns() {
        XCTAssertEqual(runs(timing("2026-01-05 09:00", between: (13, 17)), 1), [])
    }

    // MARK: Hourly

    func testEveryHour() {
        XCTAssertEqual(runs(timing("2026-01-05 10:30", .init(.hourly)), 3),
                       ["2026-01-05 10:30 EST", "2026-01-05 11:30 EST", "2026-01-05 12:30 EST"])
    }

    func testEveryThreeHours() {
        XCTAssertEqual(runs(timing("2026-01-05 22:00", .init(.hourly, interval: 3)), 3),
                       ["2026-01-05 22:00 EST", "2026-01-06 01:00 EST", "2026-01-06 04:00 EST"])
    }

    func testHourlyOnlyBetweenIncludesBothEnds() {
        let hourly = timing("2026-01-05 09:00", .init(.hourly), between: (13, 17))
        XCTAssertEqual(runs(hourly, 6), ["2026-01-05 13:00 EST", "2026-01-05 14:00 EST", "2026-01-05 15:00 EST",
                                         "2026-01-05 16:00 EST", "2026-01-05 17:00 EST", "2026-01-06 13:00 EST"])
        XCTAssertEqual(runs(timing("2026-01-05 09:30", .init(.hourly), between: (13, 17)), 5).last, "2026-01-06 13:30 EST")
    }

    func testWindowPastMidnight() {
        let night = timing("2026-01-05 20:00", .init(.hourly, interval: 2), between: (22, 2))
        XCTAssertEqual(runs(night, 4), ["2026-01-05 22:00 EST", "2026-01-06 00:00 EST", "2026-01-06 02:00 EST", "2026-01-06 22:00 EST"])
    }

    func testHourlyAcrossSpringForwardKeepsOneHourApart() {
        XCTAssertEqual(runs(timing("2026-03-08 00:00", .init(.hourly)), 4),
                       ["2026-03-08 00:00 EST", "2026-03-08 01:00 EST", "2026-03-08 03:00 EDT", "2026-03-08 04:00 EDT"])
    }

    func testHourlyAcrossFallBackRunsTheRepeatedHourTwice() {
        let hourly = timing("2026-11-01 00:00", .init(.hourly))
        let found = hourly.occurrences(after: d("2026-10-31 23:59"), through: d("2026-11-01 02:00"), calendar: calendar)
        XCTAssertEqual(found.map(text), ["2026-11-01 00:00 EDT", "2026-11-01 01:00 EDT", "2026-11-01 01:00 EST", "2026-11-01 02:00 EST"])
        XCTAssertEqual(found[2].timeIntervalSince(found[1]), 3600)
    }

    func testHourlyFarFromTheStartIsQuick() {
        let hourly = timing("2026-01-05 10:15", .init(.hourly))
        XCTAssertEqual(text(hourly.nextOccurrence(after: d("2036-06-01 08:20"), calendar: calendar)), "2036-06-01 09:15 EDT")
    }

    // MARK: Daily

    func testEveryDayKeepsTheTimeAcrossDST() {
        XCTAssertEqual(runs(timing("2026-03-07 09:00", .init(.daily)), 3),
                       ["2026-03-07 09:00 EST", "2026-03-08 09:00 EDT", "2026-03-09 09:00 EDT"])
        XCTAssertEqual(runs(timing("2026-10-31 09:00", .init(.daily)), 2), ["2026-10-31 09:00 EDT", "2026-11-01 09:00 EST"])
    }

    func testATimeThatDoesntExistRunsAnHourLater() {
        XCTAssertEqual(runs(timing("2026-03-07 02:30", .init(.daily)), 3),
                       ["2026-03-07 02:30 EST", "2026-03-08 03:30 EDT", "2026-03-09 02:30 EDT"])
    }

    func testATimeThatHappensTwiceRunsOnce() {
        XCTAssertEqual(runs(timing("2026-10-31 01:30", .init(.daily)), 3),
                       ["2026-10-31 01:30 EDT", "2026-11-01 01:30 EDT", "2026-11-02 01:30 EST"])
    }

    func testEveryThreeDays() {
        XCTAssertEqual(runs(timing("2026-01-30 08:00", .init(.daily, interval: 3)), 3),
                       ["2026-01-30 08:00 EST", "2026-02-02 08:00 EST", "2026-02-05 08:00 EST"])
    }

    func testDailyFromTheMiddleOfItsRuns() {
        let daily = timing("2026-01-01 09:00", .init(.daily, interval: 2))
        XCTAssertEqual(text(daily.nextOccurrence(after: d("2026-02-01 12:00"), calendar: calendar)), "2026-02-02 09:00 EST")
    }

    // MARK: Weekly

    func testEveryWeekOnTheStartsDay() {
        XCTAssertEqual(runs(timing("2026-01-07 09:00", .init(.weekly)), 3), // a Wednesday
                       ["2026-01-07 09:00 EST", "2026-01-14 09:00 EST", "2026-01-21 09:00 EST"])
    }

    func testWeekdays() {
        let weekdays = timing("2026-01-05 09:00", .init(.weekly, weekdays: [.monday, .tuesday, .wednesday, .thursday, .friday]))
        XCTAssertEqual(runs(weekdays, 6), ["2026-01-05 09:00 EST", "2026-01-06 09:00 EST", "2026-01-07 09:00 EST",
                                           "2026-01-08 09:00 EST", "2026-01-09 09:00 EST", "2026-01-12 09:00 EST"])
    }

    func testEveryOtherWeekOnTwoDaysStartingOnAnotherDay() {
        // Starts on a Monday, which isn't one of its days: the start still runs.
        let rule = timing("2026-01-05 09:00", .init(.weekly, interval: 2, weekdays: [.tuesday, .thursday]))
        XCTAssertEqual(runs(rule, 5), ["2026-01-05 09:00 EST", "2026-01-06 09:00 EST", "2026-01-08 09:00 EST",
                                       "2026-01-20 09:00 EST", "2026-01-22 09:00 EST"])
    }

    func testEveryOtherWeekCountsWeeksFromTheFirstDayOfTheWeek() {
        // Starts on a Saturday; Sunday the 11th begins the next week, which is skipped.
        let rule = timing("2026-01-10 09:00", .init(.weekly, interval: 2, weekdays: [.sunday, .saturday]))
        XCTAssertEqual(runs(rule, 3), ["2026-01-10 09:00 EST", "2026-01-18 09:00 EST", "2026-01-24 09:00 EST"])
    }

    // MARK: Monthly

    func testEveryMonthOnThe31stSkipsShortMonths() {
        XCTAssertEqual(runs(timing("2026-01-31 09:00", .init(.monthly)), 4),
                       ["2026-01-31 09:00 EST", "2026-03-31 09:00 EDT", "2026-05-31 09:00 EDT", "2026-07-31 09:00 EDT"])
    }

    func testMonthDays() {
        XCTAssertEqual(runs(timing("2026-01-01 09:00", .init(.monthly, monthDays: [15, 30])), 5),
                       ["2026-01-01 09:00 EST", "2026-01-15 09:00 EST", "2026-01-30 09:00 EST", "2026-02-15 09:00 EST",
                        "2026-03-15 09:00 EDT"])
    }

    func testThe29thOfFebruaryOnlyInLeapYears() {
        let rule = timing("2027-01-29 09:00", .init(.monthly, monthDays: [29]))
        XCTAssertEqual(runs(rule, 3, after: d("2027-01-30 00:00")), ["2027-03-29 09:00 EDT", "2027-04-29 09:00 EDT", "2027-05-29 09:00 EDT"])
        XCTAssertEqual(text(rule.nextOccurrence(after: d("2028-01-30 00:00"), calendar: calendar)), "2028-02-29 09:00 EST")
    }

    func testEveryThreeMonths() {
        XCTAssertEqual(runs(timing("2026-01-15 09:00", .init(.monthly, interval: 3)), 3),
                       ["2026-01-15 09:00 EST", "2026-04-15 09:00 EDT", "2026-07-15 09:00 EDT"])
    }

    func testLastFriday() {
        XCTAssertEqual(runs(timing("2026-01-01 17:00", .init(.monthly, ordinal: .init(.last, .friday))), 4),
                       ["2026-01-01 17:00 EST", "2026-01-30 17:00 EST", "2026-02-27 17:00 EST", "2026-03-27 17:00 EDT"])
    }

    func testFirstMondayAndFourthThursday() {
        XCTAssertEqual(runs(timing("2026-01-05 09:00", .init(.monthly, ordinal: .init(.first, .monday))), 3),
                       ["2026-01-05 09:00 EST", "2026-02-02 09:00 EST", "2026-03-02 09:00 EST"])
        XCTAssertEqual(runs(timing("2026-11-26 09:00", .init(.monthly, ordinal: .init(.fourth, .thursday))), 2),
                       ["2026-11-26 09:00 EST", "2026-12-24 09:00 EST"])
    }

    func testLastDayOfTheMonth() {
        XCTAssertEqual(runs(timing("2028-01-31 09:00", .init(.monthly, ordinal: .init(.last))), 4),
                       ["2028-01-31 09:00 EST", "2028-02-29 09:00 EST", "2028-03-31 09:00 EDT", "2028-04-30 09:00 EDT"])
    }

    func testSecondDayOfTheMonth() {
        XCTAssertEqual(runs(timing("2026-01-02 09:00", .init(.monthly, ordinal: .init(.second))), 2),
                       ["2026-01-02 09:00 EST", "2026-02-02 09:00 EST"])
    }

    // MARK: End

    func testEndAfterCountsRunsNotSkippedTimes() {
        let rule = timing("2026-01-05 12:00", .init(.hourly), between: (13, 14), endAfter: 3)
        XCTAssertEqual(runs(rule, 10), ["2026-01-05 13:00 EST", "2026-01-05 14:00 EST", "2026-01-06 13:00 EST"])
        XCTAssertNil(rule.nextOccurrence(after: d("2026-01-06 13:00"), calendar: calendar))
    }

    func testEndAfterFromTheMiddle() {
        let rule = timing("2026-01-01 09:00", .init(.daily), endAfter: 10)
        XCTAssertEqual(text(rule.nextOccurrence(after: d("2026-01-09 10:00"), calendar: calendar)), "2026-01-10 09:00 EST")
        XCTAssertNil(rule.nextOccurrence(after: d("2026-01-10 10:00"), calendar: calendar))
    }

    func testEndOnIncludesThatDay() {
        let rule = timing("2026-01-08 09:00", .init(.daily), endOn: "2026-01-10 00:00")
        XCTAssertEqual(runs(rule, 10), ["2026-01-08 09:00 EST", "2026-01-09 09:00 EST", "2026-01-10 09:00 EST"])
    }

    func testOccurrencesInARange() {
        let rule = timing("2026-01-05 09:00", .init(.hourly))
        XCTAssertEqual(rule.occurrences(after: d("2026-01-05 10:00"), through: d("2026-01-05 12:00"), calendar: calendar).map(text),
                       ["2026-01-05 11:00 EST", "2026-01-05 12:00 EST"])
        XCTAssertEqual(rule.occurrences(after: d("2026-01-05 10:00"), through: d("2026-01-05 10:59"), calendar: calendar), [])
    }

    func testPausedHasNoNextRun() {
        var schedule = Schedule(projectID: UUID(), title: "T", prompt: "P", baseBranch: "main", agent: .claudeCode,
                                permissions: .bypass, timing: timing("2030-01-05 09:00"))
        XCTAssertNotNil(schedule.nextRun(calendar: calendar))
        schedule.paused = true
        XCTAssertNil(schedule.nextRun(calendar: calendar))
    }

    // MARK: JSON

    func testJSONTheChatWrites() throws {
        let json = #"{"repeat": {"frequency": "monthly", "ordinal": {"week": "last"}}, "between": {"from": "09:05", "to": "17:00"}}"#
        struct Partial: Decodable { var `repeat`: ScheduleTiming.Recurrence; var between: ScheduleTiming.TimeWindow }
        let partial = try JSONDecoder().decode(Partial.self, from: Data(json.utf8))
        XCTAssertEqual(partial.repeat, .init(.monthly, ordinal: .init(.last)))
        XCTAssertEqual(partial.between.from, .init(9, 5))
        XCTAssertThrowsError(try JSONDecoder().decode(ScheduleTiming.TimeOfDay.self, from: Data(#""25:00""#.utf8)))
        XCTAssertEqual(String(decoding: try JSONEncoder().encode(ScheduleTiming.TimeOfDay(7, 0)), as: UTF8.self), #""07:00""#)
    }

    func testOlderStateWithoutSchedulesDecodes() throws {
        let old = #"{"projects": [], "tasks": [], "nextTaskID": 3001}"#
        let state = try JSONDecoder().decode(AppState.self, from: Data(old.utf8))
        XCTAssertEqual(state.schedules, [])
        XCTAssertEqual(state.wakes, [])
    }
}

@MainActor
final class ScheduleRunTests: XCTestCase {
    var git: MockGit!
    var agent: MockAgent!
    var notifier: MockNotifier!
    var store: MockStore!
    var model: AppModel!
    var project: Project!
    var temp: URL!
    var adminScripts: [String] = []

    override func setUp() async throws {
        git = MockGit()
        agent = MockAgent()
        notifier = MockNotifier()
        store = MockStore()
        temp = FileManager.default.temporaryDirectory.appendingPathComponent("shift-schedules-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        project = Project(name: "Spot", repoPath: temp.path, baseBranch: "main", permissions: .auto)
        store.state = AppState(projects: [project])
        await launch()
    }

    override func tearDown() async throws {
        model.scheduleTimer?.cancel()
        try? FileManager.default.removeItem(at: temp)
    }

    func launch() async {
        model?.scheduleTimer?.cancel()
        model = AppModel(services: Services(git: git, agents: [.claudeCode: agent], servers: MockServers(), ports: MockPorts(),
                                            notifier: notifier, store: store),
                         worktrees: temp.appendingPathComponent("worktrees"))
        model.runAsAdministrator = { [weak self] in self?.adminScripts.append($0) }
        await model.start()
    }

    func makeSchedule(_ finish: Schedule.FinishAction = .review, start: Date = Date().addingTimeInterval(3600),
                      rule: ScheduleTiming.Recurrence? = nil) -> Schedule {
        Schedule(projectID: project.id, title: "Nightly", prompt: "Update the dependencies", baseBranch: "main",
                 agent: .claudeCode, model: "sonnet", permissions: .manual,
                 timing: ScheduleTiming(start: start, repeat: rule), finish: finish)
    }

    /// For state that isn't observed (the wakes): checked every few milliseconds.
    func poll(_ what: String, _ condition: @escaping () -> Bool) async {
        var tries = 0
        while !condition(), tries < 500 {
            tries += 1
            try? await Task.sleep(for: .milliseconds(10))
        }
        let met = condition()
        XCTAssertTrue(met, "Timed out waiting for \(what)")
    }

    func run(of id: Schedule.ID) -> ScheduleRun? { model.schedule(id)?.runs.last }

    func runNow(_ schedule: Schedule) async -> Int {
        model.addSchedule(schedule)
        let taskID = model.runScheduleNow(schedule.id)!
        await waitFor("the run to finish") { self.run(of: schedule.id)?.outcome != .running }
        await model.flush()
        return taskID
    }

    func testRunNowStartsATaskWithTheSchedulesSettings() async {
        let schedule = makeSchedule()
        let taskID = await runNow(schedule)
        let task = model.task(taskID)!
        XCTAssertEqual(task.scheduleID, schedule.id)
        XCTAssertEqual(task.permissions, .manual)
        XCTAssertEqual(task.model, "sonnet")
        XCTAssertEqual(task.baseBranch, "main")
        XCTAssertEqual(agent.requests.first?.prompt, "Update the dependencies")
        XCTAssertEqual(agent.requests.first?.permissions, .manual)
        XCTAssertEqual(task.status, .completed)
        let run = run(of: schedule.id)!
        XCTAssertNil(run.due)
        XCTAssertEqual(run.taskID, taskID)
        XCTAssertEqual(run.outcome, .review)
        XCTAssertEqual(notifier.notifications.map(\.body), ["Nightly is running.", "\(task.title) is ready for review."])
        XCTAssertEqual(store.state.schedules.first?.runs.count, 1)
        XCTAssertEqual(store.state.tasks.first?.scheduleID, schedule.id)
    }

    func testArchiveWithoutChanges() async {
        let schedule = makeSchedule(.archive)
        let taskID = await runNow(schedule)
        XCTAssertEqual(model.task(taskID)?.status, .archived)
        XCTAssertEqual(run(of: schedule.id)?.outcome, .archived)
        XCTAssertTrue(notifier.notifications.last!.body.hasSuffix("finished with no changes and was archived."))
    }

    func testArchiveWithChangesLeavesItForReview() async {
        git.pendingChanges = DiffSummary(files: [FileChange(path: "a.txt", kind: .modified)])
        let schedule = makeSchedule(.archive)
        let taskID = await runNow(schedule)
        XCTAssertEqual(model.task(taskID)?.status, .completed)
        XCTAssertEqual(run(of: schedule.id)?.outcome, .review)
        XCTAssertEqual(run(of: schedule.id)?.reason, "It has changes, so it wasn't archived.")
        XCTAssertNil(model.lastError)
    }

    func testMergeWhenClean() async {
        let schedule = makeSchedule(.merge)
        let taskID = await runNow(schedule)
        XCTAssertEqual(model.task(taskID)?.status, .merged)
        XCTAssertEqual(run(of: schedule.id)?.outcome, .merged)
        XCTAssertTrue(git.calls.contains("merge shift/\(taskID) into main"))
    }

    func testMergeWithConflictsLeavesItForReview() async {
        git.canMerge = false
        let schedule = makeSchedule(.merge)
        let taskID = await runNow(schedule)
        XCTAssertEqual(model.task(taskID)?.status, .conflict)
        XCTAssertEqual(run(of: schedule.id)?.outcome, .review)
        XCTAssertFalse(git.calls.contains { $0.hasPrefix("merge") })
        XCTAssertEqual(notifier.notifications.count, 2)
    }

    func testPullRequest() async {
        let schedule = makeSchedule(.pullRequest)
        _ = await runNow(schedule)
        XCTAssertEqual(run(of: schedule.id)?.outcome, .pullRequest)
        XCTAssertTrue(notifier.notifications.last!.body.hasSuffix("in pull request #12."))
    }

    func testPullRequestWithoutGitHubCLILeavesItForReview() async {
        git.createPullRequestError = MockError("To get started with GitHub CLI, please run: gh auth login")
        let schedule = makeSchedule(.pullRequest)
        _ = await runNow(schedule)
        XCTAssertEqual(run(of: schedule.id)?.outcome, .review)
        XCTAssertTrue(run(of: schedule.id)?.reason?.contains("gh auth login") == true)
        XCTAssertNil(model.lastError)
    }

    func testBlockedRunFails() async {
        agent.scripts = [[.emit(.finished(.blocked(reason: "No network", options: [])))]]
        let schedule = makeSchedule(.merge)
        let taskID = await runNow(schedule)
        XCTAssertEqual(model.task(taskID)?.status, .blocked)
        XCTAssertEqual(run(of: schedule.id)?.outcome, .failed)
        XCTAssertEqual(run(of: schedule.id)?.reason, "No network")
    }

    func testRunStartsWhenDue() async {
        let schedule = makeSchedule(start: Date().addingTimeInterval(0.5))
        model.addSchedule(schedule)
        XCTAssertTrue(model.schedule(schedule.id)!.runs.isEmpty)
        await waitFor("the run") { self.run(of: schedule.id)?.taskID != nil }
        XCTAssertEqual(run(of: schedule.id)?.due, schedule.timing.start)
        XCTAssertNil(model.schedule(schedule.id)?.nextRun())
    }

    func testPausedDoesntRun() async {
        var schedule = makeSchedule(start: Date().addingTimeInterval(0.3))
        schedule.paused = true
        model.addSchedule(schedule)
        try? await Task.sleep(for: .seconds(0.6))
        model.setSchedulePaused(schedule.id, false)
        XCTAssertTrue(model.schedule(schedule.id)!.runs.isEmpty)
        XCTAssertNil(model.schedule(schedule.id)?.nextRun())
    }

    func testMissedWhileShiftWasntRunning() async {
        let start = Date().addingTimeInterval(-3 * 3600 - 60)
        var schedule = makeSchedule(start: start, rule: .init(.hourly))
        schedule.checkedUntil = start.addingTimeInterval(30) // ran the first one
        store.state = AppState(projects: [project], schedules: [schedule], lastAlive: start.addingTimeInterval(40))
        await launch()
        let runs = model.schedule(schedule.id)!.runs
        XCTAssertEqual(runs.map(\.outcome), [.missed, .missed, .missed])
        XCTAssertEqual(runs.map(\.reason), Array(repeating: "Shift wasn't running", count: 3))
        XCTAssertTrue(model.tasks.isEmpty)
        // Run Now still starts one.
        XCTAssertNotNil(model.runScheduleNow(schedule.id))
    }

    func testMissedWhileAsleep() async {
        let start = Date().addingTimeInterval(-3600 - 60)
        var schedule = makeSchedule(start: start, rule: .init(.daily))
        schedule.checkedUntil = start.addingTimeInterval(-120)
        store.state = AppState(projects: [project], schedules: [schedule], lastAlive: start.addingTimeInterval(-100),
                               asleepSince: start.addingTimeInterval(-90))
        await launch()
        XCTAssertEqual(model.schedule(schedule.id)!.runs.map(\.reason), ["Mac was asleep"])

        // While running: a run due between sleeping and waking is missed.
        model.lastSleep = (Date().addingTimeInterval(-600), Date())
        XCTAssertEqual(model.missedReason(Date().addingTimeInterval(-300), atLaunch: false), "Mac was asleep")
        XCTAssertNil(model.missedReason(Date().addingTimeInterval(-900), atLaunch: false))
    }

    func testWakesAreBatchedAndAskedForOnce() async {
        var schedule = makeSchedule(start: Date().addingTimeInterval(3600), rule: .init(.daily))
        schedule.wakeMac = true
        model.addSchedule(schedule)
        await poll("the wakes") { self.model.wakes.count == 7 }
        XCTAssertEqual(adminScripts.count, 1)
        XCTAssertEqual(adminScripts[0].components(separatedBy: "pmset schedule wake").count - 1, 7)
        XCTAssertEqual(model.wakes.first, Date(timeIntervalSince1970: (schedule.timing.start.timeIntervalSince1970 - 120).rounded(.down)))

        model.checkSchedules(atLaunch: false)
        model.updateSchedule(schedule)
        await model.flush()
        XCTAssertEqual(adminScripts.count, 1)

        model.deleteSchedule(schedule.id)
        await poll("the wakes cancelled") { self.model.wakes.isEmpty }
        XCTAssertEqual(adminScripts.count, 2)
        XCTAssertEqual(adminScripts[1].components(separatedBy: "pmset schedule cancel wake").count - 1, 7)
        XCTAssertEqual(store.state.wakes, [])
    }

    func testDeclinedWakesArentAskedAgainUntilSaved() async {
        model.runAsAdministrator = { [weak self] in
            self?.adminScripts.append($0)
            throw MacSetup.Failure("Cancelled.")
        }
        var schedule = makeSchedule(rule: .init(.daily))
        schedule.wakeMac = true
        model.addSchedule(schedule)
        await poll("the dialog") { !self.model.isSchedulingWakes && self.adminScripts.count == 1 }
        model.checkSchedules(atLaunch: false)
        model.runScheduleNow(schedule.id)
        XCTAssertEqual(adminScripts.count, 1)
        model.updateSchedule(schedule)
        await poll("asked again") { self.adminScripts.count == 2 }
    }

    // MARK: shiftctl

    func control(_ arguments: String...) async -> ControlReply {
        model.controlTokens["token"] = project.id
        return await model.handleControl(token: "token", arguments: arguments)
    }

    func testControlCreatesEditsAndRunsSchedules() async throws {
        var reply = await control("schedule", "create", #"""
            {"prompt": "Check the links", "timing": {"start": "2030-01-07T09:00", "repeat": {"frequency": "weekly",
             "weekdays": ["monday", "thursday"]}, "between": {"from": "08:00", "to": "18:00"}}, "finish": "archive"}
            """#)
        XCTAssertTrue(reply.ok, reply.text)
        let schedule = try XCTUnwrap(model.schedules.first)
        XCTAssertEqual(schedule.title, "Check the links")
        XCTAssertEqual(schedule.permissions, .auto)
        XCTAssertEqual(schedule.agent, .claudeCode)
        XCTAssertEqual(schedule.timing.repeat?.weekdays, [.monday, .thursday])
        XCTAssertEqual(Calendar.current.component(.hour, from: schedule.timing.start), 9)
        XCTAssertEqual(schedule.finish, .archive)
        let prefix = String(schedule.id.uuidString.prefix(6))

        reply = await control("schedules")
        XCTAssertTrue(reply.text.contains("\"next\""), reply.text)

        reply = await control("schedule", "edit", prefix, #"{"title": "Links", "timing": {"between": null}, "keepAwake": true}"#)
        XCTAssertTrue(reply.ok, reply.text)
        XCTAssertEqual(model.schedules.first?.title, "Links")
        XCTAssertNil(model.schedules.first?.timing.between)
        XCTAssertEqual(model.schedules.first?.timing.repeat?.weekdays, [.monday, .thursday])
        // The chat can't set keepAwake any more, nor see it.
        XCTAssertFalse(model.schedules.first!.keepAwake)
        XCTAssertFalse(model.scheduleKeepAwake.isHeld)
        reply = await control("schedule", prefix)
        XCTAssertFalse(reply.text.contains("keepAwake"), reply.text)
        // A saved one still keeps the Mac awake.
        var awake = try XCTUnwrap(model.schedules.first)
        awake.keepAwake = true
        model.updateSchedule(awake)
        XCTAssertTrue(model.scheduleKeepAwake.isHeld)

        reply = await control("schedule", "edit", prefix, #"{"permissions": "bypass"}"#)
        XCTAssertFalse(reply.ok)
        reply = await control("schedule", "edit", prefix, #"{"timing": {"start": "tomorrow"}}"#)
        XCTAssertFalse(reply.ok)
        XCTAssertTrue(reply.text.contains("timing.start"), reply.text)

        reply = await control("schedule", "pause", prefix)
        XCTAssertTrue(model.schedules.first!.paused)
        reply = await control("schedule", "resume", prefix)
        XCTAssertFalse(model.schedules.first!.paused)

        reply = await control("schedule", "run", prefix)
        XCTAssertTrue(reply.ok, reply.text)
        await waitFor("the run") { self.model.schedules.first?.runs.first?.outcome == .archived }

        reply = await control("schedule", prefix)
        XCTAssertTrue(reply.text.contains("\"archived\""), reply.text)

        reply = await control("schedule", "delete", prefix)
        XCTAssertTrue(reply.ok)
        XCTAssertTrue(model.schedules.isEmpty)
        XCTAssertEqual(model.tasks.count, 1)
    }

    func testChatDraftsOpenTheFormWithoutCreatingAnything() async {
        let reply = await control("schedule", "draft", #"{"title": "Deps", "prompt": "Update", "timing": {"start": "2030-01-07T09:00", "repeat": {"frequency": "daily"}}}"#)
        XCTAssertTrue(reply.ok, reply.text)
        XCTAssertTrue(reply.text.contains("Every day at"), reply.text)
        XCTAssertTrue(model.schedules.isEmpty)
        let draft = try! XCTUnwrap(model.scheduleDraft)
        XCTAssertEqual(draft.title, "Deps")
        model.saveSchedule(draft)
        XCTAssertEqual(model.schedules.map(\.id), [draft.id])
        // Saved again from Edit: updated, not added.
        var edited = draft
        edited.title = ""
        model.saveSchedule(edited)
        XCTAssertEqual(model.schedules.count, 1)
        XCTAssertEqual(model.schedules.first?.title, "Update")
    }

    func testSlashScheduleAloneOpensAnEmptyForm() {
        model.sendChat(projectID: project.id, text: "/schedule")
        XCTAssertEqual(model.scheduleDraft?.prompt, "")
        XCTAssertEqual(model.scheduleDraft?.permissions, .auto)
        XCTAssertEqual(Calendar.current.component(.minute, from: model.scheduleDraft!.timing.start), 0)
        XCTAssertTrue(model.chat(projectID: project.id)?.prompts.isEmpty ?? true)
    }

    func testDraftFromATaskJoinsItsPrompts() async {
        agent.scripts = [[.emit(.finished(.completed(summary: "Done")))], [.emit(.finished(.completed(summary: "Done")))]]
        let id = model.createTask(projectID: project.id, prompt: "Make it blue")!
        await waitFor("done") { self.model.task(id)?.status == .completed }
        model.sendPrompt(taskID: id, text: "Darker")
        await waitFor("done again") { self.model.task(id)?.status == .completed && self.model.task(id)?.prompts.count == 2 }
        let draft = model.scheduleDraft(fromTask: id)!
        XCTAssertEqual(draft.prompt, "Do the following, in order:\n\n1. Make it blue\n\n2. Darker")
        XCTAssertEqual(draft.title, model.task(id)?.title)
        XCTAssertEqual(draft.permissions, .auto)
    }

    func testControlRefusesWithoutAStart() async {
        let reply = await control("schedule", "create", #"{"prompt": "Hi"}"#)
        XCTAssertFalse(reply.ok)
        XCTAssertEqual(reply.text, "Missing timing.start.")
    }
}

final class ScheduleSummaryTests: XCTestCase {
    let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Europe/Lisbon")!
        return calendar
    }()
    let locale = Locale(identifier: "en_GB")

    func timing(_ rule: ScheduleTiming.Recurrence?, between: (Int, Int)? = nil, endAfter: Int? = nil) -> String {
        // Thursday 8 January 2026, 9:00.
        let start = calendar.date(from: DateComponents(year: 2026, month: 1, day: 8, hour: 9))!
        return ScheduleTiming(start: start, repeat: rule, between: between.map { .init(from: .init($0.0), to: .init($0.1)) },
                              endAfter: endAfter).summary(calendar: calendar, locale: locale)
    }

    func testSummaries() {
        XCTAssertEqual(timing(nil), "Once on Thu 8 Jan at 9:00")
        XCTAssertEqual(timing(.init(.hourly), between: (13, 17)), "Every hour from 13:00 to 17:00")
        XCTAssertEqual(timing(.init(.hourly, interval: 3), endAfter: 5), "Every 3 hours, 5 times")
        XCTAssertEqual(timing(.init(.daily)), "Every day at 9:00")
        XCTAssertEqual(timing(.init(.weekly)), "Every Thursday at 9:00")
        XCTAssertEqual(timing(.init(.weekly, weekdays: [.friday, .monday, .tuesday, .wednesday, .thursday])), "Every weekday at 9:00")
        XCTAssertEqual(timing(.init(.weekly, interval: 2, weekdays: [.tuesday, .thursday])), "Every 2 weeks on Tuesday and Thursday at 9:00")
        XCTAssertEqual(timing(.init(.monthly)), "Every month on the 8th at 9:00")
        XCTAssertEqual(timing(.init(.monthly, monthDays: [22, 1, 3])), "Every month on the 1st, 3rd and 22nd at 9:00")
        XCTAssertEqual(timing(.init(.monthly, ordinal: .init(.last, .friday))), "Every month on the last Friday at 9:00")
        XCTAssertEqual(timing(.init(.monthly, interval: 3, ordinal: .init(.first))), "Every 3 months on the first day at 9:00")
    }
}
