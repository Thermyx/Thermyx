import Combine
import CoreBluetooth
import Foundation
import SwiftUI

@MainActor
final class ThermyxViewModel: ObservableObject {
    /// Both insoles. Either side may be absent.
    @Published private(set) var reading = BilateralReading.empty
    @Published private(set) var isScanning = false
    /// What the user last selected on the control bar. One setting for the
    /// pair: a wearer asking for cooling means both feet.
    @Published private(set) var thermalSetting: ThermalSetting = .auto
    @Published var commandError: String?
    /// Whether the last Cool / Auto / Heat tap actually took effect.
    @Published private(set) var command = ThermalCommandTracker()
    /// A short explanation shown on the control bar when the app changes the
    /// thermal mode on the wearer's behalf (the heat lockout), so a choice
    /// never silently flips.
    @Published private(set) var controlNotice: String?
    /// The foot whose detail the user is looking at, where a screen shows one
    /// at a time. Defaults to whichever is connected.
    @Published var focusedFoot: Foot = .left
    /// Set when a wearing session ends: the insoles disconnect after a real
    /// session, or the wearer has been still for a while. Triggers the
    /// end-of-session AI summary.
    @Published private(set) var sessionEndedAt: Date?
    private var stillness = SessionStillness()
    /// Battery-life estimate for the weaker insole, from the last hour.
    @Published private(set) var batteryHoursLeft: Double?
    /// Each insole's measured drain and time left, once there's enough
    /// history to measure it (see `BatteryEstimator`).
    @Published private(set) var batteryEstimates: [Foot: BatteryEstimator.Estimate] = [:]
    private var battery = BatteryEstimator()

    let ble = ThermyxBLEService()
    let history = ThermyxHistoryStore()
    let baseline = PersonalBaselineStore()
    /// Thermal Recovery Test recoveries, and the test itself.
    let recovery = ThermyxRecoveryStore()
    let coach = RecoveryCoach()
    /// The Demo studio's timeline player (admin).
    let player = DemoPlayer()
    /// Widgets, the Live Activity and the Dynamic Island.
    let widgets = ThermyxWidgetBridge()
    /// The single-sensor test board's live table. Fed only by
    /// `ble.boardPackets`, never by insole readings, and never read by the
    /// risk engine, alerts, or Apple Health.
    private(set) lazy var board = SensorBoardStore(packets: ble.boardPackets.eraseToAnyPublisher(), history: history)

    weak var healthService: ThermyxHealthService?

    private var cancellables: Set<AnyCancellable> = []
    private var knownConnected: Set<Foot> = []
    private var sessionStart: [Foot: Date] = [:]
    private var heatExposureSeconds: [Foot: TimeInterval] = [:]
    private var lastRecordedAt: [Foot: Date] = [:]
    /// When each left/right gap started, so only sustained gaps count.
    /// What the left/right monitor reports (heavy leaning, a limp, one foot
    /// running warmer), refreshed with every reading.
    @Published private(set) var asymmetry = AsymmetryStatus.none
    /// True once both insoles have been on together this session, so losing
    /// one lowers confidence instead of passing as single-insole use.
    @Published private(set) var pairExpected = false
    /// The pair's session, written to Health once when the last foot ends.
    private var pairSession: (start: Date, end: Date, exposure: TimeInterval)?
    private var lastLockoutCommand: Date?
    private var noticeTask: Task<Void, Never>?

