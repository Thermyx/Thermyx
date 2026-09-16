import Foundation
import UserNotifications

@MainActor
final class ThermyxAlertCoordinator: ObservableObject {
    @Published private(set) var notificationsAuthorized = false
    @Published private(set) var lastAlertLevel: ThermyxRiskLevel = .unavailable
    @Published private(set) var lastBackendError: String?

    private let apiClient = ThermyxAlertAPIClient()

    func requestPermission() async {
        notificationsAuthorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    func evaluate(_ assessment: ThermyxRiskAssessment, reading: ThermyxReading, settings: ThermyxSettingsStore) {
        guard assessment.level != .unavailable else { return }
        if assessment.level != .normal, assessment.level != lastAlertLevel {
            lastAlertLevel = assessment.level
            let content = UNMutableNotificationContent()
            content.title = "Thermyx safety alert"
            content.body = assessment.level.explanation
            content.sound = assessment.level == .critical ? .defaultCritical : .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermyx.\(assessment.level.rawValue)", content: content, trigger: nil))
        }

        guard !settings.backendURL.isEmpty else { return }
        let event = ThermyxAlertEvent(
            deviceID: settings.deviceID,
            level: assessment.level.rawValue,
            reasons: assessment.reasons,
            recipients: settings.contacts.filter(\.enabled).map(\.phoneNumber),
            timestamp: .now,
            readings: .init(
                footTemperatureC: reading.footTemperatureC,
                ambientTemperatureC: reading.ambientTemperatureC,
                gaitStability: reading.gaitStability,
                pressureBalance: reading.pressureBalance,
                batteryPercent: reading.batteryPercent
            )
        )
        Task {
            do { try await apiClient.send(event: event, backendURL: settings.backendURL, token: settings.backendToken) }
            catch { self.lastBackendError = error.localizedDescription }
        }
    }
}
