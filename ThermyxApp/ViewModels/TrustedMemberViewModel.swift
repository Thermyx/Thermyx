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

    /// Opt-in worked example, so a watcher can learn the screens before a real
    /// shift. Never on by default, and every screen is banner-marked while it
    /// is showing.
    @Published var isShowingSample = false

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

    private var timer: Timer?
    private let client = ThermyxAlertAPIClient()

    func start(settings: ThermyxSettingsStore) {
        stop()
        poll(settings: settings)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak settings] _ in
            guard let self, let settings else { return }
            Task { @MainActor in self.poll(settings: settings) }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }

    /// True once enough distinct statuses have arrived to draw a trend.
    var hasHistory: Bool { isShowingSample || recentEvents.count >= 3 }

    /// The status on screen: the sample when it is showing, otherwise whatever
    /// the backend last sent.
    func displayedEvent(deviceID: String) -> ThermyxAlertEvent? {
        isShowingSample ? TrustedSampleData.latestEvent(deviceID: deviceID) : latestEvent
    }

    var displayedHistory: [ThermyxHistorySample] {
        isShowingSample ? TrustedSampleData.shift() : []
    }

    /// Both feet at the current moment. Only the teaching sample has this:
    /// a live watcher deliberately receives no sensor readings, only the
    /// wearer's safety level and how fresh it is.
    var displayedBilateral: BilateralReading? {
        isShowingSample ? TrustedSampleData.bilateral() : nil
    }

    /// How long since the wearer's phone last posted anything. The wearer's
    /// app posts at least once a minute while an insole is connected, so a
    /// long silence means their phone, signal, or insoles went quiet — not
    /// that everything is fine.
    func silence(now: Date = .now) -> TimeInterval? {
        guard !isShowingSample, let latestEvent else { return nil }
        return now.timeIntervalSince(latestEvent.timestamp)
    }

    static let silenceWarning: TimeInterval = 3 * 60

    var displayedEvents: [ThermyxRiskEvent] {
        isShowingSample ? TrustedSampleData.events() : []
    }

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
                guard result.status == "approved" else {
                    access = .pending
                    latestEvent = nil
                    return
                }
                access = .approved
                guard let state = result.state else { latestEvent = nil; return }
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
                    notifyIfEscalated(event, previous: latestEvent)
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
                lastError = nil
            } catch {
                isConnected = false
                lastError = error.localizedDescription
            }
        }
    }

    /// A local notification when the wearer's level rises, they press SOS,
    /// or they check in — so the watcher hears about it without staring at
    /// the screen. (True background push needs APNs on the relay.)
    private func notifyIfEscalated(_ event: ThermyxAlertEvent, previous: ThermyxAlertEvent?) {
        guard previous != nil || event.kind == .sos else { return } // skip the first poll after launch
        let level = ThermyxRiskLevel(rawValue: event.level) ?? .unavailable
        let before = previous.flatMap { ThermyxRiskLevel(rawValue: $0.level) } ?? .normal
        let content = UNMutableNotificationContent()
        switch event.kind {
        case .sos:
            content.title = "SOS: they pressed Call 911"
        case .ok:
            content.title = "They checked in: I'm OK"
        default:
            guard level.severity > before.severity, level.severity >= ThermyxRiskLevel.caution.severity else { return }
            content.title = "Thermyx: \(level.rawValue)"
        }
        content.body = event.kind == .ok
            ? "They're OK."
            : (ThermyxRiskLevel(rawValue: event.level)?.explanation ?? "Open Thermyx to check on them.")
        content.sound = level == .critical || event.kind == .sos ? .defaultCritical : .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermyx.watch.\(event.timestamp.timeIntervalSince1970)", content: content, trigger: nil))
    }

    deinit { timer?.invalidate() }
}
