import SwiftUI
import AppKit
import ShiftCore

extension Schedule {
    /// What selects it in the task list's selection: negative, and never -1 (the chat). The same on every launch.
    var selectionID: TaskItem.ID {
        let bytes = id.uuid
        let high = [bytes.0, bytes.1, bytes.2, bytes.3, bytes.4, bytes.5, bytes.6].reduce(0) { $0 << 8 | Int($1) }
        return -2 - high
    }

    /// A calendar for one run, arrows in a circle for a repeating one.
    var symbol: String { timing.repeat == nil ? "calendar" : "arrow.triangle.2.circlepath" }

    /// "Mon 9:00", "Today 9:00", "12 Dec 9:00": when it runs next. Nil if paused or it won't run again.
    var nextRunText: String? { nextRun().map(Self.shortDate) }

    static func shortDate(_ date: Date) -> String {
        let calendar = Calendar.current
        let time = date.formatted(date: .omitted, time: .shortened)
        if calendar.isDateInToday(date) { return "Today \(time)" }
        if calendar.isDateInTomorrow(date) { return "Tomorrow \(time)" }
        if calendar.isDateInYesterday(date) { return "Yesterday \(time)" }
        let days = abs(calendar.dateComponents([.day], from: calendar.startOfDay(for: .now), to: date).day ?? 99)
        let day = days < 7 ? date.formatted(.dateTime.weekday(.abbreviated)) : date.formatted(.dateTime.day().month(.abbreviated))
        return "\(day) \(time)"
    }

    /// The list's line: how often, and when next.
    var statusLine: String {
        if paused { return "Paused · " + timing.summary() }
        guard let next = nextRunText else { return timing.summary() + " · No more runs" }
        return timing.summary() + " · Next: " + next
    }
}

extension Schedule.FinishAction {
    var title: String {
        switch self {
        case .review: "Leave for review"
        case .archive: "Archive"
        case .pullRequest: "Open a pull request"
        case .merge: "Merge"
        }
    }
}

// MARK: - List row

struct ScheduleRow: View {
    @Environment(AppModel.self) private var model
    let schedule: Schedule
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Image(systemName: schedule.paused ? "pause.circle" : schedule.symbol)
                    .resizable().scaledToFit()
                    .frame(width: 14, height: 14)
                    .foregroundStyle(.secondary)
                Text(schedule.title).lineLimit(1)
                Spacer()
                if let next = schedule.nextRunText {
                    Text(next).font(.subheadline).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            Text(schedule.paused ? "Paused · \(schedule.timing.summary())" : schedule.timing.summary())
                .font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
        }
        .padding(.vertical, 2)
        .contextMenu { ScheduleActionItems(schedule: schedule, confirmingDelete: $confirmingDelete) }
        .deleteScheduleConfirmation(schedule, isPresented: $confirmingDelete, model: model)
    }
}

/// Run Now, Pause or Resume, Edit and Delete: the schedule's context menu and its page's More menu.
struct ScheduleActionItems: View {
    @Environment(AppModel.self) private var model
    let schedule: Schedule
    @Binding var confirmingDelete: Bool

    var body: some View {
        Button("Run Now") { model.runScheduleNow(schedule.id) }
        Button(schedule.paused ? "Resume" : "Pause") { model.setSchedulePaused(schedule.id, !schedule.paused) }
        Button("Edit…") { model.scheduleDraft = schedule }
        Divider()
        Button("Delete Schedule…", role: .destructive) { confirmingDelete = true }
    }
}

extension View {
    func deleteScheduleConfirmation(_ schedule: Schedule, isPresented: Binding<Bool>, model: AppModel) -> some View {
        confirmationDialog("Delete “\(schedule.title)”?", isPresented: isPresented) {
            Button("Delete Schedule", role: .destructive) { model.deleteSchedule(schedule.id) }
        } message: {
            Text("It won't run again. Tasks it already started won't be deleted.")
        }
    }
}

// MARK: - Page

