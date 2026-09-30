import SwiftUI

/// Cool / Auto / Heat, pinned directly above the tab bar on every user-role
/// tab. A watcher never sees this — a trusted member cannot actuate the device.
///
/// Three states matter:
/// - **Connected**: full opacity, exclusive selection, status slot shows the
///   mode the *device* reports back, not the one we asked for.
/// - **Disconnected**: 45% opacity, `UNAVAILABLE` in the status slot, no
///   control is tappable.
/// - **Heat locked out**: at High Risk or Critical the Heat segment is
///   disabled and the status slot says so. Commanding more heat into a
///   heat-strained foot is not a choice the UI should offer.
struct ThermalControlBar: View {
    @ObservedObject var viewModel: ThermyxViewModel

    private var isEnabled: Bool { viewModel.isControlAvailable }
    private var heatLocked: Bool { viewModel.isHeatLockedOut }

    var body: some View {
        VStack(spacing: Thermyx.Space.s) {
            HStack {
                Text("Thermal mode")
                    .narrowLabel(ThermyxFont.sectionLabel, tracking: ThermyxTracking.sectionLabel, color: Thermyx.Ink.textSupporting)
                Spacer()
                Text(viewModel.thermalStatusText)
                    .narrowLabel(
                        ThermyxFont.sectionLabel,
                        tracking: ThermyxTracking.sectionLabel,
                        color: viewModel.thermalStatusTint
                    )
            }

            HStack(spacing: Thermyx.Space.xs) {
                ForEach(ThermalSetting.allCases) { setting in
                    segment(for: setting)
                }
            }

            // Why the mode changed without the wearer asking (the heat
            // lockout), or why a request was refused.
            if let notice = viewModel.controlNotice ?? viewModel.commandError {
                Text(notice)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
            }
        }
        .padding(.horizontal, Thermyx.Space.screen)
        .padding(.top, Thermyx.Space.l)
        .padding(.bottom, Thermyx.Space.m)
        .background {
            Thermyx.Ink.bar
                .overlay(alignment: .top) {
                    Rectangle().fill(Thermyx.Ink.hairline).frame(height: 1)
                }
        }
        .opacity(isEnabled ? 1 : 0.45)
        .animation(.easeOut(duration: 0.2), value: isEnabled)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Thermal mode")
    }

    @ViewBuilder
    private func segment(for setting: ThermalSetting) -> some View {
        let isSelected = viewModel.thermalSetting == setting
        let isDisabled = !isEnabled || (setting == .heat && heatLocked)

        Button {
            viewModel.select(setting)
        } label: {
            HStack(spacing: Thermyx.Space.xs) {
                Image(systemName: setting == .heat && heatLocked ? "lock.fill" : setting.symbol)
                    .font(.system(size: 15, weight: .semibold))
                Text(setting.label)
                    .font(isSelected ? ThermyxFont.controlLabel : ThermyxFont.rowTitleRegular)
            }
            .foregroundStyle(foreground(for: setting, isSelected: isSelected, isDisabled: isDisabled))
            .frame(maxWidth: .infinity)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .background(
                background(for: setting, isSelected: isSelected, isDisabled: isDisabled),
                in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .strokeBorder(border(for: setting, isSelected: isSelected, isDisabled: isDisabled), lineWidth: Thermyx.Stroke.hairline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(isDisabled)
        .accessibilityLabel(accessibilityLabel(for: setting, isDisabled: isDisabled))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    // MARK: - Segment styling
    //
    // Selected Cool is a solid Signal Blue fill with ink-on-blue text; selected
    // Heat is an Ember-tinted fill with Amber text. Unselected segments are the
    // neutral outline. All label colours are full-opacity ink so they stay
    // legible in sunlight.

    private func foreground(for setting: ThermalSetting, isSelected: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Thermyx.Ink.textSupporting }
        guard isSelected else { return Thermyx.Ink.textSecondary }
        switch setting {
        case .cool: return Thermyx.Ink.onSignal
        case .auto: return Thermyx.Ink.textPrimary
        case .heat: return Thermyx.Ink.amber
        }
    }

    private func background(for setting: ThermalSetting, isSelected: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Thermyx.Tint.neutralFill }
        guard isSelected else { return Thermyx.Tint.neutralFill }
        switch setting {
        case .cool: return Thermyx.Ink.signal
        case .auto: return Thermyx.Ink.elevated
        case .heat: return Thermyx.Tint.emberFill
        }
    }

    private func border(for setting: ThermalSetting, isSelected: Bool, isDisabled: Bool) -> Color {
        if isDisabled { return Thermyx.Tint.neutralBorder }
        guard isSelected else { return Thermyx.Tint.neutralBorder }
        switch setting {
        case .cool: return .clear
        case .auto: return Thermyx.Tint.neutralBorder
        case .heat: return Thermyx.Tint.emberBorder
        }
    }

    private func accessibilityLabel(for setting: ThermalSetting, isDisabled: Bool) -> String {
        if setting == .heat, heatLocked {
            return "Heat, locked out while risk is elevated"
        }
        if isDisabled {
            return "\(setting.label), unavailable — no insole connected"
        }
        return setting.label
    }
}

/// Lets a pushed screen hide the control bar.
///
/// The bar belongs to the tab scaffold, so a screen pushed on top of a tab
/// cannot simply not draw it. Reading screens — temperature, movement,
/// learning, the article reader — opt out through this preference: they need
/// the vertical room for charts and body copy, and they are one tap from a
/// screen that has the bar.
struct ThermalControlBarHidden: PreferenceKey {
    static let defaultValue = false
    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}

extension View {
    /// Hides the thermal control bar while this screen is on top.
    func hidesThermalControlBar() -> some View {
        preference(key: ThermalControlBarHidden.self, value: true)
    }
}
