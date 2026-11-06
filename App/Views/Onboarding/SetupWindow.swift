import SwiftUI
import ShiftCore

/// The setup assistant: one step at a time, then "You're ready". Opens at first launch with what's missing, from
/// Settings › Setup for one item, and when an added project needs something.
/// Laid out like macOS's own setup panels: left-aligned, fixed size, actions at the bottom right.
struct SetupWindow: View {
    static let id = "setup"
    @Environment(SetupFlow.self) private var flow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Group {
                switch flow.page {
                case .step(let step): SetupStepView(step: step).id(step)
                case .ready: ReadyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            footer
        }
        .padding(.horizontal, 32)
        .padding(.top, 16)
        .padding(.bottom, 20)
        .frame(width: 520, height: 410)
    }

    private var footer: some View {
        HStack {
            if let back = flow.move(by: -1) {
                Button("Back") { flow.page = back }
            }
            Spacer()
            switch flow.page {
            case .ready:
                Button("Add Project") {
                    dismissWindow(id: Self.id)
                    NotificationCenter.default.post(name: .addProject, object: nil)
                }
                    .keyboardShortcut(.defaultAction)
            case .step(let step):
                let state = flow.state(step)
                if step.canSkip, state == .notDone || state.isFailed {
                    Button("Skip") { flow.skip(step) }
                }
                if state == .skipped {
                    Button(step.actionTitle) { flow.perform(step) }
                        .disabled(!flow.canPerform(step))
                }
                primaryButton(step, state)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .controlSize(.large)
    }

    /// Does the step's action, then moves on once it's done.
    @ViewBuilder private func primaryButton(_ step: SetupStep, _ state: SetupState) -> some View {
        switch state {
        case .done, .skipped:
            Button("Continue") {
                if let next = flow.move(by: 1) { flow.page = next } else { dismissWindow(id: Self.id) }
            }
        case .failed:
            Button("Try Again") { flow.perform(step) }
        case .working:
            Button(step.actionTitle) {}.disabled(true)
        case .notDone:
            // Sign-in has a button on each row.
            if step == .signIn {
                Button("Continue") {}.disabled(true)
            } else {
                Button(step.actionTitle) { flow.perform(step) }
                    .disabled(!flow.canPerform(step))
            }
        }
    }
}

/// A step's header, its own content, and how it went.
private struct SetupStepView: View {
    let step: SetupStep
    @Environment(SetupFlow.self) private var flow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: step.symbol)
                .font(.system(size: 32))
                .foregroundStyle(.tint)
                .frame(height: 40)
            VStack(alignment: .leading, spacing: 4) {
                if let progress = flow.progress(of: step) {
                    Text(progress).font(.subheadline).foregroundStyle(.secondary)
                }
                Text(flow.title(step)).font(.title2).bold()
                Text(flow.summary(step)).foregroundStyle(.secondary)
            }
            content
            SetupStatus(step: step)
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var content: some View {
        @Bindable var flow = flow
        switch step {
        case .agent:
            GroupBox {
                ForEach(AgentKind.allCases) { kind in
                    if kind != AgentKind.allCases.first { Divider() }
                    AgentChoiceRow(kind: kind, isSelected: flow.chosenAgents.contains(kind), state: flow.installed[kind] ?? .notDone) {
                        flow.toggle(kind)
                    }
                }
            }
        case .signIn:
            GroupBox {
                ForEach(flow.agents) { kind in
                    if kind != flow.agents.first { Divider() }
                    HStack {
                        Label(kind.displayName, image: kind.icon)
                        Spacer()
                        SetupStateLabel(step: step, state: flow.signedIn[kind] ?? .notDone) {
                            Button("Sign In") { flow.signIn(kind) }
                        }
                    }
                    .padding(4)
                    .frame(minHeight: 28)
                }
            }
        case .gitIdentity:
            Grid(alignment: .leading) {
                GridRow {
                    Text("Name").gridColumnAlignment(.trailing)
                    TextField("Name", text: $flow.gitName, prompt: Text(verbatim: "Jane Appleseed")).labelsHidden()
                }
                GridRow {
                    Text("Email")
                    TextField("Email", text: $flow.gitEmail, prompt: Text(verbatim: "jane@example.com")).labelsHidden()
                }
            }
        default:
            EmptyView()
        }
    }
}

/// Ticked to install. An installed agent shows that instead; a running or failed install, how it's going.
private struct AgentChoiceRow: View {
    let kind: AgentKind
    let isSelected: Bool
    let state: SetupState
    let select: () -> Void

    var body: some View {
        Button(action: select) {
            HStack(spacing: 12) {
                Image(kind.icon).imageScale(.large).frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(kind.displayName).font(.headline)
                        if kind == .claudeCode {
                            Text("Recommended")
                                .font(.caption.weight(.medium))
                                .padding(.horizontal, 6).padding(.vertical, 1)
                                .background(.tint.quaternary, in: .capsule)
                                .foregroundStyle(.tint)
                        }
                    }
                    Text(kind.tagline).font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                if state == .notDone {
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                        .imageScale(.large)
                } else {
                    SetupStateLabel(step: .agent, state: state) { EmptyView() }
                }
            }
            .padding(4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(state == .done || state == .working)
    }
}

/// How the step's action went. Its buttons are in the window's footer.
private struct SetupStatus: View {
    let step: SetupStep
    @Environment(SetupFlow.self) private var flow

    var body: some View {
        switch flow.state(step) {
        case .notDone:
            EmptyView()
        case let state where step == .signIn && !state.isFailed:
            EmptyView() // shown on each row
        case .failed(let error):
            VStack(alignment: .leading, spacing: 6) {
                Label(error, systemImage: "xmark.octagon.fill").foregroundStyle(.red)
                if flow.helper != nil {
                    Button("Help Me Fix This") { flow.askForHelp(with: step) }.buttonStyle(.link)
                }
            }
        case .skipped:
            if let warning = step.skipWarning {
                Label(warning, systemImage: "exclamationmark.triangle.fill")
                    .symbolRenderingMode(.multicolor)
                    .foregroundStyle(.secondary)
            }
        case let state:
            SetupStateLabel(step: step, state: state) { EmptyView() }
        }
    }
}

extension SetupState {
    var isFailed: Bool { if case .failed = self { true } else { false } }
}

/// Working, done, failed or skipped as a short line; `notDone` shows `action`.
struct SetupStateLabel<Action: View>: View {
    let step: SetupStep
    let state: SetupState
    @ViewBuilder let action: Action

    var body: some View {
        switch state {
        case .notDone:
            action
        case .working:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(step.workingTitle).foregroundStyle(.secondary)
            }
        // Icon last, so the icons line up on the right edge.
        case .done:
            HStack(spacing: 6) { Text(step.doneTitle); Image(systemName: "checkmark.circle.fill") }
                .foregroundStyle(.green)
        case .failed:
            HStack(spacing: 6) { Text("Failed"); Image(systemName: "xmark.octagon.fill") }
                .foregroundStyle(.red)
        case .skipped:
            Text("Skipped").foregroundStyle(.secondary)
        }
    }
}

private struct ReadyView: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 32))
                .foregroundStyle(.green)
                .frame(height: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("You're ready").font(.title2).bold()
                Text("Add a project to start your first task.").foregroundStyle(.secondary)
            }
        }
    }
}
