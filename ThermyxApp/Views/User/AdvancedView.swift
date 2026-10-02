import SwiftUI

/// Everything that used to be a top-level Device tab: connection, target
/// temperature, backend, role, and data controls.
struct AdvancedView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var health: ThermyxHealthService

    @State private var showingPairing = false
    @State private var showingRoleConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var deleteResult: String?
    @State private var legalDocument: LegalDocument.Kind?

    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        ThermyxDetailScreen(title: "Advanced") {
            #if DEBUG
            if let simulator = viewModel.ble.simulator {
                SimulatedConditionsCard(simulator: simulator, unit: unit)
            }
            #endif
            TimelineView(.periodic(from: .now, by: 1)) { context in
                DeviceHealthStrip(now: context.date)
            }
            connectionSection
            targetTemperature
            RelayConnectionCard(settings: settings, role: "wearer")
            healthSection
            sensorLayout
            dataSection
            legalRow
        }
        .sheet(item: $legalDocument) { kind in
            LegalSheet(selection: kind)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPairing) {
            DeviceProfileSheet(roles: roles, settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Change role?", isPresented: $showingRoleConfirmation, titleVisibility: .visible) {
            Button("Change role", role: .destructive) { roles.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll go back through onboarding. Your contacts and history stay on this phone.")
        }
        .confirmationDialog("Delete my data?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete my data", role: .destructive) {
                Task { deleteResult = await DataDeletion.deleteEverything(viewModel: viewModel, settings: settings) ?? "Your data was deleted." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes your history, personal baseline, and trusted contacts from this phone, disconnects the relay, and deletes what the relay holds about you, which also ends every watcher's access. Apple Health data stays in the Health app. This cannot be undone.")
        }
        .alert(deleteResult ?? "", isPresented: Binding(get: { deleteResult != nil }, set: { if !$0 { deleteResult = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Connection
    //
    // One card per insole. They connect, drop, and reconnect independently,
    // so they are reported independently — a single combined status would
    // hide which foot is actually missing.

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Insoles")
            ForEach(Foot.allCases) { foot in
                connectionCard(foot)
            }
        }
    }

    private func connectionCard(_ foot: Foot) -> some View {
        let isOn = viewModel.isConnected(foot)
        return ThermyxCard(padding: Thermyx.Space.xxl, border: isOn ? Thermyx.Tint.liveBorder : Thermyx.Ink.hairline) {
            VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                HStack(spacing: Thermyx.Space.s) {
                    Circle()
                        .fill(isOn ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                        .frame(width: 9, height: 9)
                    Text(isOn ? "\(foot.label) · connected" : "\(foot.label) · not connected")
                        .narrowLabel(ThermyxFont.statusPillLarge, tracking: ThermyxTracking.sectionLabel,
                                     color: isOn ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                    Spacer(minLength: Thermyx.Space.xs)
                    if let rssi = viewModel.ble.rssi[foot] {
                        Text("\(rssi) dBm")
                            .narrowLabel(ThermyxFont.statusPill, tracking: 1.4, color: Thermyx.Ink.textSupporting)
                            .monospacedDigit()
                    }
                }

                HStack(spacing: Thermyx.Space.l) {
                    SoleView(foot: foot, reading: viewModel.reading[foot], unit: unit)
                        .frame(height: 56)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(viewModel.ble.names[foot] ?? "No device")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(isOn ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                        Text("XIAO ESP32-C3 · BLE telemetry")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                    Spacer(minLength: 0)
                }

                HStack(spacing: Thermyx.Space.xs) {
                    subCell("Battery", viewModel.reading[foot]?.batteryPercent.map { "\($0)%" })
                    subCell("Packet rate", viewModel.ble.packetRateHz(foot).map { String(format: "%.1f Hz", $0) })
                }

                Button(isOn ? "Disconnect \(foot.label.lowercased())" : "Pair \(foot.label.lowercased())") {
                    if isOn { viewModel.disconnect(foot) } else { viewModel.scanFor(foot); showingPairing = true }
                }
                .buttonStyle(ThermyxSecondaryButtonStyle())
            }
        }
    }

    private func subCell(_ label: String, _ value: String?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .narrowLabel(ThermyxFont.axisLabel, tracking: 1.4, color: Thermyx.Ink.textSupporting)
            Text(value ?? "—")
                .font(ThermyxFont.metricNumeralCompact)
                .monospacedDigit()
                .foregroundStyle(value == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, Thermyx.Space.m)
        .padding(.vertical, Thermyx.Space.s)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(Thermyx.Tint.neutralFill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous))
        .accessibilityElement(children: .combine)
    }

    // MARK: - Target temperature

    private var targetTemperature: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Target temperature")

            ThermyxCard(padding: Thermyx.Space.xxl, radius: Thermyx.Radius.list) {
                VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                    HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.xs) {
                        Text(TemperatureFormat.degrees(settings.targetTemperatureC, in: unit))
                            .font(ThermyxFont.statNumeral)
                            .tracking(ThermyxTracking.statNumeral)
                            .monospacedDigit()
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("Hold at")
                            .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: Thermyx.Ink.textSupporting)
                    }

                    ThermalTargetSlider(value: $settings.targetTemperatureC, range: ThermyxSettingsStore.targetRange)
                        .onChange(of: settings.targetTemperatureC) { _, celsius in
                            viewModel.setTargetTemperature(celsius)
                        }

                    Text("Auto holds your feet at this temperature. It is sent to connected insoles as you change it, and heating always stops at the \(TemperatureFormat.degrees(ThermyxRiskEngine.burnLimitC, in: unit, decimals: 0)) burn-protection limit.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack {
                        Text("Cool \(TemperatureFormat.degrees(ThermyxSettingsStore.targetRange.lowerBound, in: unit, decimals: 0))")
                            .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
                        Spacer()
                        Text("Warm \(TemperatureFormat.degrees(ThermyxSettingsStore.targetRange.upperBound, in: unit, decimals: 0))")
                            .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
                    }
                }
            }
        }
    }

    // MARK: - Health

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Apple Health")

            ThermyxGroupedCard {
                Toggle(isOn: $settings.healthKitEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect Health")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(healthStatusDetail)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                }
                .tint(Thermyx.Ink.signal)
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .disabled(!health.isAvailable)
            }

            Text("Thermyx reads steps, walking steadiness, and workouts, and writes sessions as workouts. It never writes a body temperature — the insole measures contact temperature, not core temperature.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: settings.healthKitEnabled) {
            guard settings.healthKitEnabled else { return }
            await health.requestAuthorization()
        }
    }

    private var healthStatusDetail: String {
        guard health.isAvailable else { return "Not available on this device" }
        switch health.availability {
        case .authorized: return "Connected"
        case .denied: return "Denied — change this in the Health app"
        case .notDetermined: return "Not connected"
        case .notEntitled: return "Build isn't signed for HealthKit"
        case .unavailable: return "Not available on this device"
        }
    }

    // MARK: - Data and role

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Data and role")

            ThermyxGroupedCard {
                ThermyxValueRow(
                    label: "Retained readings",
                    value: "\(viewModel.history.minuteSamples.count + viewModel.history.hourSamples.count)",
                    monospaced: true
                )
                ThermyxDivider()
                ThermyxValueRow(
                    label: "Sole size",
                    value: settings.soleSize?.label ?? "Not set"
                )
                ThermyxDivider()
                ThermyxValueRow(label: "Role", value: roles.role?.rawValue ?? "—")
            }

            NavigationLink {
                DataFlowView(settings: settings)
            } label: {
                HStack {
                    Text("What leaves your phone?")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
                .padding(.horizontal, Thermyx.Space.xl)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
            }
            .buttonStyle(.plain)

            Button("Delete my data") { showingDeleteConfirmation = true }
                .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))

            Button("Change role") { showingRoleConfirmation = true }
                .buttonStyle(ThermyxSecondaryButtonStyle())
        }
    }

    // MARK: - Sensor layout
    //
    // A reference, not a readout. It shows where the eight pressure sensors
    // sit on the sole so the layout can be checked against the hardware — and
    // so the coordinate system everything else is drawn in is visible rather
    // than theoretical. No values are shown, because the current firmware
    // reports one aggregate balance channel, not eight.

    private var sensorLayout: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Sensor layout")

            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    HStack(alignment: .center, spacing: Thermyx.Space.xl) {
                        ForEach(Foot.allCases) { foot in
                            VStack(spacing: 6) {
                                SoleView(foot: foot, reading: viewModel.reading[foot], unit: unit, showsSensorSites: true)
                                    .frame(height: 190)
                                Text(foot.label)
                                    .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Text(layoutNote)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var layoutNote: String {
        let base = "Three pressure sensors per insole (heel, arch, and forefoot) and two temperature sensors."
        guard let size = settings.soleSize else {
            return base + " Set a sole size to see the spacing in millimetres."
        }
        // Heel sensor to forefoot sensor, the span the wiring run has to cover.
        let span = size.millimetres(SoleGeometry.SensorSite.forefoot.position.y - SoleGeometry.SensorSite.heel.position.y)
        return base + String(format: " At %@, the heel-to-forefoot sensor span is %.0f mm.", size.label, span)
    }

    // MARK: - Legal

    private var legalRow: some View {
        VStack(spacing: Thermyx.Space.m) {
            Button { legalDocument = .privacy } label: {
                ThermyxNavigationRow(
                    title: "Privacy & terms",
                    detail: "How Thermyx handles your data",
                    systemImage: "doc.text.fill",
                    iconTint: Thermyx.Ink.textSupporting,
                    iconFill: Thermyx.Tint.neutralFill
                )
            }
            .buttonStyle(.plain)

            Text("Thermyx is an investigational heat-risk warning aid. It does not measure core body temperature and does not diagnose heat illness.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Thermyx.Space.xs)
    }
}

/// The gradient target-temperature track with a ringed knob.
struct ThermalTargetSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>

    private var fraction: Double {
        (value - range.lowerBound) / (range.upperBound - range.lowerBound)
    }

    var body: some View {
        GeometryReader { proxy in
            let knob: CGFloat = 22
            let travel = max(0, proxy.size.width - knob)

            ZStack(alignment: .leading) {
                Capsule()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: Thermyx.Ink.signal, location: 0),
                                .init(color: Thermyx.Ink.ice, location: 0.4),
                                .init(color: Thermyx.Ink.amber, location: 0.72),
                                .init(color: Thermyx.Ink.ember, location: 1)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    .frame(height: 8)

                Circle()
                    .fill(Thermyx.Ink.textPrimary)
                    .frame(width: knob, height: knob)
                    .overlay { Circle().strokeBorder(Thermyx.Ink.midnight, lineWidth: 3) }
                    .offset(x: travel * fraction)
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { gesture in
                        let position = min(max(0, gesture.location.x - knob / 2), travel)
                        let newFraction = travel > 0 ? position / travel : 0
                        value = (range.lowerBound + newFraction * (range.upperBound - range.lowerBound))
                            .rounded(toNearest: 0.5)
                    }
            )
        }
        .frame(height: Thermyx.minimumTapTarget)
        .accessibilityElement()
        .accessibilityLabel("Target temperature")
        .accessibilityValue(String(format: "%.1f degrees Celsius", value))
        .accessibilityAdjustableAction { direction in
            switch direction {
            case .increment: value = min(range.upperBound, value + 0.5)
            case .decrement: value = max(range.lowerBound, value - 0.5)
            @unknown default: break
            }
        }
    }
}

/// A label with an inline editable value, used in the backend card.
struct ThermyxEditableRow: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Text(label)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSupporting)
                .frame(width: 96, alignment: .leading)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(ThermyxFont.body)
            .foregroundStyle(Thermyx.Ink.textPrimary)
            .multilineTextAlignment(.trailing)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.s)
        .frame(minHeight: Thermyx.minimumTapTarget)
    }
}

