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

    /// The rules for when to notify, alert, follow up, and post a heartbeat.
    private var policy = ThermyxAlertPolicy()
    /// Trend and data confidence for the circle's messages.
    private var tracker = ThermyxCircleTracker()
    /// The latest assessment, for the status card on an SOS or check-in.
    private var lastAssessment: ThermyxRiskAssessment = .unavailable

    /// Set while Demo Mode runs: nothing is posted to the relay unless the
    /// Demo studio routes it to test recipients.
    var isDemoMode = false

    // MARK: Demo studio (admins)

    /// Where the Demo studio's alerts go: the teammates' numbers picked
    /// there. Pushes go to the relay account's approved watchers. Nil means
    /// the demo posts nothing, as before.
    struct TestRoute: Equatable {
        var recipients: [String]
    }
    var testRoute: TestRoute?
    /// The studio's test buttons text these numbers (whether or not the
    /// timeline's alerts are routed).
    var studioRecipients: [String] = []
    private var quietTask: Task<Void, Never>?

    /// The studio's "phone goes quiet": holds posts for a while, so the relay
    /// tells the circle the phone went silent, then lets go.
    func holdPosts(for seconds: TimeInterval) {
        quietTask?.cancel()
        holdingPosts = true
        lastTestResult = "Quiet for \(Int(seconds / 60)) minutes. The relay texts after 3 minutes of silence during an active alert."
        quietTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(seconds))
            guard !Task.isCancelled else { return }
            self?.holdingPosts = false
        }
    }
    /// Demo notifications look exactly like real ones, for recording. Off,
    /// they say they're simulated.
    var recordingMode = true
    /// The Demo studio's "phone goes quiet": nothing is posted until it ends.
    @Published var holdingPosts = false
    /// The last test send's outcome, for the studio and Safety.
    @Published private(set) var lastTestResult: String?
    /// Asks the app to show the Critical takeover (a studio test).
    @Published var criticalTestRequest: Date?

    // MARK: What led up to an SOS

    private var episodeStartedAt: Date?
    private var episodePeak: ThermyxRiskLevel = .normal
    @Published private(set) var lastCheckInAt: Date?

    // MARK: Daily AI summary
    //
    // One summary per day, written in the evening: the first time a session
    // ends after 8:30 pm. A day that never got one (no evening wear, or the app
    // wasn't open) is caught up the next time the app opens. Once a day keeps
    // the Claude API cost down; the summary is kept and shown, never redone.

    /// The evening starts here, local time: 8:30 pm.
    static let eveningHour = 20
    static let eveningMinute = 30
    static let eveningNotificationID = "thermyx.insights.evening"

    /// 8:30 pm or later, local time.
    static func isEvening(_ date: Date, calendar: Calendar = .current) -> Bool {
        let c = calendar.dateComponents([.hour, .minute], from: date)
        return (c.hour ?? 0, c.minute ?? 0) >= (eveningHour, eveningMinute)
    }

    private var eveningCheckedAt = Date.distantPast

    /// On a day the insoles were worn, a notification at 8:30 pm local time
    /// that opens AI Insights for the day. Scheduled once a day; harmless to
    /// call often.
    func scheduleEveningInsights(history: ThermyxHistoryStore, settings: ThermyxSettingsStore, now: Date = .now,
                                 calendar: Calendar = .current) {
        guard now.timeIntervalSince(eveningCheckedAt) >= 600 else { return }
        eveningCheckedAt = now
        guard canSummarize(settings), !Self.isEvening(now, calendar: calendar) else { return }
        let worn = history.hourSamples.filter { calendar.isDateInToday($0.start) }
        let summary = ThermyxDailySummary.summary(day: now, samples: worn, events: [])
        guard summary.wornSeconds >= ThermyxWeeklyReport.minimumWear else { return }
        var at = calendar.dateComponents([.year, .month, .day], from: now)
        at.hour = Self.eveningHour
        at.minute = Self.eveningMinute
        let content = UNMutableNotificationContent()
        content.title = "Your day with Thermyx"
        content.body = "Your insights for today are ready. Tap to read them, or ask about your day."
        content.sound = .default
        content.threadIdentifier = "thermyx.insights"
        content.userInfo = ["insightsDay": calendar.startOfDay(for: now).timeIntervalSince1970]
        UNUserNotificationCenter.current().add(UNNotificationRequest(
            identifier: Self.eveningNotificationID, content: content,
            trigger: UNCalendarNotificationTrigger(dateMatching: at, repeats: false)))
    }
    private static let pendingKey = "thermyx.aiSummary.pending"

    static func summaryKey(for day: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: day)
        return String(format: "thermyx.aiSummary.%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    /// The summary written for a day, if any.
    static func storedSummary(for day: Date) -> String? {
        UserDefaults.standard.string(forKey: summaryKey(for: day))
    }

    static func store(_ summary: String, for day: Date) {
        UserDefaults.standard.set(summary, forKey: summaryKey(for: day))
    }

    /// Whether this phone may ask for summaries at all.
    private func canSummarize(_ settings: ThermyxSettingsStore) -> Bool {
        !isDemoMode && settings.aiInsightsEnabled && settings.isPairedWithRelay && settings.relayRole == "wearer"
    }

    /// When a session ends: in the evening, today's summary, once.
    func deliverSessionSummary(history: ThermyxHistoryStore, settings: ThermyxSettingsStore, now: Date = .now,
                               calendar: Calendar = .current) {
        guard canSummarize(settings), Self.isEvening(now, calendar: calendar) else { return }
        deliverSummary(for: now, history: history, settings: settings, title: "Your day with Thermyx", calendar: calendar)
    }

    /// On launch: yesterday's summary, if it was worn and never got one.
    func catchUpSummary(history: ThermyxHistoryStore, settings: ThermyxSettingsStore, now: Date = .now,
                        calendar: Calendar = .current) {
        guard canSummarize(settings),
              let yesterday = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: now)) else { return }
        deliverSummary(for: yesterday, history: history, settings: settings, title: "Yesterday with Thermyx", calendar: calendar)
    }

    private func deliverSummary(for date: Date, history: ThermyxHistoryStore, settings: ThermyxSettingsStore,
                                title: String, calendar: Calendar) {
        let day = calendar.startOfDay(for: date)
        let key = Self.summaryKey(for: day, calendar: calendar)
        let defaults = UserDefaults.standard
        guard Self.storedSummary(for: day) == nil, defaults.string(forKey: Self.pendingKey) != key else { return }
        let samples = history.hourSamples.filter { calendar.isDate($0.start, inSameDayAs: day) }
        guard !samples.isEmpty else { return }
        let summary = ThermyxDailySummary.summary(
            day: day,
            samples: samples,
            events: history.events.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
        )
        guard summary.wornSeconds >= ThermyxWeeklyReport.minimumWear else { return }
        defaults.set(key, forKey: Self.pendingKey)
        let body = ThermyxAlertAPIClient.SummaryRequest(summary, unit: settings.temperatureUnit, focus: settings.profile.focus,
                                                        usage: settings.usage)
        let url = settings.backendURL
        let token = settings.backendToken
        Task {
            defer { if defaults.string(forKey: Self.pendingKey) == key { defaults.removeObject(forKey: Self.pendingKey) } }
            guard let text = try? await apiClient.summary(body, baseURL: url, token: token) else { return }
            Self.store(text, for: day)
            // Same identifier as the 8:30 pm reminder, so a summary written
            // late replaces it instead of arriving as a second notification.
            let content = UNMutableNotificationContent()
            content.title = title
            content.body = text
            content.sound = .default
            content.threadIdentifier = "thermyx.insights"
            content.userInfo = ["insightsDay": day.timeIntervalSince1970]
            try? await UNUserNotificationCenter.current().add(
                UNNotificationRequest(identifier: Self.eveningNotificationID, content: content, trigger: nil)
            )
        }
    }

    /// Cold-foot and low-battery reminders, for the wearer only.
    private var comfort = ThermyxComfortWatch()

    /// Called on every reading alongside `evaluate`: notifies the wearer when
    /// a foot stays cold or an insole battery runs low. Never sent to the
    /// relay or the trusted circle.
    func evaluateComfort(_ reading: BilateralReading, unit: TemperatureUnit, conditions: Set<HealthCondition> = [], now: Date = .now) {
        comfort.circulationRisk = !conditions.isDisjoint(with: ThermyxComfortWatch.circulationConditions)
        for notice in comfort.update(reading, now: now) {
            let content = UNMutableNotificationContent()
            content.title = isDemoMode && !recordingMode ? "Thermyx demo — simulated, not live data" : notice.title
            content.body = notice.body(unit: unit)
            content.sound = .default
            content.threadIdentifier = "thermyx.comfort"
            if case .battery(_, let critical) = notice.kind, critical { content.interruptionLevel = .timeSensitive }
            UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: notice.id, content: content, trigger: nil))
        }
    }

    func requestPermission() async {
        notificationsAuthorized = (try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])) ?? false
    }

    /// Called on every reading. ThermyxAlertPolicy decides; this carries it out.
    func evaluate(_ assessment: ThermyxRiskAssessment, reading: BilateralReading, settings: ThermyxSettingsStore, now: Date = .now) {
        let level = assessment.level
        tracker.record(reading, now: now)
        lastAssessment = assessment
        // A Caution that's only about left vs right (leaning, a limp, one
        // foot warmer) is the wearer's to know, not a reason to text anyone.
        let leftRightOnly = level == .caution && !assessment.causes.isEmpty
            && assessment.causes.allSatisfy { [.limp, .unevenLoad, .warmerFoot].contains($0) }
        let decision = policy.evaluate(level, alertsEnabled: settings.shouldAlert(for: level) && !leftRightOnly, now: now)
        if lastAlertLevel != policy.announced { lastAlertLevel = policy.announced }
        if policy.announced.severity >= ThermyxRiskLevel.caution.severity {
            if episodeStartedAt == nil { episodeStartedAt = now }
            if policy.announced.severity > episodePeak.severity { episodePeak = policy.announced }
        } else {
            episodeStartedAt = nil
            episodePeak = .normal
        }

        if decision.notifyWearer { notifyWearer(level) }
        if decision.alert {
            location.refresh()
            send(kind: .alert, level: level, assessment: assessment, reading: reading, settings: settings, texts: true)
        } else if let followUp = decision.followUp {
            if case .still = followUp { location.refresh() }
            send(kind: .update, level: level, assessment: assessment, reading: reading, settings: settings, texts: true) { detail in
                switch followUp {
                case .still(let minutes): detail.update = "still"; detail.minutes = minutes
                case .recovering: detail.update = "recovering"
                case .resolved: detail.update = "resolved"
                }
            }
        } else if decision.heartbeat {
            send(kind: .status, level: level, assessment: assessment, reading: reading, settings: settings, texts: false)
        }
    }

    /// Why an SOS went out.
    enum SOSTrigger: String {
        /// The wearer pressed Call 911.
        case pressed
        /// Nobody answered a Critical alert's countdown.
        case noResponse
    }

    /// An SOS: texts the trusted circle with location.
    func notifyTrustedCircle(
        level: ThermyxRiskLevel,
        reading: BilateralReading,
        settings: ThermyxSettingsStore,
        trigger: SOSTrigger
    ) {
        location.refresh()
        send(kind: .sos, level: level, assessment: lastAssessment, reading: reading, settings: settings, texts: true) { detail in
            detail.sos = trigger.rawValue
            self.addContext(&detail)
        }
    }

    /// The level and time behind an SOS or help request, and the last check-in.
    private func addContext(_ detail: inout ThermyxCircleDetail, now: Date = .now) {
        if let start = episodeStartedAt, episodePeak.severity >= ThermyxRiskLevel.caution.severity {
            detail.episodeLevel = episodePeak.rawValue
            detail.episodeMinutes = max(1, Int(now.timeIntervalSince(start) / 60))
        }
        if let ok = lastCheckInAt, now.timeIntervalSince(ok) < 12 * 3600 {
            detail.lastCheckIn = ThermyxCircleDetail.localTime(ok)
        }
    }

    // MARK: Help without 911

    enum HelpPreset: String, CaseIterable, Identifiable {
        case water, walk, pickup, unwell
        var id: String { rawValue }
        var label: String {
            switch self {
            case .water: return "Need water"
            case .walk: return "Can't walk well"
            case .pickup: return "Come get me"
            case .unwell: return "Feeling unwell"
            }
        }
        var symbol: String {
            switch self {
            case .water: return "drop.fill"
            case .walk: return "figure.walk.motion"
            case .pickup: return "car.fill"
            case .unwell: return "heart.text.square"
            }
        }
    }

    /// Asks the circle for help, without calling 911: a text and a push with
    /// what's wrong, a short note, and the location (when shared).
    func askForHelp(_ preset: HelpPreset?, note: String, reading: BilateralReading, settings: ThermyxSettingsStore,
                    test: Bool = false, completion: ((String) -> Void)? = nil) {
        location.refresh()
        let level = lastAssessment.level == .unavailable ? ThermyxRiskLevel.normal : lastAssessment.level
        send(kind: .help, level: level, assessment: lastAssessment, reading: reading, settings: settings, texts: true,
             test: test, completion: completion) { detail in
            detail.help = preset?.rawValue
            detail.note = ThermyxCircleMessage.plainNote(note)
            self.addContext(&detail)
        }
    }

    // MARK: Tests

    /// A wearer's "send a test to my circle": labelled TEST, at most every
    /// ten minutes (the relay enforces it too).
    static let circleTestGap: TimeInterval = 10 * 60
    private static let circleTestKey = "thermyx.circleTest.last"

    var nextCircleTest: Date? {
        let last = UserDefaults.standard.double(forKey: Self.circleTestKey)
        guard last > 0 else { return nil }
        let next = Date(timeIntervalSince1970: last).addingTimeInterval(Self.circleTestGap)
        return next > .now ? next : nil
    }

    func sendCircleTest(settings: ThermyxSettingsStore, completion: @escaping (String) -> Void) {
        guard nextCircleTest == nil else { completion("You can send another test in a few minutes."); return }
        UserDefaults.standard.set(Date.now.timeIntervalSince1970, forKey: Self.circleTestKey)
        send(kind: .test, level: .normal, assessment: .unavailable, reading: .empty, settings: settings, texts: true,
             realCircle: true, completion: completion)
    }

    /// Demo studio: an alert of any kind, real-looking, to the test
    /// recipients only.
    func sendStudioTest(_ kind: ThermyxAlertEvent.Kind, level: ThermyxRiskLevel, reading: BilateralReading,
                        settings: ThermyxSettingsStore, adjust: @escaping (inout ThermyxCircleDetail) -> Void = { _ in }) {
        if kind == .sos || kind == .help || level.severity >= ThermyxRiskLevel.high.severity { location.refresh() }
        let assessment = lastAssessment.level == level ? lastAssessment
            : ThermyxRiskAssessment(level: level, reasons: [], foot: lastAssessment.foot ?? reading.hotterFoot,
                                    causes: level.severity >= ThermyxRiskLevel.caution.severity ? (lastAssessment.causes.isEmpty ? [.hot] : lastAssessment.causes) : [])
        send(kind: kind, level: level, assessment: assessment, reading: reading, settings: settings, texts: true, test: true,
             completion: { self.lastTestResult = $0 }) { detail in
            if kind == .sos || kind == .help { self.addContext(&detail) }
            adjust(&detail)
        }
    }

    /// Demo studio: the wearer's own notification at a level, as it looks for real.
    func testWearerNotification(_ level: ThermyxRiskLevel, after seconds: TimeInterval = 0) {
        notifyWearer(level, real: true, after: seconds)
    }

    /// The wearer checked in: tell the trusted circle they're OK, and when.
    func sendImOK(level: ThermyxRiskLevel, reading: BilateralReading, settings: ThermyxSettingsStore, now: Date = .now) {
        policy.imOK(now: now)
        lastCheckInAt = now
        let current = level == .unavailable ? .normal : level
        send(kind: .ok, level: current, assessment: lastAssessment, reading: reading, settings: settings, texts: true) { detail in
            detail.checkedIn = ThermyxCircleDetail.localTime(now)
        }
    }

    private func notifyWearer(_ level: ThermyxRiskLevel, real: Bool = false, after seconds: TimeInterval = 0) {
        let content = UNMutableNotificationContent()
        content.title = isDemoMode && !recordingMode && !real ? "Thermyx demo — simulated, not live data" : "Thermyx: \(level.rawValue)"
        content.body = level.explanation
        content.sound = level == .critical ? .defaultCritical : .default
        content.interruptionLevel = Self.interruption(for: level)
        content.relevanceScore = Double(max(0, level.severity)) / 3
        content.threadIdentifier = "thermyx.safety"
        // A delayed test lets you lock the phone or switch apps before it fires.
        let trigger = seconds > 0 ? UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false) : nil
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "thermyx.\(level.rawValue)", content: content, trigger: trigger))
    }

    /// High risk and Critical break through Focus (Time Sensitive). Needs the
    /// Time Sensitive Notifications capability on the paid team; without it
    /// iOS delivers them as ordinary notifications.
    nonisolated static func interruption(for level: ThermyxRiskLevel) -> UNNotificationInterruptionLevel {
        level.severity >= ThermyxRiskLevel.high.severity ? .timeSensitive : .active
    }

    /// Pushes an event to the relay with the status card. Approved watchers
    /// see the card; trusted contacts are texted it as sentences when texting
    /// is on. Their numbers go along only then, and location only when the
    /// wearer shares it and a safety event (High, Critical, SOS) is active.
    private func send(
        kind: ThermyxAlertEvent.Kind,
        level: ThermyxRiskLevel,
        assessment: ThermyxRiskAssessment,
        reading: BilateralReading,
        settings: ThermyxSettingsStore,
        texts: Bool,
        test: Bool = false,
        realCircle: Bool = false,
        completion: ((String) -> Void)? = nil,
        adjust: (inout ThermyxCircleDetail) -> Void = { _ in }
    ) {
        guard settings.isPairedWithRelay, settings.relayRole == "wearer" else {
            completion?("Connect to the relay first (Safety → Advanced).")
            return
        }
        // The demo posts only what the studio routes to test recipients, and
        // its test buttons. "Phone goes quiet" holds everything but tests.
        let routed = isDemoMode || test
        if isDemoMode, !test, testRoute == nil { return }
        if holdingPosts, !test, kind != .test { return }

        let activeEvent = kind == .sos || kind == .help || level.severity >= ThermyxRiskLevel.high.severity
        let consented = settings.shareLocationDuringEvents
        let circle = settings.contacts.filter(\.enabled).map(\.phoneNumber)
        let numbers = realCircle ? circle : test ? studioRecipients : routed ? (testRoute?.recipients ?? []) : circle
        let recipients = texts && settings.relayTextingEnabled && !numbers.isEmpty ? numbers : nil
        var detail = ThermyxCircleDetail.make(assessment: assessment, reading: reading, tracker: tracker,
                                              name: settings.circleName, unit: settings.temperatureUnit)
        adjust(&detail)
        let event = ThermyxAlertAPIClient.Event(
            level: level.rawValue,
            kind: kind.rawValue,
            recipients: recipients,
            location: consented && activeEvent ? location.recent : nil,
            locationConsent: consented,
            detail: detail,
            test: test ? true : nil
        )

        let url = settings.backendURL
        let token = settings.backendToken
        Task {
            do {
                let result = try await apiClient.send(event: event, baseURL: url, token: token)
                self.lastBackendError = nil
                if let enabled = result.smsEnabled { settings.relayTextingEnabled = enabled }
                if (result.texted ?? 0) > 0 { self.lastSharedAt = .now }
                completion?(Self.outcome(result, textingOn: settings.relayTextingEnabled, hadNumbers: recipients != nil))
            } catch {
                self.lastBackendError = error.localizedDescription
                completion?(error.localizedDescription)
            }
        }
    }

    /// "Texted 2, pushed 1", or why nothing went.
    static func outcome(_ r: ThermyxAlertAPIClient.EventResult, textingOn: Bool, hadNumbers: Bool) -> String {
        let texted = r.texted ?? 0, pushed = r.pushed ?? 0
        var parts: [String] = []
        if texted > 0 { parts.append("texted \(texted)") }
        if pushed > 0 { parts.append("pushed to \(pushed) watcher\(pushed == 1 ? "" : "s")") }
        if !parts.isEmpty { return "Sent: " + parts.joined(separator: ", ") + "." }
        if r.reason == "throttled" { return "Not sent: the relay held it back (too soon after the last one)." }
        if !textingOn { return "Not texted: texting is off on the relay. No watcher has push set up yet." }
        if !hadNumbers { return "Nobody to text: pick test recipients first." }
        return "Nothing was sent."
    }

    /// Withdraws location sharing on the relay straight away, rather than
    /// waiting for the next event.
    func stopSharingLocation(level: ThermyxRiskLevel, settings: ThermyxSettingsStore) {
        settings.shareLocationDuringEvents = false
        let current = level == .unavailable ? ThermyxRiskLevel.normal : level
        send(kind: .status, level: current, assessment: lastAssessment, reading: .empty, settings: settings, texts: false)
    }

    /// The text a trusted contact would get, for the preview on Safety: the
    /// real one when the wearer is at High risk or above right now, else a
    /// labelled example (the right foot at 101.5 °F and rising) in their name,
    /// unit and time, so it never pairs a normal reading with an alarm.
    func previewMessage(reading: BilateralReading, settings: ThermyxSettingsStore, shareLocation: Bool? = nil) -> String {
        let shareLocation = shareLocation ?? settings.shareLocationDuringEvents
        let live = lastAssessment.level.severity >= ThermyxRiskLevel.high.severity
        var detail: ThermyxCircleDetail
        if live {
            detail = ThermyxCircleDetail.make(assessment: lastAssessment, reading: reading, tracker: tracker,
                                              name: settings.circleName, unit: settings.temperatureUnit)
        } else {
            detail = ThermyxCircleDetail.make(assessment: .init(level: .high, reasons: []), reading: .empty, tracker: .init(),
                                              name: settings.circleName, unit: settings.temperatureUnit)
            detail.foot = "right"
            detail.causes = [ThermyxRiskCause.hot.rawValue]
            detail.footC = 38.6
            detail.trend = "rising"
            detail.confidence = "confirmed"
            detail.connection = nil
        }
        return ThermyxCircleMessage.text(
            level: (live ? lastAssessment.level : .high).rawValue, kind: "alert", detail: detail,
            locationConsent: shareLocation,
            location: shareLocation ? .init(latitude: 29.76043, longitude: -95.36981) : nil
        )
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
///   For a wearer with poor circulation, Raynaud's, diabetes or neuropathy,
///   sooner: at 27 °C, after 30 seconds, every 15 minutes. These are
///   reminders; the risk levels never change.
/// - Battery: once at 10% and once at 5% per insole, reset after charging
///   above 15% (`ThermyxBattery`).
struct ThermyxComfortWatch {
    struct Notice: Equatable {
        enum Kind: Equatable {
            case cold(Double, circulation: Bool = false)
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
            case .cold(let c, let circulation):
                return circulation
                    ? "It's at \(TemperatureFormat.degrees(c, in: unit)). With your circulation, cold feet need attention sooner, and can be hard to feel. Switch to Auto or Heat and warm them gradually."
                    : "It's been at \(TemperatureFormat.degrees(c, in: unit)) for a minute. Switch to Auto or Heat to warm it up."
            case .battery(let percent, let critical):
                return critical
                    ? "\(percent)% left. Charge it now: heating and cooling stop when it runs out, and so do your safety alerts."
                    : "\(percent)% left, about an hour of heating or cooling. Charge it soon."
            }
        }
    }

    static let coldHold: TimeInterval = 60
    static let coldRepeat: TimeInterval = 20 * 60
    static let warmResetC = 27.0

    /// Conditions that make cold feet worse or harder to feel.
    static let circulationConditions: Set<HealthCondition> = [.poorCirculation, .diabetes, .neuropathy]
    /// Set from the wearer's health conditions.
    var circulationRisk = false
    private var coldAtC: Double { circulationRisk ? 27 : ThermyxRiskEngine.coldFootC }
    private var hold: TimeInterval { circulationRisk ? 30 : Self.coldHold }
    private var repeatAfter: TimeInterval { circulationRisk ? 15 * 60 : Self.coldRepeat }
    private var resetAtC: Double { circulationRisk ? 29 : Self.warmResetC }
    static let batteryLow = ThermyxBattery.low
    static let batteryCritical = ThermyxBattery.critical
    static let batteryReset = ThermyxBattery.reset

    private var coldSince: [Foot: Date] = [:]
    private var coldNotifiedAt: [Foot: Date] = [:]
    private var batteryWarned: [Foot: Int] = [:]

    mutating func update(_ reading: BilateralReading, now: Date) -> [Notice] {
        var notices: [Notice] = []
        for r in reading.present {
            let foot = r.foot
            if let c = r.footTemperatureC {
                if c <= coldAtC {
                    let since = coldSince[foot] ?? now
                    coldSince[foot] = since
                    let due = coldNotifiedAt[foot].map { now.timeIntervalSince($0) >= repeatAfter } ?? true
                    if now.timeIntervalSince(since) >= hold, due {
                        coldNotifiedAt[foot] = now
                        notices.append(Notice(foot: foot, kind: .cold(c, circulation: circulationRisk)))
                    }
                } else {
                    coldSince[foot] = nil
                    if c >= resetAtC { coldNotifiedAt[foot] = nil }
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