    init() {
        // Buttons on the widgets, the Live Activity and the Dynamic Island
        // leave a mode request; apply it as it arrives.
        ThermyxModeInbox.onRequest = { [weak self] in Task { @MainActor in self?.applyWidgetRequest() } }
        ThermyxModeInbox.startListening()
        // Population priors (from opted-in wearers) give a new wearer's usual
        // a starting point until their own data takes over.
        ThermyxCloudService.shared.$priors
            .sink { [weak self] in self?.baseline.priors = $0 }
            .store(in: &cancellables)
        // Demo Mode writes no history, board values included.
        let ble = self.ble
        board.recordsHistory = { !ble.isDemoMode }
        ble.$boardState
            .removeDuplicates()
            .sink { [weak self] state in
                // Disconnected or gone: nothing stays on screen looking live.
                if state == .notConnected { self?.board.clear() }
            }
            .store(in: &cancellables)

        ble.$readings
            .receive(on: RunLoop.main)
            .sink { [weak self] readings in
                guard let self else { return }
                var next = BilateralReading.empty
                next.left = readings[.left]
                next.right = readings[.right]

                // A foot that has gone quiet ends its session and stops being
                // drawn, rather than lingering as though it were live.
                for foot in Foot.allCases where next[foot] == nil && self.reading[foot] != nil {
                    self.endSession(for: foot)
                }
                self.reading = next
                for r in next.present { self.battery.add(r) }
                self.batteryHoursLeft = next.present.compactMap { self.battery.hoursLeft($0.foot) }.min()
                self.batteryEstimates = Dictionary(uniqueKeysWithValues: next.present.compactMap { r in
                    self.battery.estimate(r.foot).map { (r.foot, $0) }
                })
                self.updateTrend()
                // Left vs right, over minutes. Simulated readings are watched
                // but never teach the wearer's norms. The newest packet's own
                // time is "now", so the Demo studio's story clock works.
                self.baseline.observeAsymmetry(next, learn: !self.ble.isDemoMode)
                self.asymmetry = next.hasBoth
                    ? self.baseline.asymmetryStatus(now: next.present.map(\.timestamp).max() ?? .now)
                    : .none
                // Simulated readings never teach the baseline.
                if !self.ble.isDemoMode {
                    self.baseline.observe(next, fixedLevel: self.fixedAssessment.level)
                }
                for entry in next.present { self.ingest(entry) }
                self.updateCommand()
                self.syncFocus()
                self.widgets.update(reading: next, isDemo: self.ble.isDemoMode,
                                    setting: self.thermalSetting, assessment: self.assessment)
                self.coach.observe(next, level: self.assessment.level)
                self.refreshReadiness()
            }
            .store(in: &cancellables)

        ble.$lastWriteFailure
            .compactMap { $0 }
            .sink { [weak self] failure in
                guard let self else { return }
                self.command.writeFailed(foot: failure.foot, message: failure.message)
                if let message = self.command.failureMessage { self.commandError = message }
            }
            .store(in: &cancellables)

        ble.$connected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self else { return }
                if !connected.isEmpty { self.isScanning = false }
                // A newly connected insole gets the saved hold temperature.
                for foot in connected where !self.knownConnected.contains(foot) {
                    self.ble.send(targetTemperatureC: Self.savedTargetC, to: foot)
                }
                self.knownConnected = connected
                if connected.count == 2 { self.pairExpected = true }
                if connected.isEmpty { self.pairExpected = false }
                self.syncFocus()
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    /// The fixed rules alone: thresholds, burn limit, sustained gaps.
    var fixedAssessment: ThermyxRiskAssessment {
        ThermyxRiskEngine.assess(reading, asymmetry: asymmetry)
    }

    /// The pair's risk: the fixed rules, plus the personal baseline and
    /// trend layer, which can only add caution.
    var assessment: ThermyxRiskAssessment { personal(unit: .celsius).assessment }

    /// Recomputed once per reading rather than on every redraw.
    private(set) var trend = TemperatureTrend()

    private func updateTrend() {
        // Demo Mode writes no history, so there is no honest trend to show.
        guard !ble.isDemoMode else { trend = TemperatureTrend(); return }
        let current = reading.peakFootTemperatureC
        trend = TemperatureTrend(
            delta5: history.footTrend(over: 5 * 60, current: current)?.delta,
            delta10: history.footTrend(over: 10 * 60, current: current)?.delta
        )
    }

    private func personal(unit: TemperatureUnit) -> PersonalLayer.Result {
        PersonalLayer.apply(
            fixedAssessment,
            reading: reading,
            baseline: baseline.isEnabled ? baseline.baseline : nil,
            trend: baseline.isEnabled ? trend : TemperatureTrend(),
            unit: unit,
            model: baseline.isEnabled ? baseline.model : nil,
            activity: baseline.activity,
            priors: baseline.priors
        )
    }

    /// Everything behind the current level, for "Why am I seeing this?".
    func explanation(unit: TemperatureUnit, now: Date = .now) -> RiskExplanation {
        let layered = personal(unit: unit)
        return RiskExplanation.build(
            assessment: layered.assessment,
            reading: reading,
            sustainedTemperatureGap: false,
            sustainedLoadGap: false,
            rssi: ble.rssi,
            bothExpected: pairExpected,
            unit: unit,
            asymmetry: asymmetry,
            extras: layered.signals,
            now: now
        )
    }

    private var readinessAt = Date.distantPast

    /// The Readiness widget's figures, about once a minute.
    private func refreshReadiness(now: Date = .now) {
        guard now.timeIntervalSince(readinessAt) >= 60 else { return }
        readinessAt = now
        let p = ReadinessProfile.build(reading: reading, activity: baseline.activity,
                                       model: baseline.isEnabled ? baseline.model : nil, hours: history.hourSamples,
                                       recoveries: recovery.records, comfortTargetC: Self.savedTargetC, now: now)
        let status: String = switch p.status {
        case .learning: "learning"
        case .typical: "typical"
        case .warmer: "warmer"
        case .cooler: "cooler"
        }
        widgets.readiness = .init(status: status, activity: p.activity?.label, lowC: p.range?.lowC, highC: p.range?.highC, nowC: p.nowC)
    }

    /// The timeline jumped, so what was "sustained" before the jump isn't.
    private func resetSignalHistory() {
        // Keeps what was learned about the wearer; drops the evidence.
        baseline.resetAsymmetryEvidence()
        asymmetry = .none
    }

    func assessment(for foot: Foot) -> ThermyxRiskAssessment {
        guard let entry = reading[foot] else { return .unavailable }
        return ThermyxRiskEngine.assess(entry)
    }

    /// When the current wearing session began: the earlier foot's first
    /// reading. Nil with no insole on.
    var wearingSince: Date? { sessionStart.values.min() }

    func isConnected(_ foot: Foot) -> Bool { ble.isConnected(foot) }
    var anyConnected: Bool { ble.anyConnected }
    var bothConnected: Bool { ble.bothConnected }

    /// Feet that are paired and reporting, in left-then-right order.
    var connectedFeet: [Foot] { Foot.allCases.filter(ble.isConnected) }
    var disconnectedFeet: [Foot] { Foot.allCases.filter { !ble.isConnected($0) } }

    var isControlAvailable: Bool { ble.anyConnected }
    var isHeatLockedOut: Bool { assessment.level.locksOutHeating }

    var connectionLabel: String {
        switch connectedFeet.count {
        case 2: return "Both insoles connected"
        case 1: return "\(connectedFeet[0].label) insole connected"
        default: return isScanning ? "Searching for Thermyx…" : "Not connected"
        }
    }

    /// The right-hand slot in the control bar. Reports what the devices say,
    /// not what we asked for.
    var thermalStatusText: String {
        guard isControlAvailable else { return "Unavailable" }
        if case .pending(let setting, _, _) = command.state { return "Switching to \(setting.label)…" }
        if case .failed = command.state { return "\(thermalSetting.label) not confirmed" }
        if isHeatLockedOut {
            return "Heat locked · \(reading.thermalMode?.statusLabel ?? "mixed")"
        }
        guard let mode = reading.thermalMode else {
            let modes = Set(reading.present.map(\.thermalMode))
            if modes.contains(.heating), modes.contains(.cooling) { return "Warming one foot, cooling the other" }
            if modes.contains(.cooling) { return "Cooling one foot" }
            if modes.contains(.heating) { return "Warming one foot" }
            return "Holding"
        }
        if thermalSetting == .off, mode == .off { return "Off" }
        // Cool and Heat are explicit requests; when the insole reports
        // something else, say both rather than implying it obeyed.
        if thermalSetting != .auto, mode != thermalSetting.command {
            return "\(thermalSetting.label) sent · insole \(mode.shortStatus)"
        }
        return mode.statusLabel
    }

    var thermalStatusTint: Color {
        if thermalSetting == .auto, command.failureMessage == nil, !isHeatLockedOut, !command.isPending,
           let mode = reading.thermalMode, mode == .ventilation || mode == .off {
            return Thermyx.Ink.ice
        }
        return modeTint
    }

    private var modeTint: Color {
        guard isControlAvailable else { return Thermyx.Ink.textSupporting }
        if command.failureMessage != nil || isHeatLockedOut { return Thermyx.Ink.amber }
        if command.isPending { return Thermyx.Ink.textSupporting }
        guard let mode = reading.thermalMode else { return Thermyx.Ink.amber }
        switch mode {
        case .heating: return Thermyx.Ink.amber
        case .cooling, .ventilation: return Thermyx.Ink.signal
        case .off: return Thermyx.Ink.textSupporting
        }
    }

    /// Keeps the focused foot on something that actually has data.
    private func syncFocus() {
        guard !ble.isConnected(focusedFoot), let first = connectedFeet.first else { return }
        focusedFoot = first
    }

    // MARK: - Actions

    func toggleScan() {
        if isScanning {
            ble.stopScan()
            isScanning = false
        } else {
            ble.scan()
            isScanning = true
        }
    }

    /// The Scan again button: clears what the last search found and starts
    /// a fresh one (or asks for Bluetooth, if that's what's in the way).
    func rescan() {
        isScanning = ble.rescan()
    }

    /// Starts a scan aimed at one foot, from the minimised sole on Home.
    func scanFor(_ foot: Foot) {
        focusedFoot = foot
        if !isScanning { toggleScan() }
    }

    func connect(to device: ThermyxBLEService.DiscoveredDevice, as foot: Foot? = nil) {
        ble.connectDevice(device, as: foot)
        isScanning = false
    }

    func disconnect(_ foot: Foot) { ble.disconnect(foot) }

    /// A mode asked for from a widget, the Live Activity or the Dynamic
    /// Island. Applied the way the in-app control applies it, so the heat
    /// lockout and the "not connected" rules still hold.
    func applyWidgetRequest() {
        // Left alone (until it expires) while there's nothing to control, so
        // a button pressed as the insoles reconnect still lands.
        guard let mode = ThermyxModeInbox.pending(), isControlAvailable else { return }
        ThermyxModeInbox.clear()
        let setting: ThermalSetting = switch mode {
        case .auto: .auto
        case .cool: .cool
        case .heat: .heat
        case .off: .off
        }
        guard setting != thermalSetting else { return }
        select(setting)
    }

    func select(_ setting: ThermalSetting) {
        guard isControlAvailable else { return }
        if setting == .heat, isHeatLockedOut {
            commandError = "Heating is locked out while your risk level is elevated."
            return
        }
        thermalSetting = setting
        commandError = nil
        ble.send(command: setting.command)
        track(setting)
    }

    /// Starts following a command, and re-checks once the timeout has passed
    /// in case the insole has gone quiet and no packet arrives to do it.
    private func track(_ setting: ThermalSetting) {
        command.begin(setting, feet: Set(connectedFeet), since: ble.readingClock)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(ThermalCommandTracker.timeout + 0.5))
            self?.updateCommand()
        }
    }

    private func updateCommand() {
        guard command.isPending else { return }
        command.update(readings: ble.readings, connected: ble.connected)
        if let message = command.failureMessage { commandError = message }
    }

    // MARK: - Demo

    /// What the demo starts with. The defaults are the plain demo; the
    /// debug previews use the rest to land on particular screens.
    struct DemoOptions {
        var feet: [Foot] = Foot.allCases
        /// Three-zone readings, for previewing that board.
        var zones = false
        /// Applied to the simulated pair after it's seeded, before it
        /// connects (a preview's hot afternoon, say).
        var configure: ((ThermyxInsoleSimulator) -> Void)?
    }

    @Published private(set) var isStartingDemo = false

    // The demo is held in memory, so iOS ending the app in the background (it
    // does, when it needs the memory) used to drop it. Remember that it was
    // on and start it again at the next launch; Exit demo clears this.
    private static let demoActiveKey = "thermyx.demo.active"
    private static let demoZonesKey = "thermyx.demo.zones"

    /// Whether the demo was running when the app last closed.
    var shouldResumeDemo: Bool { UserDefaults.standard.bool(forKey: Self.demoActiveKey) }

    /// Brings the demo back after a relaunch. Admin accounts only; the caller
    /// checks that.
    func resumeDemoIfNeeded() async {
        guard shouldResumeDemo, !ble.isDemoMode else { return }
        await startDemo(.init(zones: UserDefaults.standard.bool(forKey: Self.demoZonesKey)))
    }

    /// Starts the demo: a month of made-up history in place of the real
    /// history (which is kept and comes back on exit), a demo calibration
    /// if there's no real one, and the simulated pair carrying on live from
    /// where that history ends. Admin accounts only, from the UI.
    func startDemo(_ options: DemoOptions = .init()) async {
        guard !isStartingDemo else { return }
        isStartingDemo = true
        defer { isStartingDemo = false }
        UserDefaults.standard.set(true, forKey: Self.demoActiveKey)
        UserDefaults.standard.set(options.zones, forKey: Self.demoZonesKey)
        await history.loadIfNeeded()
        let feet = options.feet, zones = options.zones
        // The history is from days when Auto held its usual target; the live
        // insoles then follow whatever the target is now.
        let demo = await Task.detached(priority: .userInitiated) {
            ThermyxDemoHistory.make(feet: feet, targetC: 31, zones: zones)
        }.value
        history.enterDemo(minutes: demo.minutes, hours: demo.hours, events: demo.events)
        recovery.enterDemo(ThermyxRecoveryStore.demoRecords())
        battery = BatteryEstimator()
        for reading in demo.batteryTrail.values.flatMap({ $0 }).sorted(by: { $0.timestamp < $1.timestamp }) { battery.add(reading) }
        if baseline.model == nil, let model = CalibrationEngine.demoModel() {
            baseline.adopt(model, indoorSamples: [])
        }
        if ble.simulator == nil { ble.startDemoMode(connect: false) }
        guard let simulator = ble.simulator else { return }
        simulator.shiftStart = demo.shiftStart
        simulator.dayHeat = demo.todayHeat
        simulator.reportsZones = zones
        simulator.seed(from: demo.last)
        options.configure?(simulator)
        simulator.connect(feet: feet)
        player.attach(simulator)
        // At the timeline's pace each report is many seconds of story apart,
        // so the left/right monitor watches every physics second instead.
        simulator.onPhysicsSecond = { [weak self] pair in
            guard let self, pair.hasBoth else { return }
            self.baseline.observeAsymmetry(pair, learn: false)
        }
        player.onJump = { [weak self] in self?.resetSignalHistory() }
    }

    /// Leaves the demo: real Bluetooth, the real history as it was, and the
    /// demo calibration gone.
    func exitDemo() {
        UserDefaults.standard.set(false, forKey: Self.demoActiveKey)
        player.detach()
        ble.stopDemoMode()
        history.exitDemo()
        recovery.exitDemo()
        coach.close()
        battery = BatteryEstimator()
        batteryEstimates = [:]
        if baseline.model?.isTestData == true { baseline.clearModel() }
    }

    /// Saves a model trained in calibration and makes its comfort target
    /// Auto's hold temperature. Demo Mode readings never train anything.
    func applyCalibration(_ model: PersonalThermalModel, indoorSamples: [CalibrationSample], settings: ThermyxSettingsStore) {
        // Simulated readings (debug builds' preview harness) never train the
        // personal baseline; a debug-only scripted model may set Auto's
        // target so the flow can be checked.
        guard !ble.isDemoMode || (ble.isFakeInsole && model.isTestData) else { return }
        baseline.adopt(model, indoorSamples: model.isTestData ? [] : indoorSamples)
        if let target = model.comfortTargetC {
            settings.targetTemperatureC = target
            setTargetTemperature(target)
        }
    }

    /// Sends a new hold temperature to every connected insole.
    func setTargetTemperature(_ celsius: Double) {
        ble.send(targetTemperatureC: celsius)
    }

    private static var savedTargetC: Double {
        let stored = UserDefaults.standard.double(forKey: "thermyx.targetTemperatureC")
        return stored == 0 ? 31 : stored
    }

    private func showNotice(_ text: String) {
        controlNotice = text
        noticeTask?.cancel()
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(8))
            guard !Task.isCancelled else { return }
            self?.controlNotice = nil
        }
    }

    func setMode(_ mode: ThermalMode, foot: Foot? = nil) {
        ble.send(command: mode, to: foot)
    }

    // MARK: - Session recording

    private func ingest(_ entry: ThermyxReading) {
        let foot = entry.foot
        let pairAssessment = assessment

        // Safety override: if the pair escalates while Heat is selected — or
        // while any insole reports that it is heating, which Auto can do on
        // its own — pull both feet to cooling rather than waiting.
        let deviceHeating = reading.present.contains { $0.thermalMode == .heating }
        if pairAssessment.level.locksOutHeating, thermalSetting == .heat || deviceHeating {
            let recentlySent = lastLockoutCommand.map { Date.now.timeIntervalSince($0) < 5 } ?? false
            if !recentlySent {
                lastLockoutCommand = .now
                if thermalSetting != .cool {
                    thermalSetting = .cool
                    showNotice("Heat turned off at \(pairAssessment.level.rawValue). Switched to Cool.")
                }
                ble.send(command: .cooling)
                track(.cool)
            }
        }

        // Demo Mode readings are never written to history or Health.
        guard !ble.isDemoMode else { return }

        if sessionStart[foot] == nil { sessionStart[foot] = entry.timestamp }
        if stillness.update(entry) { sessionEndedAt = entry.timestamp }
        if let last = lastRecordedAt[foot], let temperature = entry.footTemperatureC, temperature >= 35 {
            heatExposureSeconds[foot, default: 0] += entry.timestamp.timeIntervalSince(last)
        }
        lastRecordedAt[foot] = entry.timestamp

        history.record(entry, assessment: ThermyxRiskEngine.assess(entry))
    }

    private func clearSession(_ foot: Foot) {
        sessionStart[foot] = nil
        heatExposureSeconds[foot] = nil
        lastRecordedAt[foot] = nil
    }

    /// Folds a foot's finished session into the pair's session and hands it
    /// to Apple Health once no foot is still recording, so one walk is one
    /// workout however many insoles were worn. Sessions shorter than a minute
    /// are dropped — a stray reconnect should not litter Health.
    func endSession(for foot: Foot) {
        if let start = sessionStart[foot], let end = lastRecordedAt[foot], end > start {
            let exposure = heatExposureSeconds[foot] ?? 0
            if let current = pairSession {
                pairSession = (min(current.start, start), max(current.end, end), max(current.exposure, exposure))
            } else {
                pairSession = (start, end, exposure)
            }
        }
        clearSession(foot)

        // Another foot is still recording: wait for it.
        guard sessionStart.values.isEmpty, let session = pairSession else { return }
        pairSession = nil
        guard session.end.timeIntervalSince(session.start) >= 60 else { return }
        if session.end.timeIntervalSince(session.start) >= SessionStillness.minimumWear, stillness.endSession() {
            sessionEndedAt = session.end
        }

        let peak = history.events(for: .day, style: .rolling, foot: nil)
            .compactMap(\.riskLevel)
            .max(by: { $0.severity < $1.severity })
        guard let healthService else { return }
        Task { await healthService.saveSession(start: session.start, end: session.end, heatExposureSeconds: session.exposure, peakRisk: peak) }
    }

    func endAllSessions() {
        for foot in Foot.allCases { endSession(for: foot) }
    }
}

