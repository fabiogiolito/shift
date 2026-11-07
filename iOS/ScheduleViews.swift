import ShiftProtocol
import SwiftUI

// Schedules on the phone: see them and their runs, Run Now, Pause and Resume, and save one the chat drafted.
// Editing every field and deleting stay on the Mac.

/// What opens a schedule's page in the navigation stack (a bare UUID opens a project).
struct ScheduleLink: Hashable {
    let id: UUID
}

/// In a project's list, between its tasks and the closed ones.
struct ScheduleRow: View {
    let schedule: Schedule

    var body: some View {
        NavigationLink(value: ScheduleLink(id: schedule.id)) {
            HStack(alignment: .firstLineCenter, spacing: 12) {
                Image(systemName: schedule.symbol)
                    .foregroundStyle(.secondary)
                    .frame(width: 18)
                    .alignmentGuide(.firstLineCenter) { $0[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 2) {
                    Text(schedule.title).lineLimit(2).lineHeight(.tight)
                        .alignmentGuide(.firstLineCenter) { $0[.firstTextBaseline] - 6 }
                    // Next run moves on as time passes.
                    TimelineView(.everyMinute) { _ in
                        Text(schedule.paused ? "Paused" : schedule.nextRunText.map { "Next: \($0)" } ?? "No more runs")
                            .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                    }
                }
            }
        }
    }
}

struct ScheduleDetailView: View {
    @Environment(RemoteModel.self) private var model
    let scheduleID: UUID
    @State private var isBusy = false

    var body: some View {
        if let schedule = model.schedule(scheduleID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    VStack(alignment: .leading, spacing: 8) {
                        Text(schedule.title).font(.title2.bold())
                        Group {
                            TimelineView(.everyMinute) { _ in
                                Label(schedule.statusLine, systemImage: schedule.symbol)
                            }
                            Label("When done: \(schedule.finish.title)", systemImage: schedule.finish.symbol)
                        }
                        .foregroundStyle(.secondary)
                    }
                    actions(schedule)
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Prompt").font(.subheadline).foregroundStyle(.secondary)
                        Text(schedule.prompt)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
                    }
                    runs(schedule)
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationBarTitleDisplayMode(.inline)
        } else {
            EmptyState("Schedule Deleted", systemImage: "calendar", description: Text("It was deleted on your Mac."))
        }
    }

    private func actions(_ schedule: Schedule) -> some View {
        HStack {
            Button { perform { _ = await model.runScheduleNow(schedule.id) } } label: {
                Text("Run Now").frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            Button { perform { await model.setSchedulePaused(schedule.id, !schedule.paused) } } label: {
                Text(schedule.paused ? "Resume" : "Pause").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
        }
        .controlSize(.large)
        .disabled(isBusy || model.link != .online)
    }

    @ViewBuilder private func runs(_ schedule: Schedule) -> some View {
        let runs = Array(schedule.runs.reversed())
        VStack(alignment: .leading, spacing: 8) {
            Text(runs.isEmpty ? "No runs yet" : runs.count == 1 ? "1 run" : "\(runs.count) runs")
                .font(.subheadline).foregroundStyle(.secondary)
            if !runs.isEmpty {
                VStack(spacing: 0) {
                    ForEach(runs) { run in
                        RunRow(run: run)
                        if run.id != runs.last?.id { Divider().padding(.leading, 42) }
                    }
                }
                .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
            }
        }
    }

    private func perform(_ action: @escaping () async -> Void) {
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}

/// When, how it went, and what its task did. Opens its task, if it has one.
private struct RunRow: View {
    @Environment(RemoteModel.self) private var model
    let run: ScheduleRun

    var body: some View {
        let task = run.taskID.flatMap(model.task)
        if let task {
            NavigationLink(value: task.id) { content(task) }.buttonStyle(.plain)
        } else {
            content(nil)
        }
    }

    private func content(_ task: TaskItem?) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Group {
                if let task {
                    StatusIcon(status: task.status, size: 18, pullRequestOpen: model.state.pullRequests[task.id]?.state == .open,
                               mergedByPullRequest: task.mergedPullRequest != nil)
                } else {
                    Image(systemName: run.outcome == .missed ? "exclamationmark.circle" : "xmark.circle")
                        .foregroundStyle(run.outcome == .missed ? .orange : .red)
                }
            }
            .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(Schedule.shortDate(run.due ?? run.started ?? .now)).monospacedDigit()
                Text(run.outcomeText(task: task?.status)).font(.subheadline).foregroundStyle(.secondary)
                // A missed run's reason is already in its outcome.
                if let text = run.summary ?? task?.description ?? (run.outcome == .missed ? nil : run.reason), !text.isEmpty {
                    Text(text).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if task != nil {
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .contentShape(.rect)
    }
}

/// Under the chat: the schedule it drafted, as the Mac's form has it, to save from here.
/// Changes go through the chat ("make it 10:00"), which drafts it again; the form on the Mac edits every field.
struct ScheduleDraftCard: View {
    @Environment(RemoteModel.self) private var model
    let draft: Schedule
    @State private var isBusy = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("New Schedule", systemImage: draft.symbol).font(.subheadline).foregroundStyle(.secondary)
            Text(draft.title.isEmpty ? "Untitled" : draft.title).font(.headline)
            VStack(alignment: .leading, spacing: 6) {
                TimelineView(.everyMinute) { _ in Text(draft.statusLine) }
                Label("When done: \(draft.finish.title)", systemImage: draft.finish.symbol)
            }
            .font(.subheadline).foregroundStyle(.secondary)
            if !draft.prompt.isEmpty { Text(draft.prompt).lineLimit(6) }
            HStack {
                Button { perform { await model.saveScheduleDraft(draft.id) } } label: {
                    Text("Save Schedule").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft.prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Button("Discard", role: .destructive) { perform { await model.discardScheduleDraft(draft.id) } }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .disabled(isBusy || model.link != .online)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 16))
    }

    private func perform(_ action: @escaping () async -> Void) {
        isBusy = true
        Task {
            await action()
            isBusy = false
        }
    }
}
