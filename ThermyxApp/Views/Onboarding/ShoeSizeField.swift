import SwiftUI

/// Shoe size as two dropdowns: the sizing system (US men's, US women's, UK,
/// EU) and the size in it. Any size can be chosen; it's converted through
/// foot length to the insole it needs, and shown back the way it was given.
struct ShoeSizeField: View {
    @ObservedObject var settings: ThermyxSettingsStore
    /// Glass on the onboarding pages; a plain row in settings lists.
    var glass = true

    private var system: ShoeSizeSystem { settings.shoeSizeSystem }
    private var selectedSize: Double? { settings.soleSize?.size(in: system) }

    var body: some View {
        let row = HStack(spacing: Thermyx.Space.s) {
            Text("Shoe size")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Site.textMuted)
            Spacer(minLength: Thermyx.Space.xs)
            Menu {
                Picker("Sizing", selection: $settings.shoeSizeSystem) {
                    ForEach(ShoeSizeSystem.allCases) { Text($0.label).tag($0) }
                }
            } label: {
                dropdownLabel(system.label, faint: false)
            }
            .accessibilityLabel("Sizing system, \(system.label)")
            Menu {
                Picker("Size", selection: Binding<Double?>(
                    get: { selectedSize },
                    set: { newValue in settings.soleSize = newValue.map { SoleSize.make($0, in: system) } }
                )) {
                    ForEach(system.sizes, id: \.self) { size in
                        Text(sizeText(size)).tag(Optional(size))
                    }
                }
            } label: {
                dropdownLabel(selectedSize.map(sizeText) ?? "Choose", faint: selectedSize == nil)
            }
            .accessibilityLabel("Shoe size")
            .accessibilityValue(settings.shoeSizeLabel ?? "Not chosen")
        }
        .padding(.leading, glass ? Thermyx.Space.xl : 0)
        .padding(.trailing, glass ? Thermyx.Space.s : 0)
        .frame(minHeight: 54)

        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            if glass {
                row.siteGlass(radius: Thermyx.Radius.control)
            } else {
                row
            }
            if let size = settings.soleSize {
                Text(note(size))
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(size.isSupported ? Thermyx.Site.textFaint : Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func sizeText(_ size: Double) -> String {
        size == size.rounded() ? String(Int(size)) : String(format: "%.1f", size)
    }

    private func dropdownLabel(_ text: String, faint: Bool) -> some View {
        HStack(spacing: 4) {
            Text(text)
                .font(ThermyxFont.bodyLarge)
                .monospacedDigit()
                .foregroundStyle(faint ? Thermyx.Site.textFaint : Thermyx.Site.text)
            Image(systemName: "chevron.up.chevron.down")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Thermyx.Site.textFaint)
        }
        .padding(.horizontal, Thermyx.Space.s)
        .frame(minHeight: 40)
        .background(Thermyx.Tint.neutralFill, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .contentShape(Rectangle())
    }

    private func note(_ size: SoleSize) -> String {
        let foot = Int((size.lengthMM - SoleSize.allowanceMM).rounded())
        let insole = "Insole about \(Int(size.lengthMM.rounded())) mm for a \(foot) mm foot"
        if size.isSupported { return insole + ". Trim only along the toe lines." }
        let equivalent = system == .usMen ? "" : " (US men's \(sizeText(size.usMens)))"
        return insole + equivalent + ". Today's insoles are cut for US men's 11–12; your size is saved for when yours is ready."
    }
}
