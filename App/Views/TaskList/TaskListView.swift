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
        let sections: [(String, [TaskItem])] = [
            ("Review", tasks.filter { $0.status == .completed || $0.status == .conflict }),
            ("Tasks", tasks.filter { [.working, .needsInput, .blocked].contains($0.status) }),
            ("Recently Merged", Array(tasks.filter { $0.status == .merged }
                .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }.prefix(10))),
        ]
        // The list doesn't re-measure rows and headers that are inserted or moved in place (a task moving to a new
        // section came out clipped), so a change in which task sits in which section rebuilds it at the right sizes.
        // In a ZStack so the rebuild stops there: bars attached to the list itself are rebuilt with it, and the
        // new task field would lose what is being typed in it, and its focus.
        ZStack {
            List(selection: $selection) {
                ForEach(sections, id: \.0) { section($0.0, $0.1) }
            }
            .id(sections.map { "\($0.0):\($0.1.map(\.id))" }.joined())
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
            let pushState = model.pushStates[project.id]
            if !project.isApp || pushState != nil {
                // Pushes the buttons to the column's trailing end, away from the project name.
                ToolbarSpacer(.flexible)
            }
            if !project.isApp {
                ToolbarItem {
                    Button {
                        Task { if let url = await model.baseServerURL(projectID: project.id) { ExternalApps().openInBrowser(url) } }
                    } label: {
                        Image(systemName: "globe")
                    }
                    .help("Open \(project.baseBranch) in browser")
                }
            }
            if let pushState {
                ToolbarItem { pushButton(pushState) }
            }
        }
        // Commits may have been made or pushed outside Shift while the user was away.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in activations += 1 }
        .task(id: "\(project.id)|\(model.bases(of: project.id))|\(activations)") {
            await model.refreshPushState(projectID: project.id)
        }
    }

    private func pushButton(_ state: AppModel.PushState) -> some View {
        let title = state.unpushed == 0 ? "Nothing to push"
            : "Push \(state.unpushed) \(state.unpushed == 1 ? "commit" : "commits") to "
                + state.branches.map { "\(state.remote)/\($0)" }.formatted(.list(type: .and))
        return Button {
            Task { await model.push(projectID: project.id) }
        } label: {
            HStack(spacing: 4) {
                if state.isPushing {
                    ProgressView().controlSize(.mini)
                } else {
                    Image(systemName: "arrow.up").imageScale(.small).fontWeight(.medium)
                }
                if state.unpushed > 0 { Text("\(state.unpushed)").font(.callout).monospacedDigit() }
            }
        }
        .disabled(state.unpushed == 0 || state.isPushing)
        .help(title)
        .accessibilityLabel(title)
    }

    @ViewBuilder private func section(_ title: String, _ tasks: [TaskItem]) -> some View {
        if !tasks.isEmpty {
            Section {
                ForEach(tasks) { TaskRow(task: $0) }
            } header: {
                // Extra room above each header so the groups read apart.
                Text(title).padding(.top, 10)
            }
        }
    }

    private var footer: some View {
        PromptField(placeholder: "New task", submitTitle: "Start", isNewTaskField: true) { text, attachments in
            if let id = model.createTask(projectID: project.id, prompt: text, attachments: attachments) { selection = id }
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
            // Always two lines tall, even before the description arrives: the list doesn't re-measure a row
            // whose content changes in place, so a fixed height keeps every row sized right.
            Text(task.description ?? "").font(.caption).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
        }
        .padding(.vertical, 2)
    }
}