struct ScheduleDetailView: View {
    @Environment(AppModel.self) private var model
    let scheduleID: Schedule.ID
    @Binding var selection: TaskItem.ID?
    @State private var confirmingDelete = false
    @State private var branches: [String] = []

    var body: some View {
        if let schedule = model.schedule(scheduleID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(schedule)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                        // Styled like a task's prompt history.
                        GroupBox {
                            SchedulePrompt(text: schedule.prompt)
                                .padding(8)
                        }
                        .id(schedule.id)
                    }
                    // Changed here, without the form; saved right away.
                    ScheduleSettings(schedule: Binding { schedule } set: { model.saveSchedule($0) }, branches: branches)
                    runs(schedule)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(TaskDetailView.margin)
            }
            .scrollEdgeEffectStyle(.hard, for: .top)
            .toolbar {
                ToolbarItem {
                    Text(schedule.title).font(.title3).lineLimit(1)
                        .padding(.leading, TaskDetailView.margin - TaskDetailView.toolbarInset)
                }
                .sharedBackgroundVisibility(.hidden)
                ToolbarSpacer(.flexible)
                ToolbarItem(placement: .primaryAction) {
                    Menu {
                        ScheduleActionItems(schedule: schedule, confirmingDelete: $confirmingDelete)
                    } label: {
                        Label("More", systemImage: "ellipsis.circle")
                    }
                }
            }
            .deleteScheduleConfirmation(schedule, isPresented: $confirmingDelete, model: model)
            .task(id: schedule.projectID) { branches = await model.branches(for: schedule.projectID) }
        } else {
            EmptyState("Schedule Deleted", systemImage: "calendar")
        }
    }

    private func header(_ schedule: Schedule) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Button("Run Now") { model.runScheduleNow(schedule.id) }
                    .buttonStyle(.glassProminent)
                Button(schedule.paused ? "Resume" : "Pause") { model.setSchedulePaused(schedule.id, !schedule.paused) }
                    .buttonStyle(.glass)
                Button("Edit") { model.scheduleDraft = schedule }
                    .buttonStyle(.glass)
                Spacer()
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle)
            Label(schedule.statusLine, systemImage: schedule.symbol).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private func runs(_ schedule: Schedule) -> some View {
        let runs = schedule.runs.reversed()
        VStack(alignment: .leading, spacing: 8) {
            Text(runs.isEmpty ? "No runs yet" : runs.count == 1 ? "1 run" : "\(runs.count) runs")
                .font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            if !runs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(runs)) { run in
                        runRow(run, schedule)
                        if run.id != runs.last?.id { Divider() }
                    }
                }
                .padding(.horizontal, 12)
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            }
        }
    }

    private func runRow(_ run: ScheduleRun, _ schedule: Schedule) -> some View {
        let task = run.taskID.flatMap(model.task)
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Group {
                if let task {
                    StatusIcon(status: task.status, size: 14, pullRequestOpen: model.pullRequests[task.id]?.state == .open,
                               mergedByPullRequest: task.mergedPullRequest != nil)
                } else {
                    Image(systemName: run.outcome == .missed ? "exclamationmark.circle" : "xmark.circle")
                        .foregroundStyle(run.outcome == .missed ? .orange : .red)
                }
            }
            .frame(width: 14)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(Schedule.shortDate(run.due ?? run.started ?? .now)).monospacedDigit()
                    Text("·").foregroundStyle(.secondary)
                    Text(outcome(run, task)).foregroundStyle(.secondary)
                }
                if let text = run.summary ?? task?.description ?? run.reason, !text.isEmpty {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
                if run.summary != nil || task?.description != nil, let reason = run.reason, run.outcome == .review {
                    Text(reason).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            Spacer()
            if run.outcome == .missed {
                Button("Run Now") { model.runScheduleNow(schedule.id) }.buttonStyle(.glass).controlSize(.small)
            } else if let task {
                TaskNumber(task: task)
            }
        }
        .padding(.vertical, 8)
        .contentShape(.rect)
        .onTapGesture { if let task { selection = task.id } }
        .help(task == nil ? "" : "Open its task")
    }

    private func outcome(_ run: ScheduleRun, _ task: TaskItem?) -> String {
        switch run.outcome {
        case .running:
            switch task?.status {
            case .needsInput?: "Needs input"
            case .blocked?: "Blocked"
            default: run.due == nil ? "Run by hand, running" : "Running"
            }
        case .review: "Left for review"
        case .archived: "Archived"
        case .pullRequest: "Pull request opened"
        case .merged: "Merged"
        case .missed: "Missed: \(run.reason ?? "")"
        case .failed: "Failed"
        }
    }
}

