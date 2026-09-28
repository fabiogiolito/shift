import SwiftUI
import ShiftCore

struct TaskDetailView: View {
    @Environment(AppModel.self) private var model
    let taskID: TaskItem.ID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showingDiff = false
    /// True once the diff has finished sliding in.
    @State private var diffSettled = false
    @State private var confirmingDelete = false
    @State private var isMerging = false
    @State private var changes: Result<DiffSummary, Error>?
    /// nil until first checked.
    @State private var serverRunning: Bool?
    @State private var output: Output?
    /// For capping the response panel's height.
    @State private var windowHeight: CGFloat = 0
    /// Height of the changed files' rows, for capping the list.
    @State private var changesHeight: CGFloat = 0

    private let apps = ExternalApps()

    /// The detail's keyline: content and the toolbar title start this far from the column's leading edge.
    private static let margin: CGFloat = 20
    /// Where the system places the first toolbar item of the detail column, measured from its leading edge.
    private static let toolbarInset: CGFloat = 8

    var body: some View {
        if let task = model.task(taskID), let project = model.project(task.projectID) {
            Group {
                if showingDiff {
                    DiffView(taskID: taskID, isSettled: diffSettled).frame(maxWidth: .infinity, maxHeight: .infinity)
                        .transition(reduceMotion ? .opacity : .move(edge: .trailing))
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 28) {
                            header(task, project)
                            if task.status == .completed { changesSection }
                            if !task.prompts.isEmpty { promptHistory(task) }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(Self.margin)
                    }
                    .safeAreaBar(edge: .bottom) {
                        if ResponsePanel.shows(task) {
                            ResponsePanel(task: task, maxHeight: windowHeight * 0.5)
                                .id([task.question, task.approvalRequest, task.blockedReason])
                        } else if let placeholder = promptPlaceholder(task) {
                            PromptField(placeholder: placeholder) { model.sendPrompt(taskID: taskID, text: $0, attachments: $1) }
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
                OutputSheet(title: output.rawValue) {
                    output == .serverLog ? await model.serverLog(taskID: taskID) : await model.rawOutput(taskID: taskID)
                }
            }
            .task(id: task.status) { changes = task.status == .completed ? await model.loadChanges(taskID: taskID) : nil }
            .confirmationDialog("Delete “\(task.title)”?", isPresented: $confirmingDelete) {
                Button("Delete Task", role: .destructive) { Task { await model.delete(taskID: taskID) } }
            } message: {
                Text("Its changes are discarded without merging.")
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
        ToolbarItem { status(task).font(.subheadline).foregroundStyle(.secondary).padding(.trailing, 12) }
            .sharedBackgroundVisibility(.hidden)
        ToolbarItem(placement: .primaryAction) { moreMenu(task, project) }
    }

    private func status(_ task: TaskItem) -> some View {
        HStack(spacing: 6) {
            // Working already shows a spinner under the headline and in the list.
            if task.status != .working { StatusIcon(status: task.status).controlSize(.mini) }
            if task.status == .working, let since = task.workingSince {
                TimelineView(.periodic(from: since, by: 60)) { context in
                    Text("\(task.isResolvingConflict ? "Resolving conflict" : "Working") · \(max(0, Int(context.date.timeIntervalSince(since) / 60)))m")
                }
            } else {
                Text(task.status.label)
            }
            TaskNumber(task: task)
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
            actions(task)
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
            Text("Its changes conflict with changes made to \(project.baseBranch) since it started.").foregroundStyle(.secondary)
        case .merged:
            Text("Merged into \(project.baseBranch)").foregroundStyle(.secondary)
        default:
            EmptyView()
        }
    }

    /// The status's main action first, then the server button. Hidden when there is neither.
    /// Every task with a port has a preview server, whether or not the project has a server command.
    @ViewBuilder private func actions(_ task: TaskItem) -> some View {
        let hasPrimary = task.status == .completed || task.status == .conflict
        if task.serverURL != nil || hasPrimary {
            HStack {
                primaryAction(task)
                if let server = task.serverURL, let port = task.port {
                    Button { apps.openInBrowser(server) } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "circle.fill").imageScale(.small)
                                .foregroundStyle(serverRunning == true ? Color.green : Color.secondary)
                            Text("localhost:\(String(port))")
                            Image(systemName: "arrow.up.right").imageScale(.small)
                        }
                    }
                    .buttonStyle(.glass)
                    .help(serverRunning == true ? "Open in browser" : "Server not running")
                    .task {
                        while !Task.isCancelled {
                            serverRunning = await model.isServerRunning(taskID: taskID)
                            try? await Task.sleep(for: .seconds(3))
                        }
                    }
                    // The port may still come up, so the button stays.
                    if serverRunning == false {
                        Text("Stopped").foregroundStyle(.secondary)
                        Button("Restart") { Task { await model.restartServer(taskID: taskID) } }
                            .buttonStyle(.glass).controlSize(.small)
                    }
                }
                Spacer()
            }
        }
    }

    @ViewBuilder private func primaryAction(_ task: TaskItem) -> some View {
        if task.status == .completed {
            Button("Merge") {
                isMerging = true
                Task { await model.merge(taskID: taskID); isMerging = false }
            }
            .buttonStyle(.glassProminent)
            .disabled(isMerging)
        } else if task.status == .conflict {
            Button("Resolve") { model.resolveConflict(taskID: taskID) }
                .buttonStyle(.glassProminent).tint(TaskStatus.conflict.color)
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
                    Button("View diff") { showDiff(true) }.buttonStyle(.glass)
                }
                .font(.subheadline.weight(.semibold))
                // Scrolls on its own, showing at most 4.5 files so it's clear there are more.
                GroupBox {
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
                                if file != changes.files.last { Divider() }
                            }
                        }
                        .padding(.horizontal, 8)
                        .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { changesHeight = $0 }
                    }
                    .scrollBounceBehavior(.basedOnSize)
                    // Max height, not fixed: fewer than 4.5 files take only the room they need.
                    .frame(height: min(changesHeight, changesHeight / CGFloat(max(changes.files.count, 1)) * 4.5))
                    // Let the rows draw into the box's inset, so the list is cut at the panel's edge, not short of it.
                    .scrollClipDisabled()
                }
                .clipShape(.rect(cornerRadius: 12))
            }
        case .failure(let error):
            Text("Couldn't load changes: \(error.localizedDescription)")
                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.tail)
                .help(error.localizedDescription)
        default:
            EmptyView()
        }
    }

    private func promptHistory(_ task: TaskItem) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Prompt History").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
            GroupBox {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(task.prompts) { prompt in
                        VStack(alignment: .leading, spacing: 6) {
                            if !prompt.text.isEmpty { promptText(prompt).textSelection(.enabled) }
                            if !prompt.attachments.isEmpty {
                                ScrollView(.horizontal) {
                                    HStack(spacing: 6) {
                                        ForEach(prompt.attachments, id: \.self) { AttachmentChip(url: URL(fileURLWithPath: $0)) }
                                    }
                                }
                                .scrollIndicators(.never)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 8)
                        if prompt != task.prompts.last { Divider() }
                    }
                }
                .padding(.horizontal, 8)
            }
        }
    }

    /// A pending prompt (not yet handed to the agent) pulses between secondary and tertiary.
    @ViewBuilder private func promptText(_ prompt: Prompt) -> some View {
        if !prompt.isPending {
            Text(prompt.text).foregroundStyle(.secondary)
        } else if reduceMotion {
            Text(prompt.text).foregroundStyle(.tertiary)
        } else {
            Text(prompt.text).foregroundStyle(.secondary)
                .phaseAnimator([1, 0.5]) { $0.opacity($1) } animation: { _ in .easeInOut(duration: 0.75) }
        }
    }

    private func counts(_ additions: Int, _ deletions: Int) -> some View {
        HStack(spacing: 4) {
            Text("+\(additions)").foregroundStyle(.green)
            Text("−\(deletions)").foregroundStyle(.red)
        }
        .monospacedDigit()
    }

    private func moreMenu(_ task: TaskItem, _ project: Project) -> some View {
        Menu {
            if task.status != .merged {
                // Core recreates a missing folder before the next run; until then there is nothing to open.
                let folderExists = FileManager.default.fileExists(atPath: task.worktreePath)
                Group {
                    Menu("Open in") {
                        ForEach(apps.installedEditors() + [.finder]) { app in
                            Button(app.displayName) { apps.open(task.worktreeURL, in: app) }
                        }
                    }
                    Button("Open in \(apps.terminalName())") { apps.open(task.worktreeURL, in: .terminal) }
                }
                .disabled(!folderExists)
                .help(folderExists ? "" : "The task's folder is recreated the next time the agent runs.")
                if task.port != nil {
                    Button("Restart Server") { Task { await model.restartServer(taskID: taskID) } }
                    Button("Server Log") { output = .serverLog }
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

/// Debugging text, from the ••• menu.
private enum Output: String, Identifiable {
    case serverLog = "Server Log", agentOutput = "Agent Output"
    var id: Self { self }
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
