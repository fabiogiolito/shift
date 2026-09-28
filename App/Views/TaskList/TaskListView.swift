import SwiftUI
import AppKit
import ShiftCore

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var selection: TaskItem.ID?
    @State private var activations = 0

    var body: some View {
        let tasks = model.tasks(in: project.id)
        List(selection: $selection) {
            section("Review", tasks.filter { $0.status == .completed || $0.status == .conflict })
            section("Tasks", tasks.filter { [.working, .needsInput, .blocked].contains($0.status) })
            section("Recently Merged", Array(tasks.filter { $0.status == .merged }
                .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }.prefix(10)))
        }
        // Sidebar style keeps section headers from pinning below the toolbar, so the toolbar's edge line
        // lines up with the detail column's. Its sidebar background is dropped: this is the content column.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .overlay {
            if tasks.isEmpty {
                ContentUnavailableView("No Tasks", systemImage: "tray", description: Text("Describe a task below to start one."))
            }
        }
        .safeAreaBar(edge: .bottom) { footer }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .toolbar {
            if let state = model.pushStates[project.id] {
                // Pushes the button to the column's trailing end, away from the project name.
                ToolbarSpacer(.flexible)
                ToolbarItem { pushButton(state) }
            }
        }
        // Commits may have been made or pushed outside Shift while the user was away.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in activations += 1 }
        .task(id: "\(project.id)|\(project.baseBranch)|\(activations)") {
            await model.refreshPushState(projectID: project.id)
        }
    }

    private func pushButton(_ state: AppModel.PushState) -> some View {
        let title = state.unpushed == 0 ? "Nothing to push"
            : "Push \(state.unpushed) \(state.unpushed == 1 ? "commit" : "commits") to \(state.remote)/\(project.baseBranch)"
        return Button {
            Task { await model.push(projectID: project.id) }
        } label: {
            HStack(spacing: 4) {
                if state.isPushing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "arrow.up")
                }
                if state.unpushed > 0 { Text("\(state.unpushed)").monospacedDigit() }
            }
        }
        .disabled(state.unpushed == 0 || state.isPushing)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func section(_ title: String, _ tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            Section(title) { ForEach(tasks) { TaskRow(task: $0) } }
        }
    }

    private var footer: some View {
        PromptField(placeholder: "New task", submitTitle: "Start", isNewTaskField: true) { text in
            if let id = model.createTask(projectID: project.id, prompt: text, agent: nil) { selection = id }
        }
        .padding(12)
    }
}

struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The icon's leading edge lines up with the description below it.
            HStack(spacing: 6) {
                StatusIcon(status: task.status, size: 14)
                Text(task.title).lineLimit(1)
                Spacer()
                TaskNumber(task: task)
            }
            if let description = task.description {
                Text(description).font(.caption).foregroundStyle(.secondary).lineLimit(2)
            }
        }
        .padding(.vertical, 2)
    }
}
