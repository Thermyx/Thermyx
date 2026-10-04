import Charts
import SwiftUI

// MARK: - Link status

/// Searching / connected / disconnected for the XIAO test board.
struct SensorLinkStatusPill: View {
    @ObservedObject var ble: ThermyxBLEService

    var body: some View {
        let status = ble.linkStatus
        HStack(spacing: 6) {
            if status == .searching {
                ProgressView().controlSize(.mini).tint(Thermyx.Ink.textSupporting)
            } else {
                Circle().fill(tint(status)).frame(width: 7, height: 7)
            }
            Text(status.label)
                .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: tint(status))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Test board: \(status.label)")
    }

    private func tint(_ status: SensorLinkStatus) -> Color {
        switch status {
        case .connected: return Thermyx.Ink.ice
        case .searching: return Thermyx.Ink.textSupporting
        case .disconnected(let reconnecting): return reconnecting ? Thermyx.Ink.amber : Thermyx.Ink.textFaint
        case .bluetoothUnavailable: return Thermyx.Ink.amber
        }
    }
}

// MARK: - Insights card

/// The test board's live value: raw count and percent, a two-minute trace,
/// and minute history for the selected range. It sits beside the body
/// charts and never feeds them, so a knob is never shown as a temperature.
struct AnalogInputCard: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var ble: ThermyxBLEService
    @ObservedObject var history: ThermyxHistoryStore
    @ObservedObject var settings: ThermyxSettingsStore

    /// Shown once a board has been seen, or while one is connecting.
    static func isRelevant(ble: ThermyxBLEService, viewModel: ThermyxViewModel, history: ThermyxHistoryStore) -> Bool {
        !ble.sensorFeet.isEmpty || ble.sensorReconnecting || !viewModel.recentAnalog.isEmpty || !history.analogSamples.isEmpty
    }

    private var latest: AnalogPoint? {
        guard let last = viewModel.recentAnalog.last, Date.now.timeIntervalSince(last.time) < 5 else { return nil }
        return last
    }

    private var kind: AnalogSourceKind { latest?.kind ?? settings.analogSourceKind }

    var body: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(kind.title)
                    Spacer(minLength: Thermyx.Space.xs)
                    SensorLinkStatusPill(ble: ble)
                }

                readout

                liveTrace

                historyChart

                Text(footnote)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private var readout: some View {
        if let latest {
            let input = AnalogInput(raw: latest.raw, kind: latest.kind)
            if latest.kind == .fsrLoad {
                // FSR: physical units only. The raw count lives on Advanced.
                let force = latest.forceN ?? input.forceN ?? 0
                HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.m) {
                    Text(verbatim: String(format: "%.2f N", force))
                        .font(ThermyxFont.statNumeral)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: String(format: "%.1f kPa", FSR402.pressureKPa(forceN: force)))
                            .font(ThermyxFont.rowTitleRegular)
                            .foregroundStyle(Thermyx.Ink.textSecondary)
                        Text("approx.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)
                .accessibilityLabel(String(format: "Force approximately %.2f newtons, pressure approximately %.1f kilopascals", force, FSR402.pressureKPa(forceN: force)))
            } else {
                HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.m) {
                    if let celsius = input.temperatureC {
                        Text(TemperatureFormat.degrees(celsius, in: settings.temperatureUnit))
                            .font(ThermyxFont.statNumeral)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                    } else {
                        Text("\(Int(input.percent.rounded()))%")
                            .font(ThermyxFont.statNumeral)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(verbatim: "Raw \(latest.raw) / \(ThermyxSensorProtocol.maxRaw)")
                            .font(ThermyxFont.rowTitleRegular)
                            .foregroundStyle(Thermyx.Ink.textSecondary)
                        Text(String(format: "%.2f V", input.volts))
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                    .monospacedDigit()
                }
                .accessibilityElement(children: .combine)
            }
        } else {
            Text("No live value")
                .font(ThermyxFont.rowTitleRegular)
                .foregroundStyle(Thermyx.Ink.textMuted)
        }
    }

    /// Top of the force axis: the 20 N clamp times the calibration scale.
    private var forceAxisMax: Double { FSR402.maxForceN * settings.fsrForceScale }

    @ViewBuilder
    private var liveTrace: some View {
        let points = viewModel.recentAnalog.filter { $0.kind == kind }
        if points.count >= 2 {
            Group {
                if kind == .fsrLoad {
                    Chart(points) { point in
                        LineMark(x: .value("Time", point.time), y: .value("Force (N)", point.forceN ?? 0))
                            .foregroundStyle(Thermyx.Ink.ice)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...max(forceAxisMax, points.compactMap(\.forceN).max() ?? 0))
                    .chartYAxis { newtonAxis }
                } else {
                    Chart(points) { point in
                        LineMark(x: .value("Time", point.time), y: .value("Percent", point.percent))
                            .foregroundStyle(Thermyx.Ink.ice)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { percentAxis }
                }
            }
            .chartXAxis(.hidden)
            .frame(height: 90)
            .accessibilityLabel("Last two minutes of \(kind.title.lowercased())")
            Text("Last 2 minutes · live")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
    }

    @ViewBuilder
    private var historyChart: some View {
        let samples = history.analogHistory(for: settings.insightsRange, style: settings.periodStyle)
            .filter { $0.kind == kind && (kind != .fsrLoad || $0.forceMeanN != nil) }
        if samples.count >= 2 {
            Group {
                if kind == .fsrLoad {
                    Chart(samples) { sample in
                        LineMark(x: .value("Time", sample.start), y: .value("Mean force (N)", sample.forceMeanN ?? 0))
                            .foregroundStyle(Thermyx.Ink.signal)
                    }
                    .chartYScale(domain: 0...max(forceAxisMax, samples.compactMap(\.forceMeanN).max() ?? 0))
                    .chartYAxis { newtonAxis }
                } else {
                    Chart(samples) { sample in
                        LineMark(x: .value("Time", sample.start), y: .value("Mean", sample.percentMean))
                            .foregroundStyle(Thermyx.Ink.signal)
                    }
                    .chartYScale(domain: 0...100)
                    .chartYAxis { percentAxis }
                }
            }
            .frame(height: 90)
            .accessibilityLabel("\(kind.title) history, one point per minute")
            Text("\(settings.insightsRange.caption(style: settings.periodStyle)) · minute averages")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
    }

    private var percentAxis: some AxisContent {
        AxisMarks(values: [0, 50, 100]) { value in
            AxisGridLine().foregroundStyle(Thermyx.Ink.divider)
            AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
        }
    }

    private var newtonAxis: some AxisContent {
        AxisMarks(values: [0, forceAxisMax / 2, forceAxisMax]) { value in
            AxisGridLine().foregroundStyle(Thermyx.Ink.divider)
            AxisValueLabel { if let v = value.as(Double.self) { Text(verbatim: String(format: "%g N", (v * 10).rounded() / 10)) } }
        }
    }

    private var footnote: String {
        switch kind {
        case .testInput:
            return "A test input from the XIAO board's analog pin, shown as a share of 0–3.3 V. It is not a body reading and never feeds temperature, alerts, or Apple Health."
        case .fsrLoad:
            return "Approximate force from the FSR402's typical curve (F ≈ G / 80, clamped to 20 N, × your calibration scale). Pressure assumes the full 12.7 mm sensing area. Not a calibrated scale, and never used for alerts or Apple Health."
        case .temperature:
            return AnalogTemperatureCalibration.current == nil
                ? "Temperature needs a calibration before the app will show °C."
                : "Temperature from the analog sensor, converted with its calibration."
        }
    }
}

// MARK: - Advanced: what the pin is wired to

/// Lets the team switch the analog pin between test knob, FSR402 force, and
/// (once calibrated) temperature without changing code.
struct AnalogSourceSection: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var ble: ThermyxBLEService

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Test board (XIAO analog pin)") {
                SensorLinkStatusPill(ble: ble)
            }
            ThermyxGroupedCard {
                Picker("Wired to", selection: $settings.analogSourceKind) {
                    ForEach(AnalogSourceKind.allCases.filter(\.isAvailable)) { kind in
                        Text(kind.settingLabel).tag(kind)
                    }
                }
                .tint(Thermyx.Ink.ice)
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
                .frame(minHeight: Thermyx.minimumTapTarget)

                if settings.analogSourceKind == .fsrLoad {
                    ThermyxDivider()
                    Stepper(value: $settings.fsrForceScale, in: FSR402.scaleRange, step: 0.05) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: String(format: "Calibration scale × %.2f", settings.fsrForceScale))
                                .font(ThermyxFont.body)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text("Multiplies the approximate force. 1.00 = the datasheet curve.")
                                .font(ThermyxFont.captionSmall)
                                .foregroundStyle(Thermyx.Ink.textSupporting)
                        }
                    }
                    .padding(.horizontal, Thermyx.Space.xl)
                    .padding(.vertical, Thermyx.Space.m)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                }
            }

            // The raw ADC count, for debugging the wiring. Nowhere else
            // shows it in FSR mode.
            if let last = viewModel.recentAnalog.last, Date.now.timeIntervalSince(last.time) < 5 {
                Text(verbatim: String(format: "Debug · raw ADC %d / 4095 · %.3f V", last.raw, AnalogInput(raw: last.raw, kind: last.kind).volts))
                    .font(ThermyxFont.captionSmall)
                    .monospacedDigit()
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
            Text("The board connects by itself when it's on and in range. Temperature appears here only once a calibration is set in code (AnalogTemperatureCalibration), so a test knob is never shown as a temperature.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Home

/// What Home says while a test board, rather than an insole, is connected.
struct TestBoardHomeNote: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var ble: ThermyxBLEService

    var body: some View {
        VStack(spacing: Thermyx.Space.m) {
            Text("Test board connected")
                .font(ThermyxFont.featureHeadline)
                .tracking(-0.8)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            if let last = viewModel.recentAnalog.last {
                Text(verbatim: homeValue(last))
                    .font(ThermyxFont.metricNumeral)
                    .monospacedDigit()
                    .foregroundStyle(Thermyx.Ink.ice)
            }
            Text("It sends a test input, not temperature or movement, so Home stays empty. Its live value and history are on Insights.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSupporting)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func homeValue(_ point: AnalogPoint) -> String {
        if point.kind == .fsrLoad {
            let force = point.forceN ?? FSR402.forceNewtons(raw: point.raw)
            return String(format: "%.2f N · %.1f kPa approx.", force, FSR402.pressureKPa(forceN: force))
        }
        return String(format: "%.0f%% · raw %d", AnalogInput(raw: point.raw, kind: point.kind).percent, point.raw)
    }
}
