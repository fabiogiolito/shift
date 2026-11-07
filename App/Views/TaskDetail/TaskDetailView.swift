import QuickLook
import SwiftUI
import ShiftCore

struct TaskDetailView: View {
    @Environment(\.textScale) private var textScale
    @Environment(AppModel.self) private var model
    let taskID: TaskItem.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var showingDiff = false
    /// True once the diff has finished sliding in.
    @State private var diffSettled = false
    /// The file the diff opens at, when opened from a row of the changed files.
    @State private var diffPath: String?
    /// Rename, delete and log sheets, shared with the task list's context menu.
    @State private var menu = TaskActions()
    /// The base picked in the merge dropdown, waiting for confirmation.
    @State private var newBase: String?
    @State private var branches: [String] = []
    @State private var creatingBranch = false
    /// What the project's folder has checked out, for a merged task: its base may not be it.
    @State private var checkedOut: String?
    @State private var isMerging = false
    /// For a conflicting task: the files that conflict with its base.
    @State private var conflicts: [String] = []
    /// Files a re-sync with the base conflicted in, while the user picks what to do.
    @State private var syncConflicts: [String] = []
    @State private var changes: Result<DiffSummary, Error>?
    /// The target the build button offers, with several to choose from. nil until first checked.
    @State private var suggestedTargetID: BuildTarget.ID?
    /// nil until first checked.
    @State private var server: ServerState?
    /// Whether the server button opens the tailnet link instead of localhost, when Tailscale is on.
    @AppStorage("opensTailnet") private var opensTailnet = false
    /// For capping the response panel's height.
    @State private var windowHeight: CGFloat = 0
    /// Height of the changed files' rows, for capping the list.
    @State private var changesHeight: CGFloat = 0
    @State private var reader: TranscriptReader?
    @State private var turns: [TranscriptTurn] = []
    /// The prompts showing what the agent did about them.
    @State private var openPrompts: Set<Prompt.ID> = []
    /// The screenshot open in Quick Look.
    @State private var screenshotPreview: URL?
    @State private var screenshotsExpanded = false
    /// The window's selection, so the link to the schedule that started this task can open it.
    @AppStorage("selectedTask") private var selectedRow: TaskItem.ID?
    /// Clicking the toolbar title scrolls this back to the top.
    @State private var scrollPosition = ScrollPosition(edge: .top)

    private let apps = ExternalApps()

    /// The detail's keyline: content and the toolbar title start this far from the column's leading edge.
    static let margin: CGFloat = 20
    /// Where the system places the first toolbar item of the detail column, measured from its leading edge.
    static let toolbarInset: CGFloat = 8
    private static let chevronWidth: CGFloat = 10
    /// Where a prompt's text starts, with or without a chevron.
    private static let promptIndent: CGFloat = 17

