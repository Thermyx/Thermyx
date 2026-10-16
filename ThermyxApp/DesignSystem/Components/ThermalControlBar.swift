import SwiftUI

/// The thermal control, pinned above the tab bar on every wearer screen. A
/// watcher never sees it: a trusted member can't actuate the device.
///
/// One button carries the mode: tap to step Auto → Cool → Heat → Off, hold
/// for the list. Taps land on screen at once but go to the insoles only once
/// the wearer stops tapping, so stepping past Heat on the way to Off never
/// sends a moment of heating. Beside it, the Auto target in a stepper.
///
/// - **Disconnected**: dimmed, the mode button says so, nothing actuates.
/// - **Heat locked out** (High risk and above): Heat is skipped and the
///   status says why. More heat into a heat-strained foot isn't offered.
/// - The status line reports what the insoles say back, not what was asked.
struct ThermalControlBar: View {
    @ObservedObject var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    /// The mode on screen while taps are still coming.
    @State private var pending: ThermalSetting?
    @State private var commit: Task<Void, Never>?
    @State private var targetCommit: Task<Void, Never>?

    private var isEnabled: Bool { viewModel.isControlAvailable }
    private var heatLocked: Bool { viewModel.isHeatLockedOut }
    private var shown: ThermalSetting { pending ?? viewModel.thermalSetting }
    private var unit: TemperatureUnit { settings.temperatureUnit }

