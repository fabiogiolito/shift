import PhotosUI
import SafariServices
import ShiftProtocol
import SwiftUI

struct ProjectsView: View {
    @Environment(RemoteModel.self) private var model
    @State private var confirmingForget = false

    var body: some View {
        Group {
            if !model.hasState {
                ProgressView()
            } else if model.state.projects.isEmpty {
                EmptyState("No Projects", systemImage: "folder", description: Text("Add a project in Shift on your Mac."))
            } else {
                List(model.state.projects) { project in
                    NavigationLink(value: project.id) {
                        let tasks = model.tasks(in: project.id)
                        LabeledContent {
                            let waiting = tasks.filter(\.status.needsAttention).count
                            if waiting > 0 { Text(String(waiting)).monospacedDigit().foregroundStyle(.blue) }
                        } label: {
                            HStack(alignment: .firstLineCenter, spacing: 12) {
                                Group {
                                    if case let image?? = model.projectIcons[project.id] {
                                        Image(uiImage: image).resizable().scaledToFit()
                                            .clipShape(RoundedRectangle(cornerRadius: 6))
                                            // Keeps white icons from fusing with the background.
                                            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator, lineWidth: 0.5))
                                            // The text's center sits above its x-height; this looks centered.
                                            .offset(y: 2)
                                    } else {
                                        Image(systemName: "folder").font(.system(size: 15)).foregroundStyle(.secondary)
                                    }
                                }
                                .frame(width: 28, height: 28)
                                .alignmentGuide(.firstLineCenter) { $0[VerticalAlignment.center] }
                                VStack(alignment: .leading) {
                                    Text(project.name)
                                        .alignmentGuide(.firstLineCenter) { $0[VerticalAlignment.center] }
                                    Text(Project.summary(of: tasks)).font(.subheadline)
                                        .runningShimmer(tasks.contains { $0.status == .working })
                                }
                                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                            }
                        }
                    }
                    .task(id: model.link) { await model.loadIcon(projectID: project.id) }
                }
                // Same room under the large title as the task list.
                .contentMargins(.top, 16, for: .scrollContent)
            }
        }
        .navigationTitle("Projects")
        .toolbar {
            Menu("More", systemImage: "ellipsis") {
                Button("Forget This Mac", role: .destructive) { confirmingForget = true }
            }
        }
        .confirmationDialog("Forget this Mac?", isPresented: $confirmingForget) {
            Button("Forget", role: .destructive) { model.forget() }
        } message: {
            Text("To connect again you'll need a new code from Shift on your Mac.")
        }
    }
}

struct TaskListView: View {
    @Environment(RemoteModel.self) private var model
    let projectID: UUID
    @State private var isCreating = false
    @State private var isOpeningSite = false
    @State private var site: URL?
    @State private var search = ""
    /// Lowercased tag names to show tasks with; empty shows every task.
    @State private var tagFilter: Set<String> = []
    /// What the Mac found the search in: replies and changed files, which the phone doesn't have.
    @State private var macMatches: Set<Int> = []

