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
                HStack(spacing: 5) {
                    DashSwatch(isDashed: foot.isDashedInCharts, tint: tint)
                    Text(foot.label)
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                }
                .accessibilityElement(children: .combine)
            }
        }
    }
}

private struct DashSwatch: View {
    let isDashed: Bool
    let tint: Color

    var body: some View {
        Capsule()
            .strokeBorder(
                tint,
                style: StrokeStyle(lineWidth: 2.5, dash: isDashed ? [3, 3] : [])
            )
            .frame(width: 18, height: 2.5)
    }
}
