import SwiftUI

/// Says which line is which foot.
///
/// Needed wherever a chart draws both: colour is already spoken for by
/// temperature, so the feet are told apart by line style and this explains it.
struct FootLegend: View {
    let feet: [Foot]
    var tint: Color = Thermyx.Ink.textSupporting

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            ForEach(feet) { foot in
                HStack(spacing: 6) {
                    Capsule().fill(foot.chartColor).frame(width: 16, height: 3)
                    Text(foot.label)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

