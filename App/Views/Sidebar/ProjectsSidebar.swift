import SwiftUI
import AppKit
import ShiftCore

struct ProjectsSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Project.ID?
    @State private var search = ""
    @State private var settingsProject: Project?
    @State private var removingProject: Project?
    private let apps = ExternalApps()

    private var projects: [Project] {
        search.isEmpty ? model.projects : model.projects.filter { $0.name.localizedCaseInsensitiveContains(search) }
    }

    var body: some View {
        List(selection: $selection) {
            ForEach(projects) { project in
                Label {
                    VStack(alignment: .leading) {
                        Text(project.name)
                        Text(subtitle(for: project)).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    ProjectIcon(repoPath: project.repoPath,
                                version: model.tasks(in: project.id).compactMap(\.mergedAt).max())
                }
                .padding(.vertical, 5)
                // Tasks waiting on the user; a zero badge is hidden.
                .badge(model.tasks(in: project.id).filter { [.needsInput, .blocked, .conflict, .completed].contains($0.status) }.count)
                .contextMenu {
                    Menu("Open in") {
                        ForEach(apps.installedEditors()) { app in
                            Button(app.displayName) { apps.open(project.repoURL, in: app) }
                        }
                        Divider()
                        ForEach(apps.installedTerminals(), id: \.self) { terminal in
                            Button(apps.name(of: terminal)) { apps.open(project.repoURL, withApp: terminal) }
                        }
                    }
                    Button("Settings…") { settingsProject = project }
                    Button("Remove", role: .destructive) { removingProject = project }
                }
            }
            // Offsets refer to the full list, so reordering is off while filtering.
            .onMove(perform: search.isEmpty ? { model.moveProjects(from: $0, to: $1) } : nil)
        }
        .listStyle(.sidebar)
        .searchable(text: $search, placement: .sidebar)
        .contentMargins(.top, 8, for: .scrollContent)
        .safeAreaInset(edge: .bottom, alignment: .leading) {
            Button(action: addProject) { Label("New Project", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(12)
        }
        .sheet(item: $settingsProject) { ProjectSettingsView(projectID: $0.id) }
        .confirmationDialog("Remove “\(removingProject?.name ?? "")”?",
                            isPresented: Binding(get: { removingProject != nil }, set: { if !$0 { removingProject = nil } }),
                            presenting: removingProject) { project in
            Button("Remove", role: .destructive) { Task { await model.removeProject(project.id) } }
        } message: { _ in
            Text("Its tasks are deleted without merging. The repository itself is not touched.")
        }
    }

    private func subtitle(for project: Project) -> String {
        let open = model.tasks(in: project.id).filter { $0.status != .merged }
        let running = open.filter { $0.status == .working }.count
        let noun = open.count == 1 ? "task" : "tasks"
        if open.isEmpty { return "No tasks" }
        return running == 0 ? "\(open.count) \(noun)" : "\(running) of \(open.count) \(noun) running"
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            let known = Set(model.projects.map(\.id))
            guard let project = await model.addProject(at: url) else { return }
            selection = project.id
            // A new project opens its settings, so permissions and commands can be reviewed first.
            if !known.contains(project.id) { settingsProject = project }
        }
    }
}