    var body: some View {
        let all = model.tasks(in: projectID).sorted { $0.id > $1.id }
        let tasks = all.filter(shows)
        let active = tasks.filter { !$0.status.isClosed }
        let closed = tasks.filter(\.status.isClosed).sorted { ($0.mergedAt ?? .distantPast) > ($1.mergedAt ?? .distantPast) }
        let project = model.state.projects.first { $0.id == projectID }
        let schedules = model.schedules(in: projectID)
        let tagNames: [String] = project?.tagNames ?? []
        List {
            if let project { Section { ChatRow(project: project) } }
            if !active.isEmpty {
                Section { ForEach(active) { TaskRow(task: $0) } }
            }
            // As on the Mac: between the tasks and the closed ones.
            if !schedules.isEmpty {
                Section("Scheduled") { ForEach(schedules) { ScheduleRow(schedule: $0) } }
            }
            if !closed.isEmpty {
                Section("Closed") {
                    ForEach(closed) { TaskRow(task: $0) }
                }
            }
        }
        // Room between the large title and the first group.
        .contentMargins(.top, 16, for: .scrollContent)
        // Hidden under the title until the list is pulled down: it starts scrolled just past the search field.
        .searchable(text: $search, placement: .navigationBarDrawer(displayMode: .automatic))
        .background(HideSearchOnAppear())
        .task(id: search) { await searchMac() }
        .onChange(of: tagNames) { _, names in tagFilter.formIntersection(names.map { $0.lowercased() }) }
        .overlay {
            if tasks.isEmpty && !all.isEmpty {
                EmptyState("No Matching Tasks", systemImage: "line.3.horizontal.decrease.circle",
                           description: Text(search.isEmpty ? "No tasks have the chosen tags." : "No tasks match the search."))
            } else if tasks.isEmpty && schedules.isEmpty {
                EmptyState(title: "No Tasks", systemImage: "tray", description: Text("Start one here or in Shift on your Mac.")) {
                    Button("New Task") { isCreating = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(project?.name ?? "Tasks")
        .toolbar {
            // Push, preview and the tag filter act on the project, so they share a capsule; a new task is its own thing.
            ToolbarItemGroup {
                // As on the Mac: there whenever the project has a remote, the count of commits its merged tasks left to push.
                if let push = model.state.pushStates?[projectID] {
                    Button { Task { await model.push(projectID: projectID) } } label: {
                        HStack(spacing: 4) {
                            if push.isPushing { ProgressView() } else { Image(systemName: "arrow.up") }
                            if push.unpushed > 0 { Text(String(push.unpushed)).monospacedDigit() }
                        }
                    }
                    .disabled(push.unpushed == 0 || push.isPushing)
                    .accessibilityLabel(push.title)
                }
                if let project, !project.isApp {
                    Button(action: openSite) {
                        if isOpeningSite { ProgressView() } else { Label("Open \(project.baseBranch)", systemImage: "globe") }
                    }
                    .disabled(isOpeningSite)
                }
                if let project { filterMenu(project) }
            }
            ToolbarSpacer(.fixed)
            ToolbarItem { Button("New Task", systemImage: "plus") { isCreating = true } }
        }
        .sheet(isPresented: Binding(get: { site != nil }, set: { if !$0 { site = nil } })) {
            if let site { SafariView(url: site).ignoresSafeArea() }
        }
        .navigationDestination(isPresented: $isCreating) { NewTaskView(projectID: projectID) }
    }

    private func searchMac() async {
        guard !search.trimmingCharacters(in: .whitespaces).isEmpty else { return macMatches = [] }
        // Waits for typing to pause: the Mac reads every task's log to answer.
        try? await Task.sleep(for: .milliseconds(300))
        guard !Task.isCancelled, let found = await model.searchTasks(projectID: projectID, query: search) else { return }
        macMatches = found
    }

    private func shows(_ task: TaskItem) -> Bool {
        let tagged = tagFilter.isEmpty || (task.tags ?? []).contains { tagFilter.contains($0.lowercased()) }
        return tagged && (task.matches(search) || macMatches.contains(task.id))
    }

    private func filterMenu(_ project: Project) -> some View {
        Menu {
            if project.tagNames.isEmpty {
                Text("No tags. Hold a task to tag it.")
            }
            ForEach(project.tagNames, id: \.self) { name in
                Toggle(isOn: Binding { tagFilter.contains(name.lowercased()) } set: {
                    if $0 { tagFilter.insert(name.lowercased()) } else { tagFilter.remove(name.lowercased()) }
                }) {
                    Label { Text(name) } icon: {
                        Image(systemName: "circle.fill").foregroundStyle(project.color(ofTag: name).color)
                    }
                }
            }
            if !tagFilter.isEmpty {
                Divider()
                Button("Clear", role: .destructive) { tagFilter = [] }
            }
        } label: {
            Label("Filter", systemImage: tagFilter.isEmpty ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        // Stays open, so several tags can be picked in one go.
        .menuActionDismissBehavior(.disabled)
        .accessibilityLabel("Filter by tag")
    }

    private func openSite() {
        isOpeningSite = true
        Task {
            site = await model.baseURL(projectID: projectID)
            isOpeningSite = false
        }
    }
}

/// Pinned to the top of the list, like on the Mac.
private struct ChatRow: View {
    @Environment(RemoteModel.self) private var model
    let project: Project

    var body: some View {
        NavigationLink {
            ChatView(project: project)
        } label: {
            LabeledContent {
                if model.state.chatApprovals[project.id] != nil {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.blue).accessibilityLabel("Waiting for you")
                } else if model.state.replyingChats.contains(project.id) {
                    ProgressView()
                }
            } label: {
                Label("Chat", systemImage: "bubble.left.and.text.bubble.right")
            }
        }
    }
}

/// What opens a project's chat in the navigation stack (a bare UUID opens the project).
struct ChatLink: Hashable {
    let projectID: UUID
}

/// The project's one conversation with its agent. Not a task.
struct ChatView: View {
    @Environment(RemoteModel.self) private var model
    let project: Project
    @State private var stream: LogStream?
    @State private var confirmingNew = false
    @State private var scroll = ScrollPosition(edge: .bottom)
    /// Scrolled back from the newest message: new ones don't pull the view down.
    @State private var scrolledUp = false

    var body: some View {
        let chat = model.chat(projectID: project.id)
        let replying = model.state.replyingChats.contains(project.id)
        let draft: Schedule? = model.scheduleDraft(projectID: project.id)
        ScrollView {
            messages(chat: chat, replying: replying, draft: draft)
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollPosition($scroll)
        // On send, the new message and "Working…" in view.
        .onChange(of: chat?.prompts.count) { withAnimation { scroll.scrollTo(edge: .bottom) } }
        .onChange(of: replying) { if replying { withAnimation { scroll.scrollTo(edge: .bottom) } } }
        // Follows whatever arrives, unless scrolled back to read: the log loading on open too, which can come in
        // pieces and lay out late, so it opens on the newest message.
        .onScrollGeometryChange(for: [CGFloat].self) { geo in
            [geo.contentSize.height, geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY]
        } action: { old, new in
            if !scrolledUp && new[0] > old[0] {
                scroll.scrollTo(edge: .bottom)
            } else {
                scrolledUp = new[1] > 100
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if chat == nil {
                EmptyState("Chat About \(project.name)", systemImage: "bubble.left.and.text.bubble.right",
                           description: Text("Ask about any task and plan with the agent. It can start tasks, follow them and merge them when you ask."))
            }
        }
        .safeAreaBar(edge: .bottom) {
            PromptBar(placeholder: "Ask or tell the agent anything…", commands: [.task, .schedule]) {
                await model.sendChat(projectID: project.id, text: $0, attachments: $1)
            }
        }
        .navigationTitle("Chat")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if replying {
                Button("Stop", systemImage: "stop.fill") { Task { await model.stopChat(projectID: project.id) } }
            }
            Button("New Chat", systemImage: "square.and.pencil") { confirmingNew = true }.disabled(chat == nil)
        }
        .confirmationDialog("Start a new chat?", isPresented: $confirmingNew) {
            Button("New Chat", role: .destructive) { Task { await model.newChat(projectID: project.id) } }
        } message: {
            Text("This conversation is deleted, and the agent won't remember it.")
        }
        // A first message and New Chat both change which log this is.
        .task(id: chat?.id) {
            stream = chat.map { model.openLog(.chat($0.id), agent: $0.agent ?? project.defaultAgent) }
        }
        .onChange(of: chat?.id) { old, _ in
            if let old { model.closeLog(.chat(old)) }
        }
        .onDisappear {
            if let chat { model.closeLog(.chat(chat.id)) }
        }
    }

    private func messages(chat: ProjectChat?, replying: Bool, draft: Schedule?) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Conversation(prompts: chat?.prompts ?? [], turns: stream?.turns ?? [])
            if let request = model.state.chatApprovals[project.id] {
                Label { Text(.init("Wants to \(request)")) } icon: { Image(systemName: "hand.raised.fill") }
                    .foregroundStyle(.blue)
                HStack {
                    Button("Allow") { Task { await model.answerChatApproval(projectID: project.id, allow: true) } }
                        .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { Task { await model.answerChatApproval(projectID: project.id, allow: false) } }
                        .buttonStyle(.bordered)
                }
            } else if replying {
                Label { Text(model.state.isOffline == true ? TaskItem.offlineActivity : "Working…") } icon: { ProgressView() }.foregroundStyle(.secondary)
            }
            // What the chat drafted, last: under its reply, to save from here.
            if let draft { ScheduleDraftCard(draft: draft) }
        }
    }
}

/// The first prompt, and then the task it started, in place: going back from it leads to the list.
private struct NewTaskView: View {
    @Environment(RemoteModel.self) private var model
    let projectID: UUID
    @State private var taskID: Int?
    /// The branch it starts from, if not the project's.
    @State private var base: String?
    @State private var branches: [String] = []
    /// Sent `/schedule …`: the chat drafts it, and the schedule form opens on the Mac.
    @State private var showsChat = false

    var body: some View {
        // The Mac's reply can come just ahead of the task itself.
        if let taskID, model.task(taskID) != nil {
            TaskDetailView(taskID: taskID)
        } else if showsChat, let project = model.state.projects.first(where: { $0.id == projectID }) {
            ChatView(project: project)
        } else {
            Color.clear
                .safeAreaBar(edge: .bottom) {
                    PromptBar(placeholder: "What should it do?", focusesOnAppear: true, commands: [.schedule],
                              accessory: AnyView(branchMenu)) { text, attachments in
                        // As on the Mac: the words go to the project chat, whose agent asks what's missing and opens the
                        // schedule form there. Alone, it would open an empty form on the Mac, out of sight: it needs words.
                        if let words = Prompt.command("schedule", text) {
                            guard !words.isEmpty else { return false }
                            showsChat = await model.sendChat(projectID: projectID, text: text, attachments: attachments)
                            return showsChat
                        }
                        taskID = await model.createTask(projectID: projectID, prompt: text, attachments: attachments, baseBranch: base)
                        return taskID != nil
                    }
                }
                .navigationTitle("New Task")
                .navigationBarTitleDisplayMode(.inline)
                .task(id: model.link) {
                    if model.link == .online { branches = await model.branches(projectID: projectID) }
                }
        }
    }

    @ViewBuilder private var branchMenu: some View {
        if let project = model.state.projects.first(where: { $0.id == projectID }) {
            let current = base ?? project.baseBranch
            Menu {
                // The current one is always offered, so the picker is valid before branches load.
                Picker("Starts From", selection: Binding(get: { current }, set: { base = $0 })) {
                    ForEach(branches.contains(current) ? branches : [current] + branches, id: \.self) { Text($0) }
                }
            } label: {
                HStack(spacing: 4) {
                    Image("Branch")
                    Text(current).lineLimit(1)
                }
                .font(.subheadline)
                .foregroundStyle(Color.secondary)
                .padding(.horizontal, 6)
                .frame(height: 30)
            }
            .accessibilityLabel("Starts from \(current)")
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL
    @State private var previewURL: URL?
    @State private var log: TaskLog?
    @State private var renaming = false
    @State private var addingTag = false
    @State private var confirmingDelete = false
    @State private var text = ""

    var body: some View {
        NavigationLink(value: task.id) {
            HStack(alignment: .firstLineCenter, spacing: 12) {
                StatusIcon(status: task.status, size: 18, pullRequestOpen: model.state.pullRequests[task.id]?.state == .open,
                           mergedByPullRequest: task.mergedPullRequest != nil)
                    .alignmentGuide(.firstLineCenter) { $0[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 2) {
                    // A title can wrap: center on its first line, a little above the baseline.
                    Text(task.title).lineLimit(2).lineSpacing(-2) // Not .lineHeight(.tight): it clips g, p and y.
                        .alignmentGuide(.firstLineCenter) { $0[.firstTextBaseline] - 6 }
                    if task.tags?.isEmpty == false { TaskTags(tags: task.tags, project: model.state.projects.first { $0.id == task.projectID }) }
                    Text(task.status == .working ? (model.state.isOffline == true ? TaskItem.offlineActivity : nil) ?? task.activity ?? task.status.label : task.status.label)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(model.state.isOffline == true ? 2 : 1)
                }
            }
        }
        .contextMenu { if model.link == .online { menu } }
        .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
            if let previewURL { SafariView(url: previewURL).ignoresSafeArea() }
        }
        .sheet(item: $log) { LogSheet(log: $0, taskID: task.id) }
        .alert("Rename Task", isPresented: $renaming) {
            TextField("Name", text: $text)
            Button("Rename") { Task { await model.rename(taskID: task.id, to: text) } }
            Button("Cancel", role: .cancel) {}
        }
        .alert("New Tag", isPresented: $addingTag) {
            TextField("Name", text: $text)
            Button("Add") { Task { await model.addTags(taskID: task.id, text) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Separate several tags with commas.")
        }
        .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete Task", role: .destructive) { Task { await model.delete(taskID: task.id) } }
        } message: {
            Text("Its changes are discarded without merging.")
        }
    }

    /// What its status offers, as in the task, then the Mac's context menu, without what only works there
    /// (Open In, Create Schedule from This).
    @ViewBuilder private var menu: some View {
        let project = model.state.projects.first { $0.id == task.projectID }
        if let project {
            ForEach(model.actions(for: task, in: project, openURL: openURL), id: \.title) { action in
                Button(action.title, systemImage: action.systemImage) { Task { await action.run() } }
            }
        }
        if model.canPreview(task) {
            Button("Preview", systemImage: "safari") { Task { previewURL = await model.startPreview(taskID: task.id) } }
        }
        if task.status == .working || task.approvalRequest != nil {
            Button("Stop", systemImage: "stop.fill") { Task { await model.stop(taskID: task.id) } }
        }
        if task.canResume {
            Button("Resume", systemImage: "play.fill") { Task { await model.resume(taskID: task.id) } }
        }
        Divider()
        if !task.status.isClosed, let project {
            if project.runsApp {
                Button("App Log", systemImage: "doc.text") { log = .app }
            }
            if project.isApp {
                let built = project.targets.filter { $0.kind != .run }
                let title = { (target: BuildTarget) in built.count > 1 ? "Build Log: \(target.name)" : "Build Log" }
                ForEach(built) { target in
                    Button(title(target), systemImage: "hammer") { log = .build(target.id, title: title(target)) }
                }
            }
            Button("Archive Task", systemImage: "archivebox") { Task { await model.archive(taskID: task.id) } }
        }
        if let project {
            Menu("Tags", systemImage: "tag") {
                ForEach(project.tagNames, id: \.self) { name in
                    Toggle(name, isOn: Binding {
                        task.tags?.contains { $0.caseInsensitiveCompare(name) == .orderedSame } == true
                    } set: { on in
                        Task { on ? await model.addTags(taskID: task.id, name) : await model.removeTag(taskID: task.id, name) }
                    })
                }
                Button("New Tag…", systemImage: "plus") { text = ""; addingTag = true }
            }
        }
        Button("Rename Task…", systemImage: "pencil") { text = task.title; renaming = true }
        Button("Delete Task…", systemImage: "trash", role: .destructive) { confirmingDelete = true }
    }
}

/// A task's App Log or a Build Log, from its context menu.
private enum TaskLog: Hashable, Identifiable {
    case app
    case build(UUID, title: String)
    var id: Self { self }
    var title: String {
        switch self {
        case .app: "App Log"
        case .build(_, let title): title
        }
    }
}

private struct LogSheet: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let log: TaskLog
    let taskID: Int
    @State private var text: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(text.map { $0.isEmpty ? "No output." : $0 } ?? "Loading…")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
            // The latest output, where errors are, is at the end.
            .defaultScrollAnchor(.bottom)
            .navigationTitle(log.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let text, !text.isEmpty { ShareLink(item: text) }
                Button("Done", systemImage: "checkmark") { dismiss() }
            }
        }
        .task {
            text = switch log {
            case .app: await model.serverLog(taskID: taskID) ?? ""
            case .build(let target, _): await model.buildLog(taskID: taskID, target: target) ?? ""
            }
        }
    }
}

struct TaskDetailView: View {
    @Environment(RemoteModel.self) private var model
    let taskID: Int
    @State private var stream: LogStream?
    @State private var previewURL: URL?
    @State private var startingPreview = false
    @State private var changes: DiffSummary?
    @State private var openPrompt: Prompt?
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var height: CGFloat = 0

    var body: some View {
        if let task = model.task(taskID) {
            let responses = TranscriptTurn.responses(to: task.prompts, in: stream?.turns ?? [])
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text(task.title).font(.title2.bold())
                    if let about = task.summary ?? task.description { MarkdownText(text: about) }
                    if task.tags?.isEmpty == false { TaskTags(tags: task.tags, project: model.state.projects.first { $0.id == task.projectID }, large: true) }
                    TaskStatusView(task: task)
                    if let shots = task.screenshots, !shots.isEmpty { ScreenshotsRow(shots: shots.reversed()) }
                    if let changes, !changes.files.isEmpty { ChangesRow(taskID: taskID, changes: changes) }
                    if let project = model.state.projects.first(where: { $0.id == task.projectID }) {
                        TaskActions(task: task, project: project)
                    }
                    PromptList(prompts: task.prompts) { openPrompt = $0 }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scroll)
            .onChange(of: task.prompts.count) { scroll.scrollTo(edge: .top) }
            .scrollDismissesKeyboard(.interactively)
            .safeAreaBar(edge: .bottom) {
                if ResponsePanel.shows(task) {
                    ResponsePanel(task: task, maxHeight: height * 0.5)
                        .id([task.question, task.blockedReason])
                } else if !task.status.isClosed {
                    PromptBar { await model.sendPrompt(taskID: taskID, text: $0, attachments: $1) }
                }
            }
            // Measured outside the bottom bar, as on the Mac.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                StatusIcon(status: task.status, pullRequestOpen: model.state.pullRequests[task.id]?.state == .open,
                           mergedByPullRequest: task.mergedPullRequest != nil).accessibilityLabel(task.status.label)
                if model.canPreview(task) {
                    if startingPreview {
                        ProgressView()
                    } else {
                        Button("Preview", systemImage: "safari") {
                            startingPreview = true
                            Task {
                                previewURL = await model.startPreview(taskID: taskID)
                                startingPreview = false
                            }
                        }
                    }
                }
                if task.status == .working || task.approvalRequest != nil {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stop(taskID: taskID) } }
                }
            }
            .sheet(isPresented: Binding(get: { previewURL != nil }, set: { if !$0 { previewURL = nil } })) {
                if let previewURL { SafariView(url: previewURL).ignoresSafeArea() }
            }
            .sheet(item: $openPrompt) { prompt in
                PromptResponseView(prompt: prompt, turns: responses[prompt.id] ?? [], task: task)
            }
            .task(id: taskID) {
                stream = model.openLog(.task(taskID), agent: task.agent)
            }
            // As on the Mac, and again once the Mac is back.
            .task(id: task.status == .completed && model.link == .online) {
                changes = task.status == .completed && model.link == .online ? await model.changes(taskID: taskID) : nil
            }
            .onDisappear { model.closeLog(.task(taskID)) }
        } else {
            EmptyState("Task Not Found", systemImage: "questionmark.folder", description: Text("It was deleted on your Mac."))
        }
    }
}

