import Foundation
import UserNotifications
import MacVaultCore

/// Local notifications. Only available when running as a bundled app: `UNUserNotificationCenter`
/// requires a bundle identifier, so under `swift run` posting is skipped (events still go to Activity).
enum Notifier {
    static var isAvailable: Bool {
        Bundle.main.bundleIdentifier != nil && Bundle.main.bundleURL.pathExtension == "app"
    }

    /// Asks macOS for permission. Returns whether notifications are allowed.
    static func requestAuthorization() async -> Bool {
        guard isAvailable else { return false }
        return (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])) ?? false
    }

    static func post(id: String, title: String, body: String) {
        guard isAvailable else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        let request = UNNotificationRequest(identifier: "com.macvault.\(id)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if error != nil { Log.app.error("Notification could not be posted") }
        }
    }
}