private extension Double {
    func rounded(toNearest step: Double) -> Double {
        (self / step).rounded() * step
    }
}

#if DEBUG
/// Development-only controls for the simulated insoles: the air around the
/// wearer and whether they are tiring. Together with Cool / Auto / Heat these
/// drive the risk level through every rung of the escalation ladder.
private struct SimulatedConditionsCard: View {
    @ObservedObject var simulator: ThermyxInsoleSimulator
    let unit: TemperatureUnit

    private let presets: [(String, Double)] = [("Mild", 22), ("Warm", 27), ("Hot", 36)]

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Simulated conditions")
            ThermyxCard(padding: Thermyx.Space.xxl, radius: Thermyx.Radius.list, border: Thermyx.Ink.amber.opacity(0.5)) {
                VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                    Text("Air temperature · \(TemperatureFormat.degrees(simulator.ambientC, in: unit, decimals: 0))")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Picker("Air temperature", selection: $simulator.ambientC) {
                        ForEach(presets.indices, id: \.self) { index in
                            Text(presets[index].0).tag(presets[index].1)
                        }
                    }
                    .pickerStyle(.segmented)

                    Toggle(isOn: $simulator.fatigued) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Wearer is tiring")
                                .font(ThermyxFont.rowTitle)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text("Gait stability drops and load shifts to the right foot.")
                                .font(ThermyxFont.caption)
                                .foregroundStyle(Thermyx.Ink.textMuted)
                        }
                    }
                    .tint(Thermyx.Ink.amber)

                    Toggle(isOn: $simulator.coolingFault) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Insole fault")
                                .font(ThermyxFont.rowTitle)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text("The Peltier and fan stop working and heat builds up in the shoe.")
                                .font(ThermyxFont.caption)
                                .foregroundStyle(Thermyx.Ink.textMuted)
                        }
                    }
                    .tint(Thermyx.Ink.amber)

                    Text("Hot air is Caution; add a tiring wearer for High; add an insole fault for Critical. The foot hitting 40° while heating is High on its own.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}
#endif
