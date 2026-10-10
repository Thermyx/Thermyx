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

    /// The rules for when to notify, alert, and post a heartbeat.
    private var policy = ThermyxAlertPolicy()

    /// Set while Demo Mode runs: nothing is posted to the relay, and the
    /// wearer's own notifications say they are simulated.
    var isDemoMode = false

    // MARK: End-of-session AI summary

    /// At most this often, so a stop-start day doesn't spam.
    static let summaryGap: TimeInterval = 2 * 3600
    private static let lastSummaryKey = "thermyx.aiSummary.lastAt"

    static func summaryKey(for day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "thermyx.aiSummary.%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The last AI summary written for a day, if any.
    static func storedSummary(for day: Date) -> String? {
        UserDefaults.standard.string(forKey: summaryKey(for: day))
    }

    /// When a session ends: asks the relay for a short summary of today with
    /// two or three suggestions, keeps it for the day page, and sends it as a
    /// notification. Only for a paired wearer, never in Demo Mode, and only
    /// if the relay has AI summaries turned on.
    func deliverSessionSummary(history: ThermyxHistoryStore, settings: ThermyxSettingsStore, now: Date = .now) {
        guard !isDemoMode, settings.isPairedWithRelay, settings.relayRole == "wearer" else { return }
        let defaults = UserDefaults.standard
        if let last = defaults.object(forKey: Self.lastSummaryKey) as? Date, now.timeIntervalSince(last) < Self.summaryGap { return }
        let calendar = Calendar.current
        let samples = history.hourSamples.filter { calendar.isDate($0.start, inSameDayAs: now) }
        guard !samples.isEmpty else { return }
        let today = ThermyxDailySummary.summary(
            day: calendar.startOfDay(for: now),
            samples: samples,
            events: history.events.filter { calendar.isDate($0.timestamp, inSameDayAs: now) }
        )
        defaults.set(now, forKey: Self.lastSummaryKey)
        let body = ThermyxAlertAPIClient.SummaryRequest(today, unit: settings.temperatureUnit, focus: settings.profile.focus)
        let url = settings.backendURL
        let token = settings.backendToken
        Task {
            guard let text = try? await apiClient.summary(body, baseURL: url, token: token) else { return }
            defaults.set(text, forKey: Self.summaryKey(for: now))
            let content = UNMutableNotificationContent()
            content.title = "Your Thermyx summary"
            content.body = text
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: "thermyx.summary", content: content, trigger: nil)
            )
        }
    }

    /// Cold-foot and low-battery reminders, for the wearer only.
    private var comfort = ThermyxComfortWatch()

    /// Called on every reading alongside `evaluate`: notifies the wearer when
    /// a foot stays cold or an insole battery runs low. Never sent to the
    /// relay or the trusted circle.
    func evaluateComfort(_ reading: BilateralReading, unit: TemperatureUnit, now: Date = .now) {
        for notice in comfort.update(reading, now: now) {
            let content = UNMutableNotificationContent()
            content.title = isDemoMode ? "Thermyx demo — simulated, not live data" : notice.title
            content.body = notice.body(unit: unit)
            content.sound = .default
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
        }
    }

    func requestPermission() async {
        notificationsAuthorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Re-reads the permission, e.g. after the wearer comes back from
    /// Settings.
    func refreshPermission() async {
        let status = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        notificationsAuthorized = status == .authorized || status == .provisional || status == .ephemeral
    }

    /// A harmless notification so the wearer can check alerts reach them.
    func sendTestNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Thermyx test"
        content.body = "Notifications are working. Safety alerts, cold and battery reminders, and your session summary will look like this."
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "thermyx.test", content: content,
                                  trigger: UNTimeIntervalNotificationTrigger(timeInterval: 3, repeats: false))
        )
    }

    /// Called on every reading. ThermyxAlertPolicy decides; this carries it out.
    func evaluate(_ assessment: ThermyxRiskAssessment, reading: BilateralReading, settings: ThermyxSettingsStore) {
        let level = assessment.level
        let decision = policy.evaluate(level, alertsEnabled: settings.shouldAlert(for: level))
        if lastAlertLevel != policy.announced { lastAlertLevel = policy.announced }

        if decision.notifyWearer { notifyWearer(level) }
        if decision.alert {
            location.refresh()
            send(kind: .alert, level: level, reasons: assessment.reasons, focus: assessment.foot, reading: reading, settings: settings, texts: true)
        } else if decision.heartbeat {
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
        policy.imOK()
        let current = level == .unavailable ? .normal : level
        send(kind: .ok, level: current, reasons: ["The wearer says they're OK."], focus: nil, reading: reading, settings: settings, texts: true)
    }

    private func notifyWearer(_ level: ThermyxRiskLevel) {
        let content = UNMutableNotificationContent()
        content.title = isDemoMode ? "Thermyx demo — simulated, not live data" : "Thermyx safety alert"
        content.body = level.explanation
        content.sound = level == .critical ? .defaultCritical : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermyx.\(level.rawValue)", content: content, trigger: nil))
    }

    /// Pushes an event to the relay. Approved watchers see its level and
    /// freshness. Trusted contacts' numbers go along only when the relay has
    /// texting turned on, and location only when the wearer consented and a
    /// safety event (High, Critical, SOS) is active.
    private func send(
        kind: ThermyxAlertEvent.Kind,
        level: ThermyxRiskLevel,
        reasons: [String],
        focus: Foot?,
        reading: BilateralReading,
        settings: ThermyxSettingsStore,
        texts: Bool
    ) {
        guard !isDemoMode, settings.isPairedWithRelay, settings.relayRole == "wearer" else { return }

        let activeEvent = kind == .sos || level.severity >= ThermyxRiskLevel.high.severity
        let consented = settings.shareLocationDuringEvents
        let recipients = texts && settings.relayTextingEnabled
            ? settings.contacts.filter(\.enabled).map(\.phoneNumber)
            : nil
        let event = ThermyxAlertAPIClient.Event(
            level: level.rawValue,
            kind: kind.rawValue,
            reasons: texts ? reasons : [],
            recipients: recipients,
            location: consented && activeEvent ? location.recent : nil,
            locationConsent: consented
        )

        let url = settings.backendURL
        let token = settings.backendToken
        Task {
            do {
                let result = try await apiClient.send(event: event, baseURL: url, token: token)
                self.lastBackendError = nil
                if let enabled = result.smsEnabled { settings.relayTextingEnabled = enabled }
                if (result.texted ?? 0) > 0 { self.lastSharedAt = .now }
            } catch {
                self.lastBackendError = error.localizedDescription
            }
        }
    }

    /// Withdraws location sharing on the relay straight away, rather than
    /// waiting for the next event.
    func stopSharingLocation(level: ThermyxRiskLevel, settings: ThermyxSettingsStore) {
        settings.shareLocationDuringEvents = false
        let current = level == .unavailable ? ThermyxRiskLevel.normal : level
        send(kind: .status, level: current, reasons: [], focus: nil, reading: .empty, settings: settings, texts: false)
    }

    /// The text a trusted contact would receive, for the labelled preview
    /// shown while texting is off.
    static func previewMessage(level: ThermyxRiskLevel, reasons: [String], deviceID: String, includesLocation: Bool) -> String {
        var parts = [deviceID.isEmpty ? "Thermyx \(level.rawValue) alert." : "Thermyx \(level.rawValue) on \(deviceID)."]
        if !reasons.isEmpty { parts.append(reasons.joined(separator: " ")) }
        if includesLocation { parts.append("Location: (a map link to where you are)") }
        parts.append("Please check on them.")
        return parts.joined(separator: " ")
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


/// Decides when to remind the wearer about a cold foot or a low battery.
///
/// - Cold: a foot at or below `ThermyxRiskEngine.coldFootC` for a minute.
///   Once per 20 minutes per foot, and reset when the foot warms past 27 °C.
/// - Battery: once at 20% and once at 10% per insole, reset after charging
///   above 25%.
struct ThermyxComfortWatch {
    struct Notice: Equatable {
        enum Kind: Equatable {
            case cold(Double)
            case battery(Int, critical: Bool)
        }
        let foot: Foot
        let kind: Kind

        var id: String {
            switch kind {
            case .cold: return "thermyx.cold.\(foot.rawValue)"
            case .battery: return "thermyx.battery.\(foot.rawValue)"
            }
        }

        var title: String {
            switch kind {
            case .cold: return "\(foot.label) foot is cold"
            case .battery(_, let critical): return critical ? "\(foot.label) insole battery very low" : "\(foot.label) insole battery low"
            }
        }

        func body(unit: TemperatureUnit) -> String {
            switch kind {
            case .cold(let c):
                return "It's been at \(TemperatureFormat.degrees(c, in: unit)) for a minute. Switch to Auto or Heat to warm it up."
            case .battery(let percent, let critical):
                return critical
                    ? "\(percent)% left. Charge it now or it will stop heating and cooling soon."
                    : "\(percent)% left. Charge it soon."
            }
        }
    }

    static let coldHold: TimeInterval = 60
    static let coldRepeat: TimeInterval = 20 * 60
    static let warmResetC = 27.0
    static let batteryLow = 20
    static let batteryCritical = 10
    static let batteryReset = 25

    private var coldSince: [Foot: Date] = [:]
    private var coldNotifiedAt: [Foot: Date] = [:]
    private var batteryWarned: [Foot: Int] = [:]

    mutating func update(_ reading: BilateralReading, now: Date) -> [Notice] {
        var notices: [Notice] = []
        for r in reading.present {
            let foot = r.foot
            if let c = r.footTemperatureC {
                if c <= ThermyxRiskEngine.coldFootC {
                    let since = coldSince[foot] ?? now
                    coldSince[foot] = since
                    let due = coldNotifiedAt[foot].map { now.timeIntervalSince($0) >= Self.coldRepeat } ?? true
                    if now.timeIntervalSince(since) >= Self.coldHold, due {
                        coldNotifiedAt[foot] = now
                        notices.append(Notice(foot: foot, kind: .cold(c)))
                    }
                } else {
                    coldSince[foot] = nil
                    if c >= Self.warmResetC { coldNotifiedAt[foot] = nil }
                }
            }
            if let b = r.batteryPercent {
                if b > Self.batteryReset { batteryWarned[foot] = nil }
                let threshold = b <= Self.batteryCritical ? Self.batteryCritical : b <= Self.batteryLow ? Self.batteryLow : nil
                if let threshold, (batteryWarned[foot] ?? Int.max) > threshold {
                    batteryWarned[foot] = threshold
                    notices.append(Notice(foot: foot, kind: .battery(b, critical: threshold == Self.batteryCritical)))
                }
            }
        }
        return notices
    }
}