// MARK: - Form

/// The schedule form, modeled on Calendar's event form: new or edited, nothing is saved until Save.
/// A floating panel like Reminders' New List: labels on the left, groups split by lines, Cancel and Save at the bottom.
struct ScheduleForm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var draft: Schedule
    let isNew: Bool
    let onSave: (Schedule) -> Void
    @State private var branches: [String] = []

    enum Repeat: Hashable { case never, hour, day, week, month, custom }
    enum End: Hashable { case never, after, on }
    enum MonthMode: Hashable { case days, ordinal }

    var body: some View {
        VStack(spacing: 0) {
            // A sheet has no title bar: say what it is, since several places open it.
            Text(isNew ? "New Schedule" : "Edit Schedule")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding([.horizontal, .top], 24)
            Form {
                // What
                TextField("Name:", text: $draft.title, prompt: Text("Named after the prompt"))
                // A text editor, not a field: Return adds a line here instead of pressing Save.
                LabeledContent {
                    TextEditor(text: $draft.prompt)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(.vertical, 4)
                        .padding(.horizontal, 1)
                        .frame(height: 110)
                        .background(.background, in: .rect(cornerRadius: 6))
                        .overlay(alignment: .topLeading) {
                            if draft.prompt.isEmpty {
                                Text("Everything each run's agent needs to know").foregroundStyle(.placeholder)
                                    .padding(.vertical, 4).padding(.horizontal, 6)
                                    .allowsHitTesting(false)
                            }
                        }
                        .overlay { RoundedRectangle(cornerRadius: 6).strokeBorder(.separator) }
                    // An editor has no text baseline: give it its first line's, so the label sits level with it.
                    .alignmentGuide(.firstTextBaseline) { _ in 4 + NSFont.systemFont(ofSize: NSFont.systemFontSize).ascender }
                } label: {
                    Text("Prompt:")
                }
                divider
                // When
                timingRows
                divider
                // How each run works. Permissions, branch and sleep come from the window's bar and change on the page.
                LabeledContent("Agent:") {
                    HStack {
                        ScheduleSettings.agentPicker($draft, model: model).labelsHidden().fixedSize()
                        ModelPicker(agent: draft.agent, selection: Binding { draft.model ?? "" } set: { draft.model = $0.isEmpty ? nil : $0 })
                            .labelsHidden()
                            .fixedSize()
                    }
                }
                Picker("When done:", selection: $draft.finish) {
                    Text("Leave for review").tag(Schedule.FinishAction.review)
                    Text("Archive if it has no changes").tag(Schedule.FinishAction.archive)
                    Text("Open a pull request").tag(Schedule.FinishAction.pullRequest)
                    Text("Merge if it merges cleanly").tag(Schedule.FinishAction.merge)
                }
                .fixedSize()
                if draft.finish == .archive || draft.finish == .merge { note("Otherwise it's left for review.") }
            }
            .formStyle(.columns)
            .padding(24)
            Divider().padding(.horizontal, 24)
            HStack { Spacer(); buttons }
                .padding(24)
        }
        .frame(width: 560)
        .task { branches = await model.branches(for: draft.projectID) }
    }

    @ViewBuilder private var buttons: some View {
        HStack {
            Button("Cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? "Create" : "Save") {
                model.saveSchedule(draft)
                onSave(draft)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            .disabled(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
        .controlSize(.large)
    }

    private var divider: some View { Divider().padding(.vertical, 8) }

    /// Help under a control, in the controls' column.
    private func note(_ text: String) -> some View {
        LabeledContent {
            Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 400, alignment: .leading)
        } label: {
            EmptyView()
        }
    }

    // MARK: Timing

    private var repeatChoice: Binding<Repeat> {
        Binding {
            guard let rule = draft.timing.repeat else { return .never }
            guard rule.interval == 1, rule.weekdays.isEmpty, rule.monthDays.isEmpty, rule.ordinal == nil else { return .custom }
            switch rule.frequency {
            case .hourly: return .hour
            case .daily: return .day
            case .weekly: return .week
            case .monthly: return .month
            }
        } set: { choice in
            switch choice {
            case .never: draft.timing.repeat = nil
            case .hour: draft.timing.repeat = .init(.hourly)
            case .day: draft.timing.repeat = .init(.daily)
            case .week: draft.timing.repeat = .init(.weekly)
            case .month: draft.timing.repeat = .init(.monthly)
            case .custom:
                // Shown as custom from here on: weekly on the start's day, which the user then changes.
                let day = Weekday.allCases[Calendar.current.component(.weekday, from: draft.timing.start) - 1]
                draft.timing.repeat = .init(.weekly, weekdays: [day])
            }
            if choice == .never { draft.timing.between = nil; draft.timing.endAfter = nil; draft.timing.endOn = nil }
        }
    }

    @ViewBuilder private var timingRows: some View {
        let rule = draft.timing.repeat ?? .init(.daily)
        // A date and a time field, as in Calendar: clicking the date opens a calendar.
        LabeledContent("Starts:") {
            HStack(spacing: 6) {
                DateField(date: $draft.timing.start, part: .date)
                DateField(date: $draft.timing.start, part: .time)
            }
        }
        Picker("Repeat:", selection: repeatChoice) {
            Text("Never").tag(Repeat.never)
            Divider()
            Text("Every Hour").tag(Repeat.hour)
            Text("Every Day").tag(Repeat.day)
            Text("Every Week").tag(Repeat.week)
            Text("Every Month").tag(Repeat.month)
            Divider()
            Text("Custom").tag(Repeat.custom)
        }
        .fixedSize()
        if draft.timing.repeat?.frequency == .hourly {
            note("Every run is a new task, and each one takes disk space until it's archived or merged.")
        }
        if draft.timing.repeat != nil {
            if repeatChoice.wrappedValue == .custom {
                // "Every [2] [weeks]", as in Calendar.
                LabeledContent("Every:") {
                    HStack {
                        Stepper(value: self.rule(\.interval, 1), in: 1...99) { Text("\(rule.interval)").monospacedDigit() }
                        Picker("", selection: self.rule(\.frequency, .daily)) {
                            let one = rule.interval == 1
                            Text(one ? "hour" : "hours").tag(ScheduleTiming.Recurrence.Frequency.hourly)
                            Text(one ? "day" : "days").tag(ScheduleTiming.Recurrence.Frequency.daily)
                            Text(one ? "week" : "weeks").tag(ScheduleTiming.Recurrence.Frequency.weekly)
                            Text(one ? "month" : "months").tag(ScheduleTiming.Recurrence.Frequency.monthly)
                        }
                        .labelsHidden()
                        .fixedSize()
                    }
                }
                if rule.frequency == .weekly { weekdays(rule) }
                if rule.frequency == .monthly { monthly(rule) }
            }
            if rule.frequency == .hourly || draft.timing.between != nil {
                LabeledContent("Hours:") {
                    HStack {
                        Toggle("Only between", isOn: Binding { draft.timing.between != nil } set: {
                            draft.timing.between = $0 ? .init(from: .init(9), to: .init(17)) : nil
                        })
                        if draft.timing.between != nil {
                            DateField(date: time(\.from), part: .time)
                            Text("and")
                            DateField(date: time(\.to), part: .time)
                        }
                    }
                }
            }
            endRow
        }
    }

    private func rule<T>(_ keyPath: WritableKeyPath<ScheduleTiming.Recurrence, T>, _ fallback: T) -> Binding<T> {
        Binding { draft.timing.repeat?[keyPath: keyPath] ?? fallback } set: { draft.timing.repeat?[keyPath: keyPath] = $0 }
    }

    private func time(_ keyPath: WritableKeyPath<ScheduleTiming.TimeWindow, ScheduleTiming.TimeOfDay>) -> Binding<Date> {
        Binding {
            let time = draft.timing.between?[keyPath: keyPath] ?? .init(9)
            return Calendar.current.date(bySettingHour: time.hour, minute: time.minute, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            draft.timing.between?[keyPath: keyPath] = .init(parts.hour ?? 0, parts.minute ?? 0)
        }
    }

    /// S M T W T F S, in the locale's order.
    private func weekdays(_ rule: ScheduleTiming.Recurrence) -> some View {
        let calendar = Calendar.current
        let order = (0..<7).map { Weekday.allCases[(calendar.firstWeekday - 1 + $0) % 7] }
        let chosen = rule.weekdays.isEmpty ? [Weekday.allCases[calendar.component(.weekday, from: draft.timing.start) - 1]] : rule.weekdays
        return LabeledContent("On:") {
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { day in
                    Toggle(isOn: Binding { chosen.contains(day) } set: { on in
                        var days = Set(chosen)
                        if on { days.insert(day) } else if days.count > 1 { days.remove(day) }
                        draft.timing.repeat?.weekdays = Weekday.allCases.filter(days.contains)
                    }) {
                        Text(calendar.veryShortWeekdaySymbols[day.number - 1]).frame(minWidth: 16)
                    }
                    .toggleStyle(.button)
                    .help(calendar.weekdaySymbols[day.number - 1])
                }
            }
        }
    }

    @ViewBuilder private func monthly(_ rule: ScheduleTiming.Recurrence) -> some View {
        let calendar = Calendar.current
        LabeledContent("On:") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: Binding { rule.ordinal == nil ? MonthMode.days : .ordinal } set: { mode in
                    if mode == .days {
                        draft.timing.repeat?.ordinal = nil
                    } else {
                        draft.timing.repeat?.monthDays = []
                        draft.timing.repeat?.ordinal = .init(.first, Weekday.allCases[calendar.component(.weekday, from: draft.timing.start) - 1])
                    }
                }) {
                    Text("Each").tag(MonthMode.days)
                    Text("On the").tag(MonthMode.ordinal)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                if let ordinal = rule.ordinal {
                    HStack {
                        Picker("", selection: Binding { ordinal.week } set: { draft.timing.repeat?.ordinal?.week = $0 }) {
                            Text("first").tag(ScheduleTiming.MonthOrdinal.Week.first)
                            Text("second").tag(ScheduleTiming.MonthOrdinal.Week.second)
                            Text("third").tag(ScheduleTiming.MonthOrdinal.Week.third)
                            Text("fourth").tag(ScheduleTiming.MonthOrdinal.Week.fourth)
                            Text("last").tag(ScheduleTiming.MonthOrdinal.Week.last)
                        }
                        Picker("", selection: Binding { ordinal.day } set: { draft.timing.repeat?.ordinal?.day = $0 }) {
                            ForEach(Weekday.allCases, id: \.self) { Text(calendar.weekdaySymbols[$0.number - 1]).tag(Weekday?.some($0)) }
                            Divider()
                            Text("day").tag(Weekday?.none)
                        }
                    }
                    .labelsHidden()
                    .fixedSize()
                } else {
                    let chosen = Set(rule.monthDays.isEmpty ? [calendar.component(.day, from: draft.timing.start)] : rule.monthDays)
                    Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(0..<5) { row in
                            GridRow {
                                ForEach(1...7, id: \.self) { column in
                                    let day = row * 7 + column
                                    if day <= 31 {
                                        Toggle(isOn: Binding { chosen.contains(day) } set: { on in
                                            var days = chosen
                                            if on { days.insert(day) } else if days.count > 1 { days.remove(day) }
                                            draft.timing.repeat?.monthDays = days.sorted()
                                        }) {
                                            Text("\(day)").monospacedDigit().frame(minWidth: 20)
                                        }
                                        .toggleStyle(.button)
                                    }
                                }
                            }
                        }
                    }
                    if chosen.contains(where: { $0 > 28 }) {
                        Text("Months without that day are skipped.").font(.callout).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    /// "End: [After] [5] times" or "End: [On Date] [date]".
    private var endRow: some View {
        let end: End = draft.timing.endAfter != nil ? .after : draft.timing.endOn != nil ? .on : .never
        return LabeledContent("End:") {
            HStack {
                Picker("", selection: Binding { end } set: { choice in
                    draft.timing.endAfter = choice == .after ? 10 : nil
                    draft.timing.endOn = choice == .on ? Calendar.current.date(byAdding: .month, value: 1, to: draft.timing.start) : nil
                }) {
                    Text("Never").tag(End.never)
                    Text("After").tag(End.after)
                    Text("On Date").tag(End.on)
                }
                .labelsHidden()
                .fixedSize()
                if let count = draft.timing.endAfter {
                    Stepper(value: Binding { count } set: { draft.timing.endAfter = $0 }, in: 1...999) {
                        Text(count == 1 ? "1 time" : "\(count) times").monospacedDigit()
                    }
                }
                if let date = draft.timing.endOn {
                    DateField(date: Binding { date } set: { draft.timing.endOn = $0 }, part: .date)
                }
            }
        }
    }

    // MARK: Agent

}

extension String {
    /// "Today 9:00" → "today 9:00", for the middle of a sentence. Day and month names keep their capitals.
    var lowercasedFirst: String {
        ["Today", "Tomorrow", "Yesterday"].contains(where: hasPrefix) ? prefix(1).lowercased() + dropFirst() : "on " + self
    }
}

/// The schedule form, whenever there's a draft: from `/schedule`, the chat, Create Schedule from This or Edit.
/// Once saved, the schedule is shown.
struct ScheduleFormPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    @Binding var selectedProject: Project.ID?
    @Binding var selectedTask: TaskItem.ID?

    func body(content: Content) -> some View {
        // Read here, in the body, so a draft set from outside (the chat) is observed and presents the form.
        let current = model.scheduleDraft
        content.sheet(item: Binding { current } set: { model.scheduleDraft = $0 }) { draft in
            ScheduleForm(draft: draft, isNew: model.schedule(draft.id) == nil) { saved in
                selectedProject = saved.projectID
                selectedTask = saved.selectionID
            }
        }
    }
}

/// A schedule's prompt, cut to five lines until clicked. Clicking again folds it back.
private struct SchedulePrompt: View {
    let text: String
    @Environment(\.textScale) private var textScale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false
    @State private var fullHeight: CGFloat = 0
    @State private var shownHeight: CGFloat = 0
    private static let lines = 5

    var body: some View {
        let isLong = fullHeight > shownHeight + 1 || isExpanded
        Text(text).font(.scaled(.body, textScale))
            .lineLimit(isExpanded ? nil : Self.lines)
            .frame(maxWidth: .infinity, alignment: .leading)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { shownHeight = $0 }
            // The whole text, unlimited and hidden, to tell whether five lines cut it.
            .background(alignment: .top) {
                Text(text).font(.scaled(.body, textScale)).fixedSize(horizontal: false, vertical: true).hidden()
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { fullHeight = $0 }
            }
            .contentShape(.rect)
            .onTapGesture {
                guard isLong else { return }
                withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) { isExpanded.toggle() }
            }
            // Toggles on click, so its text can't be selected: Copy is in its context menu, as for a task's prompts.
            .help(isLong ? (isExpanded ? "Click to show less" : "Click to show all") : "")
            .accessibilityAddTraits(isLong ? .isButton : [])
            .accessibilityValue(isLong ? (isExpanded ? "Expanded" : "Collapsed") : "")
            .accessibilityAction { if isLong { isExpanded.toggle() } }
            .contextMenu {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
            }
    }
}

/// The run settings the form leaves out, on the schedule's page as a box of rows like System Settings, each
/// changed in place.
struct ScheduleSettings: View {
    @Environment(AppModel.self) private var model
    @Binding var schedule: Schedule
    let branches: [String]

    /// What a run does when the Mac is asleep at its time: the two settings as one choice.
    enum Asleep: Hashable { case skip, stayAwake, wake }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Settings").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                row("Permissions", note: schedule.permissions == .manual ? "Runs wait for you to allow their commands." : nil) {
                    Picker("Permissions", selection: $schedule.permissions) {
                        ForEach(AgentPermissions.allCases) { Text($0.displayName).tag($0) }
                    }
                }
                Divider()
                row("Branch") {
                    Picker("Branch", selection: $schedule.baseBranch) {
                        // The current value is always offered, so the menu is valid before branches load.
                        ForEach(branches.contains(schedule.baseBranch) ? branches : [schedule.baseBranch] + branches, id: \.self) { Text($0) }
                    }
                }
                Divider()
                row("When the Mac is asleep",
                    note: schedule.wakeMac ? "Shift asks for your administrator password to schedule the wakes." : nil) {
                    Picker("When the Mac is asleep", selection: asleep) {
                        Text("Skip runs").tag(Asleep.skip)
                        Text("Stay awake for runs").tag(Asleep.stayAwake)
                        Text("Wake up for runs").tag(Asleep.wake)
                    }
                }
            }
            .padding(.horizontal, 12)
            .background(.background, in: .rect(cornerRadius: 10))
            .overlay { RoundedRectangle(cornerRadius: 10).strokeBorder(.separator) }
        }
    }

    private func row(_ title: String, note: String? = nil, @ViewBuilder control: () -> some View) -> some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if let note { Text(note).font(.callout).foregroundStyle(.secondary) }
            }
            Spacer(minLength: 16)
            control().labelsHidden().fixedSize()
        }
        .padding(.vertical, 10)
    }

    static func agentPicker(_ schedule: Binding<Schedule>, model: AppModel) -> some View {
        Picker("Agent", selection: Binding { schedule.wrappedValue.agent } set: { agent in
            schedule.wrappedValue.agent = agent
            schedule.wrappedValue.model = model.project(schedule.wrappedValue.projectID)?.models[agent]
        }) {
            ForEach(AgentKind.allCases) { kind in
                let installed = model.installedAgents[kind] != nil
                Label(installed ? kind.displayName : "\(kind.displayName) (not installed)", image: kind.icon)
                    .tag(kind)
                    .disabled(!installed)
            }
        }
    }

    private var asleep: Binding<Asleep> {
        Binding {
            schedule.wakeMac ? .wake : schedule.keepAwake ? .stayAwake : .skip
        } set: { choice in
            schedule.keepAwake = choice == .stayAwake
            schedule.wakeMac = choice == .wake
        }
    }
}



