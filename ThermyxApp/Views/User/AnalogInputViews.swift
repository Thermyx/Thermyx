import Charts
import SwiftUI

// Views for the single-sensor XIAO test board: connecting by hand, the Home
// readout, one Insights card per sensor, and its Advanced settings. Board
// values never feed risk levels, alerts, or Apple Health.

// MARK: - Status

/// "Not connected", "Scanning…", "Connecting…", "Connected · Thermyx",
/// "Reconnecting…".
struct BoardStatusPill: View {
    @ObservedObject var ble: ThermyxBLEService

    var body: some View {
        let state = ble.boardState
        HStack(spacing: 6) {
            switch state {
            case .scanning, .connecting, .reconnecting:
                ProgressView().controlSize(.mini).tint(tint(state))
            default:
                Circle().fill(tint(state)).frame(width: 7, height: 7)
            }
            Text(state.label)
                .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: tint(state))
                .lineLimit(1)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sensor: \(state.label)")
    }

    private func tint(_ state: BoardLinkState) -> Color {
        switch state {
        case .connected: return Thermyx.Ink.ice
        case .reconnecting: return Thermyx.Ink.amber
        case .scanning, .connecting: return Thermyx.Ink.textSupporting
        case .notConnected: return Thermyx.Ink.textFaint
        }
    }
}

// MARK: - Connect a device

/// Scan, pick, connect. Nothing connects until the user taps it; after that
/// the board is remembered and reconnects by itself until they tap
/// Disconnect.
struct ConnectDeviceView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var ble: ThermyxBLEService
    @State private var scanning = false
    @State private var showAll = false

    /// Thermyx devices: by service UUID, or named Thermyx.
    private var thermyxDevices: [ThermyxBLEService.DiscoveredDevice] {
        ble.discovered.filter(\.looksLikeThermyx)
    }

    /// Everything else with a name, only with "Show all Bluetooth devices".
    private var otherDevices: [ThermyxBLEService.DiscoveredDevice] {
        showAll ? ble.discovered.filter { !$0.looksLikeThermyx && $0.isNamed } : []
    }

    private var hiddenUnnamed: Int {
        showAll ? ble.discovered.filter { !$0.looksLikeThermyx && !$0.isNamed }.count : 0
    }

    var body: some View {
        ThermyxDetailScreen(title: "Connect a device") {
            statusCard

            HStack(spacing: Thermyx.Space.m) {
                Button(scanning ? "Stop" : "Scan") {
                    scanning ? stop() : start()
                }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .fixedSize(horizontal: true, vertical: false)
                .disabled(ble.state != .poweredOn)
                if scanning {
                    ProgressView().tint(Thermyx.Ink.textSupporting)
                }
                Spacer(minLength: 0)
            }

            ThermyxGroupedCard {
                Toggle(isOn: $showAll) {
                    Text("Show all Bluetooth devices")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                }
                .tint(Thermyx.Ink.ice)
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
                .frame(minHeight: Thermyx.minimumTapTarget)
            }
            .onChange(of: showAll) { _, _ in
                if scanning { start() }
            }

            if let problem = bluetoothProblem {
                Text(problem)
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.amber)
            }

            deviceList

            if let error = ble.errorMessage {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text("Thermyx devices are found by their Bluetooth service, so any name shows up. The sensor you connect is remembered and reconnects by itself if it drops out. After you tap Disconnect it stays disconnected until you connect it again here.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .onDisappear { if scanning { stop() } }
        .onChange(of: ble.boardState) { _, state in
            if case .connecting = state { scanning = false }
        }
    }

    private var statusCard: some View {
        ThermyxCard {
            HStack(spacing: Thermyx.Space.m) {
                VStack(alignment: .leading, spacing: 4) {
                    SectionLabel("Sensor")
                    BoardStatusPill(ble: ble)
                }
                Spacer(minLength: Thermyx.Space.xs)
                switch ble.boardState {
                case .connected, .connecting, .reconnecting:
                    Button("Disconnect") { ble.disconnectBoard() }
                        .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))
                        .fixedSize()
                default:
                    EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Thermyx devices")
            if thermyxDevices.isEmpty {
                Text(scanning ? "Looking for Thermyx devices…" : "Tap Scan to look for nearby devices.")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            } else {
                rows(thermyxDevices)
            }

            if showAll {
                SectionLabel("Other Bluetooth devices")
                    .padding(.top, Thermyx.Space.s)
                if !otherDevices.isEmpty { rows(otherDevices) }
                if hiddenUnnamed > 0 {
                    Text(verbatim: "\(hiddenUnnamed) unnamed device\(hiddenUnnamed == 1 ? "" : "s") not listed")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
            }
        }
    }

    private func rows(_ list: [ThermyxBLEService.DiscoveredDevice]) -> some View {
        ThermyxGroupedCard {
            ForEach(Array(list.enumerated()), id: \.element.id) { index, device in
                if index > 0 { ThermyxDivider() }
                Button {
                    viewModel.connect(to: device)
                    scanning = false
                } label: {
                    DeviceRow(device: device)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Connects to this device")
            }
        }
    }

    private var bluetoothProblem: String? {
        switch ble.state {
        case .poweredOn: return nil
        case .poweredOff: return "Bluetooth is off. Turn it on in Control Center."
        case .unauthorized: return "Bluetooth isn't allowed. Turn it on in Settings → Thermyx."
        case .unsupported: return "This device has no Bluetooth. Use a real iPhone."
        default: return "Starting Bluetooth…"
        }
    }

    private func start() {
        ble.scan(showAll: showAll)
        scanning = true
    }

    private func stop() {
        ble.stopScan()
        scanning = false
    }
}

private struct DeviceRow: View {
    let device: ThermyxBLEService.DiscoveredDevice

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Image(systemName: icon)
                .foregroundStyle(device.looksLikeThermyx ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: device.name)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .lineLimit(1)
                Text(kindLabel)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
            }
            Spacer(minLength: Thermyx.Space.xs)
            Text(verbatim: device.isSystemConnected ? "On iPhone" : "\(device.rssi) dBm")
                .font(ThermyxFont.captionSmall)
                .monospacedDigit()
                .foregroundStyle(device.isStrong ? Thermyx.Ink.textSecondary : Thermyx.Ink.amber)
            Image(systemName: "chevron.right")
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.m)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(device.isSystemConnected
            ? "\(device.name), \(kindLabel), already connected to this iPhone"
            : "\(device.name), \(kindLabel), signal \(device.rssi) decibel-milliwatts")
    }

    private var icon: String {
        switch device.kind {
        case .sensorBoard: return "sensor"
        case .insole: return "shoeprints.fill"
        case .other: return "dot.radiowaves.left.and.right"
        }
    }

    private var kindLabel: String {
        switch device.kind {
        case .sensorBoard: return "Thermyx sensor"
        case .insole: return device.advertisedFoot.map { "Thermyx insole · \($0.label)" } ?? "Thermyx insole"
        case .other:
            return device.looksLikeThermyx
                ? "Named Thermyx · sensor service not advertised"
                : "Other Bluetooth device"
        }
    }
}

