import AppKit
import UserNotifications

public final class SystemNotifier: NSObject, Notifying, UNUserNotificationCenterDelegate, @unchecked Sendable {
    /// Called with the task id when the user clicks a notification.
    @MainActor public var onOpenTask: (@MainActor (Int) -> Void)?

    /// nil outside a real .app bundle (swift test, previews): `current()` crashes there.
    private var center: UNUserNotificationCenter? {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
            ? UNUserNotificationCenter.current() : nil
    }

    public override init() {
        super.init()
        center?.delegate = self
    }

    public func requestAuthorization() async {
        _ = try? await center?.requestAuthorization(options: [.alert, .sound, .badge])
    }

    public func notify(title: String, body: String, taskID: Int) async {
        guard let center else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        content.userInfo = ["taskID": taskID]
        // One notification per task: a newer one replaces the older.
        try? await center.add(UNNotificationRequest(identifier: "task-\(taskID)", content: content, trigger: nil))
    }

    public func setBadge(count: Int) async {
        guard center != nil else { return }
        await MainActor.run { NSApp?.dockTile.badgeLabel = count > 0 ? String(count) : nil }
    }

    // MARK: UNUserNotificationCenterDelegate

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    public func userNotificationCenter(_ center: UNUserNotificationCenter,
                                       didReceive response: UNNotificationResponse) async {
        guard let taskID = response.notification.request.content.userInfo["taskID"] as? Int else { return }
        await MainActor.run { onOpenTask?(taskID) }
    }
}
