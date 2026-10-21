import SwiftUI

/// Starts the spotlight tutorial: after onboarding, and again from Device.
@MainActor
final class TutorialCenter: ObservableObject {
    static let shared = TutorialCenter()

    /// True while the tutorial is on screen.
    @Published var isShowing = false
    /// Bumped to ask the wearer's root to switch to Home first.
    @Published private(set) var replayRequest = 0
    /// The tab the tutorial's current step is on; the root switches to it.
    @Published var requestedTab: UserTab?

    private static let seenKey = "thermyx.tutorial.seen"

    var hasSeen: Bool { UserDefaults.standard.bool(forKey: Self.seenKey) }

    func showIfFirstRun() {
        guard !hasSeen else { return }
        isShowing = true
    }

    func replay() {
        replayRequest += 1
        isShowing = true
    }

    func finish() {
        isShowing = false
        requestedTab = .home
        UserDefaults.standard.set(true, forKey: Self.seenKey)
    }
}

/// Device, pushed from Safety: each insole, the Auto target, calibration,
/// units, the tutorial, and the rest of the settings.
struct DeviceView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var health: ThermyxHealthService

    @State private var showingPairing = false
    @State private var calibrating = false
    @State private var legalDocument: LegalDocument.Kind? = {
        #if DEBUG
        return ThermyxPreviewHarness.opensLegalSheet ? .privacy : nil
        #else
        return nil
        #endif
    }()
    @State private var targetCommit: Task<Void, Never>?

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var reading: BilateralReading { viewModel.reading }

    var body: some View {
        ThermyxDetailScreen(title: "Device", backTitle: "Safety") {
            insoles
            target
            rows
            // Titled by its own card.
            AIInsightsToggle(isOn: $settings.aiInsightsEnabled) { legalDocument = $0 }
                .id("ai")
                .padding(.top, Thermyx.Space.section - Thermyx.Space.xl)
            PermissionsSection(ble: viewModel.ble, health: health)
                .id("permissions")
                .padding(.top, Thermyx.Space.section - Thermyx.Space.xl)
            ProfileSettingsSection(roles: roles, settings: settings, health: health)
                .padding(.top, Thermyx.Space.section - Thermyx.Space.xl)
            AccountSection(roles: roles, settings: settings)
                .padding(.top, Thermyx.Space.section - Thermyx.Space.xl)
            more
                .padding(.top, Thermyx.Space.section - Thermyx.Space.xl)
        }
        .sheet(isPresented: $showingPairing) {
            DeviceProfileSheet(roles: roles, settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(item: $legalDocument) { kind in
            LegalSheet(selection: kind)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .fullScreenCover(isPresented: $calibrating) {
            NavigationStack { CalibrationView(viewModel: viewModel, settings: settings) }
                .environmentObject(viewModel)
        }
    }

    // MARK: Insoles

    private var insoles: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Foot.allCases) { foot in
                insoleRow(foot)
            }
            Text("Warns at \(ThermyxBattery.low)% and \(ThermyxBattery.critical)%.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, Thermyx.Space.s)
        }
    }

    private func insoleRow(_ foot: Foot) -> some View {
        let r = reading[foot]
        let on = viewModel.isConnected(foot)
        return Button {
            if !on { viewModel.scanFor(foot); showingPairing = true }
        } label: {
            HStack(spacing: 14) {
                FootMap(foot: foot, content: .battery(percent: r?.batteryPercent, tint: batteryTint(r?.batteryPercent)))
                    .frame(width: 26, height: 62)
                VStack(alignment: .leading, spacing: 3) {
                    Text("\(foot.label) insole")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(detail(foot))
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(on ? Thermyx.Ink.textMuted : Thermyx.Ink.amber)
                    if on {
                        Text(batteryLine(foot))
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle((r?.batteryPercent ?? 100) <= ThermyxBattery.low ? ThermyxBattery.tint(r?.batteryPercent) : Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: Thermyx.Space.s)
                if on {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(r?.batteryPercent.map { "\($0)%" } ?? "—")
                            .font(.custom(ThermyxFont.Family.monoMedium, size: 18, relativeTo: .headline))
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        BatteryGlyph(percent: r?.batteryPercent, width: 30, height: 14)
                    }
                } else {
                    Text("Pair")
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(Thermyx.Ink.ice)
                }
            }
            .padding(.vertical, 12)
            .overlay(alignment: .bottom) { ThermyxDivider() }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if on {
                Button("Disconnect \(foot.label.lowercased())", role: .destructive) { viewModel.disconnect(foot) }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityHint(on ? "Touch and hold to disconnect." : "Pairs the \(foot.label.lowercased()) insole.")
    }

    private func detail(_ foot: Foot) -> String {
        guard viewModel.isConnected(foot) else { return "Not connected" }
        var parts = ["Connected"]
        if let rssi = viewModel.ble.rssi[foot] { parts.append("\(DeviceHealthStrip.signalWord(rssi)) signal") }
        return parts.joined(separator: " · ")
    }

    /// Time left at the measured drain, the drain itself, and what the
    /// insole is spending it on.
    private func batteryLine(_ foot: Foot) -> String {
        let mode = reading[foot]?.thermalMode.shortStatus
        guard let estimate = viewModel.batteryEstimates[foot] else {
            return "Time left shows after 15 minutes of wear" + (mode.map { " · now \($0)" } ?? "")
        }
        let minutes = Int((estimate.hoursLeft * 60).rounded())
        let left = minutes >= 60 ? "\(minutes / 60) h \(minutes % 60) min" : "\(minutes) min"
        return "About \(left) left · \(String(format: "%.1f", estimate.perHour))% an hour" + (mode.map { " · \($0)" } ?? "")
    }

    private func batteryTint(_ percent: Int?) -> Color {
        guard let percent else { return Thermyx.Ink.textFaint }
        return ThermyxBattery.tint(percent)
    }

    // MARK: Auto target

    private var target: some View {
        let range = ThermyxSettingsStore.targetRange
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text("Auto target")
                    .font(ThermyxFont.sectionTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                Text(TemperatureFormat.degrees(settings.targetTemperatureC, in: unit, decimals: unit == .celsius ? 1 : 0))
                    .font(ThermyxFont.monoLarge)
                    .tracking(ThermyxTracking.monoLarge)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .contentTransition(.numericText(value: settings.targetTemperatureC))
            }
            LearnedTargetSlider(
                value: Binding(get: { settings.targetTemperatureC }, set: { setTarget($0) }),
                range: range,
                learned: learnedTargetC
            )
            .accessibilityLabel("Auto target")
            .accessibilityValue(TemperatureFormat.full(settings.targetTemperatureC, in: unit))
            HStack {
                Text(TemperatureFormat.degrees(range.lowerBound, in: unit, decimals: 0))
                Spacer()
                Spacer()
                Text(TemperatureFormat.degrees(range.upperBound, in: unit, decimals: 0))
            }
            .font(ThermyxFont.captionSmall)
            .foregroundStyle(Thermyx.Ink.textMuted)
            if let learned = learnedTargetC, abs(learned - settings.targetTemperatureC) >= 0.25 {
                Button {
                    setTarget(learned)
                } label: {
                    Label("Back to your calibrated \(TemperatureFormat.degrees(learned, in: unit, decimals: unit == .celsius ? 1 : 0))",
                          systemImage: "arrow.uturn.backward")
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(Thermyx.Ink.link)
                        .frame(minHeight: Thermyx.minimumTapTarget)
                }
                .buttonStyle(.plain)
                .transition(.opacity)
            }
        }
        .padding(.vertical, 14)
        .animation(SiteMotion.settle, value: settings.targetTemperatureC)
    }

    /// The hold temperature calibration learned, kept on the slider as an
    /// outline so it's never lost after the target is moved.
    private var learnedTargetC: Double? { viewModel.baseline.model?.comfortTargetC }

    private func setTarget(_ value: Double) {
        settings.targetTemperatureC = (value * 2).rounded() / 2
        targetCommit?.cancel()
        targetCommit = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            viewModel.setTargetTemperature(settings.targetTemperatureC)
        }
    }

    private var targetSource: String {
        guard let model = viewModel.baseline.model, let learned = model.comfortTargetC else { return "Set by you" }
        let date = model.trainedAt.formatted(.dateTime.month(.abbreviated).day())
        return abs(learned - settings.targetTemperatureC) < 0.25 ? "Calibrated \(date)" : "Moved from calibration (\(date))"
    }

    // MARK: Rows

    private var rows: some View {
        VStack(spacing: 0) {
            row("Calibration") {
                HStack(spacing: 6) {
                    Text(calibrationStatus)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                    Button(viewModel.baseline.model == nil ? "Start" : "Redo") { calibrating = true }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .tint(Thermyx.Ink.link)
                        .disabled(!viewModel.anyConnected)
                }
            }
            row("Thermal module") {
                Text(moduleStatus).foregroundStyle(Thermyx.Ink.textMuted)
            }
            row("Units") {
                ThermyxSegmentedControl(options: TemperatureUnit.allCases, label: \.shortLabel,
                                        selection: $settings.temperatureUnit, accessibilityPrefix: "Show temperatures in ")
                    .fixedSize()
            }
            Button {
                TutorialCenter.shared.replay()
            } label: {
                row("Replay tutorial") {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            row("Sensors", last: true) {
                Text("Temperature, pressure, motion")
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .font(ThermyxFont.captionSmall)
            }
        }
    }

    private var calibrationStatus: String {
        guard let model = viewModel.baseline.model else { return "Not done" }
        return model.outdoorDone ? "6 of 6" : "3 of 6"
    }

    private var moduleStatus: String {
        guard viewModel.anyConnected else { return "Offline" }
        switch reading.thermalMode {
        case .cooling?: return "Cooling · fan on"
        case .ventilation?: return "Ventilating · fan on"
        case .heating?: return "Heating"
        case .off?: return "Idle · fan off"
        case nil: return "Each foot on its own"
        }
    }

    private func row<Trailing: View>(_ title: String, last: Bool = false, @ViewBuilder trailing: () -> Trailing) -> some View {
        HStack {
            Text(title)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            Spacer(minLength: Thermyx.Space.s)
            trailing()
                .font(ThermyxFont.bodySmall)
        }
        .frame(minHeight: 52)
        .overlay(alignment: .top) { ThermyxDivider() }
        .overlay(alignment: .bottom) { if last { ThermyxDivider() } }
        .accessibilityElement(children: .combine)
    }

    // MARK: More

    private var more: some View {
        VStack(spacing: 0) {
            NavigationLink(value: SafetyDestination.advanced) {
                ThermyxNavigationRow(title: "Advanced", detail: "Relay, Health, your data",
                                     systemImage: "slider.horizontal.3", iconTint: Thermyx.Ink.textMuted)
            }
            .buttonStyle(.plain)
            Button { legalDocument = .privacy } label: {
                ThermyxNavigationRow(title: "Privacy & terms", systemImage: "doc.text",
                                     iconTint: Thermyx.Ink.textMuted)
            }
            .buttonStyle(.plain)
            Text("Thermyx is an investigational heat-risk warning aid. It does not measure core body temperature and does not diagnose heat illness.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.top, 16)
        }
    }
}

/// The Auto target slider, with a dashed ring where calibration put the
/// target. It sits behind the thumb, so it disappears when the two agree and
/// stays visible, labelled, when the target has been moved away.
struct LearnedTargetSlider: View {
    @Binding var value: Double
    let range: ClosedRange<Double>
    let learned: Double?

    private static let thumb: CGFloat = 28

    var body: some View {
        ZStack {
            if let learned {
                GeometryReader { geo in
                    let f = (min(max(learned, range.lowerBound), range.upperBound) - range.lowerBound) / (range.upperBound - range.lowerBound)
                    let x = Self.thumb / 2 + f * (geo.size.width - Self.thumb)
                    Circle()
                        .strokeBorder(Thermyx.Ink.ice, style: StrokeStyle(lineWidth: 1.5, dash: [3, 2.5]))
                        .frame(width: Self.thumb + 8, height: Self.thumb + 8)
                        .position(x: x, y: geo.size.height / 2)
                    Text("Calibrated")
                        .font(ThermyxFont.monoSmall)
                        .foregroundStyle(Thermyx.Ink.ice)
                        .fixedSize()
                        .position(x: min(max(x, 34), geo.size.width - 34), y: geo.size.height / 2 + 28)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            Slider(value: $value, in: range)
                .tint(Thermyx.Ink.signal)
        }
        .frame(height: 36)
        .padding(.bottom, learned == nil ? 0 : 18)
    }
}