// MARK: - Home

/// Home while no insole is live: the board's main sensor when one is
/// reporting, otherwise the regular empty state.
struct SensorHomeSwitch<Empty: View>: View {
    @ObservedObject var board: SensorBoardStore
    @ObservedObject var ble: ThermyxBLEService
    let unit: TemperatureUnit
    /// Tapping a sole scans for that foot's insole, as on the empty state.
    var onScan: (Foot) -> Void
    @ViewBuilder var empty: Empty

    var body: some View {
        if ble.boardState.isConnected || !board.table.connected.isEmpty {
            SensorMainView(board: board, ble: ble, unit: unit, onScan: onScan)
        } else {
            empty
        }
    }
}

/// The main page rule: temperature only if any temperature sensor is
/// connected (TMP102 before NTC, then the lowest channel); otherwise FSR,
/// then KNOB, then unknown; otherwise "No sensor connected". The insole
/// model sits below the reading: the board's slot active, the other dimmed.
struct SensorMainView: View {
    @ObservedObject var board: SensorBoardStore
    @ObservedObject var ble: ThermyxBLEService
    let unit: TemperatureUnit
    var onScan: (Foot) -> Void

    /// The slot the board fills on the model.
    static let boardFoot: Foot = .left

    var body: some View {
        VStack(spacing: Thermyx.Space.l) {
            Spacer(minLength: 0)
            BoardStatusPill(ble: ble)

            if let channel = board.mainChannel {
                let display = board.display(channel)
                VStack(spacing: Thermyx.Space.s) {
                    Text(display.title)
                        .narrowLabel(ThermyxFont.statusPillLarge, tracking: ThermyxTracking.sectionLabel, color: Thermyx.Ink.textSupporting)
                    Text(verbatim: display.primary)
                        .font(ThermyxFont.heroNumeral)
                        .tracking(ThermyxTracking.heroNumeral)
                        .monospacedDigit()
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    if let secondary = display.secondary {
                        Text(verbatim: secondary)
                            .font(ThermyxFont.metricNumeral)
                            .monospacedDigit()
                            .foregroundStyle(Thermyx.Ink.textSecondary)
                    }
                    if channel.key.channel > 0 || board.table.connected.count > 1 {
                        Text(verbatim: "Channel \(channel.key.channel)")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }
                }
                .accessibilityElement(children: .combine)
            } else {
                Text("No sensor connected")
                    .font(ThermyxFont.featureHeadline)
                    .tracking(-0.8)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text("The board is connected but no sensor has reported in the last 5 seconds.")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }

            let press = SensorReadout.fsrPress(board.table.connected, calibration: board.calibration)
            BilateralSoleView(
                unit: unit,
                onScan: onScan,
                boardFoot: Self.boardFoot,
                boardPressedZone: press == nil ? nil : SensorReadout.fsrZone,
                boardPressStrength: press ?? 0
            )
            .padding(.horizontal, Thermyx.Space.screen - Thermyx.Space.wide)
            .frame(maxHeight: .infinity)
            .animation(.easeOut(duration: 0.2), value: press)

            if ble.isDemoMode {
                Text("Simulated — not live sensor data")
                    .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: Thermyx.Ink.amber)
            }
            Text("Test board reading. Not used for risk levels, alerts, or Apple Health. Every sensor is on Insights.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, Thermyx.Space.wide)
    }
}

// MARK: - Insights

/// One card per connected board sensor.
struct BoardSensorCards: View {
    @ObservedObject var board: SensorBoardStore
    @ObservedObject var history: ThermyxHistoryStore
    @ObservedObject var ble: ThermyxBLEService

