import CoreLocation
import Foundation
import UserNotifications

@MainActor
final class ThermyxAlertCoordinator: ObservableObject {
    @Published private(set) var notificationsAuthorized = false
    @Published private(set) var lastAlertLevel: ThermyxRiskLevel = .unavailable
    @Published private(set) var lastBackendError: String?
    /// When the trusted circle was last sent something, for the Safety screen.
    @Published private(set) var lastSharedAt: Date?

    let location = ThermyxLocationProvider()
    private let apiClient = ThermyxAlertAPIClient()

    /// Minimum gap between repeat alerts while the level stays elevated.
    static let reminderInterval: TimeInterval = 5 * 60
    /// How often the current status is posted to the relay so a watcher can
    /// tell a quiet wearer from a wearer whose phone has gone silent.
    static let heartbeatInterval: TimeInterval = 60

    private var lastAlertSentAt: Date?
    private var lastAlertSentLevel: ThermyxRiskLevel = .unavailable
    private var lastPostAt: Date?

    func requestPermission() async {
        notificationsAuthorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Called on every reading. Notifies the wearer when the level rises,
    /// alerts the trusted circle on a rise (and at most every five minutes
    /// while it stays up), and otherwise posts a once-a-minute heartbeat.
    func evaluate(_ assessment: ThermyxRiskAssessment, reading: BilateralReading, settings: ThermyxSettingsStore) {
        let level = assessment.level
        guard level != .unavailable else { return }

        // Back to normal: forget the last alert so the next rise notifies
        // again, even if it is to the same level as before.
        if level == .normal {
            lastAlertLevel = .normal
            lastAlertSentLevel = .normal
            lastAlertSentAt = nil
        } else if level.severity > lastAlertLevel.severity || lastAlertLevel == .unavailable {
            lastAlertLevel = level
            notifyWearer(level)
        } else if level.severity < lastAlertLevel.severity {
            // Easing off (e.g. High back to Caution) lowers the bar, so a
            // later climb back up is announced again.
            lastAlertLevel = level
        }

        if level.severity >= ThermyxRiskLevel.caution.severity, settings.shouldAlert(for: level) {
            let rose = level.severity > lastAlertSentLevel.severity
            let reminderDue = lastAlertSentAt.map { Date.now.timeIntervalSince($0) >= Self.reminderInterval } ?? true
            if rose || reminderDue {
                lastAlertSentLevel = level
                lastAlertSentAt = .now
                location.refresh()
                send(kind: .alert, level: level, reasons: assessment.reasons, focus: assessment.foot, reading: reading, settings: settings, texts: true)
                return
            }
        }

        if lastPostAt.map({ Date.now.timeIntervalSince($0) >= Self.heartbeatInterval }) ?? true {
            send(kind: .status, level: level, reasons: assessment.reasons, focus: assessment.foot, reading: reading, settings: settings, texts: false)
        }
    }

    /// The Call 911 button: texts the trusted circle with location.
    func notifyTrustedCircle(
        level: ThermyxRiskLevel,
        reading: BilateralReading,
        settings: ThermyxSettingsStore,
        reason: String,
        kind: ThermyxAlertEvent.Kind = .sos
    ) {
        location.refresh()
        send(kind: kind, level: level, reasons: [reason], focus: nil, reading: reading, settings: settings, texts: true)
    }

    /// The wearer checked in: tell the trusted circle they're OK.
    func sendImOK(level: ThermyxRiskLevel, reading: BilateralReading, settings: ThermyxSettingsStore) {
        let current = level == .unavailable ? .normal : level
        send(kind: .ok, level: current, reasons: ["The wearer says they're OK."], focus: nil, reading: reading, settings: settings, texts: true)
    }

    private func notifyWearer(_ level: ThermyxRiskLevel) {
        let content = UNMutableNotificationContent()
        content.title = "Thermyx safety alert"
        content.body = level.explanation
        content.sound = level == .critical ? .defaultCritical : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermyx.\(level.rawValue)", content: content, trigger: nil))
    }

    /// Pushes an event to the shared relay, which forwards approved SMS to the
    /// trusted circle. Only contacts the user enabled are included, and only
    /// when the event is meant to text anyone.
    private func send(
        kind: ThermyxAlertEvent.Kind,
        level: ThermyxRiskLevel,
        reasons: [String],
        focus: Foot?,
        reading: BilateralReading,
        settings: ThermyxSettingsStore,
        texts: Bool
    ) {
        guard !settings.backendURL.isEmpty else { return }
        lastPostAt = .now

        // The readings of the foot that drove this, or the hotter one: never
        // an average, which would hide the foot that matters.
        let driver: ThermyxReading? = focus.flatMap { reading[$0] }
            ?? reading.present.max { ($0.footTemperatureC ?? -.infinity) < ($1.footTemperatureC ?? -.infinity) }
        let summary = driver.map(ThermyxAlertEvent.AlertReadings.init)
            ?? .init(footTemperatureC: nil, ambientTemperatureC: nil, gaitStability: nil, pressureBalance: nil, batteryPercent: nil)

        var event = ThermyxAlertEvent(
            deviceID: settings.deviceID,
            level: level.rawValue,
            reasons: reasons,
            recipients: texts ? settings.contacts.filter(\.enabled).map(\.phoneNumber) : [],
            timestamp: .now,
            readings: summary
        )
        event.kind = kind
        event.foot = driver?.foot.rawValue
        event.left = reading.left.map(ThermyxAlertEvent.AlertReadings.init)
        event.right = reading.right.map(ThermyxAlertEvent.AlertReadings.init)
        // Location only rides on events that text someone, never heartbeats.
        if texts { event.location = location.recent }

        let payload = event
        Task {
            do {
                try await apiClient.send(event: payload, backendURL: settings.backendURL, token: settings.backendToken)
                self.lastBackendError = nil
                if texts { self.lastSharedAt = .now }
            } catch {
                self.lastBackendError = error.localizedDescription
            }
        }
    }
}

/// When-in-use location for alerts and SOS. Asked for once; if the wearer
/// declines, alerts simply go out without a location.
@MainActor
final class ThermyxLocationProvider: NSObject, ObservableObject, CLLocationManagerDelegate {
    @Published private(set) var authorization: CLAuthorizationStatus
    private let manager = CLLocationManager()
    private var latest: CLLocation?

    override init() {
        authorization = manager.authorizationStatus
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyHundredMeters
    }

    var isAuthorized: Bool {
        authorization == .authorizedWhenInUse || authorization == .authorizedAlways
    }

    func requestPermission() {
        if authorization == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Asks for a fresh fix; the result is used by the next event.
    func refresh() {
        guard isAuthorized else { return }
        manager.requestLocation()
    }

    /// The last fix, if it is less than ten minutes old.
    var recent: ThermyxAlertEvent.AlertLocation? {
        guard let location = latest ?? manager.location,
              Date.now.timeIntervalSince(location.timestamp) < 600
        else { return nil }
        return .init(
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            accuracyM: location.horizontalAccuracy >= 0 ? location.horizontalAccuracy : nil
        )
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        let status = manager.authorizationStatus
        Task { @MainActor in
            self.authorization = status
            if self.isAuthorized { self.manager.requestLocation() }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard let last = locations.last else { return }
        Task { @MainActor in self.latest = last }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {}
}