    var body: some View {
        if let task = model.task(taskID), let project = model.project(for: task) {
            Group {
                if showingDiff {
                    DiffView(taskID: taskID, isSettled: diffSettled, selecting: diffPath).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            header(task, project)
                            if task.status == .working {
                                HStack(spacing: 8) {
                                    ProgressView().controlSize(.small)
                                    Text(model.isOffline ? TaskItem.offlineActivity
                                         : task.activity ?? (task.isResolvingConflict ? "Resolving conflict…" : "Working…"))
                                }
                                .foregroundStyle(.secondary)
                            }
                            screenshotsRow(task)
                            if task.status == .completed { changesSection }
                            if !task.prompts.isEmpty { promptList(task) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Self.margin)
                    }
                    .scrollPosition($scrollPosition)
                    .safeAreaBar(edge: .bottom) {
                        if ResponsePanel.shows(task) {
                            ResponsePanel(task: task, maxHeight: windowHeight * 0.5)
                                .id([task.question, task.approvalRequest, task.blockedReason])
                        } else if let placeholder = promptPlaceholder(task) {
                            PromptField(placeholder: placeholder, focusOnAppear: true, draftKey: "task \(taskID)", commands: [.tag]) { model.sendPrompt(taskID: taskID, text: $0, attachments: $1) }
                                .padding(12)
                        }
                    }
                    .scrollEdgeEffectStyle(.hard, for: .top)
                    .scrollEdgeEffectStyle(.soft, for: .bottom)
                    // Measured outside the bottom bar: measuring the scroll view alone shrinks as the panel grows.
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { windowHeight = $0 }
                    .transition(reduceMotion ? .opacity : .move(edge: .leading))
                }
            }
            .toolbar { toolbar(task, project) }
            .background { shortcuts(task, project) }
            // The latest prompt the agent has opens in place of the one before it; any others opened by hand stay.
            // A queued prompt waits for delivery, so the work in progress stays visible until then.
            .onChange(of: task.prompts.last { !$0.isPending }?.id, initial: true) { old, new in
                withAnimation(reduceMotion || old == new ? nil : .snappy(duration: 0.2)) {
                    if let old, old != new { openPrompts.remove(old) }
                    if let new { openPrompts.insert(new) }
                }
            }
            // The whole log the first time, then only what's added while the agent works.
            .task(id: task.status == .working) {
                if reader == nil { reader = model.transcript(taskID: taskID) }
                repeat {
                    if let new = await reader?.update() { turns = new.filter { !$0.blocks.isEmpty || !$0.promptIDs.isEmpty || $0.text != nil } }
                    guard task.status == .working else { break }
                    try? await Task.sleep(for: .seconds(1.5))
                } while !Task.isCancelled
            }
            .task(id: task.status) {
                changes = task.status == .completed ? await model.loadChanges(taskID: taskID) : nil
                menu.unchanged = (try? changes?.get())?.files.isEmpty == true
            }
            .task(id: task.status) { conflicts = await model.conflictedFiles(taskID: taskID) }
            .taskActions(task, $menu, tagsHere: false)
            .confirmationDialog("Change the base of “\(task.title)” to \(newBase ?? "")?",
                                isPresented: Binding(get: { newBase != nil }, set: { if !$0 { newBase = nil } })) {
                Button("Change Base") {
                    if let base = newBase { Task { await model.changeBase(taskID: taskID, to: base) } }
                }
            } message: {
                Text("Its own commits move onto \(newBase ?? ""), without what \(task.base(in: project)) has, and Merge puts them there. If they conflict, the agent resolves it.")
            }
            .confirmationDialog("Re-syncing with \(task.base(in: project)) conflicts",
                                isPresented: Binding(get: { !syncConflicts.isEmpty }, set: { if !$0 { syncConflicts = [] } })) {
                Button("Fix with Agent") { model.fixSyncConflict(taskID: taskID) }
                Button("View Diff") { diffPath = syncConflicts.first; showDiff(true) }
                Button("Undo", role: .cancel) {}
            } message: {
                Text("Conflicting files:\n\(syncConflicts.joined(separator: "\n"))\n\nNothing was changed. The agent can merge and resolve it, or undo leaves the task as it was.")
            }
            .onAppearAndActivate(id: project.id) { branches = await model.branches(for: project.id) }
            .sheet(isPresented: $creatingBranch) {
                NewBranchSheet(projectID: project.id, branches: branches, source: task.base(in: project)) { name in
                    newBase = name
                    Task { branches = await model.branches(for: project.id) }
                }
            }
            .task(id: task.status) {
                checkedOut = task.status == .merged ? await model.checkedOutBranch(projectID: project.id) : nil
            }
        }
    }

    // MARK: Sections

    /// The detail column's part of the window toolbar. Anything deeper than the task (the diff) gets a back button.
    @ToolbarContentBuilder private func toolbar(_ task: TaskItem, _ project: Project) -> some ToolbarContent {
        if showingDiff {
            ToolbarItem {
                Button { showDiff(false) } label: { Label("Back", systemImage: "chevron.left") }
                    .help("Back to task")
            }
        }
        ToolbarItem {
            Text(task.title).font(.title3).lineLimit(1).padding(.leading, Self.margin - Self.toolbarInset)
                .onTapGesture { withAnimation(reduceMotion ? nil : .smooth) { scrollPosition.scrollTo(edge: .top) } }
        }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem {
            BranchButton(branch: task.branch, base: task.base(in: project),
                         help: "This task's branch, which merges into \(task.base(in: project)). Click to copy it.")
        }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { moreMenu(task, project) }
    }

    /// The same structure for every status, directly on the window background: the task's own text,
    /// a status line, then the action row. What the task needs from the user is in the bottom bar.
    private func header(_ task: TaskItem, _ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 8) {
                if let headline = headline(task) {
                    Text(headline).font(.title3).textSelection(.enabled)
                }
                if task.tags?.isEmpty == false {
                    TaskTags(tags: task.tags, project: project, onRemove: { model.removeTag(taskID: task.id, $0) },
                             onDelete: { model.deleteTag(projectID: project.id, $0) },
                             isShared: { model.tagIsShared(taskID: task.id, $0) },
                             onColor: { model.setTagColor(projectID: project.id, $0, $1) })
                }
            }
            .padding(.bottom, 8)
            actions(task, project)
            statusLine(task, project)
            if let schedule = task.scheduleID.flatMap(model.schedule) {
                Button { selectedRow = schedule.selectionID } label: {
                    Label("Started by the schedule “\(schedule.title)” \(Schedule.shortDate(task.createdAt).lowercasedFirst)",
                          systemImage: schedule.symbol)
                }
                .buttonStyle(.link)
                .help("Open the schedule")
            }
        }
    }

    @ViewBuilder private func statusLine(_ task: TaskItem, _ project: Project) -> some View {
        switch task.status {
        case .conflict:
            VStack(alignment: .leading, spacing: 4) {
                Text("Its changes conflict with changes made to \(task.base(in: project)) since it started\(conflicts.isEmpty ? "." : ", in:")")
                ForEach(conflicts, id: \.self) { Text($0).monospaced().textSelection(.enabled) }
                if let line = pullRequestLine { Text(line) }
            }
            .foregroundStyle(.secondary)
        case .merged:
            let base = task.base(in: project)
            // Merged into a branch the folder does not show: say so, or the work looks gone.
            Text(checkedOut == nil || checkedOut == base ? "Merged into \(base)"
                 : "Merged into \(base). The project folder has \(checkedOut ?? "") checked out, so it doesn't show there.")
                .foregroundStyle(.secondary)
        case .archived:
            Text("Archived. Nothing was merged; any changes stay on its branch, \(task.branch).").foregroundStyle(.secondary)
        default:
            if let line = pullRequestLine { Text(line).foregroundStyle(.secondary) }
        }
    }

    private var pullRequestLine: String? {
        guard let pullRequest = model.pullRequests[taskID] else { return nil }
        let name = "Pull request #\(pullRequest.number)"
        return switch pullRequest.state {
        case .open: pullRequest.hasNewWork ? "\(name) is open. The latest changes here aren't in it yet." : "\(name) is open."
        case .merged: "\(name) was merged without the latest changes here. They are still in this task."
        case .closed: "\(name) was closed without merging. This task's changes are still here."
        }
    }

    /// The status's main action first, then the server button (the Build button for an app). Hidden when there is neither.
    /// Every task with a port has a preview server, whether or not the project has a server command.
    @ViewBuilder private func actions(_ task: TaskItem, _ project: Project) -> some View {
        let hasPrimary = task.status == .completed || task.status == .conflict || task.status == .working || task.approvalRequest != nil
        let canBuild = project.isApp && !task.status.isClosed
        if task.serverURL != nil || hasPrimary || canBuild {
            HStack {
                primaryAction(task, project)
                if canBuild {
                    buildControls(task, project)
                } else if project.serversOff, task.serverURL != nil {
                    Text("Servers are off").foregroundStyle(.secondary)
                    Button("Turn On") {
                        // The project itself, not the task's view of it (a gh-pages task sees a static website).
                        guard var updated = model.project(project.id) else { return }
                        updated.serversOff = false
                        model.updateProject(updated)
                    }
                    .buttonStyle(.glass).controlSize(.small)
                } else if let server = task.serverURL, let port = task.port {
                    let tailnet = model.tailnetHost.flatMap { URL(string: "https://\($0):\(port)") }
                    Group { serverButton(local: server, tailnet: tailnet, port: port) }
                    .task(id: task.port) {
                        while !Task.isCancelled {
                            let alive = await model.isServerRunning(taskID: taskID)
                            let answers = alive ? await model.isServerAnswering(taskID: taskID) : false
                            // Once up, a server that stops answering has crashed inside a process that stayed alive.
                            let wasUp = self.server == .up || self.server == .notResponding
                            self.server = !alive ? .stopped : answers ? .up : wasUp ? .notResponding : .starting
                            // Quick while starting, so the link turns green as soon as the port answers.
                            try? await Task.sleep(for: .seconds(self.server == .starting ? 1 : 3))
                        }
                    }
                    // The port may still come up, so the button stays.
                    // Stopped is the usual state now (started on demand): the button itself starts it.
                    if let state = self.server, state != .up, state != .stopped {
                        Text(state.label).foregroundStyle(state == .notResponding ? state.color : .secondary)
                        if state != .starting {
                            Button("Log") { openWindow(id: "server-log", value: taskID) }.buttonStyle(.glass).controlSize(.small)
                            Button("Restart") {
                                self.server = .starting
                                Task { await model.restartServer(taskID: taskID) }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                }
                Spacer()
            }
            .controlSize(.large)
            .buttonBorderShape(.roundedRectangle)
        }
    }

    /// Opens the server in the browser. The dropdown restarts it, shows its log and, with Tailscale on, chooses between
    /// localhost and the tailnet: the choice opens and stays as the main button, for every task.
    private func serverButton(local: URL, tailnet: URL?, port: Int) -> some View {
        let opened = opensTailnet ? tailnet ?? local : local
        let help = self.server == .up || self.server == nil
            ? (opened == tailnet ? "Open \(opened.absoluteString), reachable from any device on your tailnet" : "Open in browser")
            : self.server?.label ?? ""
        let label = HStack(spacing: 6) {
            Image(systemName: "circle.fill").imageScale(.small)
                .foregroundStyle(self.server?.color ?? .secondary)
            Text(opened == tailnet ? "Tailscale" : "localhost:\(String(port))")
            Image(systemName: "arrow.up.right").imageScale(.small)
        }
        return SplitButton { open(opened) } label: { label } menu: {
            if let tailnet {
                // A toggle for its checkmark. It fires on the chosen one too, which opens it again.
                Toggle("Localhost", isOn: Binding(get: { !opensTailnet }, set: { _ in
                    opensTailnet = false
                    apps.openInBrowser(local)
                }))
                Toggle("Tailscale", isOn: Binding(get: { opensTailnet }, set: { _ in
                    opensTailnet = true
                    apps.openInBrowser(tailnet)
                }))
                Divider()
            }
            Button("Restart Server") {
                self.server = .starting
                Task { await model.restartServer(taskID: taskID) }
            }
            Button("Server Log") { openWindow(id: "server-log", value: taskID) }
        }
        .help(help)
    }

    /// What the server button opens: localhost, or the tailnet when that's the chosen one.
    private func previewURL(_ task: TaskItem, _ project: Project) -> URL? {
        guard !project.isApp, !project.serversOff, let local = task.serverURL, let port = task.port else { return nil }
        return opensTailnet ? model.tailnetHost.flatMap { URL(string: "https://\($0):\(port)") } ?? local : local
    }

    /// ⌘R: what the toolbar's main server or build button does, except that a running app restarts instead of stopping.
    private func previewAction(_ task: TaskItem, _ project: Project) -> TitledAction? {
        if project.isApp && !task.status.isClosed {
            guard let target = project.targets.first(where: { $0.id == suggestedTargetID }) ?? project.targets.first else { return nil }
            guard target.kind == .run else { return TitledAction(title: actionTitle(target)) { perform(target) } }
            return TitledAction(title: "Run \(target.name)") {
                Task {
                    if isRunning(target) { await model.stopApp(taskID: taskID); server = nil }
                    await toggleRun(target)
                }
            }
        }
        return previewURL(task, project).map { url in TitledAction(title: "Open in Browser") { open(url) } }
    }

    /// ⌘.: stops the app ⌘R ran.
    private func stopAction() -> (() -> Void)? {
        guard server == .up, model.runningTargets[taskID] != nil else { return nil }
        return { Task { await model.stopApp(taskID: taskID); server = nil } }
    }

    /// The task's menu items: ⌘R, ⌘., ⇧⌘C, ⇧⌘T, ⇧⌘E and ⇧⌘O. Apart, as the body is too long a chain to type-check with them.
    private func shortcuts(_ task: TaskItem, _ project: Project) -> some View {
        Color.clear
            .focusedSceneValue(\.openPreview, previewAction(task, project))
            .focusedSceneValue(\.copyPreviewLink, copyLinkAction(task, project))
            .focusedSceneValue(\.openInTerminal, terminalAction(task, project))
            .focusedSceneValue(\.openInEditor, editorAction(task, project))
            .focusedSceneValue(\.openInFinder, finderAction(task, project))
            .focusedSceneValue(\.stopApp, stopAction())
    }

    private func copyLinkAction(_ task: TaskItem, _ project: Project) -> (() -> Void)? {
        guard let url = previewURL(task, project) else { return nil }
        return { copyToPasteboard(url.absoluteString) }
    }

    /// ⇧⌘E and ⇧⌘O, into the same folder as ⇧⌘T.
    private func editorAction(_ task: TaskItem, _ project: Project) -> TitledAction? {
        guard let editor = OpenInMenu.editor() else { return nil }
        let folder = task.status.isClosed ? project.repoURL : task.worktreeURL
        return TitledAction(title: "Open in \(apps.name(of: editor))") { apps.open(folder, withApp: editor) }
    }

    private func finderAction(_ task: TaskItem, _ project: Project) -> () -> Void {
        let folder = task.status.isClosed ? project.repoURL : task.worktreeURL
        return { apps.open(folder, in: .finder) }
    }

    /// ⇧⌘T. A merged task's folder is gone: its work is in the project's.
    private func terminalAction(_ task: TaskItem, _ project: Project) -> (() -> Void)? {
        guard let terminal = OpenInMenu.terminal() else { return nil }
        let folder = task.status.isClosed ? project.repoURL : task.worktreeURL
        return { apps.open(folder, withApp: terminal) }
    }

    /// Opens the server in the browser, starting it first if it was stopped (idle for its project's TTL, or crashed).
    private func open(_ url: URL) {
        guard server == .stopped else { return apps.openInBrowser(url) }
        server = .starting
        Task {
            await model.restartServer(taskID: taskID)
            // Up to 30 seconds for it to answer; given up on if it exits.
            for _ in 0..<30 {
                if await model.isServerAnswering(taskID: taskID) { return apps.openInBrowser(url) }
                guard await model.isServerRunning(taskID: taskID) else { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    /// What builds or runs the app. One target gets a plain button; several get a split button that offers the one
    /// the task's changes point to, and lists them all. Next to it: how each target's latest build went.
    @ViewBuilder private func buildControls(_ task: TaskItem, _ project: Project) -> some View {
        let targets = project.targets
        let main = targets.first { $0.id == suggestedTargetID } ?? targets.first
        let runs = targets.contains { $0.kind == .run }
        Group {
            if let main {
                if targets.count > 1 {
                    targetsButton(main, targets)
                } else if main.kind == .run {
                    runButton(main)
                } else {
                    buildButton(main)
                }
            }
        }
        .task(id: [AnyHashable(taskID), AnyHashable(task.status), AnyHashable(task.lastBuiltTargetID), AnyHashable(targets)]) {
            suggestedTargetID = await model.suggestedTarget(taskID: taskID)?.id
        }
        .task(id: [AnyHashable(taskID), AnyHashable(runs)]) {
            guard runs else { return }
            server = await model.isServerRunning(taskID: taskID) ? .up : nil
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let alive = await model.isServerRunning(taskID: taskID)
                if alive != (server == .up), server != nil || alive { server = alive ? .up : .stopped }
            }
        }
        // Says so when the app ends without being stopped: it may have crashed on launch.
        if runs && server == .stopped {
            Text("Stopped").foregroundStyle(.secondary)
            Button("Log") { menu.output = .appLog }.buttonStyle(.glass).controlSize(.small)
        }
        ForEach(targets) { target in
            buildStatus(target, isMain: target.id == main?.id, isOnly: targets.count == 1)
        }
    }

    /// A target's build in progress, unless its own button already says so, or why it failed.
    @ViewBuilder private func buildStatus(_ target: BuildTarget, isMain: Bool, isOnly: Bool) -> some View {
        let state = model.buildState(taskID: taskID, target: target.id)
        if state == .building, !isMain {
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Building \(target.name)…").foregroundStyle(.secondary)
            }
        }
        if case .failed(let reason) = state {
            Text(isOnly ? reason : "\(target.name): \(reason)").foregroundStyle(.secondary).lineLimit(1)
            if target.kind != .run {
                Button("Log") { menu.output = .buildLog(target, in: project) }.buttonStyle(.glass).controlSize(.small)
            }
        }
    }

    private var project: Project? { model.task(taskID).flatMap(model.project(for:)) }

    private func isRunning(_ target: BuildTarget) -> Bool {
        server == .up && model.runningTargets[taskID] == target.id
    }

    /// Builds the task's worktree and opens the app it built, replacing the one opened by the last build. An iOS
    /// build is already on its simulator by the time this returns. A script's result is its log.
    private func build(_ target: BuildTarget, showingLog: Bool = true) async {
        if let app = await model.build(taskID: taskID, target: target.id) {
            await apps.relaunch(app, environment: ["SHIFT_HOME": ShiftPaths.build(taskID: taskID).path])
        }
        if target.kind == .script && showingLog { menu.output = .buildLog(target, in: project) }
    }

    /// Opens the task's copy of the app, or stops it.
    private func toggleRun(_ target: BuildTarget) async {
        if isRunning(target) {
            await model.stopApp(taskID: taskID)
            server = nil
        } else {
            await model.runApp(taskID: taskID, target: target.id)
            if await model.isServerRunning(taskID: taskID) { server = .up }
        }
    }

    private func perform(_ target: BuildTarget) {
        Task {
            if target.kind == .run { await toggleRun(target) } else { await build(target) }
        }
    }

    private func actionTitle(_ target: BuildTarget) -> String {
        target.kind != .run ? "Build \(target.name)" : isRunning(target) ? "Stop \(target.name)" : "Run \(target.name)"
    }

    /// Several targets: the main action is the one the task's changes point to.
    private func targetsButton(_ main: BuildTarget, _ targets: [BuildTarget]) -> some View {
        let building = model.buildState(taskID: taskID, target: main.id) == .building
        let buildable = targets.filter { $0.kind != .run }
        return SplitButton {
            perform(main)
        } label: {
            if building {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text("Building \(main.name)…")
                }
            } else {
                Label(actionTitle(main), systemImage: main.kind != .run ? "hammer" : isRunning(main) ? "stop.fill" : "play.fill")
            }
        } menu: {
            ForEach(targets) { target in
                Button(actionTitle(target)) { perform(target) }
                    .disabled(model.buildState(taskID: taskID, target: target.id) == .building)
            }
            Divider()
            // One after the other: a repo's build script may regenerate the project the next build is reading.
            Button("Build All") {
                Task {
                    for target in buildable { await build(target, showingLog: false) }
                }
            }
            .disabled(buildable.allSatisfy { model.buildState(taskID: taskID, target: $0.id) == .building })
        }
        .help(main.kind == .run ? "Open or close this task's version of \(main.name)" : "Build this task's version of \(main.name)")
    }

    @ViewBuilder private func runButton(_ target: BuildTarget) -> some View {
        let running = isRunning(target)
        Button {
            perform(target)
        } label: {
            Label(running ? "Stop" : "Run", systemImage: running ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.glass)
        .help(running ? "Close this task's version of the app" : "Open this task's version of the app")
    }

    @ViewBuilder private func buildButton(_ target: BuildTarget) -> some View {
        let state = model.buildState(taskID: taskID, target: target.id)
        Button {
            perform(target)
        } label: {
            Group {
                if state == .building {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.mini)
                        Text("Building…")
                    }
                } else {
                    Label("Build", systemImage: "hammer")
                }
            }
        }
        .buttonStyle(.glass)
        .disabled(state == .building)
        .help("Build this task's version of the app and open it")
    }

    @ViewBuilder private func primaryAction(_ task: TaskItem, _ project: Project) -> some View {
        let pullRequest = model.pullRequests[taskID]
        if task.status == .completed, menu.unchanged {
            // Nothing to merge: closing it is all that's left.
            Button("Archive", action: archive)
                .buttonStyle(.glass)
                .disabled(isMerging)
                .help("Close this task without merging. It has no changes; its conversation stays in Recently Closed.")
        } else if task.status == .completed {
            let mergeTitle = "Merge into \(task.base(in: project))"
            if let pullRequest, pullRequest.state == .open {
                let view = { apps.openInBrowser(pullRequest.url) }
                SplitButton(prominent: true, action: pullRequest.hasNewWork ? pushToPullRequest : view) {
                    Text(pullRequest.hasNewWork ? "Push Changes" : "View Pull Request")
                } menu: {
                    if pullRequest.hasNewWork { Button("View Pull Request", action: view) }
                    Button(mergeTitle, action: merge)
                    Divider()
                    branchItems(task, project)
                    archiveItem
                }
                .disabled(isMerging)
            } else {
                // Without a remote there is nowhere to open a pull request: merging stays the main action.
                let opensPR = (project.opensPullRequests || pullRequest != nil) && model.pushStates[project.id]?.remote != nil
                SplitButton(prominent: true, action: opensPR ? openPullRequest : merge) {
                    Text(opensPR ? "Open Pull Request" : mergeTitle)
                } menu: {
                    Button(opensPR ? mergeTitle : "Open Pull Request", action: opensPR ? merge : openPullRequest)
                    if let pullRequest { Button("View Pull Request #\(pullRequest.number)") { apps.openInBrowser(pullRequest.url) } }
                    Divider()
                    branchItems(task, project)
                    archiveItem
                }
                .disabled(isMerging)
            }
        } else if task.status == .conflict {
            SplitButton(prominent: true, tint: TaskStatus.conflict.color) { model.resolveConflict(taskID: taskID) } label: {
                Text("Resolve")
            } menu: {
                if let pullRequest { Button("View Pull Request #\(pullRequest.number)") { apps.openInBrowser(pullRequest.url) } }
                branchItems(task, project)
                archiveItem
            }
        } else if task.status == .working || task.approvalRequest != nil {
            // Says "Task": beside an app's Run button there can be another Stop, for the app.
            Button { model.stop(taskID: taskID) } label: {
                Label("Stop Task", systemImage: "stop.fill")
            }
            .buttonStyle(.glass)
        }
    }

    private func merge() {
        isMerging = true
        Task { await model.merge(taskID: taskID); isMerging = false }
    }

    /// Closing without merging, from any primary action's menu: work it has stays on its branch.
    @ViewBuilder private var archiveItem: some View {
        Divider()
        Button("Archive", action: archive)
            .help("Close this task without merging. Its changes stay on its branch; its conversation stays in Recently Closed.")
    }

    private func archive() {
        isMerging = true
        Task { await model.archive(taskID: taskID); isMerging = false }
    }

    private func openPullRequest() {
        isMerging = true
        Task {
            defer { isMerging = false }
            // Its squashed commit is on the base now: without it, the new pull request repeats all of that work.
            if model.pullRequests[taskID]?.state == .merged {
                syncConflicts = await model.syncBase(taskID: taskID)
                guard syncConflicts.isEmpty else { return }
            }
            // Created: the button becomes View Pull Request.
            if case .browser(let url)? = await model.openPullRequest(taskID: taskID) { apps.openInBrowser(url) }
        }
    }

    private func pushToPullRequest() {
        isMerging = true
        Task { await model.pushBranch(taskID: taskID); isMerging = false }
    }

    /// What can be done with the task's branch, in the dropdown of its main action.
    @ViewBuilder private func branchItems(_ task: TaskItem, _ project: Project) -> some View {
        // The current base is always offered, so the picker is valid before branches load.
        let base = task.base(in: project)
        Menu("Base Branch") {
            Picker("Base Branch", selection: Binding(get: { base }, set: { if $0 != base { newBase = $0 } })) {
                ForEach(branches.contains(base) ? branches : [base] + branches, id: \.self) { Text($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New Branch…") { creatingBranch = true }
        }
        .help("The branch this task merges into")
        Button("Re-sync Base Branch") { Task { syncConflicts = await model.syncBase(taskID: taskID) } }
            .help("Merge the latest \(base) into this task")
        if let remote = model.pushStates[project.id]?.remote {
            Button("Push Task Branch") { Task { await model.pushBranch(taskID: taskID) } }
                .help("Push \(task.branch) to \(remote)")
        }
    }

    /// Most recent first, as a stack when there are several: a click spreads it out, then a click opens one.
    /// Quick Look's arrow keys walk through them all, to compare.
    @ViewBuilder private func screenshotsRow(_ task: TaskItem) -> some View {
        let shots = (task.screenshots ?? []).reversed().map { $0 }
        if !shots.isEmpty {
            let stacked = shots.count > 1 && !screenshotsExpanded
            ScrollView(.horizontal) {
                HStack(alignment: .center, spacing: stacked ? -90 : 8) {
                    ForEach(Array(shots.enumerated()), id: \.element.id) { index, shot in
                        Button {
                            if stacked { withAnimation(.snappy) { screenshotsExpanded = true } }
                            else { screenshotPreview = shot.url }
                        } label: {
                            AsyncImage(url: shot.url) { $0.resizable().scaledToFill() } placeholder: { Color.clear }
                                .frame(width: 96, height: 60, alignment: .top)
                                .clipShape(.rect(cornerRadius: 8))
                                .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(.separator) }
                        }
                        .buttonStyle(.plain)
                        .zIndex(Double(-index))
                        .help("\(shot.page), \(shot.date.formatted(date: .abbreviated, time: .shortened))")
                    }
                    if shots.count > 1 && screenshotsExpanded {
                        Button("Collapse", systemImage: "chevron.left") { withAnimation(.snappy) { screenshotsExpanded = false } }
                            .labelStyle(.iconOnly)
                            .buttonStyle(.borderless)
                            .help("Stack the screenshots")
                    }
                }
            }
            .scrollIndicators(.never)
            .scrollBounceBehavior(.basedOnSize)
            .quickLookPreview($screenshotPreview, in: shots.map(\.url))
        }
    }

    @ViewBuilder private var changesSection: some View {
        switch changes {
        case .success(let changes) where !changes.files.isEmpty:
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 4) {
                    Text("\(changes.files.count) \(changes.files.count == 1 ? "file" : "files") changed ·").foregroundStyle(.secondary)
                    counts(changes.additions, changes.deletions)
                    Spacer()
                    Button("View diff") { diffPath = nil; showDiff(true) }.buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
                // Scrolls on its own, showing at most 4.5 files so it's clear there are more.
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(changes.files) { file in
                            HStack {
                                Label(file.path, systemImage: fileSymbol(file.path)).lineLimit(1).truncationMode(.middle)
                                Spacer()
                                if file.isBinary { Text("Binary").foregroundStyle(.secondary) }
                                else if file.kind == .added { Text("Added").foregroundStyle(.green) }
                                else if file.kind == .deleted { Text("Deleted").foregroundStyle(.red) }
                                else { counts(file.additions, file.deletions) }
                            }
                            .padding(.vertical, 8)
                            .contentShape(.rect)
                            .onTapGesture { diffPath = file.path; showDiff(true) }
                            if file != changes.files.last { Divider() }
                        }
                    }
                    .padding(.horizontal, 12)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { changesHeight = $0 }
                }
                .scrollBounceBehavior(.basedOnSize)
                // Max height, not fixed: fewer than 4.5 files take only the room they need.
                .frame(height: min(changesHeight, changesHeight / CGFloat(max(changes.files.count, 1)) * 4.5))
                .clipShape(.rect(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.separator))
            }
        case .failure(let error):
            Text("Couldn't load changes: \(error.localizedDescription)")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .help(error.localizedDescription)
        default:
            EmptyView()
        }
    }

    private func promptList(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            // Headed like a schedule's Prompt and runs.
            Text("Prompt history").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(task.prompts.reversed()) { prompt in
                        promptRow(prompt)
                            .padding(.vertical, 8)
                        if prompt != task.prompts.first { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    /// A prompt, closed on what the agent did about it once there's something to show.
    private func promptRow(_ prompt: Prompt) -> some View {
        let replies = turns.filter { $0.promptIDs.contains(prompt.id) && (!$0.sections.isEmpty || $0.note != nil) }
        let isOpen = !replies.isEmpty && openPrompts.contains(prompt.id)
        return VStack(alignment: .leading, spacing: 6) {
            if replies.isEmpty {
                if !prompt.text.isEmpty {
                    promptText(prompt).textSelection(.enabled).padding(.leading, Self.promptIndent)
                }
            } else {
                // The whole row toggles, so its text can't be selected: Copy is in its context menu.
                Button {
                    withAnimation(reduceMotion ? nil : .snappy(duration: 0.2)) {
                        if isOpen { openPrompts.remove(prompt.id) } else { openPrompts.insert(prompt.id) }
                    }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: Self.promptIndent - Self.chevronWidth) {
                        Image(systemName: "chevron.right")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                            .rotationEffect(.degrees(isOpen ? 90 : 0))
                            .frame(width: Self.chevronWidth)
                        promptText(prompt).multilineTextAlignment(.leading)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityValue(isOpen ? "Expanded" : "Collapsed")
                .contextMenu {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(prompt.text, forType: .string)
                    }
                }
            }
            if !prompt.attachments.isEmpty {
                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        ForEach(prompt.attachments, id: \.self) { AttachmentChip(url: URL(fileURLWithPath: $0)) }
                    }
                }
                .scrollIndicators(.never)
                .padding(.leading, Self.promptIndent)
            }
            if isOpen {
                VStack(alignment: .leading, spacing: 12) {
                    // The prompt is already right above.
                    ForEach(replies) { TurnView(turn: $0, prompts: [], reader: reader).equatable() }
                }
                // Under the prompt's text, not its chevron: the steps' chevrons then sit a level in.
                .padding(.top, 2)
                .padding(.leading, Self.promptIndent)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A pending prompt (not yet handed to the agent) pulses between secondary and tertiary.
    private func promptText(_ prompt: Prompt) -> some View {
        pendingPromptText(prompt).font(.scaled(.body, textScale))
    }

    @ViewBuilder private func pendingPromptText(_ prompt: Prompt) -> some View {
        if !prompt.isPending {
            Text(prompt.text).foregroundStyle(.primary)
        } else if reduceMotion {
            Text(prompt.text).foregroundStyle(.tertiary)
        } else {
            Text(prompt.text).foregroundStyle(.primary.opacity(0.7))
                .phaseAnimator([1, 0.5]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.75) }
        }
    }

    private func counts(_ additions: Int, _ deletions: Int) -> some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }
        .font(.subheadline.monospaced())
    }

    private func moreMenu(_ task: TaskItem, _ project: Project) -> some View {
        Menu {
            TaskActionItems(task: task, project: project, actions: $menu)
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
        .popover(isPresented: $menu.editingTags, arrowEdge: .bottom) { TagEditor(taskID: task.id) }
    }

    // MARK: Helpers

    /// Slides like a navigation push and pop: the diff comes in from the trailing edge, Back reverses it.
    /// The diff is told when the slide in has finished, so it can show its content without dropping frames.
    private func showDiff(_ show: Bool) {
        if show { diffSettled = false }
        withAnimation(.smooth(duration: 0.3)) { showingDiff = show } completion: {
            if show { diffSettled = true }
        }
    }

    /// The task's own text: what it is for until it's done, then the agent's summary.
    private func headline(_ task: TaskItem) -> String? {
        switch task.status {
        case .working, .needsInput, .blocked: task.description
        case .completed, .conflict, .merged, .archived: task.summary ?? task.description
        }
    }

    private func promptPlaceholder(_ task: TaskItem) -> String? {
        switch task.status {
        case .working: "Add instructions…"
        case .needsInput: "Answer…"
        case .blocked: "Give instructions…"
        case .completed: "Ask for changes…"
        case .conflict, .merged, .archived: nil
        }
    }
}

/// The dev server, as the port link shows it.
private enum ServerState {
    /// Running, not answering yet.
    case starting
    case up
    /// Was up, still running, stopped answering.
    case notResponding
    /// The process exited.
    case stopped

    var label: String {
        switch self {
        case .starting: "Starting…"
        case .up: "Running"
        case .notResponding: "Not responding"
        case .stopped: "Stopped"
        }
    }

    var color: Color {
        switch self {
        case .starting: .yellow
        case .up: .green
        case .notResponding: .red
        case .stopped: .gray
        }
    }
}
