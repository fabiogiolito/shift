import SwiftUI
import AppKit
import ShiftCore

/// Along the bottom of the task list and task detail, split where they are. Under the list, the project's folder. Under the detail, the agent, model and permissions of the task on screen,
/// for its next prompt; with no task (the chat, or none selected), the project's, which new tasks start with.
struct ProjectBar: View {
    /// Shared with the sidebar's New Project bar, so their top edges line up.
    static let height: CGFloat = 40
    @Environment(AppModel.self) private var model
    let project: Project
    /// The task on screen. nil, or merged: the project's own choices.
    let task: TaskItem?
    /// The task list's width: the left side's.
    let listWidth: CGFloat
    @State private var showingSettings = false
    @State private var showingUsage = false

    var body: some View {
        HStack(spacing: 0) {
            newTaskSide
                .padding(.horizontal, 12)
                .frame(width: listWidth, alignment: .leading)
            Divider()
            agentSide
                .padding(.horizontal, 12)
        }
        .menuStyle(.borderlessButton)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .frame(height: Self.height)
        .background(.bar)
        .sheet(isPresented: $showingSettings) { ProjectSettingsView(projectID: project.id) }
        .focusedSceneValue(\.openProjectSettings) { showingSettings = true }
    }

    private var newTaskSide: some View {
        HStack(spacing: 16) {
            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.repoPath)
                }
                Button("Project Settings…") { showingSettings = true }
            } label: {
                // Drawn by SwiftUI, not AppKit, so a long path loses its start, not its end.
                HStack(spacing: 4) {
                    Label((project.repoPath as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
                        .lineLimit(1).truncationMode(.head)
                    Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
            .help("Repository")
            Spacer(minLength: 0)
        }
    }

    private var agentSide: some View {
        let task = self.task.flatMap { $0.status.isClosed ? nil : $0 }
        let agent = task?.agent ?? project.defaultAgent
        let modelID = task.map { $0.model ?? "" } ?? project.defaultModel
        let permissions = task?.permissions ?? project.permissions
        let whose = task == nil ? "for new tasks" : "for this task's next prompt"

        return HStack(spacing: 16) {
            // One menu for both: a submenu per agent with its models. Picking another agent's model switches agent.
            Menu {
                ForEach(AgentKind.allCases) { kind in
                    let installed = model.installedAgents[kind] != nil
                    let options = model.models[kind] ?? []
                    Menu {
                        Picker("Model", selection: Binding(get: { kind == agent ? modelID : "\u{0}" }, set: { id in
                            select(kind, id, task: task)
                        })) {
                            Text("Default model").tag("")
                            Divider()
                            ForEach(options) { Text($0.name).tag($0.id) }
                            // A saved model the agent no longer lists stays selectable.
                            if kind == agent, !modelID.isEmpty, !options.contains(where: { $0.id == modelID }) {
                                Text(modelID).tag(modelID)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Label(installed ? kind.displayName : "\(kind.displayName) (not installed)", image: kind.icon)
                    }
                    // Its session is the agent's own: switching starts a new one, so not in the middle of a turn.
                    .disabled(!installed || (kind != agent && task?.status == .working))
                }
            } label: {
                Label(modelID.isEmpty ? agent.displayName : model.modelName(modelID, for: agent), image: agent.icon)
            }
            .help("Agent and model \(whose)")

            Menu {
                Picker("Permissions", selection: Binding(get: { permissions }, set: { new in
                    if let task { model.setPermissions(taskID: task.id, to: new) } else { updateProject { $0.permissions = new } }
                })) {
                    ForEach(AgentPermissions.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(permissions.displayName, systemImage: permissions.symbol)
            }
            .help("Permissions \(whose)")

            Spacer()

            if let usage = model.usage[agent], let window = usage.tightest {
                Button { showingUsage.toggle() } label: {
                    Text(Self.describe(window))
                        .font(.subheadline)
                        .monospacedDigit()
                        .lineLimit(1)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .help("Usage limits")
                .popover(isPresented: $showingUsage, arrowEdge: .top) { UsagePopover(agent: agent) }
            }
        }
        .task(id: agent) {
            // ponytail: polled; the Claude endpoint rate-limits, so not much more often than this.
            while !Task.isCancelled {
                await model.refreshUsage(agent)
                try? await Task.sleep(for: .seconds(300))
            }
        }
    }

    /// "5-hour limit 58% left · resets 3:40 PM"
    private static func describe(_ window: AgentUsage.Window) -> String {
        var text = "\(window.name) limit \(Int(window.percentLeft().rounded()))% left"
        if let time = window.resetTime { text += " · resets \(time)" }
        return text
    }

    private func select(_ kind: AgentKind, _ id: String, task: TaskItem?) {
        if let task {
            if kind != task.agent { model.setAgent(taskID: task.id, to: kind) }
            model.setModel(taskID: task.id, to: id.isEmpty ? nil : id)
        } else {
            updateProject { $0.defaultAgent = kind; $0.defaultModel = id }
        }
    }

    private func updateProject(_ change: (inout Project) -> Void) {
        var updated = project
        change(&updated)
        model.updateProject(updated)
    }
}

/// Each agent's usage windows (session, week): how much is used, as a bar, and when it resets.
/// Opens on the active agent; the other can be peeked at without switching to it.
private struct UsagePopover: View {
    @Environment(AppModel.self) private var model
    @State private var agent: AgentKind

    init(agent: AgentKind) { _agent = State(initialValue: agent) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Picker("Agent", selection: $agent) {
                ForEach(AgentKind.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: .infinity)
            // Sized for two windows whatever the agent shows, so switching doesn't resize the popover.
            ZStack(alignment: .top) {
                windows(Array(repeating: AgentUsage.Window(name: "Weekly", usedPercent: 0, resetsAt: .distantFuture), count: 2))
                    .hidden()
                if let usage = model.usage[agent], !usage.windows.isEmpty {
                    windows(usage.windows)
                } else {
                    Text(model.installedAgents[agent] == nil ? "\(agent.displayName) isn't installed" : "No usage information")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .padding()
        .frame(width: 260)
        // The bar only polls the active agent; fetch the other's once when peeked at.
        .task(id: agent) { if model.usage[agent] == nil { await model.refreshUsage(agent) } }
    }

    private func windows(_ windows: [AgentUsage.Window]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(Array(windows.enumerated()), id: \.offset) { _, window in
                let used = 100 - window.percentLeft()
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("\(window.name) limit")
                        Spacer()
                        Text("\(Int(used.rounded()))% used").monospacedDigit().foregroundStyle(.secondary)
                    }
                    ProgressView(value: used, total: 100)
                        .tint(used >= 90 ? .red : used >= 75 ? .orange : .accentColor)
                    if let time = window.resetTime {
                        Text("Resets \(time)").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

private extension AgentUsage.Window {
    /// "3:40 PM" today, "Fri 3:40 PM" later; nil once past.
    var resetTime: String? {
        guard let resetsAt, resetsAt > .now else { return nil }
        return Calendar.current.isDateInToday(resetsAt)
            ? resetsAt.formatted(date: .omitted, time: .shortened)
            : resetsAt.formatted(.dateTime.weekday().hour().minute())
    }
}

extension AgentKind {
    /// Monochrome template mark in the asset catalog, sized like a symbol at body size.
    var icon: String { self == .claudeCode ? "agent-claude" : "agent-codex" }
}

extension Project {
    /// The model picked for the default agent; "" is the agent's own default.
    var defaultModel: String {
        get { models[defaultAgent] ?? "" }
        set { models[defaultAgent] = newValue.isEmpty ? nil : newValue }
    }
}

extension AppModel {
    func modelName(_ id: String, for agent: AgentKind) -> String {
        id.isEmpty ? "Default model" : models[agent]?.first { $0.id == id }?.name ?? id
    }
}

/// The branch new tasks start from, with New Branch…. In the new task field, next to Start.
struct BaseBranchMenu: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var branches: [String] = []
    @State private var creatingBranch = false

    var body: some View {
        // The current value is always offered, so the menu is valid before branches load.
        let options = branches.contains(project.baseBranch) ? branches : [project.baseBranch] + branches
        Menu {
            Picker("Base branch", selection: Binding(get: { project.baseBranch }, set: setBase)) {
                ForEach(options, id: \.self) { Text($0) }
            }
            .pickerStyle(.inline)
            Divider()
            Button("New Branch…") { creatingBranch = true }
        } label: {
            // Drawn by SwiftUI, like the folder menu, so it takes the secondary color.
            HStack(spacing: 4) {
                // Body is 13pt; the icon 2pt smaller.
                Image(systemName: "arrow.triangle.branch").font(.system(size: 11))
                Text(project.baseBranch)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .semibold))
            }
            .contentShape(Rectangle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden)
        .foregroundStyle(.secondary)
        .fixedSize()
        .help("Base branch for new tasks")
        .onAppearAndActivate(id: project.id) { branches = await model.branches(for: project.id) }
        .sheet(isPresented: $creatingBranch) {
            NewBranchSheet(projectID: project.id, branches: branches, source: project.baseBranch) { name in
                setBase(name)
                Task { branches = await model.branches(for: project.id) }
            }
        }
    }

    private func setBase(_ name: String) {
        var updated = project
        updated.baseBranch = name
        model.updateProject(updated)
    }
}

/// An agent's models, its own default first.
struct ModelPicker: View {
    @Environment(AppModel.self) private var model
    let agent: AgentKind
    @Binding var selection: String

    var body: some View {
        let options = model.models[agent] ?? []
        Picker("Model", selection: $selection) {
            Text("Default").tag("")
            ForEach(options) { Text($0.name).tag($0.id) }
            // A saved model the agent no longer lists stays selectable.
            if !selection.isEmpty && !options.contains(where: { $0.id == selection }) {
                Text(selection).tag(selection)
            }
        }
    }
}

/// Asks for a new branch's name and the branch it starts from, and creates it in the project's repo.
struct NewBranchSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let projectID: Project.ID
    let branches: [String]
    let onCreated: (String) -> Void
    @State private var name = ""
    @State private var source: String
    @State private var isCreating = false

    init(projectID: Project.ID, branches: [String], source: String, onCreated: @escaping (String) -> Void) {
        self.projectID = projectID
        self.branches = branches.contains(source) ? branches : [source] + branches
        self.onCreated = onCreated
        _source = State(initialValue: source)
    }

    var body: some View {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        Form {
            TextField("Name", text: $name, prompt: Text("feature/new-homepage"))
            Picker("From", selection: $source) {
                ForEach(branches, id: \.self) { Text($0) }
            }
        }
        .formStyle(.grouped)
        .frame(width: 380)
        .navigationTitle("New Branch")
        .toolbar {
            ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            ToolbarItem(placement: .confirmationAction) {
                Button("Create") {
                    isCreating = true
                    Task {
                        // On failure the sheet stays open; the model's error alert says why.
                        if await model.createBranch(projectID: projectID, name: trimmed, from: source) {
                            onCreated(trimmed)
                            dismiss()
                        }
                        isCreating = false
                    }
                }
                .disabled(trimmed.isEmpty || isCreating)
            }
        }
    }
}

extension View {
    /// Runs `action` now and each time Shift comes to the front: branches may have been made in a terminal.
    func onAppearAndActivate(id: some Equatable, _ action: @escaping () async -> Void) -> some View {
        modifier(ActivationTask(id: id, action: action))
    }
}

private struct ActivationTask<ID: Equatable>: ViewModifier {
    let id: ID
    let action: () async -> Void
    @State private var activations = 0

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in activations += 1 }
            .task(id: "\(id)|\(activations)") { await action() }
    }
}
