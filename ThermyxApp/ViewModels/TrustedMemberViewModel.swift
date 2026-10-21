import Combine
import Foundation
import UserNotifications

@MainActor
final class TrustedMemberViewModel: ObservableObject {
    @Published private(set) var latestEvent: ThermyxAlertEvent?
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    /// A rolling window of distinct statuses received this session, so the
    /// watcher's Insights tab can show how the shift has gone rather than only
    /// the current moment. Nothing is retained across launches — the watcher
    /// sees what the backend has actually sent them.
    @Published private(set) var recentEvents: [ThermyxAlertEvent] = []
    /// The wearer's status card as the relay last sent it: the detail, the
    /// current event's timeline, and a location during an active event.
    @Published private(set) var card: ThermyxAlertAPIClient.WatchState?

    /// Where this watcher stands with the wearer's relay.
    enum Access: Equatable {
        case notConnected
        /// Paired, but the wearer has not approved this watcher yet.
        case pending
        case approved
        /// The wearer removed this watcher, or access expired.
        case removed
    }
    @Published private(set) var access: Access = .notConnected

    private static let windowSize = 24

    /// True once the relay has this phone's push token and has push turned
    /// on: alerts then arrive from Apple, even with the app closed, so the
    /// app doesn't also post its own copy.
    @Published private(set) var pushActive = false
    private var registeredToken: String?
    private weak var settings: ThermyxSettingsStore?
    private var pushSubscription: AnyCancellable?

    private var timer: Timer?
    private let client = ThermyxAlertAPIClient()

    func start(settings: ThermyxSettingsStore) {
        #if DEBUG
        if let sample = Self.previewCard() {
            access = .approved
            isConnected = true
            card = sample
            latestEvent = ThermyxAlertEvent(
                deviceID: "", level: sample.level, reasons: [], recipients: [], timestamp: sample.updatedDate ?? .now,
                readings: .init(footTemperatureC: nil, ambientTemperatureC: nil, gaitStability: nil, pressureBalance: nil, batteryPercent: nil),
                kind: .init(rawValue: sample.kind), location: sample.location)
            return
        }
        #endif
        stop()
        self.settings = settings
        // A new token (first launch, reinstall, restore) goes to the relay.
        pushSubscription = ThermyxPushRegistrar.shared.$deviceToken
            .compactMap { $0 }
            .sink { [weak self] _ in self?.uploadPushToken() }
        poll(settings: settings)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak settings] _ in
            guard let self, let settings else { return }
            Task { @MainActor in self.poll(settings: settings) }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// True once enough distinct statuses have arrived to draw a trend.
    var hasHistory: Bool { recentEvents.count >= 3 }

    /// The status on screen: whatever the relay last sent.
    func displayedEvent(deviceID: String) -> ThermyxAlertEvent? { latestEvent }

    /// A watcher receives the wearer's safety level and its freshness, never
    /// their sensor history, so there is none to show.
    var displayedHistory: [ThermyxHistorySample] { [] }

    /// A live watcher deliberately receives no sensor readings.
    var displayedBilateral: BilateralReading? { nil }

    /// How long since the wearer's phone last posted anything. The wearer's
    /// app posts at least once a minute while an insole is connected, so a
    /// long silence means their phone, signal, or insoles went quiet — not
    /// that everything is fine.
    func silence(now: Date = .now) -> TimeInterval? {
        guard let latestEvent else { return nil }
        return now.timeIntervalSince(latestEvent.timestamp)
    }

    static let silenceWarning: TimeInterval = 3 * 60

    var displayedEvents: [ThermyxRiskEvent] { [] }

    private func poll(settings: ThermyxSettingsStore) {
        guard settings.isPairedWithRelay, settings.relayRole == "watcher" else {
            access = .notConnected
            isConnected = false
            lastError = nil
            return
        }
        let url = settings.backendURL
        let token = settings.backendToken
        Task {
            do {
                let result = try await client.watch(baseURL: url, token: token)
                isConnected = true
                lastError = nil
                uploadPushToken()
                guard result.status == "approved" else {
                    access = .pending
                    latestEvent = nil
                    card = nil
                    return
                }
                access = .approved
                guard let state = result.state else { latestEvent = nil; card = nil; return }
                if card != state { card = state }
                let event = ThermyxAlertEvent(
                    deviceID: "",
                    level: state.level,
                    reasons: [],
                    recipients: [],
                    timestamp: ThermyxAlertAPIClient.parseDate(state.updatedAt) ?? .now,
                    readings: .init(footTemperatureC: nil, ambientTemperatureC: nil, gaitStability: nil, pressureBalance: nil, batteryPercent: nil),
                    kind: ThermyxAlertEvent.Kind(rawValue: state.kind),
                    location: state.location
                )
                if event.timestamp != latestEvent?.timestamp {
                    notifyIfEscalated(event, previous: latestEvent, state: state)
                    recentEvents.append(event)
                    if recentEvents.count > Self.windowSize {
                        recentEvents.removeFirst(recentEvents.count - Self.windowSize)
                    }
                }
                latestEvent = event
            } catch ThermyxAlertAPIClient.ClientError.accessRemoved {
                access = .removed
                isConnected = false
                latestEvent = nil
                card = nil
                lastError = nil
            } catch {
                isConnected = false
                lastError = error.localizedDescription
            }
        }
    }