/// A date or a time as a plain field, the way Calendar and Reminders show them: no stepper, and clicking a date
/// opens a small calendar under it. SwiftUI's DatePicker can't show that calendar, so this is AppKit's.
struct DateField: NSViewRepresentable {
    enum Part { case date, time }
    @Binding var date: Date
    let part: Part

    func makeNSView(context: Context) -> NSDatePicker {
        let picker = NSDatePicker()
        picker.datePickerStyle = .textField
        picker.datePickerElements = part == .date ? .yearMonthDay : .hourMinute
        picker.presentsCalendarOverlay = part == .date
        picker.isBezeled = true
        picker.drawsBackground = true
        picker.target = context.coordinator
        picker.action = #selector(Coordinator.changed(_:))
        picker.setContentHuggingPriority(.required, for: .horizontal)
        return picker
    }

    func updateNSView(_ picker: NSDatePicker, context: Context) {
        context.coordinator.date = $date
        if picker.dateValue != date { picker.dateValue = date }
    }

    func makeCoordinator() -> Coordinator { Coordinator(date: $date) }

    final class Coordinator: NSObject {
        var date: Binding<Date>
        init(date: Binding<Date>) { self.date = date }
        @objc func changed(_ picker: NSDatePicker) { date.wrappedValue = picker.dateValue }
    }
}
