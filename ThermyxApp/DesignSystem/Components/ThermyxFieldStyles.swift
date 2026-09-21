import SwiftUI

/// A discovered insole in the pairing list.
///
/// When the firmware says which foot it is on, pairing is one tap. When it
/// does not, the row asks — because guessing and getting it backwards would
/// mislabel every reading from then on.
struct DiscoveredDeviceRow: View {
    let device: ThermyxBLEService.DiscoveredDevice
    /// Called with the foot to pair as. Nil means the device declared its own.
    var onPair: (Foot?) -> Void

    var body: some View {
        VStack(spacing: Thermyx.Space.s) {
            HStack(spacing: Thermyx.Space.m) {
                Circle()
                    .fill(device.isStrong ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
                    .frame(width: 9, height: 9)
                VStack(alignment: .leading, spacing: 2) {
                    Text(device.name)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .lineLimit(1)
                    Text("\(device.isStrong ? "Signal strong" : "Weak signal") · \(device.rssi) dBm")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                        .monospacedDigit()
                }
                Spacer(minLength: Thermyx.Space.xs)

                if let foot = device.advertisedFoot {
                    Button { onPair(foot) } label: {
                        Text("Pair \(foot.shortLabel)")
                            .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: Thermyx.Ink.ice)
                            .padding(.horizontal, Thermyx.Space.m)
                            .frame(minHeight: Thermyx.minimumTapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Pair as \(foot.label) insole")
                }
            }

            if device.advertisedFoot == nil {
                HStack(spacing: Thermyx.Space.xs) {
                    Text("Which foot?")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                    ForEach(Foot.allCases) { foot in
                        Button { onPair(foot) } label: {
                            Text(foot.label)
                                .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.ice)
                                .frame(maxWidth: .infinity)
                                .frame(minHeight: Thermyx.minimumTapTarget)
                                .background(Thermyx.Tint.liveFill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous)
                                        .strokeBorder(Thermyx.Tint.liveBorder, lineWidth: Thermyx.Stroke.hairline)
                                }
                                .contentShape(.rect)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Pair as \(foot.label) insole")
                    }
                }
            }
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.m)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous)
                .strokeBorder(
                    device.isStrong ? Thermyx.Ink.signal : Thermyx.Ink.hairline,
                    lineWidth: device.isStrong ? Thermyx.Stroke.emphasis : Thermyx.Stroke.hairline
                )
        }
        .accessibilityElement(children: .contain)
    }
}

/// The dark field style used across pairing, onboarding, and Advanced.
struct ThermyxTextFieldStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .font(ThermyxFont.bodyLarge)
            .foregroundStyle(Thermyx.Ink.textPrimary)
            .padding(.horizontal, Thermyx.Space.xl)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .strokeBorder(Thermyx.Tint.neutralBorder, lineWidth: Thermyx.Stroke.hairline)
            }
    }
}
