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
    @State private var search = ""
    /// Bumped by ⌘F to focus the search field.
    @State private var searchFocusRequests = 0
    /// Per task, what search finds besides its own fields: the agent's replies and the changed files' paths.
    /// Read when a search starts, as it needs every log and worktree.
    @State private var searchText: [TaskItem.ID: String] = [:]
    /// The layout key while a row's tags popover is open: a rebuild would take the row, and the popover, away.
    @State private var heldKey: String?
    /// Titles of the sections folded down to their header; in defaults joined by newlines.
    /// State rather than `@AppStorage`: a defaults write redraws the list outside the toggle's animation. Saved by hand.
    @State private var collapsedSections = Set(UserDefaults.standard.string(forKey: "collapsedTaskSections")?
        .split(separator: "\n").map(String.init) ?? [])

    var body: some View {
        let all = model.tasks(in: project.id)
        let tasks = Self.filter(all, tags: tagFilter, search: search, extra: searchText)
        let sections = Self.sections(tasks)
        let schedules = Self.schedules(model.schedules(in: project.id))
        // The list doesn't re-measure rows and headers that are inserted or moved in place (a task moving to a new
        // section came out clipped), so a change in which task sits in which section rebuilds it at the right sizes.
        // In a ZStack so the rebuild stops there: bars attached to the list itself are rebuilt with it, and the
        // new task field would lose what is being typed in it, and its focus.
        // A description or tags add lines to a row, so one arriving or going rebuilds it too.
        // Not on what the search leaves: the rebuild would take the search field's focus with every keystroke.
        let key = Self.sections(Self.filter(all, tags: tagFilter)).map { "\($0.0):\($0.1.map { "\($0.id)\($0.description?.isEmpty == false)\($0.tags?.isEmpty == false)" })" }.joined()
            + "S:\(schedules.map(\.id))"
        ZStack {
            List(selection: $selection) {
                searchBar(project.tagNames)
                    .listRowSeparator(.hidden)
                    .selectionDisabled()
                ChatRow(replying: model.replyingChats.contains(project.id),
                        waiting: model.chatApprovalRequest(projectID: project.id) != nil).tag(ChatRow.id)
                ForEach(sections.dropLast(), id: \.0) { section($0.0, $0.1) }
                // Above Recently Closed: what's still to come.
                if !schedules.isEmpty {
                    Section {
                        if !isCollapsed("Scheduled") {
                            ForEach(schedules) { ScheduleRow(schedule: $0).tag($0.selectionID) }
                        }
                    } header: {
                        header("Scheduled", count: schedules.count)
                    }
                }
                if let closed = sections.last { section(closed.0, closed.1) }
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
                           description: Text(search.isEmpty ? "No tasks have the chosen tags." : "No tasks match the search."))
            } else if tasks.isEmpty && schedules.isEmpty {
                EmptyState("No Tasks", systemImage: "tray", description: Text("Describe a task below to start one."))
            }
        }
        .safeAreaBar(edge: .bottom) { footer }
        .scrollEdgeEffectStyle(.soft, for: .bottom)
        .toolbar {
            let pushState = model.pushStates[project.id]
            // Pushes the buttons to the column's trailing end, away from the project name.
            ToolbarSpacer(.flexible)
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
        // A tag that leaves the project leaves the filter too, or the list would stay filtered by a tag it no longer offers.
        .onChange(of: project.tagNames) { tagFilter.formIntersection(project.tagNames.map { $0.lowercased() }) }
        .focusedSceneValue(\.focusSearch) { searchFocusRequests += 1 }
        .task(id: search.isEmpty ? nil : project.id) {
            guard !search.isEmpty else { return searchText = [:] }
            for task in model.tasks(in: project.id) where searchText[task.id] == nil {
                let text = await model.searchText(taskID: task.id)
                guard !Task.isCancelled else { return }
                searchText[task.id] = text
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

    /// Tasks with any of `tags` (lowercased) whose title, description, tags, prompts or `extra` text contain `search`.
    /// Nothing chosen and no search: all of them.
    static func filter(_ tasks: [TaskItem], tags: Set<String>, search: String = "",
                       extra: [TaskItem.ID: String] = [:]) -> [TaskItem] {
        tasks.filter { task in
            (tags.isEmpty || (task.tags ?? []).contains { tags.contains($0.lowercased()) })
                && task.matches(search, extra: extra[task.id] ?? "")
        }
    }

    private func searchBar(_ tagNames: [String]) -> some View {
        HStack(spacing: 8) {
            SearchField(text: $search, focusRequests: searchFocusRequests)
            filterMenu(tagNames).buttonStyle(.borderless).imageScale(.large)
        }
        // Out to the edges of the rows' selection below.
        .padding(.horizontal, -6)
        .padding(.bottom, 10)
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

    /// Soonest next run first; paused ones and those that won't run again after them.
    static func schedules(_ schedules: [Schedule]) -> [Schedule] {
        schedules.sorted { ($0.nextRun() ?? .distantFuture, $0.title) < ($1.nextRun() ?? .distantFuture, $1.title) }
    }

    /// Every row's selection, in the order the list shows them: the chat, tasks, schedules, closed tasks. For ⌘[ and ⌘].
    static func rowIDs(_ model: AppModel, project: Project.ID) -> [TaskItem.ID] {
        let sections = Self.sections(model.tasks(in: project))
        return [ChatRow.id] + sections.dropLast().flatMap { $0.1.map(\.id) }
            + schedules(model.schedules(in: project)).map(\.selectionID) + (sections.last?.1.map(\.id) ?? [])
    }

    private func pushButton(_ state: AppModel.PushState) -> some View {
        let title = state.title
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
                if !isCollapsed(title) { ForEach(tasks) { TaskRow(task: $0) } }
            } header: {
                header(title, count: tasks.count)
            }
        }
    }

    /// Not while searching: what's found would hide in a folded section.
    private func isCollapsed(_ title: String) -> Bool {
        search.isEmpty && collapsedSections.contains(title)
    }

    private func header(_ title: String, count: Int) -> some View {
        SectionHeader(title: title, count: count, collapsed: isCollapsed(title)) {
            // Not part of the list's rebuild key, so its rows slide in and out and the chevron turns. After the click
            // is handled: changed during the table's own mouse handling, the rows snap without animating.
            DispatchQueue.main.async {
                withAnimation {
                    if collapsedSections.remove(title) == nil { collapsedSections.insert(title) }
                }
                UserDefaults.standard.set(collapsedSections.sorted().joined(separator: "\n"), forKey: "collapsedTaskSections")
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
        PromptField(placeholder: "New task or ‘/’ for commands", submitTitle: "Start", isNewTaskField: true,
                    draftKey: "project \(project.id)", commands: [.schedule],
                    onNewSchedule: { model.scheduleDraft = model.newSchedule(projectID: project.id) },
                    accessory: AnyView(BaseBranchMenu(project: project))) { text, attachments in
            // `/schedule` alone opens the schedule form; with words, the chat drafts it, asking what it needs to know.
            if let words = AppModel.command("schedule", text) {
                model.sendChat(projectID: project.id, text: text)
                if !words.isEmpty { selection = ChatRow.id }
            } else if let id = model.createTask(projectID: project.id, prompt: text, attachments: attachments) {
                selection = id
            }
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
                if let schedule = task.scheduleID.flatMap(model.schedule) {
                    Image(systemName: schedule.symbol).imageScale(.small).foregroundStyle(.secondary)
                        .help("Started by the schedule “\(schedule.title)”")
                }
                TaskNumber(task: task)
            }
            // Two lines tall when there is one, nothing when not: the list rebuilds when a description arrives.
            if task.description?.isEmpty == false {
                Text(task.description ?? "").font(.subheadline).foregroundStyle(.secondary).lineLimit(2, reservesSpace: true)
            }
            if task.tags?.isEmpty == false { TaskTags(tags: task.tags, project: model.project(task.projectID),
                         onRemove: { model.removeTag(taskID: task.id, $0) },
                         onDelete: { model.deleteTag(projectID: task.projectID, $0) },
                         isShared: { model.tagIsShared(taskID: task.id, $0) },
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

/// A section title with a chevron that folds the section: shown on hover, and always while folded, with the count of
/// what's hidden next to the title.
private struct SectionHeader: View {
    let title: String
    let count: Int
    let collapsed: Bool
    let toggle: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: 4) {
                Text(title)
                if collapsed { Text("\(count)").monospacedDigit().foregroundStyle(.tertiary) }
                Image(systemName: "chevron.down")
                    .imageScale(.small)
                    .fontWeight(.semibold)
                    .rotationEffect(.degrees(collapsed ? -90 : 0))
                    // Quicker than the rows, so the click answers straight away.
                    .animation(.easeOut(duration: 0.1), value: collapsed)
                    .opacity(collapsed || hovering ? 1 : 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(collapsed ? "Show \(title)" : "Hide \(title)")
        // Extra room around each header so the groups read apart and the first row isn't tight under it.
        .padding(.top, 10).padding(.bottom, 4)
    }
}

/// AppKit's own search field: SwiftUI has one only as `.searchable`, which goes in a toolbar or sidebar, not in a list.
private struct SearchField: NSViewRepresentable {
    @Binding var text: String
    var focusRequests: Int

    func makeNSView(context: Context) -> NSSearchField {
        let field = NSSearchField()
        field.placeholderString = "Search"
        field.delegate = context.coordinator
        field.sendsSearchStringImmediately = true
        // The clear button reports through its action, not as a text change.
        field.target = context.coordinator
        field.action = #selector(Coordinator.changed(_:))
        return field
    }

    func updateNSView(_ field: NSSearchField, context: Context) {
        context.coordinator.parent = self
        if field.stringValue != text { field.stringValue = text }
        if context.coordinator.focusRequests != focusRequests {
            context.coordinator.focusRequests = focusRequests
            field.window?.makeFirstResponder(field)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchField
        var focusRequests: Int
        init(_ parent: SearchField) { self.parent = parent; focusRequests = parent.focusRequests }
        func controlTextDidChange(_ note: Notification) {
            parent.text = (note.object as? NSSearchField)?.stringValue ?? ""
        }
        @objc func changed(_ field: NSSearchField) { parent.text = field.stringValue }
    }
}
