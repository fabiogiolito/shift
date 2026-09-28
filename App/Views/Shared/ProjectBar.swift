import SwiftUI
import AppKit
import ShiftCore

/// The project's options, along the bottom of the task list and task detail.
struct ProjectBar: View {
    @Environment(AppModel.self) private var model
    let project: Project
    @State private var branches: [String] = []
    @State private var showingSettings = false

    var body: some View {
        // The current value is always offered, so the menu is valid before branches load.
        let branchOptions = branches.contains(project.baseBranch) ? branches : [project.baseBranch] + branches

        HStack(spacing: 16) {
            Menu {
                Button("Show in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: project.repoPath)
                }
                Button("Project Settings…") { showingSettings = true }
            } label: {
                Label((project.repoPath as NSString).abbreviatingWithTildeInPath, systemImage: "folder")
            }
            .help("Repository")

            Menu {
                Picker("Base branch", selection: binding(\.baseBranch)) {
                    ForEach(branchOptions, id: \.self) { Text($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(project.baseBranch, systemImage: "arrow.triangle.branch")
            }
            .help("Base branch")

            Menu {
                Picker("Agent", selection: binding(\.defaultAgent)) {
                    ForEach(AgentKind.allCases) { kind in
                        let installed = model.installedAgents[kind] != nil
                        Label(installed ? kind.displayName : "\(kind.displayName) (not installed)", image: kind.icon)
                            .tag(kind)
                            .disabled(!installed)
                    }
                }
                .pickerStyle(.inline)
            } label: {
                Label(project.defaultAgent.displayName, image: project.defaultAgent.icon)
            }
            .help("Agent for new tasks")

            Menu {
                ModelPicker(agent: project.defaultAgent, selection: binding(\.defaultModel))
                    .pickerStyle(.inline)
            } label: {
                Label(model.modelName(project.defaultModel, for: project.defaultAgent), systemImage: "cpu")
            }
            .help("Model")

            Menu {
                Picker("Permissions", selection: binding(\.permissions)) {
                    ForEach(AgentPermissions.allCases) { Label($0.displayName, systemImage: $0.symbol).tag($0) }
                }
                .pickerStyle(.inline)
            } label: {
                Label(project.permissions.displayName, systemImage: project.permissions.symbol)
            }
            .help("Agent permissions")

            Spacer()

            if let usage = model.usage[project.defaultAgent], let window = usage.tightest {
                Text(Self.describe(window))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .help(usage.windows.map { "\($0.name) limit: \(Self.describe($0, named: false))" }
                        .joined(separator: "\n"))
            }
        }
        .menuStyle(.borderlessButton)
        .labelStyle(.titleAndIcon)
        .fixedSize(horizontal: false, vertical: true)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .task(id: project.id) { branches = await model.branches(for: project.id) }
        .task(id: project.defaultAgent) {
            // ponytail: polled; the Claude endpoint rate-limits, so not much more often than this.
            while !Task.isCancelled {
                await model.refreshUsage(project.defaultAgent)
                try? await Task.sleep(for: .seconds(300))
            }
        }
        .sheet(isPresented: $showingSettings) { ProjectSettingsView(projectID: project.id) }
        .focusedSceneValue(\.openProjectSettings) { showingSettings = true }
    }

    /// "5-hour limit 58% left · resets 3:40 PM"
    private static func describe(_ window: AgentUsage.Window, named: Bool = true) -> String {
        var text = (named ? "\(window.name) limit " : "") + "\(Int(window.percentLeft().rounded()))% left"
        if let resetsAt = window.resetsAt, resetsAt > .now {
            let time = Calendar.current.isDateInToday(resetsAt)
                ? resetsAt.formatted(date: .omitted, time: .shortened)
                : resetsAt.formatted(.dateTime.weekday().hour().minute())
            text += " · resets \(time)"
        }
        return text
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<Project, Value>) -> Binding<Value> {
        Binding(get: { project[keyPath: keyPath] }, set: {
            var updated = project
            updated[keyPath: keyPath] = $0
            model.updateProject(updated)
        })
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
