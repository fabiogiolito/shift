import SwiftUI
import ShiftCore

/// Each thing Shift needs on this Mac, checked when shown, with a way to fix it: the setup sheet at that step.
struct SetupSettingsView: View {
    @Environment(SetupFlow.self) private var flow
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Form {
            Section {
                row("Command Line Tools", systemImage: SetupStep.commandLineTools.symbol, step: .commandLineTools)
                row("Node.js", systemImage: SetupStep.node.symbol, step: .node)
                ForEach(AgentKind.allCases) { agent in agentRow(agent) }
                row("Git identity", systemImage: SetupStep.gitIdentity.symbol, step: .gitIdentity)
                row("GitHub", systemImage: SetupStep.github.symbol, step: .github)
                row("Notifications", systemImage: SetupStep.notifications.symbol, step: .notifications)
                row("Tailscale", systemImage: SetupStep.tailscale.symbol, step: .tailscale)
            } footer: {
                Text("Commits need a Git name and email. Without GitHub, Shift can't open pull requests or follow them. Tailscale lets your iPhone reach this Mac.")
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .formStyle(.grouped)
        .labelStyle(FixedIconLabelStyle())
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
        .task {
            await flow.refresh()
            // ponytail: polls while shown; Tailscale has no change notification we can observe.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(3))
                await flow.refreshTailscale()
            }
        }
    }

    private func row(_ title: String, systemImage: String, step: SetupStep) -> some View {
        LabeledContent {
            status(step, flow.state(step), button: buttonTitle(step)) { open(step) }
        } label: {
            Label(title, systemImage: systemImage)
        }
    }

    /// Install it from the setup sheet; sign in right here.
    private func agentRow(_ agent: AgentKind) -> some View {
        LabeledContent {
            let installed = flow.installed[agent] ?? .notDone
            if installed == .done {
                status(.signIn, flow.signedIn[agent] ?? .notDone, button: "Sign In") { flow.signIn(agent) }
            } else {
                status(.agent, installed, button: "Install") {
                    flow.chosenAgents = [agent]
                    open(.agent)
                }
            }
        } label: {
            Label(agent.displayName, image: agent.icon)
        }
    }

    private func status(_ step: SetupStep, _ state: SetupState, button: String, action: @escaping () -> Void) -> some View {
        // The button alone says it isn't done.
        HStack {
            if state != .notDone && state != .skipped {
                SetupStateLabel(step: step, state: state) { EmptyView() }
            }
            if state != .done && state != .working {
                Button(button, action: action)
            }
        }
    }

    private func buttonTitle(_ step: SetupStep) -> String {
        switch step {
        case .github: "Connect"
        case .gitIdentity: "Create"
        case .notifications: "Turn On"
        case .tailscale: flow.tailscaleOff ? "Turn On" : MacSetup.hasTailscaleApp() ? "Set Up" : "Install"
        default: "Install"
        }
    }

    private func open(_ step: SetupStep) {
        flow.start([step])
        openWindow(id: "main") // the sheet is on the main window
    }
}

/// The icon in a fixed-width column, so every row's title starts at the same place.
private struct FixedIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 8) {
            configuration.icon.frame(width: 22)
            configuration.title
        }
    }
}
