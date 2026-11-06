import Foundation

/// A prompt that starts a task by itself on a timetable (docs/specs/scheduled-tasks.md). Each time it comes due it
/// starts a run: a new task in its project, from its base branch, with its agent, model and permissions.
/// Its JSON is also what the project chat's agent reads and writes through `shiftctl schedule`.
public struct Schedule: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    public var projectID: Project.ID
    public var title: String
    public var prompt: String
    public var baseBranch: String
    public var agent: AgentKind
    /// nil: the agent's own default.
    public var model: String?
    public var permissions: AgentPermissions
    public var timing: ScheduleTiming
    public var finish: FinishAction
    /// Holds a power assertion while a run is coming, so the Mac doesn't go to sleep by itself.
    public var keepAwake: Bool
    /// Has the Mac woken shortly before each run (`pmset schedule wake`, needs the admin password).
    public var wakeMac: Bool
    public var paused: Bool
    /// Oldest first.
    public var runs: [ScheduleRun]
    public var createdAt: Date
    /// Every occurrence up to here has been started or logged as missed.
    public var checkedUntil: Date

    public enum FinishAction: String, Codable, CaseIterable, Sendable {
        case review, archive, pullRequest, merge

        public init(from decoder: Decoder) throws {
            self = FinishAction(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .review
        }
    }

    public init(id: UUID = UUID(), projectID: Project.ID, title: String, prompt: String, baseBranch: String,
                agent: AgentKind, model: String? = nil, permissions: AgentPermissions, timing: ScheduleTiming,
                finish: FinishAction = .review, keepAwake: Bool = false, wakeMac: Bool = false, paused: Bool = false,
                runs: [ScheduleRun] = [], createdAt: Date = Date(), checkedUntil: Date? = nil) {
        self.id = id
        self.projectID = projectID
        self.title = title
        self.prompt = prompt
        self.baseBranch = baseBranch
        self.agent = agent
        self.model = model
        self.permissions = permissions
        self.timing = timing
        self.finish = finish
        self.keepAwake = keepAwake
        self.wakeMac = wakeMac
        self.paused = paused
        self.runs = runs
        self.createdAt = createdAt
        // A start up to a minute ago still runs: "now" is in the past by the time it's saved.
        self.checkedUntil = checkedUntil ?? createdAt.addingTimeInterval(-60)
    }

    /// The next time it comes due, nil if paused or it won't any more.
    public func nextRun(after date: Date = Date(), calendar: Calendar = .current) -> Date? {
        paused ? nil : timing.nextOccurrence(after: max(date, checkedUntil), calendar: calendar)
    }
}

/// One time a schedule came due, or was run by hand.
public struct ScheduleRun: Codable, Identifiable, Hashable, Sendable {
    public var id: UUID
    /// When it was due. nil: Run Now.
    public var due: Date?
    public var started: Date?
    public var taskID: TaskItem.ID?
    public var outcome: Outcome
    /// Why it was missed or failed, or why the finish action wasn't applied.
    public var reason: String?
    /// The task's description, once it has one.
    public var summary: String?

    public enum Outcome: String, Codable, Sendable {
        case running, review, archived, pullRequest, merged, missed, failed

        /// One from a newer build reads as left for review.
        public init(from decoder: Decoder) throws {
            self = Outcome(rawValue: try decoder.singleValueContainer().decode(String.self)) ?? .review
        }
    }

    public init(id: UUID = UUID(), due: Date?, started: Date? = nil, taskID: TaskItem.ID? = nil, outcome: Outcome,
                reason: String? = nil, summary: String? = nil) {
        self.id = id
        self.due = due
        self.started = started
        self.taskID = taskID
        self.outcome = outcome
        self.reason = reason
        self.summary = summary
    }
}

public enum Weekday: String, Codable, CaseIterable, Sendable {
    case sunday, monday, tuesday, wednesday, thursday, friday, saturday

    /// `Calendar`'s: 1 is Sunday.
    public var number: Int { Self.allCases.firstIndex(of: self)! + 1 }
}

/// When a schedule runs, modeled on Calendar's event form (without years, with hours). Local time.
public struct ScheduleTiming: Codable, Hashable, Sendable {
    /// The first run, or the only one. Always a run, whatever the repeat rule, unless outside `between`.
    public var start: Date
    /// nil: never repeats.
    public var `repeat`: Recurrence?
    /// Only runs whose time of day is in this window (both ends included) happen; the others are skipped.
    public var between: TimeWindow?
    /// Stops after this many runs (skipped ones don't count, missed ones do).
    public var endAfter: Int?
    /// No runs after this day (it's included).
    public var endOn: Date?

