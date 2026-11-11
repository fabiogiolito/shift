import SwiftUI
import ShiftCore
#if UPDATER
import Sparkle
#endif

@main
struct ShiftApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var ready = false
    @AppStorage(TextScale.key) private var textScale = 1.0

    var body: some Scene {
        Window("Shift", id: "main") {
            Group {
                if ready {
                    ContentView()
                } else {
                    ProgressView()
                }
            }
            .frame(minWidth: 960, minHeight: 600)
            .environment(delegate.model)
            .environment(delegate.setupFlow)
            .environment(\.textScale, textScale)
            .background {
                // ⌘= too, the key under + without Shift, as in Safari and Xcode.
                Button("") { textScale = TextScale.step(textScale, by: 1) }.keyboardShortcut("=")
                    .opacity(0).allowsHitTesting(false).accessibilityHidden(true)
            }
            .background { OpenWindowHandoff(delegate: delegate) }
            // At first launch with what's missing, from Settings › Setup, and when a new project needs something.
            .sheet(isPresented: Bindable(delegate.setupFlow).isPresented) {
                SetupSheet().environment(delegate.setupFlow)
            }
            // An agent signed out: straight to signing it in again, unless the sheet is already up. Closed again when
            // its tasks carry on without it (signed in elsewhere).
            .onChange(of: delegate.model.tasks.first(where: \.isSignedOut)?.agent, initial: true) { _, agent in
                let flow = delegate.setupFlow
                if let agent, !flow.isPresented { flow.signInAgain(agent) }
                if agent == nil, flow.isPresented, flow.page == .step(.signInAgain), flow.state(.signInAgain) == .notDone {
                    flow.isPresented = false
                }
            }
            .task {
                #if DEBUG
                if ProcessInfo.processInfo.environment["SHIFT_PREVIEW"] == nil { await DemoProject.seed() }
                #endif
                await delegate.model.start()
                #if DEBUG
                delegate.model.addDemoPullRequests()
                #endif
                ready = true
                Analytics.start(model: delegate.model)
                delegate.applyScreenshotSize()
                await delegate.openSetupIfNeeded()
            }
        }
        .commands {
            SidebarCommands()
            NewTaskCommand()
            ProjectSettingsCommand()
            ShortcutCommands()
            TextSizeCommands()
            #if UPDATER
            if let updater = delegate.updater {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.checkForUpdates(nil) }
                }
            }
            #endif
        }

        // One per task: asking again brings its window forward. Not restored: the model only starts with the main window.
        WindowGroup(id: "server-log", for: TaskItem.ID.self) { $taskID in
            if let taskID {
                ServerLogWindow(taskID: taskID).environment(delegate.model)
            }
        }
        .defaultSize(width: 720, height: 480)
        .restorationBehavior(.disabled)

        // Like Force Quit Applications, for every project's tasks. Listed in the Window menu by itself.
        Window(MemoryWindow.title, id: MemoryWindow.id) {
            MemoryWindow().environment(delegate.model)
        }
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)

        Settings {
            SettingsView().environment(delegate.model).environment(delegate.setupFlow)
        }
    }
}

/// Gives the delegate SwiftUI's `openWindow`, which can reopen the window after it has been closed.
private struct OpenWindowHandoff: View {
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Color.clear.onAppear { delegate.openWindow = openWindow }
    }
}


/// ⌘N starts a task, not a window. Its own `Commands` so the focused value is read here, not in the app's body:
/// the value is a closure, new on every update of the field, and read in the body it re-created the whole window
/// content, which updated the field again, on every event (scrolling included).
private struct NewTaskCommand: Commands {
    @FocusedValue(\.focusNewTask) private var focusNewTask
    @FocusedValue(\.newSchedule) private var newSchedule

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { focusNewTask?() }
                .keyboardShortcut("n")
                .disabled(focusNewTask == nil)
            // The same empty form as `/schedule` alone in the New task field.
            Button("New Schedule…") { newSchedule?() }
                .keyboardShortcut("n", modifiers: [.command, .option])
                .disabled(newSchedule == nil)
        }
    }
}

/// ⇧⌘, opens the current project's settings, under Shift's own (⌘,). Its own `Commands` for the reason above.
private struct ProjectSettingsCommand: Commands {
    @FocusedValue(\.openProjectSettings) private var openProjectSettings

