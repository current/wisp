import Foundation
import UserNotifications
import WispCore

/// Posts alerts as user notifications. Permission is asked the first time an alert
/// actually fires, not at launch.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    private var asked = false
    var onOpen: ((String) -> Void)?

    private var center: UNUserNotificationCenter? {
        // UNUserNotificationCenter traps when the process is not inside an app bundle.
        Bundle.main.bundleIdentifier == nil ? nil : UNUserNotificationCenter.current()
    }

    override init() {
        super.init()
        center?.delegate = self
    }

    func post(_ alert: Alert) {
        guard let center else { return }
        let deliver = {
            let content = UNMutableNotificationContent()
            content.title = alert.title
            content.body = alert.body
            content.userInfo = ["app": alert.appID]
            content.threadIdentifier = alert.kind.rawValue
            let request = UNNotificationRequest(identifier: "\(alert.kind.rawValue)-\(alert.appID)", content: content, trigger: nil)
            center.add(request)
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
        let app = response.notification.request.content.userInfo["app"] as? String
        DispatchQueue.main.async {
            if let app { self.onOpen?(app) }
            completionHandler()
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