    public init(start: Date, repeat: Recurrence? = nil, between: TimeWindow? = nil, endAfter: Int? = nil, endOn: Date? = nil) {
        self.start = start
        self.repeat = `repeat`
        self.between = between
        self.endAfter = endAfter
        self.endOn = endOn
    }

    public struct Recurrence: Codable, Hashable, Sendable {
        public enum Frequency: String, Codable, Sendable { case hourly, daily, weekly, monthly }

        public var frequency: Frequency
        /// Every N hours, days, weeks or months.
        public var interval: Int
        /// Weekly: the days it runs. Empty: the start's.
        public var weekdays: [Weekday]
        /// Monthly: days of the month, 1–31; months without that day are skipped. Empty, with no `ordinal`: the start's.
        public var monthDays: [Int]
        /// Monthly, instead of `monthDays`: "the last Friday", "the first day".
        public var ordinal: MonthOrdinal?

        public init(_ frequency: Frequency, interval: Int = 1, weekdays: [Weekday] = [], monthDays: [Int] = [],
                    ordinal: MonthOrdinal? = nil) {
            self.frequency = frequency
            self.interval = interval
            self.weekdays = weekdays
            self.monthDays = monthDays
            self.ordinal = ordinal
        }

        /// Only the frequency is required, so the chat's agent can write one by hand.
        public init(from decoder: Decoder) throws {
            let values = try decoder.container(keyedBy: CodingKeys.self)
            frequency = try values.decode(Frequency.self, forKey: .frequency)
            interval = try values.decodeIfPresent(Int.self, forKey: .interval) ?? 1
            weekdays = try values.decodeIfPresent([Weekday].self, forKey: .weekdays) ?? []
            monthDays = try values.decodeIfPresent([Int].self, forKey: .monthDays) ?? []
            ordinal = try values.decodeIfPresent(MonthOrdinal.self, forKey: .ordinal)
        }
    }

    public struct MonthOrdinal: Codable, Hashable, Sendable {
        public enum Week: String, Codable, Sendable { case first, second, third, fourth, last }
        public var week: Week
        /// nil: a day of any kind ("the last day").
        public var day: Weekday?

        public init(_ week: Week, _ day: Weekday? = nil) {
            self.week = week
            self.day = day
        }
    }

    public struct TimeWindow: Codable, Hashable, Sendable {
        public var from: TimeOfDay
        /// Before `from`: the window runs past midnight.
        public var to: TimeOfDay

        public init(from: TimeOfDay, to: TimeOfDay) {
            self.from = from
            self.to = to
        }

        func contains(_ minute: Int) -> Bool {
            from.minutes <= to.minutes ? (from.minutes...to.minutes).contains(minute)
                : minute >= from.minutes || minute <= to.minutes
        }
    }

    /// "13:00" in JSON.
    public struct TimeOfDay: Codable, Hashable, Sendable {
        public var hour: Int
        public var minute: Int

        public init(_ hour: Int, _ minute: Int = 0) {
            self.hour = hour
            self.minute = minute
        }

        var minutes: Int { hour * 60 + minute }

        public init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            let parts = try container.decode(String.self).split(separator: ":").map { Int($0) }
            guard parts.count == 2, let hour = parts[0], let minute = parts[1], (0..<24).contains(hour), (0..<60).contains(minute) else {
                throw DecodingError.dataCorruptedError(in: container, debugDescription: "A time of day is \"HH:mm\".")
            }
            self.init(hour, minute)
        }

