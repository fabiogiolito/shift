import CoreGraphics
import SwiftUI
import ShiftCore

struct ProjectSettingsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let projectID: Project.ID
    @State private var draft: Project?
    @State private var branches: [String] = []
    @State private var creatingBranch = false
    /// Other projects: chosen in the picker; nil follows the project (an app has a build command).
    @State private var isApp: Bool?

    init(projectID: Project.ID) {
        self.projectID = projectID
    }

    var body: some View {
        Group {
            if let draft {
                form(Binding(get: { self.draft ?? draft }, set: { self.draft = $0 }))
            } else {
                EmptyState("Project not found", systemImage: "folder.badge.questionmark")
            }
        }
        .frame(minWidth: 480, minHeight: 420)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") {
                    if var draft {
                        // The paths field keeps what's typed as is, separators included.
                        for index in draft.buildTargets.indices {
                            draft.buildTargets[index].paths = draft.buildTargets[index].paths
                                .map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                        }
                        model.updateProject(draft)
                    }
                    dismiss()
                }
                // Other than a native app (its command can come later), an app is a project with a build command:
                // without one, it would not stay an app.
                .disabled(draft?.name.trimmingCharacters(in: .whitespaces).isEmpty ?? true
                          || (draft.map { usesBuild($0) && !$0.isApp } ?? false))
            }
        }
        .task {
            if draft == nil { draft = model.project(projectID) }
            branches = await model.branches(for: projectID)
            await model.refreshPushState(projectID: projectID)
        }
    }

    /// Tested by building or running an app, not on a dev server.
    private func usesBuild(_ project: Project) -> Bool {
        switch project.type {
        case .staticWebsite, .dynamicWebsite: false
        case .nativeApp, .electronApp: true
        case .other: isApp ?? project.isApp
        }
    }

    /// One command stays one field. The list shows once there are more targets, or one that isn't what the type implies.
    private func showsTargetList(_ project: Project) -> Bool {
        project.buildTargets.count > 1 || project.buildTargets.first.map { $0.kind != project.defaultTargetKind } == true
    }

    /// Follows the target by id, so it stays right while the list is reordered or shrinks.
    private func binding(_ target: BuildTarget, in project: Binding<Project>) -> Binding<BuildTarget> {
        Binding(get: { project.wrappedValue.buildTargets.first { $0.id == target.id } ?? target },
                set: { new in
                    guard let index = project.wrappedValue.buildTargets.firstIndex(where: { $0.id == target.id }) else { return }
                    project.wrappedValue.buildTargets[index] = new
                })
    }

    /// The first one added to a single command joins it, so there are two to tell apart.
    private func addTarget(to project: Binding<Project>) {
        let kind = project.wrappedValue.defaultTargetKind
        if project.wrappedValue.buildTargets.isEmpty {
            project.wrappedValue.buildTargets = [BuildTarget(name: "App", command: "", kind: kind)]
        }
        let number = project.wrappedValue.buildTargets.count + 1
        project.wrappedValue.buildTargets.append(BuildTarget(name: "Target \(number)", command: "", kind: kind))
    }

    private func moveTarget(_ target: BuildTarget, by offset: Int, in project: Binding<Project>) {
        guard let index = project.wrappedValue.buildTargets.firstIndex(where: { $0.id == target.id }),
              project.wrappedValue.buildTargets.indices.contains(index + offset) else { return }
        project.wrappedValue.buildTargets.swapAt(index, index + offset)
    }

    @ViewBuilder private func targetSection(_ target: BuildTarget, in project: Binding<Project>) -> some View {
        let row = binding(target, in: project)
        let targets = project.wrappedValue.buildTargets
        Section {
            TextField("Name", text: row.name)
            Picker("Kind", selection: row.kind) {
                ForEach(BuildTarget.Kind.allCases) { Text($0.displayName).tag($0) }
            }
            commandField("Command", text: row.command, prompt: Text(verbatim: "scripts/build.sh"))
            // Split on commas and kept as typed: tidying it here would undo the separator being typed. Done tidies it.
            TextField("Paths", text: Binding(
                get: { row.wrappedValue.paths.joined(separator: ",") },
                set: { row.wrappedValue.paths = $0.split(separator: ",", omittingEmptySubsequences: false).map(String.init) }),
                      prompt: Text(verbatim: "App/, Shared/"))
                .autocorrectionDisabled()
        } header: {
            HStack {
                Text(target.name)
                Spacer()
                Button { moveTarget(target, by: -1, in: project) } label: {
                    Label("Move Up", systemImage: "chevron.up").labelStyle(.iconOnly)
                }
                .disabled(targets.first?.id == target.id)
                Button { moveTarget(target, by: 1, in: project) } label: {
                    Label("Move Down", systemImage: "chevron.down").labelStyle(.iconOnly)
                }
                .disabled(targets.last?.id == target.id)
                Button { project.wrappedValue.buildTargets.removeAll { $0.id == target.id } } label: {
                    Label("Remove", systemImage: "trash").labelStyle(.iconOnly)
                }
            }
            .buttonStyle(.borderless)
        }
    }

    /// A terminal command: its value is monospaced, its label is not.
    private func commandField(_ label: String, text: Binding<String>, prompt: Text) -> some View {
        LabeledContent(label) {
            TextField(label, text: text, prompt: prompt)
                .labelsHidden()
                .multilineTextAlignment(.trailing)
                .fontDesign(.monospaced)
                .autocorrectionDisabled()
        }
    }

    private func form(_ project: Binding<Project>) -> some View {
        let current = project.wrappedValue
        // The current value is always offered, so the picker is valid before branches load.
        let branchOptions = branches.contains(current.baseBranch) ? branches : [current.baseBranch] + branches

        return Form {
            Section("General") {
                TextField("Name", text: project.name)
                LabeledContent("Folder") {
                    Text(current.repoPath).textSelection(.enabled).lineLimit(1).truncationMode(.head)
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: current.repoPath)
                    }
                }
                HStack {
                    Picker("Base branch for new tasks", selection: project.baseBranch) {
                        ForEach(branchOptions, id: \.self) { Text($0) }
                    }
                    Button("New Branch…") { creatingBranch = true }
                }
                .sheet(isPresented: $creatingBranch) {
                    NewBranchSheet(projectID: projectID, branches: branches, source: current.baseBranch) { name in
                        project.wrappedValue.baseBranch = name
                        Task { branches = await model.branches(for: projectID) }
                    }
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
                ModelPicker(agent: current.defaultAgent, selection: project.defaultModel)
            }

            Section {
                Picker("Project type", selection: Binding(
                    get: { current.type },
                    set: { type in
                        project.wrappedValue.type = type
                        isApp = nil
                        Task { draft = await model.project(current, as: type) }
                    })) {
                    ForEach(ProjectType.allCases) { Text($0.displayName).tag($0) }
                }
                if current.type != .staticWebsite {
                    commandField("Setup", text: project.setupCommand,
                                 prompt: Text(verbatim: "pnpm install && cp \"$SHIFT_REPO/.env\" ."))
                }
                if current.type == .other {
                    Picker("Test with", selection: Binding(
                        get: { isApp ?? current.isApp },
                        set: {
                            isApp = $0
                            if !$0 { project.wrappedValue.buildTargets = [] }
                            else if !project.wrappedValue.isApp { project.wrappedValue.buildTargets = current.defaultBuildTargets }
                        })) {
                        Text("Dev server").tag(false)
                        Text("App build").tag(true)
                    }
                }
                if usesBuild(current) && showsTargetList(current) {
                    // Each target has a section of its own, below.
                } else if current.runsApp {
                    commandField("Run", text: project.buildCommand, prompt: Text("Required, e.g. pnpm run dev"))
                    Button("Add Target") { addTarget(to: project) }
                } else if usesBuild(current) {
                    commandField("Build", text: project.buildCommand,
                                 prompt: Text(current.type == .nativeApp ? "Detected when you build, e.g. scripts/build.sh" : "Required, e.g. scripts/build.sh"))
                    Button("Add Target") { addTarget(to: project) }
                } else if current.type != .staticWebsite {
                    commandField("Start server", text: project.serverCommand, prompt: Text("pnpm dev --port $PORT"))
                }
            } header: {
                Text("Development")
            } footer: {
                Text(current.type == .staticWebsite ? "Each task's files are served on localhost, on a port of their own."
                     : "Setup runs once in each new task's worktree before the agent starts. " + (
                    usesBuild(current) && showsTargetList(current) ? "Each target runs in the task's worktree when you click its button."
                    : current.runsApp ? "Run opens the task's copy of the app when you click Run, with its own empty data, so tasks can run side by side."
                    : usesBuild(current) ? "Build runs in the task's worktree when you click Build; if the last line it prints is the path of a .app, Shift opens it."
                    : "The server runs in each task's worktree with PORT set; leave it empty if the project has no dev server."))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if usesBuild(current) && showsTargetList(current) {
                ForEach(current.buildTargets) { targetSection($0, in: project) }
                Section {
                    Button("Add Target") { addTarget(to: project) }
                } footer: {
                    Text("Mac app and iOS Simulator targets print the path of their .app last, and Shift opens it. Run keeps running until you stop it. Script shows its log. The build button offers the target whose paths, such as App/, cover most of what a task changed. Commands get the target's name in SHIFT_TARGET.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }

            Section {
                Toggle("Take progress screenshots", isOn: project.takesScreenshots)
                    .onChange(of: current.takesScreenshots) { _, isOn in
                        // Capturing a Mac app's window needs it, and the agent runs as part of Shift.
                        if isOn && usesBuild(current) { CGRequestScreenCaptureAccess() }
                    }
            } footer: {
                Text(usesBuild(current)
                     ? "The agent builds and runs the app to capture the view each prompt changes, and how it looked before the task's first change, which takes longer. A Mac app needs Screen Recording permission for Shift. They show above the changed files."
                     : "Keeps screenshots of what each prompt changes, and of how the page looked before the task's first change. They show above the changed files.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            if let remote = model.pushStates[projectID]?.remote {
                Section {
                    Toggle("Push task branches to \(remote)", isOn: project.pushTaskBranches)
                    Toggle("Open pull requests instead of merging", isOn: project.opensPullRequests)
                } header: {
                    Text("Git")
                } footer: {
                    Text("Pushes each task's branch when the task is finished. With pull requests on, a finished task's main button opens one on GitHub, and merging moves to its dropdown. With the GitHub CLI (gh) signed in, Shift follows the pull request: it shows when it's open, pushes new changes to it, and marks the task Merged once it's merged.")
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .formStyle(.grouped)
    }
}

#Preview {
    let model = AppModel.preview()
    return ProjectSettingsView(projectID: model.projects[0].id).environment(model)
}