/// What the task is waiting for, and the way to answer it.
private struct TaskStatusView: View {
    @Environment(RemoteModel.self) private var model
    let task: TaskItem

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let request = task.approvalRequest {
                Label { Text(.init("Wants to \(request)")) } icon: { Image(systemName: "hand.raised.fill") }
                    .foregroundStyle(.blue)
                HStack {
                    Button("Allow") { Task { await model.answerApproval(taskID: task.id, allow: true) } }
                        .buttonStyle(.borderedProminent)
                    Button("Deny", role: .destructive) { Task { await model.answerApproval(taskID: task.id, allow: false) } }
                        .buttonStyle(.bordered)
                }
            } else if task.status == .working {
                Label { Text((model.state.isOffline == true ? TaskItem.offlineActivity : nil) ?? task.activity ?? "Working…") } icon: { ProgressView() }
                    .foregroundStyle(.secondary)
            } else if task.status == .conflict {
                Label("It doesn't merge cleanly into its base.", systemImage: "checkmark.circle.fill").foregroundStyle(.orange)
            } else if task.status == .archived {
                Text("Archived. Nothing was merged; any changes stay on its branch, \(task.branch).").foregroundStyle(.secondary)
            } else if task.status == .merged, let project = model.state.projects.first(where: { $0.id == task.projectID }) {
                Text("Merged into \(task.base(in: project))").foregroundStyle(.secondary)
            }
            if task.canResume {
                Button("Resume") { Task { await model.resume(taskID: task.id) } }.buttonStyle(.borderedProminent)
            }
        }
    }
}