    /// How long a pause in tapping counts as a decision.
    private static let settleDelay: Duration = .milliseconds(650)

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: Thermyx.Space.s) {
                modeButton
                    .spotlightTarget(.thermalMode)
                stepper
                    .spotlightTarget(.targetStepper)
            }
            // Why the mode changed without the wearer asking (the heat
            // lockout), or why a request was refused.
            if let notice = viewModel.controlNotice ?? viewModel.commandError {
                Text(notice)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 4)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background {
            Color.black.overlay(alignment: .top) { ThermyxDivider() }
        }
        .animation(SiteMotion.settle, value: viewModel.controlNotice ?? viewModel.commandError)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thermal control")
    }

    // MARK: Mode

    private var modeButton: some View {
        Button(action: step) {
            HStack(spacing: Thermyx.Space.m) {
                ThermyxModeDot(mode: shown.widgetMode, size: 12)
                    .opacity(isEnabled ? 1 : 0.4)
                VStack(alignment: .leading, spacing: 1) {
                    Text(isEnabled ? shown.label : "No insoles")
                        .font(.custom(ThermyxFont.Family.semibold, size: 17, relativeTo: .headline))
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(statusLine)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(statusTint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Thermyx.Space.xl)
            .frame(maxWidth: .infinity, minHeight: 54)
            .background(Thermyx.Tint.neutralFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
        }
        .buttonStyle(PressScaleStyle())
        .disabled(!isEnabled)
        .contextMenu {
            ForEach(ThermalSetting.cycle) { setting in
                Button {
                    choose(setting)
                } label: {
                    Label(setting.label, systemImage: setting == .heat && heatLocked ? "lock.fill" : setting.symbol)
                }
                .disabled(setting == .heat && heatLocked)
            }
        }
        .sensoryFeedback(.selection, trigger: pending)
        .accessibilityLabel("Thermal mode, \(shown.label)")
        .accessibilityValue(statusLine)
        .accessibilityHint(isEnabled ? "Tap to change mode. Touch and hold for all modes." : "Connect an insole to control it.")
        .accessibilityActions {
            ForEach(ThermalSetting.cycle) { setting in
                if !(setting == .heat && heatLocked) {
                    Button(setting.label) { choose(setting) }
                }
            }
        }
    }

    /// The next mode in the cycle, skipping Heat while it's locked out.
    private func step() {
        var next = shown.next
        if next == .heat, heatLocked { next = next.next }
        pending = next
        commit?.cancel()
        commit = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            choose(next)
        }
    }

    private func choose(_ setting: ThermalSetting) {
        commit?.cancel()
        pending = nil
        viewModel.select(setting)
    }

    private var statusLine: String {
        guard isEnabled else { return "Connect to control" }
        if let pending, pending != viewModel.thermalSetting { return "Release to switch" }
        if case .pending(let setting, _, _) = viewModel.command.state { return "Switching to \(setting.label)…" }
        if case .failed = viewModel.command.state { return "\(viewModel.thermalSetting.label) not confirmed" }
        if heatLocked { return "Heat locked · risk elevated" }
        let target = TemperatureFormat.degrees(settings.targetTemperatureC, in: unit, decimals: unit == .celsius ? 1 : 0)
        guard let mode = viewModel.reading.thermalMode else {
            return AutoStatus.split(modes: viewModel.reading.present.map(\.thermalMode), target: target,
                                    setting: viewModel.thermalSetting)
        }
        switch (viewModel.thermalSetting, mode) {
        case (.off, _): return "Sensing only"
        case (.auto, _):
            return AutoStatus.line(mode: mode, footC: viewModel.reading.peakFootTemperatureC,
                                   targetC: settings.targetTemperatureC, target: target)
        case (.cool, .cooling), (.cool, .ventilation): return "Cooling"
        case (.heat, .heating): return "Heating"
        default: return "\(viewModel.thermalSetting.label) sent · insole \(mode.shortStatus)"
        }
    }

    private var statusTint: Color {
        guard isEnabled else { return Thermyx.Ink.textFaint }
        if viewModel.command.failureMessage != nil || heatLocked { return Thermyx.Ink.amber }
        return Thermyx.Ink.textMuted
    }

    // MARK: Target

    private var stepper: some View {
        HStack(spacing: 0) {
            stepButton(systemImage: "minus", delta: -0.5)
            Text(TemperatureFormat.degrees(settings.targetTemperatureC, in: unit, decimals: unit == .celsius ? 1 : 0))
                .font(.custom(ThermyxFont.Family.monoMedium, size: 18, relativeTo: .headline))
                .monospacedDigit()
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .frame(minWidth: 64)
                .contentTransition(.numericText())
                .accessibilityHidden(true)
            stepButton(systemImage: "plus", delta: 0.5)
        }
        .padding(.horizontal, 5)
        .frame(height: 54)
        .background(Thermyx.Tint.neutralFill, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Auto target")
        .accessibilityValue(TemperatureFormat.full(settings.targetTemperatureC, in: unit))
        .accessibilityAdjustableAction { direction in
            nudge(direction == .increment ? 0.5 : -0.5)
        }
    }

    private func stepButton(systemImage: String, delta: Double) -> some View {
        let range = ThermyxSettingsStore.targetRange
        let atLimit = delta < 0 ? settings.targetTemperatureC <= range.lowerBound : settings.targetTemperatureC >= range.upperBound
        return Button {
            nudge(delta)
        } label: {
            Image(systemName: systemImage)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(atLimit ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                .frame(width: 44, height: 44)
                .contentShape(.rect)
        }
        .buttonStyle(PressScaleStyle())
        .disabled(atLimit)
        .sensoryFeedback(.increase, trigger: settings.targetTemperatureC) { _, _ in delta > 0 }
        .sensoryFeedback(.decrease, trigger: settings.targetTemperatureC) { _, _ in delta < 0 }
    }

    /// Changes the target on screen at once; sends it once the stepping stops.
    private func nudge(_ delta: Double) {
        let range = ThermyxSettingsStore.targetRange
        let next = min(max(settings.targetTemperatureC + delta, range.lowerBound), range.upperBound)
        guard next != settings.targetTemperatureC else { return }
        withAnimation(SiteMotion.press) { settings.targetTemperatureC = next }
        targetCommit?.cancel()
        targetCommit = Task {
            try? await Task.sleep(for: Self.settleDelay)
            guard !Task.isCancelled else { return }
            viewModel.setTargetTemperature(next)
        }
    }
}

/// Presses in under the finger; nothing else.
struct PressScaleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .opacity(configuration.isPressed ? 0.8 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
    }
}

extension ThermalSetting {
    /// The order the mode button steps through.
    static let cycle: [ThermalSetting] = [.auto, .cool, .heat, .off]

    var next: ThermalSetting {
        let all = Self.cycle
        let i = all.firstIndex(of: self) ?? 0
        return all[(i + 1) % all.count]
    }

    /// The same setting as the widgets and Dynamic Island draw it.
    var widgetMode: ThermyxWidgetMode {
        switch self {
        case .auto: return .auto
        case .cool: return .cool
        case .heat: return .heat
        case .off: return .off
        }
    }
}

/// What Auto is doing, in words that match the numbers on screen: heating
/// when the insole heats, cooling when it cools, and holding when it only
/// runs the fan because the foot is already near the target. It never says
/// "cooling" for a foot that's below the target.
enum AutoStatus {
    /// Each insole regulates on its own, so the two can briefly differ:
    /// say what's happening rather than that they disagree.
    static func split(modes: [ThermalMode], target: String, setting: ThermalSetting) -> String {
        let set = Set(modes)
        if set.contains(.heating), set.contains(.cooling) { return "Warming one foot, cooling the other" }
        if setting == .auto {
            if set.contains(.cooling) { return "Cooling one foot to \(target)" }
            if set.contains(.heating) { return "Warming one foot to \(target)" }
            return "Holding \(target)"
        }
        return "\(setting.label) · insoles settling"
    }

    static func line(mode: ThermalMode, footC: Double?, targetC: Double, target: String) -> String {
        switch mode {
        case .heating: return "Warming to \(target)"
        case .cooling: return "Cooling to \(target)"
        case .ventilation, .off:
            guard let footC else { return "Holding \(target)" }
            let gap = footC - targetC
            if abs(gap) <= 1 { return "Holding \(target)" }
            return gap < 0 ? "Below \(target) · warming soon" : "Above \(target) · cooling soon"
        }
    }
}
