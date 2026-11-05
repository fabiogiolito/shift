import SwiftUI
import ShiftCore

/// The memory every project's tasks use, heaviest first, with ways to stop them. Modeled on Force Quit Applications.
struct MemoryWindow: View {
    static let id = "memory"
    static let title = "Memory Used by Tasks"

    @Environment(AppModel.self) private var model
    @State private var selection: Row?

    enum Row: Hashable {
        case project(Project.ID)
        case task(TaskItem.ID)
        case chat(Project.ID)
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    /// One line of the list: a project's heading, or one of its tasks (or its chat).
    struct Item: Identifiable {
        var id: Row
        var use: MemoryUse
    }

    /// Projects with something running, heaviest first, each followed by its tasks (and chat), heaviest first.
    private var items: [Item] {
        model.projects.compactMap { project -> [Item]? in
            var rows = model.tasks(in: project.id).compactMap { task in
                model.taskMemory[task.id].map { Item(id: .task(task.id), use: $0) }
            }
            if let chat = model.chatMemory[project.id] { rows.append(Item(id: .chat(project.id), use: MemoryUse(agent: chat))) }
            guard !rows.isEmpty else { return nil }
            let heading = Item(id: .project(project.id), use: MemoryUse(agent: rows.reduce(0) { $0 + $1.use.total }))
            return [heading] + rows.sorted { $0.use.total > $1.use.total }
        }
        .sorted { $0[0].use.total > $1[0].use.total }
        .flatMap { $0 }
    }

    var body: some View {
        let items = items
        VStack(alignment: .leading, spacing: 12) {
            Text("Memory used by agents and servers on each project.")
                .foregroundStyle(.secondary)
            List(items, selection: $selection) { item in
                if case .project(let id) = item.id, let project = model.project(id) {
                    projectRow(project, item.use)
                } else {
                    taskRow(item.id, item.use)
                }
            }
            // Outlined, with the selection edge to edge, like Force Quit Applications.
            .listStyle(.bordered)
            .overlay { if items.isEmpty { Text("Nothing is running.").foregroundStyle(.secondary) } }
            .frame(height: 260)
            HStack {
                Spacer()
                Button(isProject ? "Stop All Servers" : "Stop Server", action: stopServers)
                    .disabled(serverTasks.isEmpty)
                Button(stopTitle, action: stopTasks)
                    .disabled(runningTasks.isEmpty && runningChat == nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 460)
        .navigationTitle(Self.title)
    }

    private func projectRow(_ project: Project, _ use: MemoryUse) -> some View {
        HStack {
            ProjectIcon(repoPath: project.repoPath, version: model.tasks(in: project.id).compactMap(\.mergedAt).max())
            Text(project.name).fontWeight(.semibold).lineLimit(1)
            Spacer(minLength: 12)
            Text(Self.format(use.total)).fontWeight(.semibold).monospacedDigit()
        }
    }

    private func taskRow(_ row: Row, _ use: MemoryUse) -> some View {
        let task: TaskItem? = if case .task(let id) = row { model.task(id) } else { nil }
        return HStack(alignment: .firstTextBaseline) {
            // Under the project's name, past its icon.
            Color.clear.frame(width: 18, height: 1)
            if let task {
                Text(verbatim: "#\(task.id)").foregroundStyle(.secondary).monospacedDigit()
            }
            VStack(alignment: .leading) {
                Text(task?.title ?? "Project Chat").lineLimit(1).truncationMode(.tail)
                // Agent and server apart, when both use some.
                if use.agent > 0, use.server > 0 {
                    Text("Agent \(Self.format(use.agent)) · Server \(Self.format(use.server))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 12)
            Text(Self.format(use.total)).monospacedDigit().layoutPriority(1)
        }
    }

    private var isProject: Bool { if case .project = selection { true } else { false } }

    /// The tasks the selection covers: one, or a whole project's.
    private var selectedTasks: [TaskItem] {
        switch selection {
        case .project(let id): model.tasks(in: id)
        case .task(let id): model.task(id).map { [$0] } ?? []
        case .chat, nil: []
        }
    }

    private var serverTasks: [TaskItem] { selectedTasks.filter { $0.serverPID != nil } }
    private var runningTasks: [TaskItem] { selectedTasks.filter { $0.status == .working || $0.approvalRequest != nil } }
    private var runningChat: Project.ID? {
        switch selection {
        case .project(let id), .chat(let id): model.replyingChats.contains(id) ? id : nil
        default: nil
        }
    }

    private var stopTitle: String {
        switch selection {
        case .project: "Stop All Tasks"
        case .chat: "Stop Chat"
        default: "Stop Task"
        }
    }

    private func stopServers() {
        let ids = serverTasks.map(\.id)
        Task { for id in ids { await model.stopServer(taskID: id) } }
    }

    private func stopTasks() {
        runningTasks.forEach { model.stop(taskID: $0.id) }
        if let chat = runningChat { model.stopChat(projectID: chat) }
    }
}