    var body: some View {
        ForEach(board.table.connected) { channel in
            SensorCard(channel: channel, display: board.display(channel), calibration: board.calibration,
                       minutes: history.sensorHistory(key: channel.key.id), isDemo: ble.isDemoMode)
        }
    }
}

/// A sensor's live value, its last two minutes, and per-minute history,
/// all in its own units.
struct SensorCard: View {
    let channel: SensorChannel
    let display: SensorDisplay
    let calibration: SensorCalibration
    let minutes: [SensorMinute]
    let isDemo: Bool

    var body: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                SectionLabel(display.title) {
                    Text(verbatim: "CH \(channel.key.channel)")
                        .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: Thermyx.Ink.textFaint)
                }

                HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.m) {
                    Text(verbatim: display.primary)
                        .font(ThermyxFont.statNumeral)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    if let secondary = display.secondary {
                        Text(verbatim: secondary)
                            .font(ThermyxFont.rowTitleRegular)
                            .foregroundStyle(Thermyx.Ink.textSecondary)
                    }
                }
                .monospacedDigit()
                .accessibilityElement(children: .combine)

                if channel.trace.count >= 2 {
                    Chart(channel.trace) { point in
                        LineMark(x: .value("Time", point.time), y: .value(display.chartUnit, point.value))
                            .foregroundStyle(Thermyx.Ink.ice)
                            .interpolationMethod(.monotone)
                    }
                    .chartYScale(domain: domain(channel.trace.map(\.value)))
                    .chartYAxis { axis }
                    .chartXAxis(.hidden)
                    .frame(height: 90)
                    .accessibilityLabel("Last two minutes of \(display.title)")
                    Text(verbatim: "Last 2 minutes · live · \(display.chartUnit)")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }

                if minutes.count >= 2 {
                    Chart(minutes) { minute in
                        LineMark(x: .value("Minute", minute.start), y: .value(display.chartUnit, minute.mean))
                            .foregroundStyle(Thermyx.Ink.signal)
                        PointMark(x: .value("Minute", minute.start), y: .value(display.chartUnit, minute.mean))
                            .foregroundStyle(Thermyx.Ink.signal)
                            .symbolSize(12)
                    }
                    .chartYScale(domain: domain(minutes.map(\.mean)))
                    .chartYAxis { axis }
                    .frame(height: 90)
                    .accessibilityLabel("\(display.title), one point per minute")
                }
                if let last = minutes.last {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Per-minute average")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textFaint)
                        ForEach(Array(minutes.suffix(3).reversed())) { minute in
                            HStack {
                                Text(minute.start, format: .dateTime.hour().minute())
                                Spacer()
                                Text(verbatim: SensorFormat.value(minute.mean, unit: display.chartUnit))
                            }
                            .font(ThermyxFont.captionSmall)
                            .monospacedDigit()
                            .foregroundStyle(minute.id == last.id ? Thermyx.Ink.textSecondary : Thermyx.Ink.textSupporting)
                        }
                    }
                }

                if isDemo {
                    Text("Simulated — not live sensor data")
                        .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: Thermyx.Ink.amber)
                }
                Text(footnote)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func domain(_ values: [Double]) -> ClosedRange<Double> {
        switch channel.key.type {
        case .fsr:
            return 0...max(FSR402.maxForceN * calibration.fsrScale, values.max() ?? 0)
        case .knob:
            return 0...Double(ThermyxSensorProtocol.maxRaw)
        default:
            let low = values.min() ?? 0
            let high = values.max() ?? 1
            let pad = max((high - low) * 0.2, channel.key.type.isTemperature ? 0.5 : 1)
            return (low - pad)...(high + pad)
        }
    }

    private var axis: some AxisContent {
        AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
            AxisGridLine().foregroundStyle(Thermyx.Ink.divider)
            AxisValueLabel {
                if let v = value.as(Double.self) { Text(verbatim: SensorFormat.axis(v, unit: display.chartUnit)) }
            }
        }
    }

    private var footnote: String {
        switch channel.key.type {
        case .ntc:
            return "10 kΩ NTC (B 3950), 5-sample average, plus your offset. Shows -- outside -20 to 100 °C. Not a body reading: never used for alerts or Apple Health."
        case .tmp102:
            return "TMP102 digital sensor, °C as sent by the board. Not used for alerts or Apple Health."
        case .fsr:
            return "Approximate force from the FSR402's typical curve (G / 80, clamped to 20 N, × your scale). Pressure assumes the 12.7 mm pad. Not a calibrated scale."
        case .knob:
            return "Test input from the board's analog pin: raw 0–4095 and volts (4095 = 3.3 V). No conversion."
        case .unknown:
            return "The board sent a sensor type this app doesn't know, so only its raw value is shown."
        }
    }
}

