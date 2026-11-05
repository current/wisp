import Foundation
import UserNotifications
import WispCore

/// Posts alerts as user notifications. Permission is asked the first time an alert
/// actually fires, not at launch.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var asked = false
    var onOpen: ((String) -> Void)?
    /// A click on a Clean Up notification, with what it should open.
    var onClean: (([String: String]) -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter traps when the process is not inside an app bundle.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func post(_ alert: Alert) {
        post(id: "\(alert.kind.rawValue)-\(alert.appID)", title: alert.title, body: alert.body, info: ["app": alert.appID], thread: alert.kind.rawValue)
    }

    func post(id: String, title: String, body: String, info: [String: String], thread: String) {
        guard let center else { return }
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            content.userInfo = info
            content.threadIdentifier = thread
            center.add(UNNotificationRequest(identifier: id, content: content, trigger: nil))
        }
        if asked {
            deliver()
            return
        }
        asked = true
        center.requestAuthorization(options: [.alert, .sound]) { granted, _ in
            if granted { DispatchQueue.main.async(execute: deliver) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo as? [String: String] ?? [:]
        DispatchQueue.main.async {
            if info["clean"] != nil { self.onClean?(info) } else if let app = info["app"] { self.onOpen?(app) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