/// The bottom bar of a task waiting on the user, in place of the prompt bar, as on the Mac:
/// what the agent asks or couldn't do, its suggested replies to pick one of, and "Something else" to write one.
private struct ResponsePanel: View {
    @Environment(RemoteModel.self) private var model
    let task: TaskItem
    /// The tallest the panel gets before its content scrolls.
    let maxHeight: CGFloat

    /// Index into the options; `options.count` is "Something else". Nothing is chosen at first.
    @State private var choice: Int?
    @State private var isSending = false
    @State private var contentHeight: CGFloat = 0

    /// Approvals keep their Allow and Deny in the status, above.
    static func shows(_ task: TaskItem) -> Bool {
        task.approvalRequest == nil && (task.status == .blocked || (task.status == .needsInput && task.question != nil))
    }

    private var options: [String] { task.options ?? [] }
    private var placeholder: String { task.status == .blocked ? "Give instructions…" : "Answer…" }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(task.status == .blocked ? "Couldn't continue" : "The agent needs a decision")
                        .font(.subheadline).foregroundStyle(.secondary)
                    MarkdownText(text: task.question ?? task.blockedReason ?? "")
                }
                if options.isEmpty {
                    answerField
                } else {
                    VStack(alignment: .leading, spacing: 0) {
                        ForEach(options.indices, id: \.self) { row($0, options[$0]) }
                        row(options.count, "Something else")
                    }
                    if choice == options.count {
                        answerField
                    } else {
                        Button(action: sendChoice) {
                            Text(isSending ? "Sending…" : "Send").frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.glassProminent)
                        .controlSize(.large)
                        .disabled(choice == nil || isSending || model.link != .online)
                    }
                }
            }
            .padding(16)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .frame(height: maxHeight > 0 ? min(contentHeight, maxHeight) : contentHeight)
        .glassEffect(.regular, in: .rect(cornerRadius: 24))
        // Blue or red like the task's status icon: the task is waiting on this.
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(task.status.color, lineWidth: 1.5))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    private func row(_ index: Int, _ title: String) -> some View {
        Button { choice = index } label: {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Image(systemName: choice == index ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(choice == index ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                Text(title).foregroundStyle(.primary).multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(.vertical, 8)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(choice == index ? .isSelected : [])
    }

    private var answerField: some View {
        PromptBar(placeholder: placeholder, focusesOnAppear: !options.isEmpty, inset: false) {
            await model.sendPrompt(taskID: task.id, text: $0, attachments: $1)
        }
    }

    private func sendChoice() {
        guard let choice, choice < options.count else { return }
        isSending = true
        Task {
            if await model.sendPrompt(taskID: task.id, text: options[choice]) { self.choice = nil }
            isSending = false
        }
    }
}

/// A `/command` the + menu offers: `/schedule`, `/task`.
struct PromptCommand {
    let name: String
    let title: String
    let systemImage: String

    static let schedule = PromptCommand(name: "schedule", title: "New Schedule", systemImage: "calendar.badge.clock")
    static let task = PromptCommand(name: "task", title: "New Task", systemImage: "plus.square")
}

private struct PromptBar: View {
    @Environment(RemoteModel.self) private var model
    var placeholder = "Ask for changes…"
    var focusesOnAppear = false
    /// False inside the response panel: no margins of its own.
    var inset = true
    /// Offered in the + menu, under Photos and Files: each starts the message with its `/command`.
    var commands: [PromptCommand] = []
    /// Beside Send. With one, the text has the full width and the buttons go on a row under it.
    var accessory: AnyView?
    /// False if it didn't go through: what was written stays.
    let onSend: (_ text: String, _ attachments: [String]) async -> Bool
    @State private var text = ""
    @State private var showsPhotos = false
    @State private var showsFiles = false
    @State private var picked: [PhotosPickerItem] = []
    @State private var images: [PromptImage] = []
    @State private var viewing: PromptImage?
    @State private var isSending = false
    @State private var isTall = false
    @State private var isExpanded = false

    private static let controlSize: CGFloat = 30

    private var canSend: Bool { (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !images.isEmpty) && !isSending && model.link == .online }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !images.isEmpty {
                ScrollViewReader { proxy in
                    ScrollView(.horizontal) {
                        HStack(spacing: 8) {
                            ForEach(images) { image in
                                Button { viewing = image } label: {
                                    Group {
                                        if let picture = image.image {
                                            Image(uiImage: picture).resizable().scaledToFill()
                                        } else {
                                            VStack(spacing: 2) {
                                                Image(systemName: "doc").font(.title3)
                                                Text(image.file?.name ?? "").font(.caption2).lineLimit(1).padding(.horizontal, 4)
                                            }
                                            .foregroundStyle(Color.secondary)
                                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                                            .background(.fill.tertiary)
                                        }
                                    }
                                    .frame(width: 56, height: 56)
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                }
                                .accessibilityLabel(image.file?.name ?? "Attached picture")
                            }
                        }
                        .padding(.horizontal, 4)
                    }
                    .scrollIndicators(.hidden)
                    .padding(.top, 3)
                    // New pictures go at the end; bring the latest one into view.
                    .onChange(of: images.count) { old, new in
                        if new > old, let last = images.last { withAnimation { proxy.scrollTo(last.id, anchor: .trailing) } }
                    }
                }
            }
            if let accessory {
                // The text has the full width here: leave the expand button room at its end.
                textView.padding(.trailing, isTall ? Self.controlSize : 0).padding(.horizontal, 6).padding(.top, 2)
                    .overlay(alignment: .topTrailing) { expandButton }
                HStack(spacing: 8) {
                    addMenu
                    Spacer()
                    accessory
                    sendButton
                }
            } else {
                // At the bottom, and all as tall as one line of text: centered on a single line, and level with the last of several.
                HStack(alignment: .bottom, spacing: 8) {
                    addMenu
                    textView
                    sendButton
                }
                // Over the send button's column.
                .overlay(alignment: .topTrailing) { expandButton }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // The same glass everywhere, so the answer field looks like the prompt bar.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, inset ? 16 : 0)
        .padding(.bottom, inset ? 8 : 0)
        .animation(.default, value: images)
        .photosPicker(isPresented: $showsPhotos, selection: $picked, matching: .images)
        .onChange(of: picked) {
            guard !picked.isEmpty else { return }
            let items = picked
            picked = []
            Task {
                for item in items {
                    if let data = try? await item.loadTransferable(type: Data.self), let image = UIImage(data: data) {
                        images.append(PromptImage(image: image))
                    }
                }
            }
        }
        .fileImporter(isPresented: $showsFiles, allowedContentTypes: [.item], allowsMultipleSelection: true) { result in
            for url in (try? result.get()) ?? [] {
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                guard let data = try? Data(contentsOf: url) else { continue }
                images.append(PromptImage(image: UIImage(data: data), file: (url.lastPathComponent, data)))
            }
        }
        .sheet(isPresented: $isExpanded) {
            VStack(alignment: .trailing, spacing: 12) {
                Button("Collapse", systemImage: "arrow.up.right.and.arrow.down.left") { isExpanded = false }
                    .labelStyle(.iconOnly)
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                PromptTextView(placeholder: placeholder, text: $text, focusesOnAppear: true, maxLines: nil) { pasted in
                    images += pasted.map { PromptImage(image: $0) }
                }
                .padding(.horizontal, 8)
                sendButton
            }
            .padding(16)
        }
        .sheet(item: $viewing) { image in
            PromptImageViewer(image: image.image, name: image.file?.name) { images.removeAll { $0.id == image.id } }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Photos", systemImage: "photo.on.rectangle") { present($showsPhotos) }
            Button("Files", systemImage: "folder") { present($showsFiles) }
            if !commands.isEmpty {
                Section {
                    ForEach(commands, id: \.name) { command in
                        Button(command.title, systemImage: command.systemImage) { start(command) }
                    }
                }
            }
        } label: {
            Image(systemName: "plus")
                .foregroundStyle(Color.secondary) // .secondary alone would be a shade of the tint.
                .frame(width: Self.controlSize, height: Self.controlSize)
                .accessibilityLabel("Add")
        }
    }

    private var textView: some View {
        PromptTextView(placeholder: placeholder, text: $text, focusesOnAppear: focusesOnAppear) { pasted in
            images += pasted.map { PromptImage(image: $0) }
        }
        .onGeometryChange(for: Bool.self) { $0.size.height > UIFont.preferredFont(forTextStyle: .body).lineHeight * 2.5 } action: { isTall = $0 }
        .padding(.vertical, 4)
    }

    /// Three lines or more: open the text in a sheet.
    @ViewBuilder private var expandButton: some View {
        if isTall {
            Button("Expand", systemImage: "arrow.down.left.and.arrow.up.right") { isExpanded = true }
                .labelStyle(.iconOnly)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Color.secondary)
                .frame(width: Self.controlSize, height: Self.controlSize)
        }
    }

    private var sendButton: some View {
        Button("Send", systemImage: isSending ? "ellipsis.circle.fill" : "arrow.up.circle.fill") {
            isExpanded = false
            send()
        }
        .labelStyle(.iconOnly)
        .font(.system(size: Self.controlSize - 2))
        .frame(width: Self.controlSize, height: Self.controlSize)
        .disabled(!canSend)
    }

    /// After the menu has gone: presenting while it's still closing is dropped, which took several taps.
    // ponytail: fixed delay, tied to the menu's close animation.
    private func present(_ shows: Binding<Bool>) {
        Task {
            try? await Task.sleep(for: .milliseconds(300))
            shows.wrappedValue = true
        }
    }

    /// `/name ` in front of what's written, in place of any command already there.
    private func start(_ command: PromptCommand) {
        var rest = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let other = commands.first(where: { Prompt.command($0.name, rest) != nil }) {
            rest = Prompt.command(other.name, rest) ?? rest
        }
        text = "/\(command.name) " + rest
    }

    private func send() {
        isSending = true
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task {
            defer { isSending = false }
            do {
                var paths: [String] = []
                for image in images {
                    if let file = image.file {
                        paths.append(try await model.upload(file.data, name: file.name))
                        continue
                    }
                    // JPEG whatever the library holds: agents can't read HEIC.
                    guard let jpeg = image.image?.jpegData(compressionQuality: 0.8) else { continue }
                    paths.append(try await model.upload(jpeg, name: "photo.jpg"))
                }
                if await onSend(text, paths) {
                    text = ""
                    images = []
                }
            } catch {
                model.lastError = "Couldn't send the attachments to your Mac: \(error.localizedDescription)"
            }
        }
    }
}

/// A picture, or a file from Files (sent as is, under its own name).
private struct PromptImage: Identifiable, Equatable {
    let id = UUID()
    var image: UIImage?
    var file: (name: String, data: Data)?

    static func == (a: Self, b: Self) -> Bool { a.id == b.id }
}

/// A picture, large: one about to be sent, which can be removed, or one already sent. Swipe down or Close to go back.
private struct PromptImageViewer: View {
    let image: UIImage?
    var name: String?
    var onRemove: (() -> Void)?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if let image {
                    Image(uiImage: image).resizable().scaledToFit()
                } else {
                    ContentUnavailableView(name ?? "File", systemImage: "doc")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                    }
                    if let onRemove {
                        ToolbarItem(placement: .destructiveAction) {
                            Button("Remove", systemImage: "trash", role: .destructive) {
                                onRemove()
                                dismiss()
                            }
                        }
                    }
                }
        }
    }
}

