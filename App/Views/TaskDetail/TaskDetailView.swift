import SwiftUI
import ShiftCore

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let taskID: TaskItem.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.openWindow) private var openWindow
    @State private var showingDiff = false
    /// True once the diff has finished sliding in.
    @State private var diffSettled = false
    /// The file the diff opens at, when opened from a row of the changed files.
    @State private var diffPath: String?
    @State private var confirmingDelete = false
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
    /// nil until first checked.
    @State private var server: ServerState?
    /// Whether the server button opens the tailnet link instead of localhost, when Tailscale is on.
    @AppStorage("opensTailnet") private var opensTailnet = false
    /// The "Copied" popover on the branch button.
    @State private var branchCopied = false
    @State private var output: Output?
    /// For capping the response panel's height.
    @State private var windowHeight: CGFloat = 0
    /// Height of the changed files' rows, for capping the list.
    @State private var changesHeight: CGFloat = 0
    @State private var reader: TranscriptReader?
    @State private var turns: [TranscriptTurn] = []
    /// The prompts showing what the agent did about them.
    @State private var openPrompts: Set<Prompt.ID> = []

    private let apps = ExternalApps()

    /// The detail's keyline: content and the toolbar title start this far from the column's leading edge.
    static let margin: CGFloat = 20
    /// Where the system places the first toolbar item of the detail column, measured from its leading edge.
    static let toolbarInset: CGFloat = 8
    private static let chevronWidth: CGFloat = 10
    /// Where a prompt's text starts, with or without a chevron.
    private static let promptIndent: CGFloat = 17

    var body: some View {
        if let task = model.task(taskID), let project = model.project(task.projectID) {
            Group {
                if showingDiff {
                    DiffView(taskID: taskID, isSettled: diffSettled, selecting: diffPath).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            header(task, project)
                            if task.status == .completed { changesSection }
                            if !task.prompts.isEmpty { promptList(task) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Self.margin)
                    }
                    .safeAreaBar(edge: .bottom) {
                        if ResponsePanel.shows(task) {
                            ResponsePanel(task: task, maxHeight: windowHeight * 0.5)
                                .id([task.question, task.approvalRequest, task.blockedReason])
                        } else if let placeholder = promptPlaceholder(task) {
                            PromptField(placeholder: placeholder, draftKey: "task \(taskID)") { model.sendPrompt(taskID: taskID, text: $0, attachments: $1) }
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
            .sheet(item: $output) { output in
                OutputSheet(title: output.rawValue, hasRaw: output == .agentOutput) { raw in
                    switch output {
                    case .appLog: await model.serverLog(taskID: taskID)
                    case .buildLog: model.buildLog(taskID: taskID)
                    case .agentOutput: raw ? await model.rawOutput(taskID: taskID) : await model.readableOutput(taskID: taskID)
                    }
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
            .task(id: task.status) { changes = task.status == .completed ? await model.loadChanges(taskID: taskID) : nil }
            .task(id: task.status) { conflicts = await model.conflictedFiles(taskID: taskID) }
            .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmingDelete) {
                Button("Delete Task", role: .destructive) { Task { await model.delete(taskID: taskID) } }
            } message: {
                Text("Its changes are discarded without merging.")
            }
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
        ToolbarItem { Text(task.title).font(.title3).lineLimit(1).padding(.leading, Self.margin - Self.toolbarInset) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarSpacer(.flexible)
        ToolbarItem { branchButton(task) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { moreMenu(task, project) }
    }

    /// The task's branch: click to copy its name.
    private func branchButton(_ task: TaskItem) -> some View {
        Button {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(task.branch, forType: .string)
            branchCopied = true
        } label: {
            Label(task.branch, systemImage: "arrow.triangle.branch")
                .labelStyle(.titleAndIcon)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .buttonStyle(.accessoryBar)
        .help("This task's branch. Click to copy it.")
        .popover(isPresented: $branchCopied, arrowEdge: .bottom) {
            Text("Copied").padding(.horizontal, 10).padding(.vertical, 6)
        }
        .task(id: branchCopied) {
            guard branchCopied else { return }
            try? await Task.sleep(for: .seconds(1.2))
            if !Task.isCancelled { branchCopied = false }
        }
    }

    /// The same structure for every status, directly on the window background: the task's own text,
    /// a status line, the action row, then what the agent is doing. What the task needs from the user is in the bottom bar.
    private func header(_ task: TaskItem, _ project: Project) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            if let headline = headline(task) {
                Text(headline).font(.title3).textSelection(.enabled)
            }
            statusLine(task, project)
            actions(task, project)
            if task.status == .working {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(task.activity ?? (task.isResolvingConflict ? "Resolving conflict…" : "Working…"))
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func statusLine(_ task: TaskItem, _ project: Project) -> some View {
        switch task.status {
        case .conflict:
            VStack(alignment: .leading, spacing: 4) {
                Text("Its changes conflict with changes made to \(task.base(in: project)) since it started\(conflicts.isEmpty ? "." : ", in:")")
                ForEach(conflicts, id: \.self) { Text($0).monospaced().textSelection(.enabled) }
            }
            .foregroundStyle(.secondary)
        case .merged:
            let base = task.base(in: project)
            // Merged into a branch the folder does not show: say so, or the work looks gone.
            Text(checkedOut == nil || checkedOut == base ? "Merged into \(base)"
                 : "Merged into \(base). The project folder has \(checkedOut ?? "") checked out, so it doesn't show there.")
                .foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// The status's main action first, then the server button (the Build button for an app) and the branch. Hidden when there is neither.
    /// Every task with a port has a preview server, whether or not the project has a server command.
    @ViewBuilder private func actions(_ task: TaskItem, _ project: Project) -> some View {
        let hasPrimary = task.status == .completed || task.status == .conflict
        let canBuild = project.isApp && task.status != .merged
        if task.serverURL != nil || hasPrimary || canBuild {
            HStack {
                primaryAction(task, project)
                if canBuild && project.runsApp {
                    runButton
                } else if canBuild {
                    buildButton
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
                    if let state = self.server, state != .up {
                        Text(state.label).foregroundStyle(state == .starting ? .secondary : state.color)
                        if state != .starting {
                            Button("Log") { openWindow(id: "server-log", value: taskID) }.buttonStyle(.glass).controlSize(.small)
                            Button("Restart") {
                                self.server = .starting
                                Task { await model.restartServer(taskID: taskID) }
                            }
                            .buttonStyle(.glass).controlSize(.small)
                        }
                    }
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(task.branch, forType: .string)
                    } label: {
                        Label(task.branch, systemImage: "arrow.triangle.branch")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)
                    .help("The branch this server runs. Click to copy.")
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
        return SplitButton { apps.openInBrowser(opened) } label: { label } menu: {
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

    /// Opens the task's copy of the app, or stops it. Says so when the app ends without being stopped: it may have
    /// crashed on launch.
    @ViewBuilder private var runButton: some View {
        let running = server == .up
        Button {
            Task {
                if running {
                    await model.stopApp(taskID: taskID)
                    server = nil
                } else {
                    await model.runApp(taskID: taskID)
                    if await model.isServerRunning(taskID: taskID) { server = .up }
                }
            }
        } label: {
            Label(running ? "Stop" : "Run", systemImage: running ? "stop.fill" : "play.fill")
        }
        .buttonStyle(.glass)
        .help(running ? "Close this task's version of the app" : "Open this task's version of the app")
        .task(id: taskID) {
            server = await model.isServerRunning(taskID: taskID) ? .up : nil
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                let alive = await model.isServerRunning(taskID: taskID)
                if alive != (server == .up), server != nil || alive { server = alive ? .up : .stopped }
            }
        }
        if server == .stopped {
            Text("Stopped").foregroundStyle(.secondary)
            Button("Log") { output = .appLog }.buttonStyle(.glass).controlSize(.small)
        }
        if case .failed(let reason) = model.builds[taskID] {
            Text(reason).foregroundStyle(.secondary).lineLimit(1)
        }
    }

    /// Builds the task's worktree and opens the app it built, replacing the one opened by the last build.
    @ViewBuilder private var buildButton: some View {
        let state = model.builds[taskID]
        Button {
            Task {
                if let app = await model.build(taskID: taskID) {
                    await apps.relaunch(app, environment: ["SHIFT_HOME": ShiftPaths.build(taskID: taskID).path])
                }
            }
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
        if case .failed(let reason) = state {
            Text(reason).foregroundStyle(.secondary).lineLimit(1)
            Button("Log") { output = .buildLog }.buttonStyle(.glass).controlSize(.small)
        }
    }

    @ViewBuilder private func primaryAction(_ task: TaskItem, _ project: Project) -> some View {
        if task.status == .completed {
            SplitButton(prominent: true) {
                isMerging = true
                Task { await model.merge(taskID: taskID); isMerging = false }
            } label: {
                Text("Merge into \(task.base(in: project))")
            } menu: {
                Button("Open Pull Request") {
                    isMerging = true
                    Task {
                        if let url = await model.pullRequestURL(taskID: taskID) { apps.openInBrowser(url) }
                        isMerging = false
                    }
                }
                Divider()
                branchItems(task, project)
            }
            .disabled(isMerging)
        } else if task.status == .conflict {
            SplitButton(prominent: true, tint: TaskStatus.conflict.color) { model.resolveConflict(taskID: taskID) } label: {
                Text("Resolve")
            } menu: {
                branchItems(task, project)
            }
        }
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
                .padding(.top, 2)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A pending prompt (not yet handed to the agent) pulses between secondary and tertiary.
    @ViewBuilder private func promptText(_ prompt: Prompt) -> some View {
        if !prompt.isPending {
            Text(prompt.text).foregroundStyle(.primary.opacity(0.7))
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
        .font(.caption.monospaced())
    }

    private func moreMenu(_ task: TaskItem, _ project: Project) -> some View {
        Menu {
            if task.status != .merged {
                // Core recreates a missing folder before the next run; until then there is nothing to open.
                let folderExists = FileManager.default.fileExists(atPath: task.worktreePath)
                Group {
                    Menu("Open in") {
                        ForEach(apps.installedEditors()) { app in
                            Button(app.displayName) { apps.open(task.worktreeURL, in: app) }
                        }
                        Divider()
                        ForEach(apps.installedTerminals(), id: \.self) { terminal in
                            Button(apps.name(of: terminal)) { apps.open(task.worktreeURL, withApp: terminal) }
                        }
                    }
                }
                .disabled(!folderExists)
                .help(folderExists ? "" : "The task's folder is recreated the next time the agent runs.")
                if project.runsApp {
                    Button("App Log") { output = .appLog }
                } else if project.isApp {
                    Button("Build Log") { output = .buildLog }
                }
                Button("Agent Output") { output = .agentOutput }
                if task.status == .working || task.approvalRequest != nil {
                    Button("Stop Task") { model.stop(taskID: taskID) }
                }
                Divider()
            }
            Button("Delete Task…", role: .destructive) { confirmingDelete = true }
        } label: {
            Label("More", systemImage: "ellipsis.circle")
        }
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
        case .completed, .conflict, .merged: task.summary ?? task.description
        }
    }

    private func promptPlaceholder(_ task: TaskItem) -> String? {
        switch task.status {
        case .working: "Add instructions…"
        case .needsInput: "Answer…"
        case .blocked: "Give instructions…"
        case .completed: "Ask for changes…"
        case .conflict, .merged: nil
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
        case .starting: .orange
        case .up: .green
        case .notResponding, .stopped: .red
        }
    }
}

/// Debugging text, from the ••• menu.
private enum Output: String, Identifiable {
    case appLog = "App Log", buildLog = "Build Log", agentOutput = "Agent Output"
    var id: Self { self }
}

private struct OutputSheet: View {
    let title: String
    /// Offers the unformatted text too, for debugging.
    let hasRaw: Bool
    let load: (_ raw: Bool) async -> String
    @State private var text: String?
    @State private var raw = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text(title).font(.headline)
                Spacer()
                if hasRaw { Toggle("Raw", isOn: $raw).toggleStyle(.checkbox) }
            }
            ScrollView {
                Text(text.map { $0.isEmpty ? "No output." : $0 } ?? "Loading…")
                    .font(hasRaw && !raw ? .body : .callout.monospaced())
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
        .task(id: raw) { text = await load(raw) }
    }
}
