import ActivityKit
import SwiftUI
import UIKit
import UserNotifications

/// The iOS switches Thermyx depends on that live outside the app:
/// notifications and Live Activities here; Bluetooth, location and Apple
/// Health in their own services. Read again whenever the app comes back to
/// the front, since the wearer may have just changed one in Settings.
@MainActor
final class ThermyxPermissions: ObservableObject {
    static let shared = ThermyxPermissions()

    @Published private(set) var notifications: UNAuthorizationStatus = .notDetermined
    @Published private(set) var liveActivitiesEnabled = true

    private init() {}

    func refresh() async {
        notifications = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        liveActivitiesEnabled = ActivityAuthorizationInfo().areActivitiesEnabled
    }

    var notificationsAllowed: Bool {
        [.authorized, .provisional, .ephemeral].contains(notifications)
    }

    /// iOS's prompt the first time; after a "Don't Allow", only Settings can
    /// turn notifications back on.
    func requestNotifications() async {
        if notifications == .notDetermined {
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
        } else {
            Self.openNotificationSettings()
        }
        await refresh()
    }

    /// Thermyx's own page in Settings: Bluetooth, location, notifications
    /// and Live Activities all have their switches there.
    static func openSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Thermyx's notification settings, where iOS has a page for them.
    static func openNotificationSettings() {
        guard let url = URL(string: UIApplication.openNotificationSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    /// Health permissions are managed in the Health app (Sharing → Apps), not
    /// in Settings, so the button opens Health.
    static func openHealth() {
        guard let url = URL(string: "x-apple-health://") else { return }
        UIApplication.shared.open(url) { opened in
            if !opened { openSettings() }
        }
    }
}

extension PermissionPrompt.Status {
    init(_ notifications: UNAuthorizationStatus) {
        switch notifications {
        case .notDetermined: self = .notAsked
        case .authorized, .provisional, .ephemeral: self = .allowed
        default: self = .denied
        }
    }
}

/// A nudge every Sunday evening to look at the week: days worn, time,
/// steps and heat against the week before. Local only; nothing is sent.
enum ThermyxWeeklyReminder {
    static let identifier = "thermyx.weekly"

    static func schedule(center: UNUserNotificationCenter = .current()) {
        Task {
            let settings = await center.notificationSettings()
            guard [.authorized, .provisional, .ephemeral].contains(settings.authorizationStatus) else { return }
            let pending = await center.pendingNotificationRequests()
            guard !pending.contains(where: { $0.identifier == identifier }) else { return }
            let content = UNMutableNotificationContent()
            content.title = "Your week with Thermyx"
            content.body = "Your streak, time worn, steps and heat, compared with last week."
            var when = DateComponents()
            when.weekday = 1
            when.hour = 18
            try? await center.add(UNNotificationRequest(identifier: identifier, content: content,
                                                        trigger: UNCalendarNotificationTrigger(dateMatching: when, repeats: true)))
        }
    }
}