/// A text field that also takes pasted pictures, which SwiftUI's doesn't. Grows to `maxLines`, then scrolls;
/// with none, it fills the space it's given.
private struct PromptTextView: UIViewRepresentable {
    let placeholder: String
    @Binding var text: String
    let focusesOnAppear: Bool
    var maxLines: Int? = 6
    let onPasteImages: ([UIImage]) -> Void

    final class TextView: UITextView {
        var onPasteImages: ([UIImage]) -> Void = { _ in }
        let placeholderLabel = UILabel()

        override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
            if action == #selector(paste(_:)), UIPasteboard.general.hasImages { return true }
            return super.canPerformAction(action, withSender: sender)
        }

        /// Scrolls once the text is taller than the field: decided here, from the field's real size, as SwiftUI
        /// also measures it at other widths. Turning scrolling on leaves the offset at the top, so the line being
        /// typed would sit below the edge: bring the caret into view; turning it off goes back to the top.
        override func layoutSubviews() {
            super.layoutSubviews()
            guard bounds.width > 0, bounds.height > 0 else { return }
            let fitting = sizeThatFits(CGSize(width: bounds.width, height: .greatestFiniteMagnitude)).height
            let scrolls = fitting > bounds.height + 1
            guard isScrollEnabled != scrolls else { return }
            isScrollEnabled = scrolls
            // Set straight away: scrollRangeToVisible would slide the line in.
            var offset: CGFloat = 0
            if scrolls {
                let caret = caretRect(for: selectedTextRange?.end ?? endOfDocument)
                offset = min(max(caret.maxY - bounds.height, 0), fitting - bounds.height)
            }
            contentOffset = CGPoint(x: 0, y: offset)
        }