        public func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(String(format: "%02d:%02d", hour, minute))
        }
    }

    // MARK: Occurrences

    /// The first run strictly after `date`, nil if there are no more.
    public func nextOccurrence(after date: Date, calendar: Calendar = .current) -> Date? {
        var next: Date?
        forEachOccurrence(from: date, calendar: calendar) { occurrence in
            guard occurrence > date else { return true }
            next = occurrence
            return false
        }
        return next
    }

    /// The runs in `(after, through]`, oldest first.
    public func occurrences(after: Date, through: Date, calendar: Calendar = .current) -> [Date] {
        var found: [Date] = []
        forEachOccurrence(from: after, calendar: calendar) { occurrence in
            guard occurrence <= through else { return false }
            if occurrence > after { found.append(occurrence) }
            return true
        }
        return found
    }

    /// Calls `body` with each run in order, until it returns false or there are no more. `hint`: runs before it
    /// may be left out (they still are when the count of runs matters).
    private func forEachOccurrence(from hint: Date, calendar: Calendar, _ body: (Date) -> Bool) {
        let hint = endAfter == nil ? hint : start
        let lastDay = endOn.flatMap { calendar.date(byAdding: .day, value: 1, to: calendar.startOfDay(for: $0)) }
        var count = 0
        // False once there are no more.
        func offer(_ date: Date) -> Bool {
            if let lastDay, date >= lastDay { return false }
            if let between {
                let time = calendar.dateComponents([.hour, .minute], from: date)
                guard between.contains((time.hour ?? 0) * 60 + (time.minute ?? 0)) else { return true }
            }
            count += 1
            if let endAfter, count > endAfter { return false }
            return body(date)
        }
        guard let rule = `repeat`, rule.interval > 0 else {
            _ = offer(start)
            return
        }

        if rule.frequency == .hourly {
            // In elapsed time, so a DST change neither skips nor doubles a run.
            let step = Double(rule.interval) * 3600
            var k = max(0, Int((hint.timeIntervalSince(start) / step).rounded(.down)))
            // ponytail: stops 20 years out; nothing here runs that long.
            while k < 200_000, offer(start.addingTimeInterval(Double(k) * step)) { k += 1 }
            return
        }

        let startDay = calendar.startOfDay(for: start)
        let time = calendar.dateComponents([.hour, .minute, .second], from: start)
        let first = calendar.dateComponents([.year, .month, .day, .weekday], from: start)
        let skipped = max(0, calendar.dateComponents([.day], from: startDay, to: calendar.startOfDay(for: hint)).day ?? 0)
        // Weeks are counted from the start's week, as the calendar's locale starts them.
        let weekOffset = ((first.weekday ?? 1) - calendar.firstWeekday + 7) % 7
        let weekdays = Set(rule.weekdays.isEmpty ? [first.weekday ?? 1] : rule.weekdays.map(\.number))
        let monthDays = Set(rule.monthDays.isEmpty ? [first.day ?? 1] : rule.monthDays)

        // ponytail: looks 30 years ahead for a day that matches; a rule no month satisfies ("every Feb 30") finds nothing.
        for offset in skipped..<(skipped + 366 * 30) {
            guard let day = calendar.date(byAdding: .day, value: offset, to: startDay) else { return }
            let date = calendar.dateComponents([.year, .month, .day, .weekday], from: day)
            let matches: Bool
            if offset == 0 {
                matches = true
            } else {
                switch rule.frequency {
                case .hourly, .daily:
                    matches = offset % rule.interval == 0
                case .weekly:
                    matches = weekdays.contains(date.weekday ?? 0) && ((offset + weekOffset) / 7) % rule.interval == 0
                case .monthly:
                    let months = ((date.year ?? 0) - (first.year ?? 0)) * 12 + (date.month ?? 0) - (first.month ?? 0)
                    guard months % rule.interval == 0 else { matches = false; break }
                    if let ordinal = rule.ordinal {
                        matches = Self.day(ordinal, inMonthOf: day, calendar: calendar) == date.day
                    } else {
                        matches = monthDays.contains(date.day ?? 0)
                    }
                }
            }
            guard matches else { continue }
            // A time that doesn't exist that day (DST starts) moves an hour later; one that happens twice runs the first time.
            guard let run = offset == 0 ? start : calendar.date(from: DateComponents(year: date.year, month: date.month, day: date.day,
                                                                                      hour: time.hour, minute: time.minute, second: time.second)),
                  run >= start else { continue }
            if !offer(run) { return }
        }
    }

    /// The day of the month `ordinal` falls on in `date`'s month.
    static func day(_ ordinal: MonthOrdinal, inMonthOf date: Date, calendar: Calendar) -> Int? {
        guard let length = calendar.range(of: .day, in: .month, for: date)?.count,
              let firstOfMonth = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) else { return nil }
        let index = [MonthOrdinal.Week.first, .second, .third, .fourth].firstIndex(of: ordinal.week)
        guard let weekday = ordinal.day else { return index.map { $0 + 1 } ?? length }
        let firstWeekday = calendar.component(.weekday, from: firstOfMonth)
        let firstMatch = 1 + (weekday.number - firstWeekday + 7) % 7
        if let index { return firstMatch + index * 7 }
        return firstMatch + ((length - firstMatch) / 7) * 7
    }
}