enum SensorFormat {
    static func value(_ value: Double, unit: String) -> String {
        switch unit {
        case "°C": return String(format: "%.1f °C", value)
        case "N": return String(format: "%.2f N", value)
        default: return String(format: "%.0f", value)
        }
    }

    static func axis(_ value: Double, unit: String) -> String {
        switch unit {
        case "°C": return String(format: "%.1f°", value)
        case "N": return String(format: "%g N", (value * 10).rounded() / 10)
        default: return String(format: "%.0f", value)
        }
    }
}

// MARK: - Advanced

/// Detection is automatic; the override is for a board whose firmware still
/// sends bare numbers. Calibration and the raw counts for wiring checks.
struct BoardSettingsSection: View {
    @ObservedObject var board: SensorBoardStore
    @ObservedObject var ble: ThermyxBLEService
    @State private var connecting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Test board sensors") {
                BoardStatusPill(ble: ble)
            }
            ThermyxGroupedCard {
                Button {
                    connecting = true
                } label: {
                    HStack {
                        Text("Connect a device")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Spacer()
                        Image(systemName: "chevron.right")
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }
                    .padding(.horizontal, Thermyx.Space.xl)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)

                ThermyxDivider()
                row {
                    Picker("Sensor type", selection: $board.typeOverride) {
                        ForEach(SensorTypeOverride.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                    .tint(Thermyx.Ink.ice)
                }

                ThermyxDivider()
                row {
                    Stepper(value: $board.calibration.ntcOffsetC, in: -10...10, step: 0.1) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: String(format: "NTC offset %+.1f °C", board.calibration.ntcOffsetC))
                                .font(ThermyxFont.body)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text("Added to every NTC temperature. 0.0 = no correction.")
                                .font(ThermyxFont.captionSmall)
                                .foregroundStyle(Thermyx.Ink.textSupporting)
                        }
                    }
                }

                ThermyxDivider()
                row {
                    Stepper(value: $board.calibration.fsrScale, in: FSR402.scaleRange, step: 0.05) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(verbatim: String(format: "FSR scale × %.2f", board.calibration.fsrScale))
                                .font(ThermyxFont.body)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text("Multiplies the approximate force. 1.00 = the datasheet curve.")
                                .font(ThermyxFont.captionSmall)
                                .foregroundStyle(Thermyx.Ink.textSupporting)
                        }
                    }
                }
            }

            ForEach(board.table.connected) { channel in
                if let raw = channel.value.raw {
                    Text(verbatim: String(format: "Debug · %@ ch %d · raw %d / 4095 · %.3f V",
                                          channel.key.type.code, channel.key.channel, raw, AnalogPin.volts(raw: raw)))
                        .font(ThermyxFont.captionSmall)
                        .monospacedDigit()
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
            }
            Text("Sensors are detected from what the board sends (TYPE,CHANNEL,VALUE). Use the override only for older firmware that sends a bare number. Board readings never change risk levels, send alerts, or write to Apple Health.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .sheet(isPresented: $connecting) {
            NavigationStack { ConnectDeviceView(ble: ble) }
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private func row<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .padding(.horizontal, Thermyx.Space.xl)
            .padding(.vertical, Thermyx.Space.m)
            .frame(minHeight: Thermyx.minimumTapTarget)
    }
}
