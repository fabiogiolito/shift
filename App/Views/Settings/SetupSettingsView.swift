import SwiftUI
import ShiftCore

/// Each thing Shift needs on this Mac, with its state and a way to fix it. Opens the setup window at that step.
/// Phase 1 shows `SetupFlow`'s fake states.
struct SetupSettingsView: View {
    @Environment(SetupFlow.self) private var flow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                row("Command Line Tools", systemImage: SetupStep.commandLineTools.symbol, step: .commandLineTools)
                ForEach(AgentKind.allCases) { kind in
                    row(kind.displayName, image: kind.icon, step: .agent,
                        state: flow.agents.contains(kind) ? flow.state(.agent) : .notDone)
                }
                row("Git identity", systemImage: SetupStep.gitIdentity.symbol, step: .gitIdentity)
                row("GitHub", systemImage: SetupStep.github.symbol, step: .github)
            } footer: {
                Text("Commits need a Git name and email. Without GitHub, Shift can't open pull requests or follow them.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }

    private func row(_ title: String, systemImage: String? = nil, image: String? = nil, step: SetupStep,
                     state: SetupState? = nil) -> some View {
        let state = state ?? flow.state(step)
        return LabeledContent {
            HStack {
                SetupStateLabel(step: step, state: state == .skipped ? .notDone : state) {
                    Text(step.missingTitle).foregroundStyle(.secondary)
                }
                if state != .done && state != .working {
                    Button(step == .github ? "Connect" : "Fix") {
                        flow.page = .step(step)
                        openWindow(id: SetupWindow.id)
                    }
                }
            }
        } label: {
            if let image { Label(title, image: image) } else { Label(title, systemImage: systemImage ?? "") }
        }
    }
}
