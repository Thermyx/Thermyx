import SwiftUI

/// Day / Week / Month, plus the switch between calendar-aligned and rolling
/// windows.
///
/// The two controls sit together because they answer one question jointly:
/// *which stretch of time am I looking at.* Separating them would make the
/// Standard switch look like a display preference rather than a change of
/// window — which is what it is.
struct InsightsRangeBar: View {
    @Binding var range: InsightsRange
    @Binding var style: InsightsPeriodStyle
    /// Nil hides the foot selector — used when only one insole has history,
    /// where offering a choice between one option would be noise.
    var footFilter: Binding<FootFilter>?
    var availableFeet: [Foot] = []

    private var isStandard: Bool { style == .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            HStack(spacing: Thermyx.Space.s) {
                ThermyxSegmentedControl(
                    options: InsightsRange.allCases,
                    label: \.label,
                    selection: $range,
                    accessibilityPrefix: "Show "
                )

                Button {
                    style = isStandard ? .rolling : .standard
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: isStandard ? "checkmark.square.fill" : "square")
                            .font(.system(size: 15, weight: .semibold))
                        Text("Standard")
                            .narrowLabel(
                                ThermyxFont.statusPill,
                                tracking: ThermyxTracking.axisLabel,
                                color: isStandard ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting
                            )
                    }
                    .foregroundStyle(isStandard ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting)
                    .padding(.horizontal, Thermyx.Space.m)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                    .background(
                        isStandard ? Thermyx.Tint.liveFill : Thermyx.Tint.neutralFill,
                        in: Capsule()
                    )
                    .overlay {
                        Capsule().strokeBorder(
                            isStandard ? Thermyx.Tint.liveBorder : Thermyx.Tint.neutralBorder,
                            lineWidth: Thermyx.Stroke.hairline
                        )
                    }
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Standard periods")
                .accessibilityValue(isStandard ? "On" : "Off")
                .accessibilityHint(isStandard
                    ? "Currently aligned to the calendar. Double tap for a rolling window."
                    : "Currently a rolling window. Double tap to align to the calendar.")

                Spacer(minLength: 0)
            }

            if let footFilter, availableFeet.count > 1 {
                ThermyxSegmentedControl(
                    options: FootFilter.allCases,
                    label: \.label,
                    selection: footFilter,
                    accessibilityPrefix: "Show "
                )
                .fixedSize()
            }

            Text(explanation)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Says what the current combination actually means, because "Standard" on
    /// its own does not tell you where the window starts.
    private var explanation: String {
        switch (range, style) {
        case (.day, .standard): return "Since midnight today."
        case (.week, .standard): return "Since the start of this week."
        case (.month, .standard): return "Since the first of the month."
        case (.day, .rolling): return "The last 24 hours, rolling."
        case (.week, .rolling): return "The last 7 days, rolling."
        case (.month, .rolling): return "The last 30 days, rolling."
        }
    }
}
