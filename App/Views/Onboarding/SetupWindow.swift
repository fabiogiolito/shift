import SwiftUI
import ShiftCore

/// The setup assistant: one step at a time, then "You're ready". Phase 1 opens only from Help › Test Onboarding.
struct SetupWindow: View {
    static let id = "setup"
    @Environment(SetupFlow.self) private var flow
    @Environment(\.dismissWindow) private var dismissWindow

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch flow.page {
                case .step(let step): SetupStepView(step: step).id(step)
                case .ready: ReadyView { dismissWindow(id: Self.id) }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)

            Divider()
            footer
            #if DEBUG
            SetupDebugBar()
            #endif
        }
        .frame(width: 620, height: 600)
    }

    private var footer: some View {
        HStack {
            switch flow.page {
            case .step(let step) where SetupStep.projectSteps.contains(step):
                Text("Project setup").foregroundStyle(.secondary)
            case .step(let step):
                Text("Step \(SetupStep.firstLaunch.firstIndex(of: step)! + 1) of \(SetupStep.firstLaunch.count)")
                    .foregroundStyle(.secondary)
            case .ready:
                EmptyView()
            }
            Spacer()
            if let back = flow.move(by: -1) {
                Button("Back") { flow.page = back }
            }
            if case .step(let step) = flow.page {
                Button("Continue") {
                    if let next = flow.move(by: 1) { flow.page = next } else { dismissWindow(id: Self.id) }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(![.done, .skipped].contains(flow.state(step)))
            }
        }
        .controlSize(.large)
        .padding(20)
    }
}

/// A step's header, its own content, and its state.
private struct SetupStepView: View {
    let step: SetupStep
    @Environment(SetupFlow.self) private var flow
    @State private var showsManual = false

    var body: some View {
        VStack(spacing: 20) {
            VStack(spacing: 8) {
                Image(systemName: step.symbol)
                    .font(.system(size: 44))
                    .foregroundStyle(.tint)
                    .frame(height: 56)
                Text(step.title).font(.title).bold()
                Text(summary)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }

            content

            SetupStatus(step: step)

            if let manual = flow.state(step) == .done ? nil
                : step.manualSteps(agents: flow.agents, packageManager: flow.packageManager) {
                DisclosureGroup("Do it yourself", isExpanded: $showsManual) {
                    Text(manual)
                        .font(.callout.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                }
                .frame(maxWidth: 420)
            }
        }
        .padding(.horizontal, 48)
        .padding(.top, 40)
    }

    private var summary: String {
        step == .node ? "It runs its dev server with Node.js and \(flow.packageManager)." : step.summary
    }

    @ViewBuilder private var content: some View {
        @Bindable var flow = flow
        switch step {
        case .agent:
            Form {
                Section {
                    ForEach(AgentKind.allCases) { kind in
                        AgentChoiceRow(kind: kind, isSelected: flow.agents.contains(kind)) { flow.agent = kind }
                    }
                }
                Section {
                    Toggle("Install both", isOn: $flow.installBoth).toggleStyle(.checkbox)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 440, height: 210)
        case .signIn:
            Form {
                ForEach(flow.agents) { kind in
                    LabeledContent {
                        SetupStateLabel(step: step, state: flow.state(step)) {
                            Button("Sign In") { flow.perform(step) }
                        }
                    } label: {
                        Label(kind.displayName, image: kind.icon)
                    }
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 440, height: CGFloat(flow.agents.count) * 44 + 40)
        case .gitIdentity:
            Form {
                TextField("Name", text: $flow.gitName, prompt: Text(verbatim: "Jane Appleseed"))
                TextField("Email", text: $flow.gitEmail, prompt: Text(verbatim: "jane@example.com"))
            }
            .formStyle(.grouped)
            .scrollDisabled(true)
            .frame(width: 440, height: 120)
        default:
            EmptyView()
        }
    }
}

private struct AgentChoiceRow: View {
    let kind: AgentKind
    let isSelected: Bool
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
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.tertiary))
                    .imageScale(.large)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }
}

/// The step's main button, or how it went.
private struct SetupStatus: View {
    let step: SetupStep
    @Environment(SetupFlow.self) private var flow

    var body: some View {
        let state = flow.state(step)
        VStack(spacing: 12) {
            switch state {
            case .notDone:
                // Sign-in has a button on each row.
                if step != .signIn {
                    Button(step.actionTitle) { flow.perform(step) }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
                if step.canSkip {
                    Button("Skip") { flow.skip(step) }.buttonStyle(.link)
                }
            case .working, .done:
                if step != .signIn { SetupStateLabel(step: step, state: state) { EmptyView() } }
            case .failed(let error):
                Label(error, systemImage: "xmark.octagon.fill")
                    .foregroundStyle(.red)
                HStack {
                    Button("Help Me Fix This") {}
                    Button("Try Again") { flow.perform(step) }.buttonStyle(.borderedProminent)
                }
                .controlSize(.large)
            case .skipped:
                if let warning = step.skipWarning {
                    Label(warning, systemImage: "exclamationmark.triangle.fill")
                        .symbolRenderingMode(.multicolor)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: 420)
                }
                Button(step.actionTitle) { flow.perform(step) }.controlSize(.large)
            }
        }
        .multilineTextAlignment(.center)
    }
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
        case .done:
            Label(step.doneTitle, systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failed:
            Label("Failed", systemImage: "xmark.octagon.fill")
                .foregroundStyle(.red)
        case .skipped:
            Text("Skipped").foregroundStyle(.secondary)
        }
    }
}

private struct ReadyView: View {
    let addProject: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.seal.fill")
                .font(.system(size: 56))
                .foregroundStyle(.green)
            Text("You're ready").font(.title).bold()
            Text("Add a project to start your first task.")
                .foregroundStyle(.secondary)
            Button("Add Project", action: addProject)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .padding(.top, 8)
        }
        .frame(maxHeight: .infinity)
    }
}

#if DEBUG
/// Switches the step's fake state and jumps between steps. Debug builds only.
private struct SetupDebugBar: View {
    @Environment(SetupFlow.self) private var flow

    var body: some View {
        HStack {
            if case .step(let step) = flow.page {
                Picker("State", selection: stateBinding(step)) {
                    Text("Not Done").tag("notDone")
                    Text("Working").tag("working")
                    Text("Done").tag("done")
                    Text("Failed").tag("failed")
                    Text("Skipped").tag("skipped")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }
            Spacer()
            Menu("Go To") {
                ForEach(SetupStep.firstLaunch) { step in Button(step.title) { flow.page = .step(step) } }
                Button("You're ready") { flow.page = .ready }
                Divider()
                ForEach(SetupStep.projectSteps) { step in Button(step.title) { flow.page = .step(step) } }
                Divider()
                Button("Start Over") { flow.reset() }
            }
            .fixedSize()
        }
        .controlSize(.small)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.12))
    }

    private func stateBinding(_ step: SetupStep) -> Binding<String> {
        Binding {
            switch flow.state(step) {
            case .notDone: "notDone"
            case .working: "working"
            case .done: "done"
            case .failed: "failed"
            case .skipped: "skipped"
            }
        } set: { tag in
            flow.states[step] = switch tag {
            case "working": .working
            case "done": .done
            case "failed": .failed(step.sampleError)
            case "skipped": .skipped
            default: .notDone
            }
        }
    }
}
#endif
