import SwiftUI
import ShiftCore

/// Everything Shift needs on a Mac, in one place: the setup window and Settings › Setup both draw from these.
/// Phase 1 is visuals only: `SetupFlow` holds fake states and its actions only move them. Phase 2 attaches the real
/// check and action to each step here.
enum SetupStep: String, CaseIterable, Identifiable {
    case commandLineTools, node, agent, signIn, gitIdentity, github
    /// Asked when a project that needs them is added, not at first launch.
    case packageManager, xcode

    static let firstLaunch: [SetupStep] = [.commandLineTools, .node, .agent, .signIn, .gitIdentity, .github]
    static let projectSteps: [SetupStep] = [.packageManager, .xcode]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .commandLineTools: "Command Line Tools"
        case .agent: "Choose your agent"
        case .signIn: "Sign in"
        case .gitIdentity: "Your name for commits"
        case .github: "Connect GitHub"
        case .node: "Node.js"
        case .packageManager: "This project needs a package manager"
        case .xcode: "This project needs Xcode"
        }
    }

    var symbol: String {
        switch self {
        case .commandLineTools: "terminal"
        case .agent: "sparkles"
        case .signIn: "person.crop.circle"
        case .gitIdentity: "signature"
        case .github: "arrow.triangle.pull"
        case .node: "cube"
        case .packageManager: "shippingbox"
        case .xcode: "hammer"
        }
    }

    var summary: String {
        switch self {
        case .commandLineTools: "Apple's developer tools, including Git. Shift needs them for every project."
        case .agent: "The coding agent that works on your tasks. Choose one or both."
        case .signIn: "Each agent needs your account. Signing in opens Terminal."
        case .gitIdentity: "Every commit is signed with a name and email."
        case .github: "Lets Shift open pull requests, follow them, and push your branches."
        case .node: "Most web projects need it to run."
        case .packageManager: "It installs its packages with a package manager Node.js doesn't include."
        case .xcode: "It builds a native app, which needs Xcode."
        }
    }

    var actionTitle: String {
        switch self {
        case .signIn: "Sign In"
        case .gitIdentity: "Save"
        case .github: "Connect GitHub"
        default: "Install"
        }
    }

    var workingTitle: String {
        switch self {
        case .signIn: "Waiting for sign-in…"
        case .gitIdentity: "Saving…"
        case .github: "Connecting…"
        default: "Installing…"
        }
    }

    var doneTitle: String {
        switch self {
        case .signIn: "Signed in"
        case .gitIdentity: "Saved"
        case .github: "Connected"
        default: "Installed"
        }
    }

    /// For Settings, when it isn't done.
    var missingTitle: String {
        switch self {
        case .signIn: "Not signed in"
        case .gitIdentity: "Not set"
        case .github: "Not connected"
        default: "Not installed"
        }
    }

    var canSkip: Bool { [.github, .packageManager, .xcode].contains(self) }

    /// What won't work if it's skipped.
    var skipWarning: String? {
        switch self {
        case .github: "Shift can't open pull requests or follow them, and pushing may fail. You can connect GitHub later in Settings."
        case .packageManager: "The project's dev server won't start until it's installed."
        case .xcode: "The project can't be built or run until Xcode is installed."
        default: nil
        }
    }
}

enum SetupState: Hashable {
    case notDone, working, done, failed(String), skipped
}

extension AgentKind {
    var tagline: String {
        self == .claudeCode ? "Anthropic's coding agent." : "OpenAI's coding agent."
    }
}

/// The setup window's place and each step's state. Phase 1: fake states; nothing is checked, installed or changed.
@MainActor @Observable
final class SetupFlow {
    enum Page: Hashable { case step(SetupStep), ready }

    var page: Page = .step(.commandLineTools)
    var states: [SetupStep: SetupState] = [:]
    var chosenAgents: Set<AgentKind> = [.claudeCode]
    var gitName = ""
    var gitEmail = ""
    var packageManager = "pnpm"

    var agents: [AgentKind] { AgentKind.allCases.filter(chosenAgents.contains) }

    func toggle(_ agent: AgentKind) {
        if chosenAgents.contains(agent) { chosenAgents.remove(agent) } else { chosenAgents.insert(agent) }
    }

    func state(_ step: SetupStep) -> SetupState { states[step] ?? .notDone }

    /// Phase 1: a short fake run that always succeeds.
    func perform(_ step: SetupStep) {
        states[step] = .working
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if states[step] == .working { states[step] = .done }
        }
    }

    /// What the step needs filled in before its action can run.
    func canPerform(_ step: SetupStep) -> Bool {
        switch step {
        case .agent: !chosenAgents.isEmpty
        case .gitIdentity:
            !gitName.trimmingCharacters(in: .whitespaces).isEmpty
                && gitEmail.wholeMatch(of: /\s*[^@\s]+@[^@\s]+\.[^@\s]+\s*/) != nil
        default: true
        }
    }

    func skip(_ step: SetupStep) { states[step] = .skipped }

    func reset() {
        page = .step(.commandLineTools)
        states = [:]
    }

    /// Where Continue and Back go. Project steps stand alone: Continue closes the window.
    func move(by offset: Int) -> Page? {
        let pages = SetupStep.firstLaunch.map(Page.step) + [.ready]
        guard let index = pages.firstIndex(of: page), pages.indices.contains(index + offset) else { return nil }
        return pages[index + offset]
    }
}

#if DEBUG
extension SetupStep {
    var sampleError: String {
        switch self {
        case .commandLineTools: "The installer quit before finishing."
        case .agent: "The download failed: no internet connection."
        case .signIn: "Sign-in was cancelled in Terminal."
        case .gitIdentity: "Couldn't write ~/.gitconfig: permission denied."
        case .github: "GitHub sign-in timed out."
        case .node: "The download failed: no internet connection."
        case .packageManager: "Corepack couldn't install pnpm."
        case .xcode: "The Xcode license hasn't been accepted."
        }
    }
}

extension SetupFlow {
    /// SHIFT_ONBOARDING=github:failed opens the window there, for screenshots. `ready` is the last screen.
    func apply(debugSpec spec: String) {
        let parts = spec.split(separator: ":").map(String.init)
        if parts.first == "ready" { page = .ready; return }
        guard let step = parts.first.flatMap(SetupStep.init(rawValue:)) else { return }
        page = .step(step)
        chosenAgents = step == .signIn ? Set(AgentKind.allCases) : [.claudeCode]
        switch parts.count > 1 ? parts[1] : "" {
        case "working": states[step] = .working
        case "done": states[step] = .done
        case "failed": states[step] = .failed(step.sampleError)
        case "skipped": states[step] = .skipped
        default: break
        }
    }
}
#endif
