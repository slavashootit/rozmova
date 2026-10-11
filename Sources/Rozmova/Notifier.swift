import Foundation
import UserNotifications

/// "Report ready" and other results; clicking one opens its file.
@MainActor
final class Notifier: NSObject, UNUserNotificationCenterDelegate {
    var onOpen: ((URL) -> Void)?

    func setUp() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        Task {
            do {
                _ = try await center.requestAuthorization(options: [.alert, .sound])
            } catch {
                Log.info("Notifications not allowed: \(error.localizedDescription)")
            }
        }
    }

    /// `file` opens on click; `link` is a web address (a meeting to join, a release page).
    func post(title: String, body: String, file: URL? = nil, link: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if let file {
            content.userInfo = ["file": file.path]
        } else if let link {
            content.userInfo = ["link": link.absoluteString]
        }
        post(id: UUID().uuidString, content: content)
    }

    private func post(id: String, content: UNNotificationContent) {
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        Task {
            do {
                try await UNUserNotificationCenter.current().add(request)
            } catch {
                Log.info("Notification failed: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let url = (info["file"] as? String).map { URL(fileURLWithPath: $0) }
            ?? (info["link"] as? String).flatMap { URL(string: $0) }
        Task { @MainActor in
            if let url {
                self.onOpen?(url)
            }
        }
        completionHandler()
    }

    /// Menu bar apps are never "in front", but show banners anyway.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
