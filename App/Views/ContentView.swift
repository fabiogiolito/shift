import SwiftUI
import ShiftCore

struct ContentView: View {
    @Environment(AppModel.self) private var model
    @State private var selectedProject: Project.ID?
    /// Persisted so the app reopens on the task the user was looking at.
    @AppStorage("selectedTask") private var selectedTask: TaskItem.ID?
    /// The project bar spans the task list and detail columns but not the sidebar. No split view placement
    /// does that, so it's laid over the window's bottom trailing corner, sized from the two columns.
    @State private var listWidth: CGFloat = 0
    @State private var detailWidth: CGFloat = 0
    @State private var barHeight: CGFloat = 0

    var body: some View {
        let project = selectedProject.flatMap(model.project)
        NavigationSplitView {
            ProjectsSidebar(selection: $selectedProject)
                .navigationSplitViewColumnWidth(min: 180, ideal: 220)
        } content: {
            Group {
                if let project {
                    TaskListView(project: project, selection: $selectedTask)
                        .toolbar {
                            ToolbarItem(placement: .navigation) {
                                // Lines the name up with the list's section headers.
                                Text(project.name).font(.title3).padding(.leading, 6)
                            }
                                .sharedBackgroundVisibility(.hidden)
                        }
                } else if model.projects.isEmpty {
                    ContentUnavailableView("No Projects", systemImage: "folder",
                                           description: Text("Add a Git repository with New Project."))
                } else {
                    ContentUnavailableView("No Project Selected", systemImage: "sidebar.left")
                }
            }
            // Full column size, so the bar's width is right whatever the column shows.
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding(.bottom, barHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { listWidth = $0 }
            .navigationSplitViewColumnWidth(min: 280, ideal: 360, max: 520)
        } detail: {
            Group {
                if let selectedTask, let project, model.task(selectedTask)?.projectID == project.id {
                    TaskDetailView(taskID: selectedTask).id(selectedTask)
                } else {
                    ContentUnavailableView("No Task Selected", systemImage: "checklist")
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .safeAreaPadding(.bottom, barHeight)
            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { detailWidth = $0 }
        }
        // The project and task names are toolbar items, one per column. With a window title, the detail
        // column's items would be pushed to its trailing edge instead of starting at its leading edge.
        .toolbar(removing: .title)
        .overlay(alignment: .bottomTrailing) {
            if let project {
                VStack(spacing: 0) {
                    Divider()
                    ProjectBar(project: project)
                }
                .frame(width: listWidth + detailWidth)
                .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { barHeight = $0 }
            }
        }
        .frame(minWidth: 960, minHeight: 600)
        // Opens on the selected task's project; otherwise clearing a mismatched project would drop the task,
        // e.g. when a notification click reopens the window on a task in another project.
        .onAppear {
            selectedProject = selectedProject ?? selectedTask.flatMap(model.task)?.projectID ?? model.projects.first?.id
        }
        .onChange(of: model.projects) {
            if selectedProject.flatMap(model.project) == nil { selectedProject = model.projects.first?.id }
        }
        // A notification click selects a task from outside; follow it to its project.
        .onChange(of: selectedTask) {
            if let projectID = selectedTask.flatMap(model.task)?.projectID { selectedProject = projectID }
        }
        .onChange(of: selectedProject) {
            if selectedTask.flatMap(model.task)?.projectID != selectedProject { selectedTask = nil }
        }
        .alert("Something Went Wrong", isPresented: Binding(get: { model.lastError != nil },
                                                           set: { if !$0 { model.lastError = nil } })) {
            Button("OK") {}
        } message: {
            Text(model.lastError ?? "")
        }
    }
}

#Preview {
    ContentView().environment(AppModel.preview())
}
