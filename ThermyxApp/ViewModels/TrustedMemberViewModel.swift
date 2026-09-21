import Foundation

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

    private static let windowSize = 24

    private var timer: Timer?
    private let client = ThermyxAlertAPIClient()

    func start(settings: ThermyxSettingsStore, deviceID: String) {
        stop()
        poll(settings: settings, deviceID: deviceID)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak settings] _ in
            guard let self, let settings else { return }
            Task { @MainActor in self.poll(settings: settings, deviceID: deviceID) }
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

    /// Both feet at the current moment. Only the sample provides this today;
    /// the shared backend carries a single summary per event, so a live
    /// watcher sees the summary until the backend learns to send both.
    var displayedBilateral: BilateralReading? {
        isShowingSample ? TrustedSampleData.bilateral() : nil
    }

    var displayedEvents: [ThermyxRiskEvent] {
        isShowingSample ? TrustedSampleData.events() : []
    }

    private func poll(settings: ThermyxSettingsStore, deviceID: String) {
        guard !settings.backendURL.isEmpty else {
            isConnected = false
            lastError = nil
            return
        }
        Task {
            do {
                let event = try await client.fetchStatus(deviceID: deviceID, backendURL: settings.backendURL, token: settings.backendToken)
                if let event, event.timestamp != latestEvent?.timestamp {
                    recentEvents.append(event)
                    if recentEvents.count > Self.windowSize {
                        recentEvents.removeFirst(recentEvents.count - Self.windowSize)
                    }
                }
                latestEvent = event
                isConnected = true
                lastError = nil
            } catch {
                isConnected = false
                lastError = error.localizedDescription
            }
        }
    }

    deinit { timer?.invalidate() }
}
