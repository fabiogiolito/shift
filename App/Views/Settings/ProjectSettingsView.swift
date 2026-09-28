import SwiftUI
import ShiftCore

struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let projectID: Project.ID
    @State private var draft: Project?
    @State private var branches: [String] = []
    /// Chosen in the picker; nil follows the project (an app has a build command).
    @State private var isApp: Bool?

    init(projectID: Project.ID) {
        self.projectID = projectID
    }

    var body: some View {
        Group {
            if let draft {
                form(Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }))
            } else {
                ContentUnavailableView("Project not found", systemImage: "folder.badge.questionmark")
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if let draft { model.updateProject(draft) }
                    dismiss()
                }
                // An app is a project with a build command: without one, App build would not stick.
                .disabled(draft?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true
                          || (isApp == true && draft?.isApp == false))
            }
        }
        .task {
            if draft == nil { draft = model.project(projectID) }
            branches = await model.branches(for: projectID)
        }
    }

    private func form(_ project: Binding<Project>) -> some View {
        let current = project.wrappedValue
        let found = model.instructionFiles(for: projectID)
        // The current value is always offered, so the picker is valid before branches load.
        let branchOptions = branches.contains(current.baseBranch) ? branches : [current.baseBranch] + branches

        return Form {
            Section("General") {
                TextField("Name", text: project.name)
                LabeledContent("Repository") {
                    Text(current.repoPath).textSelection(.enabled).lineLimit(1).truncationMode(.head)
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: current.repoPath)
                    }
                }
                Picker("Base branch", selection: project.baseBranch) {
                    ForEach(branchOptions, id: \.self) { Text($0) }
                }
            }

            Section {
                Picker("Permissions", selection: project.permissions) {
                    ForEach(AgentPermissions.allCases) { Text($0.displayName).tag($0) }
                }
            } header: {
                Text("Agent")
            } footer: {
                Text(current.permissions.summary)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section {
                Picker("Default agent", selection: project.defaultAgent) {
                    ForEach(AgentKind.allCases) { kind in
                        let installed = model.installedAgents[kind] != nil
                        Label(installed ? kind.displayName : "\(kind.displayName) (not installed)", image: kind.icon)
                            .tag(kind)
                            .disabled(!installed)
                    }
                }
                ForEach(["AGENTS.md", "CLAUDE.md"], id: \.self) { name in
                    LabeledContent(name) {
                        if found.contains(name) {
                            Text("Found")
                            Button("Open") {
                                NSWorkspace.shared.open(current.repoURL.appendingPathComponent(name))
                            }
                        } else {
                            Text("Not found")
                        }
                    }
                }
            }

            Section {
                TextField("Setup", text: project.setupCommand,
                          prompt: Text(verbatim: "pnpm install && cp \"$SHIFT_REPO/.env\" ."))
                    .autocorrectionDisabled()
                Picker("Test with", selection: Binding(
                    get: { isApp ?? current.isApp },
                    set: { isApp = $0; if !$0 { project.wrappedValue.buildCommand = "" } })) {
                    Text("Dev server").tag(false)
                    Text("App build").tag(true)
                }
                if isApp ?? current.isApp {
                    TextField("Build", text: project.buildCommand, prompt: Text("Required, e.g. scripts/build.sh"))
                        .autocorrectionDisabled()
                } else {
                    TextField("Start server", text: project.serverCommand, prompt: Text("pnpm dev --port $PORT"))
                        .autocorrectionDisabled()
                    LabeledContent("Port", value: "Automatic")
                }
            } header: {
                Text("Development")
            } footer: {
                Text(isApp ?? current.isApp ? """
                    Setup runs once in each new task's worktree before the agent starts. \
                    Build runs in the task's worktree when you click Build; if the last line it prints is the path of a .app, Shift opens it.
                    """ : """
                    Setup runs once in each new task's worktree before the agent starts. \
                    The server runs in each task's worktree with PORT set; leave it empty if the project has no dev server.
                    """)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Section("Advanced") {
                LabeledContent("Worktree location", value: "Managed automatically")
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    let model = AppModel.preview()
    return ProjectSettingsView(projectID: model.projects[0].id).environment(model)
}
