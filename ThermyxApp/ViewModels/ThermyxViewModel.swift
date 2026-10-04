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
    /// The last two minutes of test-board values, newest last, for the live
    /// trace on Insights. Kept in memory, so it works in Demo Mode too.
    @Published private(set) var recentAnalog: [AnalogPoint] = []
    static let analogTraceSeconds: TimeInterval = 120
    private var lastAnalogAt: [Foot: Date] = [:]

    /// Whether the last Cool / Auto / Heat tap actually took effect.
    @Published private(set) var command = ThermalCommandTracker()
    /// A short explanation shown on the control bar when the app changes the
    /// thermal mode on the wearer's behalf (the heat lockout), so a choice
    /// never silently flips.
    @Published private(set) var controlNotice: String?
    /// The foot whose detail the user is looking at, where a screen shows one
    /// at a time. Defaults to whichever is connected.
    @Published var focusedFoot: Foot = .left

    let ble = ThermyxBLEService()
    let history = ThermyxHistoryStore()
    let baseline = PersonalBaselineStore()

    weak var healthService: ThermyxHealthService?

    private var cancellables: Set<AnyCancellable> = []
    private var knownConnected: Set<Foot> = []
    private var sessionStart: [Foot: Date] = [:]
    private var heatExposureSeconds: [Foot: TimeInterval] = [:]
    private var lastRecordedAt: [Foot: Date] = [:]
    /// When each left/right gap started, so only sustained gaps count.
    private var temperatureGapSince: Date?
    private var loadGapSince: Date?
    /// True once both insoles have been on together this session, so losing
    /// one lowers confidence instead of passing as single-insole use.
    @Published private(set) var pairExpected = false
    /// The pair's session, written to Health once when the last foot ends.
    private var pairSession: (start: Date, end: Date, exposure: TimeInterval)?
    private var lastLockoutCommand: Date?
    private var noticeTask: Task<Void, Never>?

    init() {
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
                self.updateTrend()
                self.trackAsymmetry(next)
                // Simulated readings never teach the baseline.
                if !self.ble.isDemoMode {
                    self.baseline.observe(next, fixedLevel: self.fixedAssessment.level)
                }
                for entry in next.present { self.ingest(entry) }
                self.updateCommand()
                self.syncFocus()
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
        ThermyxRiskEngine.assess(
            reading,
            sustainedTemperatureGap: isSustained(temperatureGapSince),
            sustainedLoadGap: isSustained(loadGapSince)
        )
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
            unit: unit
        )
    }

    /// Everything behind the current level, for "Why am I seeing this?".
    func explanation(unit: TemperatureUnit, now: Date = .now) -> RiskExplanation {
        let layered = personal(unit: unit)
        return RiskExplanation.build(
            assessment: layered.assessment,
            reading: reading,
            sustainedTemperatureGap: isSustained(temperatureGapSince),
            sustainedLoadGap: isSustained(loadGapSince),
            rssi: ble.rssi,
            bothExpected: pairExpected,
            unit: unit,
            extras: layered.signals,
            now: now
        )
    }

    private func isSustained(_ since: Date?) -> Bool {
        guard let since else { return false }
        return Date.now.timeIntervalSince(since) >= ThermyxRiskEngine.sustainedAsymmetrySeconds
    }

    private func trackAsymmetry(_ pair: BilateralReading) {
        if pair.hotterFoot == nil { temperatureGapSince = nil } else if temperatureGapSince == nil { temperatureGapSince = .now }
        if pair.favouredFoot == nil { loadGapSince = nil } else if loadGapSince == nil { loadGapSince = .now }
    }

    func assessment(for foot: Foot) -> ThermyxRiskAssessment {
        guard let entry = reading[foot] else { return .unavailable }
        return ThermyxRiskEngine.assess(entry)
    }

    func isConnected(_ foot: Foot) -> Bool { ble.isConnected(foot) }
    var anyConnected: Bool { ble.anyConnected }
    var bothConnected: Bool { ble.bothConnected }

    /// Feet that are paired and reporting, in left-then-right order.
    var connectedFeet: [Foot] { Foot.allCases.filter(ble.isConnected) }
    var disconnectedFeet: [Foot] { Foot.allCases.filter { !ble.isConnected($0) } }

    /// Cool / Auto / Heat need a full insole; a test board takes no commands.
    var isControlAvailable: Bool { !ble.controllableFeet.isEmpty }
    var isHeatLockedOut: Bool { assessment.level.locksOutHeating }

    var connectionLabel: String {
        if !ble.sensorFeet.isEmpty, ble.controllableFeet.isEmpty { return "Test board connected" }
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
        guard let mode = reading.thermalMode else { return "Feet differ" }
        // Cool and Heat are explicit requests; when the insole reports
        // something else, say both rather than implying it obeyed.
        if thermalSetting != .auto, mode != thermalSetting.command {
            return "\(thermalSetting.label) sent · insole \(mode.shortStatus)"
        }
        return mode.statusLabel
    }

    var thermalStatusTint: Color {
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

    /// Starts a scan aimed at one foot, from the minimised sole on Home.
    func scanFor(_ foot: Foot) {
        focusedFoot = foot
        if !isScanning { toggleScan() }
    }

    func connect(to device: ThermyxBLEService.DiscoveredDevice, as foot: Foot? = nil) {
        ble.connect(to: device, as: foot)
        isScanning = false
    }

    func disconnect(_ foot: Foot) { ble.disconnect(foot) }

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
        command.begin(setting, feet: ble.controllableFeet)
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

        // A test-board value: once per packet (readings republish whenever
        // either foot updates), into the live trace and, outside Demo Mode,
        // the analog history.
        if let analog = entry.analogInput, entry.timestamp > (lastAnalogAt[foot] ?? .distantPast) {
            lastAnalogAt[foot] = entry.timestamp
            recentAnalog.append(AnalogPoint(time: entry.timestamp, raw: analog.raw, kind: analog.kind, forceN: analog.forceN))
            let cutoff = entry.timestamp.addingTimeInterval(-Self.analogTraceSeconds)
            recentAnalog.removeAll { $0.time < cutoff }
            if !ble.isDemoMode { history.recordAnalog(analog, at: entry.timestamp) }
        }
        // A board that only sends a test input has no body reading: no
        // session, no Health workout, no risk history.
        guard entry.hasSensorData else { return }

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