        // Following the caret as it types, a text view animates its scroll: the new line slides in. It should just be there.
        override func setContentOffset(_ contentOffset: CGPoint, animated: Bool) {
            super.setContentOffset(contentOffset, animated: false)
        }

        override func scrollRectToVisible(_ rect: CGRect, animated: Bool) {
            super.scrollRectToVisible(rect, animated: false)
        }

        override func paste(_ sender: Any?) {
            if UIPasteboard.general.hasImages, let images = UIPasteboard.general.images, !images.isEmpty {
                onPasteImages(images)
            } else {
                super.paste(sender)
            }
        }
    }

    final class Coordinator: NSObject, UITextViewDelegate {
        var parent: PromptTextView
        init(_ parent: PromptTextView) { self.parent = parent }

        func textViewDidChange(_ textView: UITextView) {
            parent.text = textView.text
            (textView as? TextView)?.placeholderLabel.isHidden = !textView.text.isEmpty
            if textView.isScrollEnabled { textView.scrollRangeToVisible(textView.selectedRange) }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIView(context: Context) -> TextView {
        let view = TextView()
        view.delegate = context.coordinator
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.isScrollEnabled = false
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        let label = view.placeholderLabel
        label.text = placeholder
        label.font = view.font
        label.adjustsFontForContentSizeCategory = true
        label.textColor = .placeholderText
        label.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: view.frameLayoutGuide.leadingAnchor),
            label.trailingAnchor.constraint(lessThanOrEqualTo: view.frameLayoutGuide.trailingAnchor),
            label.topAnchor.constraint(equalTo: view.frameLayoutGuide.topAnchor),
        ])
        if focusesOnAppear { DispatchQueue.main.async { view.becomeFirstResponder() } }
        return view
    }

    func updateUIView(_ view: TextView, context: Context) {
        context.coordinator.parent = self
        view.onPasteImages = onPasteImages
        if view.text != text { view.text = text }
        view.placeholderLabel.text = placeholder
        view.placeholderLabel.isHidden = !text.isEmpty
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: TextView, context: Context) -> CGSize? {
        let width = proposal.width ?? 200
        let measure = { (textView: UITextView) in textView.sizeThatFits(CGSize(width: width, height: .greatestFiniteMagnitude)).height }
        let fitting = measure(view)
        guard let maxLines else { return CGSize(width: width, height: proposal.height.flatMap { $0.isFinite ? $0 : nil } ?? fitting) }
        // As tall as `maxLines` lines really are: laid out, a line is taller than the font's lineHeight.
        Self.probe.font = view.font
        Self.probe.text = Array(repeating: "X", count: maxLines).joined(separator: "\n")
        let height = min(fitting, measure(Self.probe))
        return CGSize(width: width, height: ceil(height))
    }

    /// Measures how tall `maxLines` lines are, set up as the field is.
    private static let probe: UITextView = {
        let view = UITextView()
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        return view
    }()
}

struct TaskAction {
    let title: String
    let systemImage: String
    let run: () async -> Void
}

extension RemoteModel {
    /// What a task's status offers, its main action first: the detail's buttons and the list's context menu.
    func actions(for task: TaskItem, in project: Project, openURL: OpenURLAction) -> [TaskAction] {
        let id = task.id, model = self
        let pullRequest = state.pullRequests[id]
        let view = pullRequest.map { pullRequest in
            TaskAction(title: "View Pull Request #\(pullRequest.number)", systemImage: PullRequest.symbol()) { openURL(pullRequest.url) }
        }
        let viewing = view.map { [$0] } ?? []
        switch task.status {
        case .completed:
            let merge = TaskAction(title: "Merge into \(task.base(in: project))", systemImage: "arrow.triangle.merge") { await model.merge(taskID: id) }
            if pullRequest?.state == .open {
                let push = TaskAction(title: "Push Changes", systemImage: "arrow.up") { await model.push(taskID: id) }
                return [merge] + (pullRequest?.hasNewWork == true ? [push] : []) + viewing
            }
            // Its squashed commit is on the base by now, so a new one would repeat that work. On the Mac, which can re-sync first.
            if pullRequest?.state == .merged { return [merge] + viewing }
            let open = TaskAction(title: "Open Pull Request", systemImage: PullRequest.symbol()) {
                if let url = await model.pullRequestURL(taskID: id) { openURL(url) }
            }
            return [merge, open] + viewing
        case .conflict:
            return [TaskAction(title: "Resolve", systemImage: "wrench.and.screwdriver") { await model.resolveConflict(taskID: id) }] + viewing
        default:
            return []
        }
    }
}

/// The status's main action, the rest under the button beside it, as in the Mac's split button.
/// Merging and pull requests name the branch they go to, and that menu changes it.
private struct TaskActions: View {
    @Environment(RemoteModel.self) private var model
    @Environment(\.openURL) private var openURL
    let task: TaskItem
    let project: Project
    @State private var isBusy = false
    @State private var branches: [String] = []
    @State private var newBase: String?

    private var actions: [TaskAction] { model.actions(for: task, in: project, openURL: openURL) }

    var body: some View {
        if let main = actions.first {
            let base = task.base(in: project)
            HStack {
                Button { perform(main) } label: {
                    Text(main.title).lineLimit(1).frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Menu {
                    ForEach(actions.dropFirst(), id: \.title) { action in
                        Button(action.title, systemImage: action.systemImage) { perform(action) }
                    }
                    Divider()
                    // The current base is always offered, so the picker is valid before branches load.
                    Picker("Base Branch", selection: Binding(get: { base }, set: { if $0 != base { newBase = $0 } })) {
                        ForEach(branches.contains(base) ? branches : [base] + branches, id: \.self) { Text($0) }
                    }
                    .pickerStyle(.menu)
                } label: {
                    Label("More", systemImage: "ellipsis").labelStyle(.iconOnly).frame(maxHeight: .infinity)
                }
                .buttonStyle(.bordered)
            }
            .fixedSize(horizontal: false, vertical: true) // The menu as tall as the button.
            .controlSize(.large)
            .disabled(isBusy || model.link != .online)
            .task(id: model.link) {
                if model.link == .online { branches = await model.branches(projectID: project.id) }
            }
            .confirmationDialog("Change the base to \(newBase ?? "")?",
                                isPresented: Binding(get: { newBase != nil }, set: { if !$0 { newBase = nil } }),
                                titleVisibility: .visible) {
                Button("Change Base") {
                    if let newBase { Task { await model.changeBase(taskID: task.id, to: newBase) } }
                }
            } message: {
                Text("Its own commits move onto \(newBase ?? ""), without what \(base) has, and Merge puts them there. If they conflict, the agent resolves it.")
            }
        }
    }

    private func perform(_ action: TaskAction) {
        isBusy = true
        Task {
            await action.run()
            isBusy = false
        }
    }
}

private struct ChangesRow: View {
    let taskID: Int
    let changes: DiffSummary

