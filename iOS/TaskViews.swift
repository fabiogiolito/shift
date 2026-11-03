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
                                            // The text's center sits above its x-height; this looks centered.
                                            .offset(y: 2)
                                    } else {
                                        Image(systemName: "folder").foregroundStyle(.tint)
                                    }
                                }
                                .frame(width: 28, height: 28)
                                .alignmentGuide(.firstLineCenter) { $0[VerticalAlignment.center] }
                                VStack(alignment: .leading) {
                                    Text(project.name)
                                        .alignmentGuide(.firstLineCenter) { $0[VerticalAlignment.center] }
                                    Text(Project.summary(of: tasks)).font(.subheadline).foregroundStyle(.secondary)
                                }
                                .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
                            }
                        }
                    }
                    .task(id: model.link) { await model.loadIcon(projectID: project.id) }
                }
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

    var body: some View {
        let tasks = model.tasks(in: projectID).sorted { $0.id > $1.id }
        let active = tasks.filter { $0.status != .merged }, merged = tasks.filter { $0.status == .merged }
        let project = model.state.projects.first { $0.id == projectID }
        List {
            if let project { Section { ChatRow(project: project) } }
            if !active.isEmpty {
                Section { ForEach(active) { TaskRow(task: $0) } }
            }
            if !merged.isEmpty {
                Section("Merged") {
                    ForEach(merged) { TaskRow(task: $0) }
                }
            }
        }
        // Room between the large title and the first group.
        .contentMargins(.top, 16, for: .scrollContent)
        .overlay {
            if tasks.isEmpty {
                EmptyState(title: "No Tasks", systemImage: "tray", description: Text("Start one here or in Shift on your Mac.")) {
                    Button("New Task") { isCreating = true }.buttonStyle(.borderedProminent)
                }
            }
        }
        .navigationTitle(project?.name ?? "Tasks")
        .toolbar {
            if let project, !project.isApp {
                Button(action: openSite) {
                    if isOpeningSite { ProgressView() } else { Label("Open \(project.baseBranch)", systemImage: "globe") }
                }
                .disabled(isOpeningSite)
            }
            Button("New Task", systemImage: "plus") { isCreating = true }
        }
        .sheet(isPresented: Binding(get: { site != nil }, set: { if !$0 { site = nil } })) {
            if let site { SafariView(url: site).ignoresSafeArea() }
        }
        .navigationDestination(isPresented: $isCreating) { NewTaskView(projectID: projectID) }
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

/// The project's one conversation with its agent. Not a task.
private struct ChatView: View {
    @Environment(RemoteModel.self) private var model
    let project: Project
    @State private var stream: LogStream?
    @State private var confirmingNew = false

    var body: some View {
        let chat = model.chat(projectID: project.id)
        let replying = model.state.replyingChats.contains(project.id)
        ScrollView {
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
                    Label { Text("Working…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                }
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .defaultScrollAnchor(.bottom)
        .scrollDismissesKeyboard(.interactively)
        .overlay {
            if chat == nil {
                EmptyState("Chat About \(project.name)", systemImage: "bubble.left.and.text.bubble.right",
                           description: Text("Ask about any task and plan with the agent. It can start tasks, follow them and merge them when you ask."))
            }
        }
        .safeAreaBar(edge: .bottom) {
            PromptBar(placeholder: "Ask or tell the agent anything…") {
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
}

/// The first prompt, and then the task it started, in place: going back from it leads to the list.
private struct NewTaskView: View {
    @Environment(RemoteModel.self) private var model
    let projectID: UUID
    @State private var taskID: Int?

    var body: some View {
        // The Mac's reply can come just ahead of the task itself.
        if let taskID, model.task(taskID) != nil {
            TaskDetailView(taskID: taskID)
        } else {
            Color.clear
                .safeAreaBar(edge: .bottom) {
                    PromptBar(placeholder: "What should it do?", focusesOnAppear: true) { text, attachments in
                        taskID = await model.createTask(projectID: projectID, prompt: text, attachments: attachments)
                        return taskID != nil
                    }
                }
                .navigationTitle("New Task")
                .navigationBarTitleDisplayMode(.inline)
        }
    }
}

private struct TaskRow: View {
    let task: TaskItem

    var body: some View {
        NavigationLink(value: task.id) {
            HStack(alignment: .firstLineCenter, spacing: 12) {
                StatusIcon(status: task.status, size: 18)
                    .alignmentGuide(.firstLineCenter) { $0[VerticalAlignment.center] }
                VStack(alignment: .leading, spacing: 2) {
                    // A title can wrap: center on its first line, a little above the baseline.
                    Text(task.title).lineLimit(2).lineHeight(.tight)
                        .alignmentGuide(.firstLineCenter) { $0[.firstTextBaseline] - 6 }
                    Text(task.status == .working ? task.activity ?? task.status.label : task.status.label)
                        .font(.footnote).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
    }
}

struct TaskDetailView: View {
    @Environment(RemoteModel.self) private var model
    let taskID: Int
    @State private var stream: LogStream?
    @State private var showsPreview = false
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
                } else if task.status != .merged {
                    PromptBar { await model.sendPrompt(taskID: taskID, text: $0, attachments: $1) }
                }
            }
            // Measured outside the bottom bar, as on the Mac.
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { height = $0 }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                StatusIcon(status: task.status).accessibilityLabel(task.status.label)
                if model.previewURL(task) != nil {
                    Button("Preview", systemImage: "safari") { showsPreview = true }
                }
                if task.status == .working || task.approvalRequest != nil {
                    Button("Stop", systemImage: "stop.fill") { Task { await model.stop(taskID: taskID) } }
                }
            }
            .sheet(isPresented: $showsPreview) {
                if let url = model.previewURL(task) { SafariView(url: url).ignoresSafeArea() }
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
                Label { Text(task.activity ?? "Working…") } icon: { ProgressView() }
                    .foregroundStyle(.secondary)
            } else if task.status == .conflict {
                Label("It doesn't merge cleanly into its base.", systemImage: "checkmark.circle.fill").foregroundStyle(.orange)
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

private struct PromptBar: View {
    @Environment(RemoteModel.self) private var model
    var placeholder = "Ask for changes…"
    var focusesOnAppear = false
    /// False inside the response panel: no margins of its own.
    var inset = true
    /// False if it didn't go through: what was written stays.
    let onSend: (_ text: String, _ attachments: [String]) async -> Bool
    @State private var text = ""
    @FocusState private var isFocused: Bool
    @State private var pictures: [PhotosPickerItem] = []
    @State private var isSending = false

    private static let controlSize: CGFloat = 30

    private var canSend: Bool { (!text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !pictures.isEmpty) && !isSending && model.link == .online }

    var body: some View {
        // At the bottom, and all as tall as one line of text: centered on a single line, and level with the last of several.
        HStack(alignment: .bottom, spacing: 8) {
            PhotosPicker(selection: $pictures, matching: .images) {
                Image(systemName: pictures.isEmpty ? "photo" : "photo.badge.checkmark")
                    .foregroundStyle(Color.secondary) // .secondary alone would be a shade of the tint.
                    .frame(width: Self.controlSize, height: Self.controlSize)
                    .accessibilityLabel("Attach pictures")
            }
            TextField(placeholder, text: $text, axis: .vertical)
                .lineLimit(1...6)
                .focused($isFocused)
                .padding(.vertical, 4)
            Button("Send", systemImage: isSending ? "ellipsis.circle.fill" : "arrow.up.circle.fill", action: send)
                .labelStyle(.iconOnly)
                .font(.system(size: Self.controlSize - 2))
                .frame(width: Self.controlSize, height: Self.controlSize)
                .disabled(!canSend)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        // The same glass everywhere, so the answer field looks like the prompt bar.
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 22))
        .padding(.horizontal, inset ? 16 : 0)
        .padding(.bottom, inset ? 8 : 0)
        .onAppear { if focusesOnAppear { isFocused = true } }
    }

    private func send() {
        isSending = true
        // Not `isFocused = false`: here it reads false with the field focused, and setting it does nothing.
        UIApplication.shared.sendAction(#selector(UIResponder.resignFirstResponder), to: nil, from: nil, for: nil)
        Task {
            defer { isSending = false }
            do {
                var paths: [String] = []
                for picture in pictures {
                    // JPEG whatever the library holds: agents can't read HEIC.
                    guard let data = try await picture.loadTransferable(type: Data.self),
                          let jpeg = UIImage(data: data)?.jpegData(compressionQuality: 0.8) else { continue }
                    paths.append(try await model.upload(jpeg, name: "photo.jpg"))
                }
                if await onSend(text, paths) {
                    text = ""
                    pictures = []
                }
            } catch {
                model.lastError = "Couldn't send the pictures to your Mac: \(error.localizedDescription)"
            }
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

    private struct Action {
        let title: String
        let run: () async -> Void
    }

    private var actions: [Action] {
        let id = task.id, model = model, openURL = openURL
        let pullRequest = model.state.pullRequests[id]
        let view = pullRequest.map { pullRequest in
            Action(title: "View Pull Request #\(pullRequest.number)") { openURL(pullRequest.url) }
        }
        let viewing = view.map { [$0] } ?? []
        switch task.status {
        case .completed:
            let merge = Action(title: "Merge into \(task.base(in: project))") { await model.merge(taskID: id) }
            if pullRequest?.state == .open {
                let push = Action(title: "Push to Pull Request") { await model.push(taskID: id) }
                return (pullRequest?.hasNewWork == true ? [push] : []) + viewing + [merge]
            }
            // Its squashed commit is on the base by now, so a new one would repeat that work. On the Mac, which can re-sync first.
            if pullRequest?.state == .merged { return [merge] + viewing }
            let open = Action(title: "Open Pull Request") {
                if let url = await model.pullRequestURL(taskID: id) { openURL(url) }
            }
            return (project.opensPullRequests || pullRequest != nil ? [open, merge] : [merge, open]) + viewing
        case .conflict:
            return [Action(title: "Resolve") { await model.resolveConflict(taskID: id) }] + viewing
        default:
            return []
        }
    }

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
                        Button(action.title) { perform(action) }
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

    private func perform(_ action: Action) {
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
                        Text(prompt.text.isEmpty ? prompt.attachments.first.map { ($0 as NSString).lastPathComponent } ?? "" : prompt.text)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
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
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    PromptBubble(prompt: prompt)
                    ForEach(turns) { TurnView(turn: $0) }
                    if turns.isEmpty {
                        if task.status == .working {
                            Label { Text(task.activity ?? "Working…") } icon: { ProgressView() }.foregroundStyle(.secondary)
                        } else {
                            Text("No response to show.").foregroundStyle(.secondary)
                        }
                    }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
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
            ForEach(prompt.attachments, id: \.self) { path in
                Label((path as NSString).lastPathComponent, systemImage: "paperclip").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground), in: .rect(cornerRadius: 12)) // What a group box has here.
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

private extension VerticalAlignment {
    /// The middle of a row's first line of text, for an icon beside a title and subtitle.
    enum FirstLineCenter: AlignmentID {
        static func defaultValue(in d: ViewDimensions) -> CGFloat { d[VerticalAlignment.center] }
    }
    static let firstLineCenter = VerticalAlignment(FirstLineCenter.self)
}
