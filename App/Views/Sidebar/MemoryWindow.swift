import SwiftUI
import ShiftCore

/// The memory a project's tasks use, heaviest first, with ways to stop them. Modeled on Force Quit Applications.
struct MemoryWindow: View {
    static let id = "memory"

    let projectID: Project.ID
    @Environment(AppModel.self) private var model
    @State private var selection: Row.ID?

    struct Row: Identifiable {
        /// nil: the project chat.
        var task: TaskItem?
        var use: MemoryUse
        var id: Int { task?.id ?? 0 }
    }

    static func format(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .memory)
    }

    private var rows: [Row] {
        var rows = model.tasks(in: projectID).compactMap { task in
            model.taskMemory[task.id].map { Row(task: task, use: $0) }
        }
        if let chat = model.chatMemory[projectID] { rows.append(Row(task: nil, use: MemoryUse(agent: chat))) }
        return rows.sorted { $0.use.total > $1.use.total }
    }

    private var selected: Row? { rows.first { $0.id == selection } }

    var body: some View {
        let name = model.project(projectID)?.name ?? "Project"
        VStack(alignment: .leading, spacing: 12) {
            Text("Agents and servers started by these tasks use this memory.")
                .foregroundStyle(.secondary)
            List(rows, selection: $selection) { row in
                HStack {
                    VStack(alignment: .leading) {
                        Text(verbatim: row.task.map { "\($0.title) #\($0.id)" } ?? "Project Chat").lineLimit(1)
                        if let detail = detail(row) {
                            Text(detail).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(Self.format(row.use.total)).monospacedDigit()
                }
            }
            .overlay { if rows.isEmpty { Text("Nothing is running.").foregroundStyle(.secondary) } }
            .frame(height: 220)
            HStack {
                Spacer()
                Button("Stop Server") {
                    if let id = selected?.task?.id { Task { await model.stopServer(taskID: id) } }
                }
                .disabled(selected?.task?.serverPID == nil)
                Button(selected?.task == nil && selected != nil ? "Stop Chat" : "Stop Task", action: stop)
                    .disabled(!canStop)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 440)
        .navigationTitle("Memory used by \(name)")
    }

    /// Agent and server apart, when both use some.
    private func detail(_ row: Row) -> String? {
        guard row.use.agent > 0, row.use.server > 0 else { return nil }
        return "Agent \(Self.format(row.use.agent)) · Server \(Self.format(row.use.server))"
    }

    private var canStop: Bool {
        guard let selected else { return false }
        guard let task = selected.task else { return model.replyingChats.contains(projectID) }
        return task.status == .working || task.approvalRequest != nil
    }

    private func stop() {
        guard let selected else { return }
        if let task = selected.task { model.stop(taskID: task.id) } else { model.stopChat(projectID: projectID) }
    }
}
