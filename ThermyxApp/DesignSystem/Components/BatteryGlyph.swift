import SwiftUI

/// Battery thresholds shared by the glyphs, the warnings and the widgets:
/// a heads-up at 10% and an urgent one at 5%.
enum ThermyxBattery {
    static let low = 10
    static let critical = 5
    /// A warning re-arms once the insole charges back above this.
    static let reset = 15

    static func tint(_ percent: Int?) -> Color {
        guard let percent else { return Thermyx.Ink.textFaint }
        if percent <= critical { return Thermyx.Ink.ember }
        if percent <= low { return Thermyx.Ink.amber }
        return Thermyx.Ink.ice
    }
}

/// A battery drawn to scale: the fill is the charge, the colour says when to
/// act. An empty outline with no reading.
struct BatteryGlyph: View {
    let percent: Int?
    var width: CGFloat = 24
    var height: CGFloat = 12

    var body: some View {
        let tint = ThermyxBattery.tint(percent)
        let fraction = CGFloat(min(max(percent ?? 0, 0), 100)) / 100
        HStack(spacing: 1) {
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height * 0.3, style: .continuous)
                    .strokeBorder(Thermyx.Ink.textMuted.opacity(percent == nil ? 0.5 : 0.8), lineWidth: 1)
                RoundedRectangle(cornerRadius: height * 0.18, style: .continuous)
                    .fill(tint)
                    .frame(width: max(percent == nil ? 0 : 2, (width - 4) * fraction))
                    .padding(2)
            }
            .frame(width: width, height: height)
            RoundedRectangle(cornerRadius: 1)
                .fill(Thermyx.Ink.textMuted.opacity(0.8))
                .frame(width: 2, height: height * 0.4)
        }
        .animation(SiteMotion.settle, value: percent)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Battery")
        .accessibilityValue(percent.map { "\($0) percent" } ?? "No reading")
    }
}
