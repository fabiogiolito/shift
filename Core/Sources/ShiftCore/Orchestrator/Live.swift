import Foundation

extension AppModel {
    /// The real thing. `onOpenTask` is called when the user clicks a notification.
    public static func live(onOpenTask: @escaping @MainActor (Int) -> Void) -> AppModel {
        let notifier = SystemNotifier()
        notifier.onOpenTask = onOpenTask
        return AppModel(services: Services(
            git: GitService(),
            agents: [.claudeCode: ClaudeCodeAdapter(), .codex: CodexAdapter()],
            servers: ServerManager(),
            ports: PortAllocator(),
            notifier: notifier,
            store: JSONStateStore()
        ))
    }
}
