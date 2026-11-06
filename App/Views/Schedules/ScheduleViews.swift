import SwiftUI
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
            Text("It won't run again. The tasks its runs started stay.")
        }
    }
}

// MARK: - Page

struct ScheduleDetailView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.textScale) private var textScale
    let scheduleID: Schedule.ID
    @Binding var selection: TaskItem.ID?
    @State private var confirmingDelete = false

    var body: some View {
        if let schedule = model.schedule(scheduleID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    header(schedule)
                    // Styled like a task's prompt history.
                    GroupBox {
                        Text(schedule.prompt).font(.scaled(.body, textScale)).textSelection(.enabled)
                            .padding(.leading, TaskDetailView.promptIndent)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
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
                Button("Delete") { confirmingDelete = true }
                    .buttonStyle(.glass)
                Spacer()
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle)
            VStack(alignment: .leading, spacing: 4) {
                Label(schedule.statusLine, systemImage: schedule.symbol)
                Text(details(schedule))
            }
            .foregroundStyle(.secondary)
        }
    }

    /// "Open a pull request when done · Claude Code, Opus · from main".
    private func details(_ schedule: Schedule) -> String {
        let model = schedule.model.flatMap { id in self.model.models[schedule.agent]?.first { $0.id == id }?.name ?? id }
        let finish = schedule.finish == .review ? "Left for review when done" : "\(schedule.finish.title) when done"
        var parts = [finish, [schedule.agent.displayName, model].compactMap { $0 }.joined(separator: ", "),
                     "from \(schedule.baseBranch)"]
        if schedule.keepAwake { parts.append("keeps the Mac awake") }
        if schedule.wakeMac { parts.append("wakes the Mac") }
        return parts.joined(separator: " · ")
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
        NavigationStack {
            Form {
                Section {
                    TextField("Title", text: $draft.title, prompt: Text("Named after the prompt if empty"))
                    TextField("Prompt", text: $draft.prompt, prompt: Text("What each run's agent should do"), axis: .vertical)
                        .lineLimit(4...12)
                } footer: {
                    Text("Every run is a new task with this prompt. Its agent knows nothing else, so say everything it needs.")
                        .foregroundStyle(.secondary)
                }
                timingSection
                if draft.timing.repeat != nil { customSection; endSection }
                Section {
                    Picker("When it finishes", selection: $draft.finish) {
                        Text("Leave for review").tag(Schedule.FinishAction.review)
                        Text("Archive if it has no changes").tag(Schedule.FinishAction.archive)
                        Text("Open a pull request").tag(Schedule.FinishAction.pullRequest)
                        Text("Merge if it merges cleanly").tag(Schedule.FinishAction.merge)
                    }
                } footer: {
                    if draft.finish == .archive || draft.finish == .merge {
                        Text("Otherwise it's left for review.").foregroundStyle(.secondary)
                    }
                }
                agentSection
                Section {
                    Toggle("Keep Mac awake while a run is coming", isOn: $draft.keepAwake)
                    Toggle("Wake Mac for runs", isOn: $draft.wakeMac)
                } footer: {
                    if draft.wakeMac {
                        Text("Shift asks for your administrator password to schedule the wakes. A closed MacBook without an external display may not fully wake.")
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Runs missed while the Mac sleeps or Shift is closed aren't caught up.").foregroundStyle(.secondary)
                    }
                }
            }
            .formStyle(.grouped)
            .navigationTitle(isNew ? "New Schedule" : "Edit Schedule")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        model.saveSchedule(draft)
                        onSave(draft)
                        dismiss()
                    }
                    .disabled(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 560, idealHeight: 720)
        .task { branches = await model.branches(for: draft.projectID) }
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

    private var timingSection: some View {
        Section {
            DatePicker("Starts", selection: $draft.timing.start)
            Picker("Repeat", selection: repeatChoice) {
                Text("Never").tag(Repeat.never)
                Divider()
                Text("Every Hour").tag(Repeat.hour)
                Text("Every Day").tag(Repeat.day)
                Text("Every Week").tag(Repeat.week)
                Text("Every Month").tag(Repeat.month)
                Divider()
                Text("Custom").tag(Repeat.custom)
            }
        } footer: {
            if draft.timing.repeat?.frequency == .hourly {
                Label("Every run is its own task: they take disk space and memory until they're archived or merged.",
                      systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func rule<T>(_ keyPath: WritableKeyPath<ScheduleTiming.Recurrence, T>, _ fallback: T) -> Binding<T> {
        Binding { draft.timing.repeat?[keyPath: keyPath] ?? fallback } set: { draft.timing.repeat?[keyPath: keyPath] = $0 }
    }

    @ViewBuilder private var customSection: some View {
        let rule = draft.timing.repeat ?? .init(.daily)
        if repeatChoice.wrappedValue == .custom {
            Section("Custom") {
                Picker("Frequency", selection: self.rule(\.frequency, .daily)) {
                    Text("Hourly").tag(ScheduleTiming.Recurrence.Frequency.hourly)
                    Text("Daily").tag(ScheduleTiming.Recurrence.Frequency.daily)
                    Text("Weekly").tag(ScheduleTiming.Recurrence.Frequency.weekly)
                    Text("Monthly").tag(ScheduleTiming.Recurrence.Frequency.monthly)
                }
                let unit = switch rule.frequency {
                case .hourly: rule.interval == 1 ? "hour" : "hours"
                case .daily: rule.interval == 1 ? "day" : "days"
                case .weekly: rule.interval == 1 ? "week" : "weeks"
                case .monthly: rule.interval == 1 ? "month" : "months"
                }
                Stepper(value: self.rule(\.interval, 1), in: 1...99) {
                    LabeledContent("Every", value: rule.interval == 1 ? unit.capitalized : "\(rule.interval) \(unit)")
                }
                if rule.frequency == .weekly { weekdays(rule) }
                if rule.frequency == .monthly { monthly(rule) }
            }
        }
        if rule.frequency == .hourly || draft.timing.between != nil {
            Section {
                Toggle("Only between", isOn: Binding { draft.timing.between != nil } set: {
                    draft.timing.between = $0 ? .init(from: .init(9), to: .init(17)) : nil
                })
                if draft.timing.between != nil {
                    DatePicker("From", selection: time(\.from), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: time(\.to), displayedComponents: .hourAndMinute)
                }
            } footer: {
                if draft.timing.between != nil {
                    Text("Runs at other times of day are skipped.").foregroundStyle(.secondary)
                }
            }
        }
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
        return LabeledContent("On") {
            HStack(spacing: 4) {
                ForEach(order, id: \.self) { day in
                    Toggle(calendar.veryShortWeekdaySymbols[day.number - 1], isOn: Binding { chosen.contains(day) } set: { on in
                        var days = Set(chosen)
                        if on { days.insert(day) } else if days.count > 1 { days.remove(day) }
                        draft.timing.repeat?.weekdays = Weekday.allCases.filter(days.contains)
                    })
                    .toggleStyle(.button)
                    .help(calendar.weekdaySymbols[day.number - 1])
                }
            }
        }
    }

    @ViewBuilder private func monthly(_ rule: ScheduleTiming.Recurrence) -> some View {
        let calendar = Calendar.current
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
        } else {
            let chosen = Set(rule.monthDays.isEmpty ? [calendar.component(.day, from: draft.timing.start)] : rule.monthDays)
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 4), count: 7), spacing: 4) {
                ForEach(1...31, id: \.self) { day in
                    Toggle(isOn: Binding { chosen.contains(day) } set: { on in
                        var days = chosen
                        if on { days.insert(day) } else if days.count > 1 { days.remove(day) }
                        draft.timing.repeat?.monthDays = days.sorted()
                    }) {
                        Text("\(day)").monospacedDigit().frame(maxWidth: .infinity)
                    }
                    .toggleStyle(.button)
                }
            }
            if chosen.contains(where: { $0 > 28 }) {
                Text("Months without that day are skipped.").font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var endSection: some View {
        let end: End = draft.timing.endAfter != nil ? .after : draft.timing.endOn != nil ? .on : .never
        return Section {
            Picker("End Repeat", selection: Binding { end } set: { choice in
                draft.timing.endAfter = choice == .after ? 10 : nil
                draft.timing.endOn = choice == .on ? Calendar.current.date(byAdding: .month, value: 1, to: draft.timing.start) : nil
            }) {
                Text("Never").tag(End.never)
                Text("After").tag(End.after)
                Text("On Date").tag(End.on)
            }
            if let count = draft.timing.endAfter {
                Stepper(value: Binding { count } set: { draft.timing.endAfter = $0 }, in: 1...999) {
                    LabeledContent("After", value: count == 1 ? "1 time" : "\(count) times")
                }
            }
            if let date = draft.timing.endOn {
                DatePicker("On", selection: Binding { date } set: { draft.timing.endOn = $0 }, displayedComponents: .date)
            }
        }
    }

    // MARK: Agent

    private var agentSection: some View {
        let branchOptions = branches.contains(draft.baseBranch) ? branches : [draft.baseBranch] + branches
        return Section {
            Picker("Agent", selection: Binding { draft.agent } set: { agent in
                draft.agent = agent
                draft.model = model.project(draft.projectID)?.models[agent]
            }) {
                ForEach(AgentKind.allCases) { kind in
                    let installed = model.installedAgents[kind] != nil
                    Label(installed ? kind.displayName : "\(kind.displayName) (not installed)", image: kind.icon)
                        .tag(kind)
                        .disabled(!installed)
                }
            }
            ModelPicker(agent: draft.agent, selection: Binding { draft.model ?? "" } set: { draft.model = $0.isEmpty ? nil : $0 })
            Picker("Permissions", selection: $draft.permissions) {
                ForEach(AgentPermissions.allCases) { Text($0.displayName).tag($0) }
            }
            Picker("Base branch", selection: $draft.baseBranch) {
                ForEach(branchOptions, id: \.self) { Text($0) }
            }
        } header: {
            Text("Each Run")
        } footer: {
            Text(draft.permissions == .manual
                 ? "With Manual permissions, a run waits for you to allow its commands."
                 : "Changes apply from the next run.")
                .foregroundStyle(.secondary)
        }
    }
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
