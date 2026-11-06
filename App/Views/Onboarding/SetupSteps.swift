import SwiftUI
import ShiftCore

/// Everything Shift needs on a Mac, in one place: the setup window and Settings › Setup both draw from these.
/// `SetupFlow` runs each step's real check and action, through `MacSetup`.
enum SetupStep: String, CaseIterable, Identifiable {
    case commandLineTools, node, agent, signIn, gitIdentity, github
    /// Asked when a project that needs them is added, not at first launch.
    case packageManager, xcode
    /// From Settings only: for pairing a phone and sharing servers.
    case tailscale

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
        case .tailscale: "Tailscale"
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
        case .tailscale: "network"
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
        case .tailscale: "Lets your iPhone reach this Mac, and opens task servers on your other devices."
        }
    }

    var actionTitle: String {
        switch self {
        case .signIn: "Sign In"
        case .gitIdentity: "Save"
        case .github: "Connect GitHub"
        case .tailscale: "Set Up"
        default: "Install"
        }
    }

    var workingTitle: String {
        switch self {
        case .signIn: "Waiting for sign-in…"
        case .gitIdentity: "Saving…"
        case .github, .tailscale: "Connecting…"
        default: "Installing…"
        }
    }

    var doneTitle: String {
        switch self {
        case .signIn: "Signed in"
        case .gitIdentity: "Saved"
        case .github, .tailscale: "Connected"
        default: "Installed"
        }
    }

    var canSkip: Bool { [.github, .packageManager, .xcode, .tailscale].contains(self) }

    /// What won't work if it's skipped.
    var skipWarning: String? {
        switch self {
        case .github: "Shift can't open pull requests or follow them, and pushing may fail. You can connect GitHub later in Settings."
        case .packageManager: "The project's dev server won't start until it's installed."
        case .xcode: "The project can't be built or run until Xcode is installed."
        case .tailscale: "Your iPhone can't reach this Mac until Tailscale is set up."
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

/// The setup window's place and each step's state, from real checks (`MacSetup`). Settings › Setup shows the same.
@MainActor @Observable
final class SetupFlow {
    enum Page: Hashable { case step(SetupStep), ready }

    private let model: AppModel
    var page: Page = .ready
    /// The steps this run of the window walks through: what was missing when it opened.
    private(set) var steps: [SetupStep] = []
    /// First launch ends with "You're ready"; a fix from Settings or a project's steps just close.
    private(set) var endsReady = false
    private var isProjectSetup = false
    private var states: [SetupStep: SetupState] = [:]
    private(set) var installed: [AgentKind: SetupState] = [:]
    private(set) var signedIn: [AgentKind: SetupState] = [:]
    /// Agents to install: not installed yet, and ticked.
    var chosenAgents: Set<AgentKind> = []
    var gitName = ""
    var gitEmail = ""
    var packageManager = "npm"

    init(model: AppModel) { self.model = model }

    /// Installed agents, the ones to sign in.
    var agents: [AgentKind] { AgentKind.allCases.filter { installed[$0] == .done } }

    func toggle(_ agent: AgentKind) {
        if chosenAgents.contains(agent) { chosenAgents.remove(agent) } else { chosenAgents.insert(agent) }
    }

    func state(_ step: SetupStep) -> SetupState {
        switch step {
        case .agent:
            chosenAgents.isEmpty ? (agents.isEmpty ? .notDone : .done) : Self.combined(chosenAgents.map { installed[$0] ?? .notDone })
        // One signed-in agent is enough; the other can be signed in from Settings.
        case .signIn:
            agents.contains { signedIn[$0] == .done } ? .done : Self.combined(agents.map { signedIn[$0] ?? .notDone })
        default: states[step] ?? .notDone
        }
    }

    /// Any first-launch step still to do: the window opens at launch.
    var needsSetup: Bool {
        SetupStep.firstLaunch.contains { [.notDone, .working].contains(state($0)) || state($0).isFailed }
    }

    /// "Step 2 of 5" on first launch, "Project setup" for a project's steps.
    func progress(of step: SetupStep) -> String? {
        if isProjectSetup { return "Project setup" }
        guard endsReady, let index = steps.firstIndex(of: step) else { return nil }
        return "Step \(index + 1) of \(steps.count)"
    }

    // MARK: Opening

    func startFirstLaunch() {
        start(SetupStep.firstLaunch.filter { state($0) != .done }, endsReady: true)
    }

    func start(_ steps: [SetupStep], endsReady: Bool = false, isProjectSetup: Bool = false) {
        self.steps = steps
        self.endsReady = endsReady
        self.isProjectSetup = isProjectSetup
        page = steps.first.map(Page.step) ?? .ready
    }

    /// What a project added from `folder` needs that this Mac doesn't have.
    func projectSteps(for folder: URL) async -> [SetupStep] {
        var needed: [SetupStep] = []
        if let manager = MacSetup.packageManager(of: folder) {
            if !(await MacSetup.hasNode()) { needed.append(.node); states[.node] = .notDone }
            if manager != "npm", !(await MacSetup.hasPackageManager(manager)) {
                packageManager = manager
                states[.packageManager] = .notDone
                needed.append(.packageManager)
            }
        }
        if MacSetup.needsXcode(folder), !(await MacSetup.hasXcode()) {
            states[.xcode] = .notDone
            needed.append(.xcode)
        }
        return needed
    }

    /// Where Continue and Back go.
    func move(by offset: Int) -> Page? {
        let pages = steps.map(Page.step) + (endsReady ? [.ready] : [])
        guard let index = pages.firstIndex(of: page), pages.indices.contains(index + offset) else { return nil }
        return pages[index + offset]
    }

    // MARK: Checks

    /// Checks everything at once. Leaves steps that are running alone.
    func refresh() async {
        async let tools = MacSetup.hasCommandLineTools()
        async let node = MacSetup.hasNode()
        async let identity = MacSetup.gitIdentity()
        async let github = MacSetup.isGitHubConnected()
        async let tailscale = MacSetup.isTailscaleReady()
        var agentsFound: [AgentKind: Bool] = [:]
        var agentsSignedIn: [AgentKind: Bool] = [:]
        for agent in AgentKind.allCases {
            agentsFound[agent] = await MacSetup.isInstalled(agent)
            if agentsFound[agent] == true { agentsSignedIn[agent] = await MacSetup.isSignedIn(agent) }
        }
        let (hasTools, hasNode, (name, email), hasGitHub, hasTailscale) = await (tools, node, identity, github, tailscale)

        set(.commandLineTools, done: hasTools)
        set(.node, done: hasNode)
        set(.gitIdentity, done: !name.isEmpty && !email.isEmpty)
        set(.github, done: hasGitHub)
        set(.tailscale, done: hasTailscale)
        for agent in AgentKind.allCases {
            if installed[agent] != .working { installed[agent] = agentsFound[agent] == true ? .done : .notDone }
            if signedIn[agent] != .working { signedIn[agent] = agentsSignedIn[agent] == true ? .done : .notDone }
        }
        chosenAgents = agents.isEmpty ? [.claudeCode] : []
        if gitName.isEmpty { gitName = name.isEmpty ? NSFullUserName() : name }
        if gitEmail.isEmpty { gitEmail = email }
    }

    private func set(_ step: SetupStep, done: Bool) {
        guard states[step] != .working else { return }
        states[step] = done ? .done : step.canSkip && skipped.contains(step.rawValue) ? .skipped : .notDone
    }

    // MARK: Actions

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

    func perform(_ step: SetupStep) {
        switch step {
        case .agent: installAgents()
        case .signIn: agents.filter { signedIn[$0] != .done }.forEach(signIn)
        default:
            states[step] = .working
            Task {
                do {
                    try await action(step)
                    states[step] = .done
                    skipped.remove(step.rawValue)
                } catch {
                    states[step] = .failed(error.localizedDescription)
                }
                await model.reloadEnvironment()
            }
        }
    }

    private func action(_ step: SetupStep) async throws {
        switch step {
        case .commandLineTools: try await MacSetup.installCommandLineTools()
        case .node: try await MacSetup.installNode()
        case .gitIdentity:
            try await MacSetup.setGitIdentity(name: gitName.trimmingCharacters(in: .whitespaces),
                                              email: gitEmail.trimmingCharacters(in: .whitespaces))
        case .github: try await MacSetup.connectGitHub()
        case .packageManager: try await MacSetup.installPackageManager(packageManager)
        case .xcode: try await MacSetup.installXcode()
        case .tailscale: try await MacSetup.setUpTailscale()
        case .agent, .signIn: break
        }
    }

    /// One after the other; stops at the first that fails.
    private func installAgents() {
        let queue = AgentKind.allCases.filter { chosenAgents.contains($0) && installed[$0] != .done }
        Task {
            for agent in queue {
                installed[agent] = .working
                do {
                    try await MacSetup.install(agent)
                    installed[agent] = .done
                    chosenAgents.remove(agent)
                    signedIn[agent] = await MacSetup.isSignedIn(agent) ? .done : .notDone
                } catch {
                    installed[agent] = .failed(error.localizedDescription)
                    break
                }
            }
            await model.reloadEnvironment()
        }
    }

    func signIn(_ agent: AgentKind) {
        signedIn[agent] = .working
        Task {
            do {
                try await MacSetup.signIn(agent)
                signedIn[agent] = .done
            } catch {
                signedIn[agent] = .failed(error.localizedDescription)
            }
        }
    }

    func skip(_ step: SetupStep) {
        states[step] = .skipped
        // Not asked again at launch. A project's steps are asked again for the next project.
        if SetupStep.firstLaunch.contains(step) { skipped.insert(step.rawValue) }
    }

    /// An installed, signed-in agent that can help when a step fails.
    var helper: AgentKind? { agents.first { signedIn[$0] == .done } }

    func askForHelp(with step: SetupStep) {
        guard let helper, case .failed(let error) = state(step) else { return }
        MacSetup.askForHelp(helper, with: "\(step.title): \(error)")
    }

    private var skipped: Set<String> {
        get { Set(UserDefaults.standard.stringArray(forKey: "setupSkipped") ?? []) }
        set { UserDefaults.standard.set(Array(newValue), forKey: "setupSkipped") }
    }

    private static func combined(_ states: [SetupState]) -> SetupState {
        if states.isEmpty { return .notDone }
        if states.contains(.working) { return .working }
        if let failed = states.first(where: \.isFailed) { return failed }
        return states.allSatisfy { $0 == .done } ? .done : .notDone
    }
}
