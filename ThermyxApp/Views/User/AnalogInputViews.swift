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
                    Text("Raw \(latest.raw) / \(ThermyxSensorProtocol.maxRaw)")
                        .font(ThermyxFont.rowTitleRegular)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                    Text(String(format: "%.2f V", input.volts))
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                }
                .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
        } else {
            Text("No live value")
                .font(ThermyxFont.rowTitleRegular)
                .foregroundStyle(Thermyx.Ink.textMuted)
        }
    }

    @ViewBuilder
    private var liveTrace: some View {
        let points = viewModel.recentAnalog
        if points.count >= 2 {
            Chart(points) { point in
                LineMark(x: .value("Time", point.time), y: .value("Percent", point.percent))
                    .foregroundStyle(Thermyx.Ink.ice)
                    .interpolationMethod(.monotone)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Thermyx.Ink.divider)
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
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
        if samples.count >= 2 {
            Chart(samples) { sample in
                LineMark(x: .value("Time", sample.start), y: .value("Mean", sample.percentMean))
                    .foregroundStyle(Thermyx.Ink.signal)
            }
            .chartYScale(domain: 0...100)
            .chartYAxis {
                AxisMarks(values: [0, 50, 100]) { value in
                    AxisGridLine().foregroundStyle(Thermyx.Ink.divider)
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)%") } }
                }
            }
            .frame(height: 90)
            .accessibilityLabel("\(kind.title) history, one point per minute")
            Text("\(settings.insightsRange.caption(style: settings.periodStyle)) · minute averages")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
    }

    private var footnote: String {
        switch kind {
        case .testInput:
            return "A test input from the XIAO board's analog pin, shown as a share of 0–3.3 V. It is not a body reading and never feeds temperature, alerts, or Apple Health."
        case .fsrLoad:
            return "Load from the pressure sensor as a share of its range. Not calibrated to weight."
        case .temperature:
            return AnalogTemperatureCalibration.current == nil
                ? "Temperature needs a calibration before the app will show °C."
                : "Temperature from the analog sensor, converted with its calibration."
        }
    }
}

// MARK: - Advanced: what the pin is wired to

/// Lets the team switch the analog pin between test knob, FSR load, and
/// (once calibrated) temperature without changing code.
struct AnalogSourceSection: View {
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
                Text("\(AnalogInput(raw: last.raw, kind: last.kind).percent, specifier: "%.0f")% · raw \(last.raw)")
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
}
