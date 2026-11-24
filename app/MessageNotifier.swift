// The notifications for new text messages (MessageAlerts.swift decides when): posted with UNUserNotificationCenter,
// whose permission is asked the first time one is to be posted (NotificationGate). A notification says only that the
// modem has new or unread messages: no sender, no text (the background never reads them, so they stay unread on the
// modem). Each replaces the one before it in Notification Center. A click shows the Messages screen.
import AppKit
import UserNotifications

final class MessageNotifier: NSObject, UNUserNotificationCenterDelegate {
    private static let identifier = "io.rmnetdriver.RMNet.messages"

    private lazy var gate = NotificationGate<UNNotificationRequest>(
        ask: { done in
            UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge]) { granted, _ in
                DispatchQueue.main.async { done(granted) }
            }
        },
        check: { done in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                let ok = settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional
                DispatchQueue.main.async { done(ok) }
            }
        },
        add: { UNUserNotificationCenter.current().add($0) })

    /// What a click does: show the window at the Messages screen.
    var open: () -> Void = {}

    /// Posts `alert`; asks for permission the first time.
    func post(_ alert: MessageAlert) {
        let words = alertContent(alert)
        let content = UNMutableNotificationContent()
        content.title = words.title
        content.body = words.body
        content.sound = .default
        content.threadIdentifier = "messages"
        gate.post(UNNotificationRequest(identifier: MessageNotifier.identifier, content: content, trigger: nil))
    }

    // Shown also while RMNet is the active app (its window may be on another screen than Messages).
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        DispatchQueue.main.async {
            self.open()
            completionHandler()
        }
    }
}