    var body: some Commands {
        CommandGroup(after: .appSettings) {
            Button("Project Settings…") { openProjectSettings?() }
                .keyboardShortcut(",", modifiers: [.command, .shift])
                .disabled(openProjectSettings == nil)
        }
    }
}

/// Menu items for moving around and for the task on screen, each published as a focused value by the view that can do it.
/// Its own `Commands` for the reason above.
private struct ShortcutCommands: Commands {
    @FocusedValue(\.focusPrompt) private var focusPrompt
    @FocusedValue(\.focusSearch) private var focusSearch
    @FocusedValue(\.selectProject) private var selectProject
    @FocusedValue(\.selectTask) private var selectTask
    @FocusedValue(\.openPreview) private var openPreview
    @FocusedValue(\.copyPreviewLink) private var copyPreviewLink
    @FocusedValue(\.openInTerminal) private var openInTerminal
    @FocusedValue(\.openInEditor) private var openInEditor
    @FocusedValue(\.openInFinder) private var openInFinder
    @FocusedValue(\.stopApp) private var stopApp
    @FocusedValue(\.openRepository) private var openRepository

    var body: some Commands {
        CommandGroup(after: .newItem) {
            Button("Message Agent") { focusPrompt?() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
                .disabled(focusPrompt == nil)
        }
        CommandGroup(before: .textEditing) {
            Button("Search Tasks") { focusSearch?() }
                .keyboardShortcut("f")
                .disabled(focusSearch == nil)
        }
        CommandMenu("Go") {
            Button("Previous Project") { selectProject?(-1) }
                .keyboardShortcut("[", modifiers: [.command, .shift])
                .disabled(selectProject == nil)
            Button("Next Project") { selectProject?(1) }
                .keyboardShortcut("]", modifiers: [.command, .shift])
                .disabled(selectProject == nil)
            Divider()
            Button("Previous Task") { selectTask?(-1) }
                .keyboardShortcut("[")
                .disabled(selectTask == nil)
            Button("Next Task") { selectTask?(1) }
                .keyboardShortcut("]")
                .disabled(selectTask == nil)
        }
        CommandMenu("Task") {
            Button(openPreview?.title ?? "Open in Browser") { openPreview?.perform() }
                .keyboardShortcut("r")
                .disabled(openPreview == nil)
            Button("Stop") { stopApp?() }
                .keyboardShortcut(".")
                .disabled(stopApp == nil)
            Button("Copy Link") { copyPreviewLink?() }
                .keyboardShortcut("c", modifiers: [.command, .shift])
                .disabled(copyPreviewLink == nil)
            Button("Open in Terminal") { openInTerminal?() }
                .keyboardShortcut("t", modifiers: [.command, .shift])
                .disabled(openInTerminal == nil)
            Button(openInEditor?.title ?? "Open in Editor") { openInEditor?.perform() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
                .disabled(openInEditor == nil)
            Button("Show in Finder") { openInFinder?() }
                .keyboardShortcut("o", modifiers: [.command, .shift])
                .disabled(openInFinder == nil)
            Button("Open on GitHub") { openRepository?() }
                .keyboardShortcut("g", modifiers: [.command, .shift])
                .disabled(openRepository == nil)
        }
    }
}

/// View › Make Text Bigger and Smaller, for the conversation, the diff and the agent's questions.
private struct TextSizeCommands: Commands {
    @AppStorage(TextScale.key) private var textScale = 1.0

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Divider()
            Button("Actual Size") { textScale = 1 }
                .keyboardShortcut("0")
                .disabled(textScale == 1)
            Button("Make Text Bigger") { textScale = TextScale.step(textScale, by: 1) }
                .keyboardShortcut("+")
                .disabled(textScale >= TextScale.steps.last!)
            Button("Make Text Smaller") { textScale = TextScale.step(textScale, by: -1) }
                .keyboardShortcut("-")
                .disabled(textScale <= TextScale.steps.first!)
        }
    }
}

/// A menu item whose title depends on what's on screen.
struct TitledAction {
    var title: String
    var perform: () -> Void
}