    var body: some View {
        NavigationLink {
            ChangesView(taskID: taskID, changes: changes)
        } label: {
            HStack(spacing: 6) {
                Text("\(changes.files.count) \(changes.files.count == 1 ? "file" : "files") changed").foregroundStyle(.secondary)
                Text("+\(changes.additions)").foregroundStyle(.green)
                Text("-\(changes.deletions)").foregroundStyle(.red)
                Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
            }
            .font(.subheadline)
            .monospacedDigit()
        }
        .buttonStyle(.plain)
    }
}

/// Every changed file's diff on one page, each under a heading with its stats.
private struct ChangesView: View {
    @Environment(RemoteModel.self) private var model
    let taskID: Int
    let changes: DiffSummary
    @State private var diffs: [FileDiff]?

    var body: some View {
        Group {
            if let diffs, !diffs.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0, pinnedViews: .sectionHeaders) {
                        ForEach(diffs) { diff in
                            Section {
                                FileDiffBody(diff: diff).padding(.bottom, 16)
                            } header: {
                                FileChangeRow(change: diff.change)
                                    .padding(.horizontal)
                                    .padding(.vertical, 10)
                                    .background(.bar)
                            }
                        }
                    }
                }
            } else if diffs == nil {
                ProgressView()
            } else {
                EmptyState("No Diff", systemImage: "doc", description: Text("Couldn't load the changes."))
            }
        }
        .navigationTitle("\(changes.files.count) \(changes.files.count == 1 ? "File" : "Files") Changed")
        .navigationBarTitleDisplayMode(.inline)
        .task { diffs = await model.diff(taskID: taskID) ?? [] }
    }
}

private struct FileChangeRow: View {
    let change: FileChange

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text((change.path as NSString).lastPathComponent).fontWeight(.semibold).lineLimit(1)
                let folder = (change.path as NSString).deletingLastPathComponent
                if !folder.isEmpty {
                    Text(folder).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.head)
                }
            }
            Spacer(minLength: 8)
            if change.kind != .modified {
                Text(change.kind.rawValue.capitalized).font(.caption).foregroundStyle(.secondary)
            }
            if change.isBinary {
                Text("Binary").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("+\(change.additions)").foregroundStyle(.green)
                Text("-\(change.deletions)").foregroundStyle(.red)
            }
        }
        .font(.subheadline)
        .monospacedDigit()
    }
}

/// Most recent first, as on the Mac. A tap opens them full screen, to swipe through.
private struct ScreenshotsRow: View {
    let shots: [TaskScreenshot]
    @State private var open: TaskScreenshot?

    var body: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(shots) { shot in
                    Button { open = shot } label: {
                        ScreenshotImage(shot: shot, fill: true)
                            .frame(width: 120, height: 75, alignment: .top)
                            .clipShape(.rect(cornerRadius: 8))
                            .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Screenshot of \(shot.page)")
                }
            }
        }
        .scrollIndicators(.never)
        .fullScreenCover(item: $open) { ScreenshotViewer(shots: shots, selection: $0.id) }
    }
}

private struct ScreenshotViewer: View {
    let shots: [TaskScreenshot]
    @State var selection: UUID
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            TabView(selection: $selection) {
                ForEach(shots) { ScreenshotImage(shot: $0, fill: false).tag($0.id) }
            }
            .tabViewStyle(.page(indexDisplayMode: shots.count > 1 ? .automatic : .never))
            .navigationTitle(shots.first { $0.id == selection }?.page ?? "")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Done", systemImage: "xmark") { dismiss() } }
        }
    }
}

/// One file's hunks, scrolling sideways for long lines.
private struct FileDiffBody: View {
    let diff: FileDiff
    /// So short lines still color the full width.
    @State private var width: CGFloat = 0

    var body: some View {
        if diff.change.isBinary || diff.hunks.isEmpty {
            Text(diff.change.isBinary ? "Binary file, no diff to show." : "No changes to show.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .padding()
        } else {
            ScrollView(.horizontal) {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(diff.hunks.enumerated()), id: \.offset) { _, hunk in
                        Text(hunk.header)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(minWidth: width, maxWidth: .infinity, alignment: .leading)
                            .background(Color(.secondarySystemBackground))
                        ForEach(Array(hunk.lines.enumerated()), id: \.offset) { _, line in
                            Text((line.kind == .added ? "+ " : line.kind == .removed ? "− " : "  ") + line.text)
                                .padding(.horizontal, 8)
                                .frame(minWidth: width, maxWidth: .infinity, alignment: .leading)
                                .background(line.kind == .added ? Color.green.opacity(0.15)
                                            : line.kind == .removed ? Color.red.opacity(0.15) : Color.clear)
                        }
                    }
                }
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: true, vertical: false)
            }
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { width = $0 }
        }
    }
}

private struct ScreenshotImage: View {
    @Environment(RemoteModel.self) private var model
    let shot: TaskScreenshot
    let fill: Bool
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image {
                let picture = Image(uiImage: image).resizable()
                if fill { picture.scaledToFill() } else { picture.scaledToFit() }
            } else {
                Color(.secondarySystemBackground)
            }
        }
        .task(id: shot.id) { image = await model.image(shot) }
    }
}

/// Most recent on top, each opening what the agent did about it.
private struct PromptList: View {
    let prompts: [Prompt]
    let onOpen: (Prompt) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(prompts.reversed()) { prompt in
                Button { onOpen(prompt) } label: {
                    HStack(spacing: 8) {
                        VStack(alignment: .leading, spacing: 6) {
                            if !prompt.text.isEmpty {
                                Text(prompt.text).lineLimit(2).multilineTextAlignment(.leading)
                            }
                            if !prompt.attachments.isEmpty {
                                HStack(spacing: 6) { ForEach(prompt.attachments.prefix(4), id: \.self) { AttachmentThumbnail(path: $0, size: 40) } }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
                    }
                    .padding(12)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .opacity(prompt.isPending ? 0.6 : 1)
                if prompt.id != prompts.first?.id { Divider().padding(.leading, 12) }
            }
        }
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12))
    }
}

