import SwiftUI
import ShiftCore

/// What the task's menus ask to show: shared by the More menu in the task's header and the task list's context menu.
struct TaskActions {
    var output: TaskOutput?
    var renaming = false
    var addingTag = false
    var confirmingDelete = false
    /// Completed with nothing committed or uncommitted against its base: it can be archived.
    var unchanged = false
}

/// The items of a task's More menu, also its context menu in the task list.
struct TaskActionItems: View {
    @Environment(AppModel.self) private var model
    @Environment(\.colorScheme) private var colorScheme
    let task: TaskItem
    let project: Project
    @Binding var actions: TaskActions

    var body: some View {
        if !task.status.isClosed {
            // Core recreates a missing folder before the next run; until then there is nothing to open.
            let folderExists = FileManager.default.fileExists(atPath: task.worktreePath)
            Group {
                OpenInMenu(directory: task.worktreeURL)
            }
            .disabled(!folderExists)
            .help(folderExists ? "" : "The task's folder is recreated the next time the agent runs.")
            if project.runsApp {
                Button("App Log") { actions.output = .appLog }
            }
            if project.isApp {
                let built = project.targets.filter { $0.kind != .run }
                if built.count > 1 {
                    Menu("Build Log") {
                        ForEach(built) { target in
                            Button(target.name) { actions.output = .buildLog(target, in: project) }
                        }
                    }
                } else if let target = built.first {
                    Button("Build Log") { actions.output = .buildLog(target, in: project) }
                }
            }
            if task.status == .working || task.approvalRequest != nil {
                Button("Stop Task") { model.stop(taskID: task.id) }
            }
            Divider()
        }
        if actions.unchanged && !task.status.isClosed {
            Button("Archive Task") { Task { await model.archive(taskID: task.id) } }
        }
        Menu("Tags") {
            ForEach(TaskListView.tagNames(model.tasks(in: project.id)), id: \.self) { name in
                let on = task.tags?.contains { $0.caseInsensitiveCompare(name) == .orderedSame } == true
                Button {
                    if on { model.removeTag(taskID: task.id, name) } else { model.addTags(taskID: task.id, name) }
                } label: {
                    // Menus drop item icons and colors, so the checkbox, dot and name are one picture,
                    // like the tag filter's rows.
                    menuImage(HStack(spacing: 6) {
                        Image(systemName: on ? "checkmark.square.fill" : "square")
                            .foregroundStyle(on ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                        Circle().fill(project.color(ofTag: name).color).frame(width: 8, height: 8)
                        Text(name)
                    }
                    .font(.body)
                    .environment(\.colorScheme, colorScheme))
                    .accessibilityLabel(on ? "\(name), on" : name)
                }
            }
            Divider()
            Button("New Tag…") { actions.addingTag = true }
        }
        Button("Rename Task…") { actions.renaming = true }
        Button("Delete Task…", role: .destructive) { actions.confirmingDelete = true }
    }
}

extension View {
    /// The log sheet, rename alert and delete confirmation the task's menu items open.
    func taskActions(_ task: TaskItem, _ actions: Binding<TaskActions>) -> some View {
        modifier(TaskActionsPresenter(task: task, actions: actions))
    }
}

private struct TaskActionsPresenter: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @Binding var actions: TaskActions

    func body(content: Content) -> some View {
        let taskID = task.id
        content
            .sheet(item: $actions.output) { output in
                OutputSheet(title: output.title) {
                    switch output {
                    case .appLog: await model.serverLog(taskID: taskID)
                    case .buildLog(let target, _): model.buildLog(taskID: taskID, target: target)
                    }
                }
            }
            .renameTaskAlert(task, isPresented: $actions.renaming)
            .modifier(NewTagAlert(task: task, isPresented: $actions.addingTag))
            .confirmationDialog("Delete “\(task.title)”?", isPresented: $actions.confirmingDelete) {
                Button("Delete Task", role: .destructive) { Task { await model.delete(taskID: taskID) } }
            } message: {
                Text("Its changes are discarded without merging.")
            }
    }
}

/// Asks for one or more comma-separated tags to add to `task`.
private struct NewTagAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @Binding var isPresented: Bool
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { if isPresented { name = "" } }
            .alert("New Tag", isPresented: $isPresented) {
                TextField("Name", text: $name)
                Button("Add") { model.addTags(taskID: task.id, name) }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Separate several tags with commas.")
            }
    }
}

/// Debugging text, from the ••• menu.
enum TaskOutput: Hashable, Identifiable {
    case appLog
    case buildLog(BuildTarget.ID, title: String)
    var id: Self { self }

    static func buildLog(_ target: BuildTarget, in project: Project?) -> Self {
        .buildLog(target.id, title: (project?.targets.count ?? 0) > 1 ? "Build Log: \(target.name)" : "Build Log")
    }

    var title: String {
        switch self {
        case .appLog: "App Log"
        case .buildLog(_, let title): title
        }
    }
}

private struct OutputSheet: View {
    let title: String
    let load: () async -> String
    @State private var text: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.map { $0.isEmpty ? "No output." : $0 } ?? "Loading…")
                    .font(.callout.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
            // The latest output, where errors are, is at the end.
            .defaultScrollAnchor(.bottom)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.separator))
            HStack {
                Spacer()
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text ?? "", forType: .string)
                }
                .disabled(text?.isEmpty ?? true)
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 640, maxWidth: .infinity, minHeight: 420, maxHeight: .infinity)
        .task { text = await load() }
    }
}