extension FocusedValues {
    /// Moves focus to the New task field. Published by the task list.
    @Entry var focusNewTask: (() -> Void)?
    /// Opens the empty schedule form for the selected project. Published by the window.
    @Entry var newSchedule: (() -> Void)?
    /// Moves focus to the open task's or the chat's prompt field. Published by the field.
    @Entry var focusPrompt: (() -> Void)?
    /// Moves focus to the projects search field. Published by the sidebar.
    @Entry var focusSearch: (() -> Void)?
    /// Selects the project or the task this many places away. Published by the window.
    @Entry var selectProject: ((Int) -> Void)?
    @Entry var selectTask: ((Int) -> Void)?
    /// Opens the server in the browser, or builds the app. Published by the task detail and the chat.
    @Entry var openPreview: TitledAction?
    /// Copies the server's link. Published by the task detail and the chat.
    @Entry var copyPreviewLink: (() -> Void)?
    /// Opens the task's folder, or the project's from the chat, in the first terminal.
    @Entry var openInTerminal: (() -> Void)?
    /// Opens the same folder in the first installed editor.
    @Entry var openInEditor: TitledAction?
    /// Opens the same folder in Finder.
    @Entry var openInFinder: (() -> Void)?
    /// Opens the selected project's GitHub repository in the browser. Published by the window.
    @Entry var openRepository: (() -> Void)?
    /// Stops the app the task's Run started. Published by the task detail.
    @Entry var stopApp: (() -> Void)?
    /// Opens the current project's settings. Published by the project bar.
    @Entry var openProjectSettings: (() -> Void)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openWindow: OpenWindowAction?
    lazy var setupFlow = SetupFlow(model: model)
    #if UPDATER
    /// Release builds only (see project.yml). Checks the feed in `SUFeedURL` in the background.
    let updater: SPUStandardUpdaterController? = ProcessInfo.processInfo.environment["SHIFT_PREVIEW"] != nil
        ? nil
        : SPUStandardUpdaterController(startingUpdater: true, updaterDelegate: nil, userDriverDelegate: nil)
    #endif
    /// Launch reconciles every task itself, so the first check waits for the next activation.
    private var lastMergeCheck = Date()

    // SHIFT_PREVIEW=1 launches with sample data and no side effects; SHIFT_PREVIEW=promo with screenshot data.
    lazy var model: AppModel = switch ProcessInfo.processInfo.environment["SHIFT_PREVIEW"] {
    case "1": .preview()
    case "promo": .promo()
    default: .live(onOpenTask: { [weak self] taskID in
            // ContentView reads the selection from here, whether its window is open or opens now.
            UserDefaults.standard.set(taskID, forKey: "selectedTask")
            self?.showWindow()
        })
    }

    func showWindow() {
        NSApp.activate()
        openWindow?(id: "main")
    }

    /// The model sets itself as the notification delegate: it must be by the end of launch, or a click that launched
    /// the app is lost.
    func applicationWillFinishLaunching(_ notification: Notification) { _ = model }

    /// SHIFT_APPEARANCE=dark forces dark mode, for screenshots.
    func applicationDidFinishLaunching(_ notification: Notification) {
        if ProcessInfo.processInfo.environment["SHIFT_APPEARANCE"] == "dark" { NSApp.appearance = NSAppearance(named: .darkAqua) }
        #if UPDATER
        // Sparkle's own schedule waits a day between checks; check on every launch too. Prompts only if one is found.
        updater?.updater.checkForUpdatesInBackground()
        #endif
    }

    /// SHIFT_WINDOW_SIZE=1280x780 sizes the window, for screenshots.
    func applyScreenshotSize() {
        let size = ProcessInfo.processInfo.environment["SHIFT_WINDOW_SIZE"]?.split(separator: "x").compactMap { Double($0) }
        guard let size, size.count == 2, let window = NSApp.windows.first(where: \.isVisible) else { return }
        window.setFrame(NSRect(origin: window.frame.origin, size: CGSize(width: size[0], height: size[1])), display: true)
    }

    /// Opens the setup sheet when this Mac is missing something Shift needs. Not for sample data.
    func openSetupIfNeeded() async {
        guard ProcessInfo.processInfo.environment["SHIFT_PREVIEW"] == nil else { return }
        await setupFlow.refresh()
        guard setupFlow.needsSetup else { return }
        setupFlow.startFirstLaunch()
    }

    /// Tasks keep running when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Dock icon click with no window open.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { showWindow() }
        return true
    }

    /// The base branch may have moved while the user was away.
    func applicationDidBecomeActive(_ notification: Notification) {
        guard Date().timeIntervalSince(lastMergeCheck) >= 10 else { return }
        lastMergeCheck = Date()
        Task { await model.refreshMergeability() }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.shutdown()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
