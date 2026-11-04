import SwiftUI
import AppKit
import ShiftCore

struct ProjectsSidebar: View {
    @Environment(AppModel.self) private var model
    @Binding var selection: Project.ID?
    @State private var search = ""
    @State private var settingsProject: Project?
    @State private var removingProject: Project?
    @State private var scrolledUnderBar = false

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
                    OpenInMenu(directory: project.repoURL, project: project)
                    if !project.isApp {
                        // Stops the dev servers of its base and its tasks, for their memory.
                        Button(project.serversOff ? "Turn Servers On" : "Turn Servers Off") {
                            var updated = project
                            updated.serversOff.toggle()
                            model.updateProject(updated)
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
        // A background and divider only once projects scroll under New Project, like the task prompt bar.
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Button(action: addProject) { Label("New Project", systemImage: "plus") }
                .buttonStyle(.borderless)
                .padding(.horizontal, 12)
                .frame(maxWidth: .infinity, minHeight: ProjectBar.height, maxHeight: ProjectBar.height, alignment: .leading)
                .background(scrolledUnderBar ? AnyShapeStyle(.bar) : AnyShapeStyle(.clear))
                .overlay(alignment: .top) { if scrolledUnderBar { Divider() } }
        }
        .onScrollGeometryChange(for: Bool.self) { geo in
            geo.contentOffset.y + geo.containerSize.height - geo.contentInsets.bottom < geo.contentSize.height - 1
        } action: { scrolledUnderBar = $1 }
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
        Project.summary(of: model.tasks(in: project.id)) + (project.serversOff && !project.isApp ? " · Servers off" : "")
    }

    private func addProject() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Add"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task {
            var initializingGit = false
            if !(await model.isRepository(url)) {
                let alert = NSAlert()
                alert.messageText = "This folder isn't a Git repository."
                alert.informativeText = "Initialize Git to use it with Shift?"
                alert.addButton(withTitle: "Initialize Git")
                alert.addButton(withTitle: "Cancel")
                guard alert.runModal() == .alertFirstButtonReturn else { return }
                initializingGit = true
            }
            let known = Set(model.projects.map(\.id))
            guard let project = await model.addProject(at: url, initializingGit: initializingGit) else { return }
            selection = project.id
            // A new project opens its settings, so permissions and commands can be reviewed first.
            if !known.contains(project.id) { settingsProject = project }
        }
    }
}