/// Decides when a wearing session has ended for the AI summary: after at
/// least 20 minutes of wear, either the insoles are taken off or the wearer
/// has been still (no steps) for 15 minutes. Once per session.
struct SessionStillness {
    static let minimumWear: TimeInterval = 20 * 60
    static let stillFor: TimeInterval = 15 * 60
    /// Steps per minute below which the wearer counts as still.
    static let stillCadence = 5.0

    private var wearStart: Date?
    private var stillSince: Date?
    private var summarized = false

    /// Feed each recorded reading. True when this reading ends the session.
    mutating func update(_ reading: ThermyxReading) -> Bool {
        let now = reading.timestamp
        if wearStart == nil { wearStart = now }
        guard let cadence = reading.cadenceStepsPerMinute else { return false }
        if cadence >= Self.stillCadence {
            stillSince = nil
            summarized = false
            return false
        }
        if stillSince == nil { stillSince = now }
        guard !summarized, let start = wearStart, let still = stillSince,
              still.timeIntervalSince(start) >= Self.minimumWear,
              now.timeIntervalSince(still) >= Self.stillFor
        else { return false }
        summarized = true
        return true
    }

    /// The insoles were taken off. True if this session still needs a summary.
    mutating func endSession() -> Bool {
        defer { self = SessionStillness() }
        return !summarized
    }
}

