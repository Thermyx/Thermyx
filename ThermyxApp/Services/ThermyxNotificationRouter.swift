import Foundation
import UserNotifications

/// Shows Thermyx's notifications while the app is open too, and sends a tap
/// on the evening insights notification to AI Insights for that day.
final class ThermyxNotificationRouter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ThermyxNotificationRouter()

    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification,
                                withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .list])
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                withCompletionHandler completionHandler: @escaping () -> Void) {
        if let seconds = response.notification.request.content.userInfo["insightsDay"] as? Double {
            let day = Date(timeIntervalSince1970: seconds)
            Task { @MainActor in ThermyxDeepLink.shared.insightsDay = day }
        }
        completionHandler()
    }
}
