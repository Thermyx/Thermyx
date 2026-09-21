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
    /// The foot whose detail the user is looking at, where a screen shows one
    /// at a time. Defaults to whichever is connected.
    @Published var focusedFoot: Foot = .left

    let ble = ThermyxBLEService()
    let history = ThermyxHistoryStore()

    weak var healthService: ThermyxHealthService?

    private var cancellables: Set<AnyCancellable> = []
    private var sessionStart: [Foot: Date] = [:]
    private var heatExposureSeconds: [Foot: TimeInterval] = [:]
    private var lastRecordedAt: [Foot: Date] = [:]

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
                for entry in next.present { self.ingest(entry) }
                self.syncFocus()
            }
            .store(in: &cancellables)

        ble.$connected
            .removeDuplicates()
            .sink { [weak self] connected in
                guard let self else { return }
                if !connected.isEmpty { self.isScanning = false }
                self.syncFocus()
            }
            .store(in: &cancellables)
    }

    // MARK: - Derived state

    /// The pair's risk, including the left/right signals.
    var assessment: ThermyxRiskAssessment { ThermyxRiskEngine.assess(reading) }

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
        ble.send(command: setting.command)
    }

    func setMode(_ mode: ThermalMode, foot: Foot? = nil) {
        ble.send(command: mode, to: foot)
    }

    // MARK: - Session recording

    private func ingest(_ entry: ThermyxReading) {
        let foot = entry.foot
        let pairAssessment = ThermyxRiskEngine.assess(reading)

        // Safety override: if the pair escalates while Heat is selected, pull
        // both feet back to cooling rather than waiting for the user.
        if pairAssessment.level.locksOutHeating, thermalSetting == .heat {
            thermalSetting = .cool
            ble.send(command: .cooling)
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

    /// Hands a finished session to Apple Health, then clears it. A session
    /// shorter than a minute is dropped rather than written — a stray
    /// reconnect should not litter Health with empty workouts.
    func endSession(for foot: Foot) {
        guard let start = sessionStart[foot],
              let end = lastRecordedAt[foot],
              end.timeIntervalSince(start) >= 60
        else {
            clearSession(foot)
            return
        }
        let exposure = heatExposureSeconds[foot] ?? 0
        let peak = history.events(for: .day, style: .rolling, foot: foot)
            .compactMap(\.riskLevel)
            .max(by: { $0.severity < $1.severity })
        clearSession(foot)

        guard let healthService else { return }
        // Only one foot's session is written, so two insoles do not produce
        // two overlapping workouts for the same walk.
        guard foot == .left || !ble.isConnected(.left) else { return }
        Task { await healthService.saveSession(start: start, end: end, heatExposureSeconds: exposure, peakRisk: peak) }
    }

    func endAllSessions() {
        for foot in Foot.allCases { endSession(for: foot) }
    }
}
