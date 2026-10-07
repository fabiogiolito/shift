import SwiftUI
import ShiftCore
#if UPDATER
import Sparkle
#endif

@main
struct ShiftApp: App {
    @NSApplicationDelegateAdaptor private var delegate: AppDelegate
    @State private var ready = false

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
            .background { OpenWindowHandoff(delegate: delegate) }
            .task {
                await delegate.model.start()
                ready = true
                delegate.applyScreenshotSize()
            }
        }
        .commands {
            NewTaskCommand()
            ProjectSettingsCommand()
            #if UPDATER
            if let updater = delegate.updater {
                CommandGroup(after: .appInfo) {
                    Button("Check for Updates…") { updater.checkForUpdates(nil) }
                }
            }
            #endif
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

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("New Task") { focusNewTask?() }
                .keyboardShortcut("n")
                .disabled(focusNewTask == nil)
        }
    }
}

/// ⌘, opens the current project's settings; Shift has no app-wide settings. Its own `Commands` for the reason above.
private struct ProjectSettingsCommand: Commands {
    @FocusedValue(\.openProjectSettings) private var openProjectSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Project Settings…") { openProjectSettings?() }
                .keyboardShortcut(",")
                .disabled(openProjectSettings == nil)
        }
    }
}

extension FocusedValues {
    /// Moves focus to the New task field. Published by the task list.
    @Entry var focusNewTask: (() -> Void)?
    /// Opens the current project's settings. Published by the project bar.
    @Entry var openProjectSettings: (() -> Void)?
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    var openWindow: OpenWindowAction?
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