    /// Sends this phone's push token to the relay, once per token. Pending
    /// watchers register too; the relay pushes only to approved ones.
    private func uploadPushToken() {
        guard let settings, settings.isPairedWithRelay, settings.relayRole == "watcher",
              let deviceToken = ThermyxPushRegistrar.shared.deviceToken, deviceToken != registeredToken else { return }
        let environment = ThermyxPushRegistrar.shared.environment
        let url = settings.backendURL
        let token = settings.backendToken
        Task {
            guard let result = try? await client.registerPush(deviceToken: deviceToken, environment: environment, baseURL: url, token: token)
            else { return }
            registeredToken = deviceToken
            pushActive = result.pushEnabled
        }
    }

    /// A local notification when the wearer's level rises, they press SOS,
    /// they check in, or a follow-up arrives, worded like the text a trusted
    /// contact gets, so the watcher hears about it without staring at the
    /// screen, unless the relay is already pushing to this phone (APNs).
    private func notifyIfEscalated(_ event: ThermyxAlertEvent, previous: ThermyxAlertEvent?, state: ThermyxAlertAPIClient.WatchState) {
        guard !pushActive else { return } // Apple already delivers it
        guard previous != nil || event.kind == .sos else { return } // skip the first poll after launch
        let level = ThermyxRiskLevel(rawValue: event.level) ?? .unavailable
        let before = previous.flatMap { ThermyxRiskLevel(rawValue: $0.level) } ?? .normal
        var kind = event.kind?.rawValue ?? "alert"
        switch event.kind {
        case .sos, .ok, .update, .help, .test: break
        default:
            // A heartbeat that shows a rise reads as an alert.
            guard level.severity > before.severity, level.severity >= ThermyxRiskLevel.caution.severity else { return }
            kind = "alert"
        }
        let text = ThermyxCircleMessage.text(
            level: event.level, kind: kind, detail: state.detail,
            locationConsent: state.location != nil,
            location: state.location.map { .init(latitude: $0.latitude, longitude: $0.longitude) }
        )
        var lines = text.components(separatedBy: "\n")
        let content = UNMutableNotificationContent()
        content.title = lines.isEmpty ? "Thermyx" : lines.removeFirst()
        // The watcher has the map on screen; the link isn't needed here.
        content.body = lines.filter { !$0.hasPrefix("Location") && $0 != ThermyxCircleMessage.followUp }.joined(separator: " ")
        let urgent = level.severity >= ThermyxRiskLevel.high.severity || event.kind == .sos || event.kind == .help
        content.sound = level == .critical || event.kind == .sos ? .defaultCritical : .default
        content.interruptionLevel = urgent ? .timeSensitive : .active
        content.threadIdentifier = "thermyx.watch"
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermyx.watch.\(event.timestamp.timeIntervalSince1970)", content: content, trigger: nil))
    }

    #if DEBUG
    /// `-ThermyxUIPreview trustedHandoff` / `trustedRecovered`: a sample event.
    private static func previewCard(now: Date = .now) -> ThermyxAlertAPIClient.WatchState? {
        let recovered = ThermyxPreviewHarness.state == .trustedRecovered
        guard ThermyxPreviewHarness.state == .trustedHandoff || recovered else { return nil }
        let iso = ISO8601DateFormatter()
        func at(_ minutesAgo: Double) -> String { iso.string(from: now.addingTimeInterval(-minutesAgo * 60)) }
        var detail = ThermyxCircleDetail()
        detail.name = "Miheer"
        detail.foot = "right"
        detail.causes = recovered ? nil : ["hot", "unsteady"]
        detail.footC = recovered ? 36.9 : 38.7
        detail.trend = recovered ? "falling" : "rising"
        detail.confidence = "confirmed"
        detail.battery = recovered ? nil : .init(foot: "left", percent: 9)
        var timeline: [ThermyxAlertAPIClient.TimelineEntry] = [
            .init(at: at(9), kind: "alert", level: "High risk"),
            .init(at: at(7), kind: "update", level: "High risk", update: "still"),
            .init(at: at(5), kind: "alert", level: "Critical"),
        ]
        if recovered {
            timeline += [
                .init(at: at(4), kind: "ok", level: "Critical"),
                .init(at: at(1), kind: "update", level: "Caution", update: "recovering"),
            ]
        }
        return .init(
            level: recovered ? "Caution" : "Critical", kind: recovered ? "update" : "alert", updatedAt: at(0.2),
            location: recovered ? nil : .init(latitude: 29.76043, longitude: -95.36981, accuracyM: 30, expiresAt: at(-55)),
            detail: detail, since: at(9), timeline: timeline)
    }
    #endif

    deinit { timer?.invalidate() }
}