/// A prompt, and what the agent did about it. Fills in as the agent works.
private struct PromptResponseView: View {
    let prompt: Prompt
    let turns: [TranscriptTurn]
    let task: TaskItem
    @Environment(RemoteModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var scroll = ScrollPosition(edge: .top)
    @State private var atBottom = true

    private struct Extent: Equatable { var height: CGFloat; var below: CGFloat }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PromptBubble(prompt: prompt)
                    ForEach(turns) { TurnView(turn: $0) }
                    if turns.isEmpty {
                        if task.status == .working {
                            Label { Text((model.state.isOffline == true ? TaskItem.offlineActivity : nil) ?? task.activity ?? "Working…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                        } else {
                            Text("No response to show.").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollPosition($scroll)
            // Was at the very bottom and more arrived: stays there. Otherwise, whether it's at the bottom now.
            .onScrollGeometryChange(for: Extent.self) { geo in
                Extent(height: geo.contentSize.height, below: geo.contentSize.height + geo.contentInsets.bottom - geo.visibleRect.maxY)
            } action: { old, new in
                if old.below <= 4 && new.height > old.height {
                    scroll.scrollTo(edge: .bottom)
                } else {
                    atBottom = new.below <= 4
                }
            }
            .overlay(alignment: .bottom) {
                if !atBottom {
                    Button("Scroll to Bottom", systemImage: "arrow.down") { withAnimation { scroll.scrollTo(edge: .bottom) } }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.glass)
                        .buttonBorderShape(.circle)
                        .controlSize(.large)
                        .padding(.bottom, 8)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .animation(.default, value: atBottom)
            .navigationTitle("Response")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                Button("Close", systemImage: "xmark") { dismiss() }
            }
        }
    }
}

/// The prompts in order, each with what the agent did about it.
private struct Conversation: View {
    let prompts: [Prompt]
    let turns: [TranscriptTurn]

    var body: some View {
        let answered = Set(turns.flatMap(\.promptIDs))
        ForEach(turns) { turn in
            TurnView(turn: turn, prompts: prompts.filter { turn.promptIDs.contains($0.id) })
        }
        // Not reached the agent yet, or from a log that doesn't say.
        ForEach(prompts.filter { !answered.contains($0.id) }) { PromptBubble(prompt: $0).opacity($0.isPending ? 0.6 : 1) }
    }
}

private struct TurnView: View {
    let turn: TranscriptTurn
    var prompts: [Prompt] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let note = turn.note { Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary) }
            ForEach(prompts) { PromptBubble(prompt: $0) }
            if let text = turn.text { Text(text).font(.footnote).foregroundStyle(.secondary).lineLimit(3) }
            ForEach(turn.sections) { SectionView(section: $0) }
        }
    }
}

private struct PromptBubble: View {
    let prompt: Prompt

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !prompt.text.isEmpty { Text(prompt.text).textSelection(.enabled) }
            if !prompt.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) { ForEach(prompt.attachments, id: \.self) { AttachmentThumbnail(path: $0, size: 64, opens: true) } }
                }
                .scrollIndicators(.hidden)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12)) // What a group box has here.
    }
}

/// An attached picture, fetched from the Mac; with `opens`, tapping it shows it large. Anything it can't show as
/// one is its file name.
private struct AttachmentThumbnail: View {
    @Environment(RemoteModel.self) private var model
    let path: String
    let size: CGFloat
    var opens = false
    @State private var image: UIImage?
    @State private var loaded = false
    @State private var viewing = false

    var body: some View {
        Group {
            if let image {
                let thumbnail = Image(uiImage: image).resizable().scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(.rect(cornerRadius: 8))
                    .accessibilityLabel("Attached picture")
                if opens {
                    Button { viewing = true } label: { thumbnail }
                        .buttonStyle(.plain)
                        .sheet(isPresented: $viewing) { PromptImageViewer(image: image) }
                } else {
                    thumbnail
                }
            } else if loaded {
                Label((path as NSString).lastPathComponent, systemImage: "paperclip").font(.footnote).foregroundStyle(.secondary).lineLimit(1)
            } else {
                Color(.tertiarySystemFill).frame(width: size, height: size).clipShape(.rect(cornerRadius: 8))
            }
        }
        .task(id: path) {
            image = await model.image(attachment: path)
            loaded = true
        }
    }
}

private struct SectionView: View {
    let section: TranscriptSection

    var body: some View {
        switch section {
        case .message(_, let text): MarkdownText(text: text)
        case .steps(_, let steps):
            DisclosureGroup {
                ForEach(steps) { StepRow(step: $0) }
            } label: {
                Text(TranscriptStep.summary(steps)).font(.footnote).foregroundStyle(.secondary)
            }
        case .error(_, let text): Label(text, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
        case .approval(_, let summary):
            Label { Text(.init("Asked to \(summary)")) } icon: { Image(systemName: "hand.raised.fill") }.foregroundStyle(.blue)
        }
    }
}

private struct StepRow: View {
    let step: TranscriptStep

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(step.title).font(.footnote).foregroundStyle(step.failure == nil ? Color.secondary : .red)
            if !step.preview.isEmpty {
                Text(step.preview).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(12).textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SafariView: UIViewControllerRepresentable {
    let url: URL
    func makeUIViewController(context: Context) -> SFSafariViewController { SFSafariViewController(url: url) }
    func updateUIViewController(_ controller: SFSafariViewController, context: Context) {}
}

extension VerticalAlignment {
    /// The middle of a row's first line of text, for an icon beside a title and subtitle.
    enum FirstLineCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let firstLineCenter = VerticalAlignment(FirstLineCenter.self)
}

/// Scrolls the list just past the navigation bar's search field, as Mail does, so a small pull shows it.
/// SwiftUI's own scroll position doesn't move a list shorter than the screen; the scroll view underneath does.
/// iOS 26 folds the large title away with the search field.
private struct HideSearchOnAppear: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView { Probe() }
    func updateUIView(_ view: UIView, context: Context) {}

    private final class Probe: UIView {
        private var found = false
        private var observation: NSKeyValueObservation?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil, !found else { return }
            find(tries: 20)
        }

        /// Tries again until the search field is laid out in the navigation bar.
        private func find(tries: Int) {
            guard tries > 0, !found else { return }
            guard let bar = Self.searchBar(from: self), bar.frame.height > 0, let list = window.flatMap(Self.list) else {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.find(tries: tries - 1) }
                return
            }
            found = true
            list.alwaysBounceVertical = true
            // The insets grow once the search field joins the navigation bar, so from what they are a moment later.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                let hidden = -list.adjustedContentInset.top + bar.frame.height
                list.setContentOffset(CGPoint(x: 0, y: hidden), animated: false)
                // The tasks arriving from the Mac reload the list, which goes back to the top: hide it again,
                // until the list is touched or a few seconds have passed.
                self?.observation = list.observe(\.contentSize) { list, _ in
                    DispatchQueue.main.async {
                        guard !list.isTracking, list.contentOffset.y < hidden else { return }
                        list.setContentOffset(CGPoint(x: 0, y: hidden), animated: false)
                    }
                }
                list.panGestureRecognizer.addTarget(self as Any, action: #selector(Probe.stop))
                DispatchQueue.main.asyncAfter(deadline: .now() + 3) { self?.stop() }
            }
        }

        @objc private func stop() { observation = nil }

        private static func searchBar(from view: UIView) -> UISearchBar? {
            var responder: UIResponder? = view
            while let current = responder {
                if let bar = (current as? UIViewController)?.navigationItem.searchController?.searchBar { return bar }
                responder = current.next
            }
            return nil
        }

        /// The list: the one under the navigation bar, which insets it.
        private static func list(in view: UIView) -> UIScrollView? {
            if let list = view as? UICollectionView, list.adjustedContentInset.top > 0, !list.isHidden { return list }
            for sub in view.subviews { if let found = list(in: sub) { return found } }
            return nil
        }
    }
}