/// Estimates battery life from how fast each insole's charge fell over the
/// last hour. Nil until there are 15 minutes of data and a drop of at least
/// 2 points, so it never guesses from noise.
struct BatteryEstimator {
    static let window: TimeInterval = 3600
    static let minimumSpan: TimeInterval = 15 * 60
    static let minimumDrop = 2.0

    private var history: [Foot: [(time: Date, percent: Int)]] = [:]

    mutating func add(_ reading: ThermyxReading) {
        guard let percent = reading.batteryPercent else { return }
        var points = history[reading.foot] ?? []
        // Charging (a rise) starts the estimate over.
        if let last = points.last, percent > last.percent + 1 { points.removeAll() }
        if points.last?.percent != percent || points.isEmpty { points.append((reading.timestamp, percent)) }
        points.removeAll { reading.timestamp.timeIntervalSince($0.time) > Self.window }
        if points.isEmpty { points.append((reading.timestamp, percent)) }
        history[reading.foot] = points
        latest[reading.foot] = (reading.timestamp, percent)
    }

    private var latest: [Foot: (time: Date, percent: Int)] = [:]

    /// The measured drain over the last hour and what it leaves.
    struct Estimate: Equatable {
        /// Percent per hour.
        let perHour: Double
        let hoursLeft: Double
    }

    func estimate(_ foot: Foot) -> Estimate? {
        guard let first = history[foot]?.first, let now = latest[foot] else { return nil }
        let span = now.time.timeIntervalSince(first.time)
        let drop = Double(first.percent - now.percent)
        guard span >= Self.minimumSpan, drop >= Self.minimumDrop else { return nil }
        let perHour = drop / (span / 3600)
        return Estimate(perHour: perHour, hoursLeft: Double(now.percent) / perHour)
    }

    func hoursLeft(_ foot: Foot) -> Double? { estimate(foot)?.hoursLeft }
}
