import SwiftUI
import AppKit
import ShiftCore

struct TaskListView: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @Binding var selection: TaskItem.ID?
    @State private var activations = 0
    /// Lowercased tag names to show tasks with; empty shows every task.
    @State private var tagFilter: Set<String> = []
    @State private var showingFilter = false
    /// The layout key while a row's tags popover is open: a rebuild would take the row, and the popover, away.
    @State private var heldKey: String?

    var body: some View {
        let all = model.tasks(in: project.id)
        let tasks = Self.filter(all, tags: tagFilter)
        let sections = Self.sections(tasks)
        // The list doesn't re-measure rows and headers that are inserted or moved in place (a task moving to a new
        // section came out clipped), so a change in which task sits in which section rebuilds it at the right sizes.
        // In a ZStack so the rebuild stops there: bars attached to the list itself are rebuilt with it, and the
        // new task field would lose what is being typed in it, and its focus.
        // A description or tags add lines to a row, so one arriving or going rebuilds it too.
        let key = sections.map { "\($0.0):\($0.1.map { "\($0.id)\($0.description?.isEmpty == false)\($0.tags?.isEmpty == false)" })" }.joined()
        ZStack {
            List(selection: $selection) {
                ChatRow(replying: model.replyingChats.contains(project.id),
                        waiting: model.chatApprovalRequest(projectID: project.id) != nil).tag(ChatRow.id)
                ForEach(sections, id: \.0) { section($0.0, $0.1) }
            }
            .id(heldKey ?? key)
            .environment(\.holdTaskListLayout) { heldKey = $0 ? key : nil }
        }
        // Sidebar style keeps section headers from pinning below the toolbar, so the toolbar's edge line
        // lines up with the detail column's. Its sidebar background is dropped: this is the content column.
        .listStyle(.sidebar)
        .scrollContentBackground(.hidden)
        .scrollEdgeEffectStyle(.hard, for: .top)
        .overlay {
            if tasks.isEmpty && !all.isEmpty {
                EmptyState("No Matching Tasks", systemImage: "line.3.horizontal.decrease.circle",
                           description: Text("No tasks have the chosen tags."))
            } else if tasks.isEmpty {
                EmptyState("No Tasks", systemImage: "tray", description: Text("Describe a task below to start one."))
            }
        }
        .safeAreaBar(edge: .bottom) { footer }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .toolbar {
            let pushState = model.pushStates[project.id]
            let tagNames = project.tagNames
            // Pushes the buttons to the column's trailing end, away from the project name.
            ToolbarSpacer(.flexible)
            ToolbarItem { filterMenu(tagNames) }
            if !project.isApp {
                ToolbarItem {
                    let opening = model.openingBase.contains(project.id)
                    Button {
                        Task { if let url = await model.baseServerURL(projectID: project.id) { ExternalApps().openInBrowser(url) } }
                    } label: {
                        if opening {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "globe")
                        }
                    }
                    .disabled(opening)
                    .help(opening ? "Starting the server for \(project.baseBranch)…" : "Open \(project.baseBranch) in browser")
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
            // Likely back from the browser, where a pull request was opened or merged.
            await model.refreshPullRequests(projectID: project.id)
        }
    }

    /// Tasks with any of `tags` (lowercased). Nothing chosen: all of them.
    static func filter(_ tasks: [TaskItem], tags: Set<String>) -> [TaskItem] {
        guard !tags.isEmpty else { return tasks }
        return tasks.filter { ($0.tags ?? []).contains { tags.contains($0.lowercased()) } }
    }

    /// A popover rather than a menu: it stays open, so several tags can be picked in one go.
    private func filterMenu(_ names: [String]) -> some View {
        let active = !tagFilter.isEmpty
        return Button {
            showingFilter.toggle()
        } label: {
            Image(systemName: active ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease.circle")
        }
        .help(active ? "Showing some tasks by tag" : "Filter tasks by tag")
        .popover(isPresented: $showingFilter, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                if names.isEmpty {
                    Text("**No tags.**\nRight click a task to tag it.").foregroundStyle(.secondary)
                        .frame(width: 200, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(names, id: \.self) { name in
                    Toggle(isOn: Binding { tagFilter.contains(name.lowercased()) } set: {
                        if $0 { tagFilter.insert(name.lowercased()) } else { tagFilter.remove(name.lowercased()) }
                    }) {
                        HStack(spacing: 6) {
                            Circle().fill(project.color(ofTag: name).color).frame(width: 8, height: 8)
                            Text(name)
                        }
                    }
                    .toggleStyle(.checkbox)
                }
                if active {
                    Divider()
                    Button("Clear") { tagFilter = []; showingFilter = false }.buttonStyle(.plain)
                }
            }
            .padding(12)
            .frame(minWidth: 140, alignment: .leading)
        }
    }

    /// The list's sections in order. Also gives ⌘[ and ⌘] the order to step through.
    static func sections(_ tasks: [TaskItem]) -> [(String, [TaskItem])] {
        [
            ("Review", tasks.filter { $0.status == .completed || $0.status == .conflict }),
            ("Tasks", tasks.filter { [.working, .needsInput, .blocked].contains($0.status) }),
            ("Recently Closed", Array(tasks.filter { $0.status.isClosed }
                .sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }.prefix(10))),
        ]
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
                if state.unpushed > 0 { Text("\(state.unpushed)").monospacedDigit() }
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
                // Extra room around each header so the groups read apart and the first row isn't tight under it.
                Text(title).padding(.top, 10).padding(.bottom, 4)
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let warning = model.emptyBaseWarning(projectID: project.id) {
                Label(warning, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            newTaskField
        }
        .padding(12)
    }

    private var newTaskField: some View {
        PromptField(placeholder: "New task", submitTitle: "Start", isNewTaskField: true,
                    draftKey: "project \(project.id)") { text, attachments in
            if let id = model.createTask(projectID: project.id, prompt: text, attachments: attachments) { selection = id }
        }
    }
}

extension EnvironmentValues {
    /// Called with true while a row shows its tags popover, and false when it closes.
    @Entry var holdTaskListLayout: (Bool) -> Void = { _ in }
}

struct TaskRow: View {
    let task: TaskItem
    @Environment(AppModel.self) private var model
    @Environment(\.holdTaskListLayout) private var holdLayout
    @State private var actions = TaskActions()

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            // The icon's leading edge lines up with the description below it.
            HStack(spacing: 6) {
                StatusIcon(status: task.status, size: 14, pullRequestOpen: model.pullRequests[task.id]?.state == .open,
                           mergedByPullRequest: task.mergedPullRequest != nil)
                Text(task.title).lineLimit(1)
                Spacer()
                TaskNumber(task: task)
            }
            // Two lines tall when there is one, nothing when not: the list rebuilds when a description arrives.
            if task.description?.isEmpty == false {
                Text(task.description ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            if task.tags?.isEmpty == false { TaskTags(tags: task.tags, project: model.project(task.projectID),
                         onDelete: { model.removeTag(taskID: task.id, $0) },
                         onColor: { model.setTagColor(projectID: task.projectID, $0, $1) }).padding(.top, 2) }
        }
        .padding(.vertical, 2)
        .contextMenu {
            if let project = model.project(task.projectID) {
                TaskActionItems(task: task, project: project, actions: $actions)
            }
        }
        .taskActions(task, $actions)
        .onChange(of: actions.editingTags) { holdLayout(actions.editingTags) }
        // ponytail: one diff per finished task in the list, for its context menu; cache in AppModel if lists grow long.
        .task(id: task.status) {
            let changes = task.status == .completed ? await model.changes(taskID: task.id) : nil
            actions.unchanged = changes?.files.isEmpty == true
        }
    }
}

extension View {
    /// Asks for a new name for `task`. Shared by the task list and the More menu.
    func renameTaskAlert(_ task: TaskItem, isPresented: Binding<Bool>) -> some View {
        modifier(RenameTaskAlert(task: task, isPresented: isPresented))
    }
}

private struct RenameTaskAlert: ViewModifier {
    @Environment(AppModel.self) private var model
    let task: TaskItem
    @Binding var isPresented: Bool
    @State private var name = ""

    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { if isPresented { name = task.title } }
            .alert("Rename Task", isPresented: $isPresented) {
                TextField("Name", text: $name)
                Button("Rename") { model.rename(taskID: task.id, to: name) }
                Button("Cancel", role: .cancel) {}
            }
    }
}
