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
    /// A short explanation shown on the control bar when the app changes the
    /// thermal mode on the wearer's behalf (the heat lockout), so a choice
    /// never silently flips.
    @Published private(set) var controlNotice: String?
    /// The foot whose detail the user is looking at, where a screen shows one
    /// at a time. Defaults to whichever is connected.
    @Published var focusedFoot: Foot = .left

    let ble = ThermyxBLEService()
    let history = ThermyxHistoryStore()

    weak var healthService: ThermyxHealthService?

    private var cancellables: Set<AnyCancellable> = []
    private var knownConnected: Set<Foot> = []
    private var sessionStart: [Foot: Date] = [:]
    private var heatExposureSeconds: [Foot: TimeInterval] = [:]
    private var lastRecordedAt: [Foot: Date] = [:]
    /// When each left/right gap started, so only sustained gaps count.
    private var temperatureGapSince: Date?
    private var loadGapSince: Date?
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
                self.trackAsymmetry(next)
                for entry in next.present { self.ingest(entry) }
                self.syncFocus()
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
                self.syncFocus()
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    /// The pair's risk, including the left/right signals.
    var assessment: ThermyxRiskAssessment {
        ThermyxRiskEngine.assess(
            reading,
            sustainedTemperatureGap: isSustained(temperatureGapSince),
            sustainedLoadGap: isSustained(loadGapSince)
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
        if isHeatLockedOut { return Thermyx.Ink.amber }
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
            }
        }

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
