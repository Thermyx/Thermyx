import SwiftUI

/// Day / Week / Month as the design's underlined tabs: the accessory on the
/// Insights title.
struct InsightsRangeTabs: View {
    @Binding var range: InsightsRange

    var body: some View {
        HStack(spacing: 16) {
            ForEach(InsightsRange.allCases) { option in
                let selected = option == range
                Button {
                    withAnimation(SiteMotion.settle) { range = option }
                } label: {
                    Text(option.label)
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(selected ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                        .padding(.bottom, 4)
                        .overlay(alignment: .bottom) {
                            Rectangle().fill(selected ? Thermyx.Ink.ice : .clear).frame(height: 2)
                        }
                        .frame(minHeight: 44)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Show \(option.label.lowercased())")
                .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
            }
        }
        .sensoryFeedback(.selection, trigger: range)
    }
}

/// Under the title: whether periods follow the calendar or roll, which foot
/// to show, and a line saying what the window actually is.
///
/// The calendar switch sits with the range because together they answer one
/// question, which stretch of time am I looking at.
struct InsightsRangeBar: View {
    @Binding var range: InsightsRange
    @Binding var style: InsightsPeriodStyle
    /// Nil hides the foot selector — used when only one insole has history,
    /// where offering a choice between one option would be noise.
    var footFilter: Binding<FootFilter>?
    var availableFeet: [Foot] = []

    private var isStandard: Bool { style == .standard }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            HStack(spacing: Thermyx.Space.m) {
                Text(explanation)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                Spacer(minLength: 0)
                Toggle(isOn: Binding(get: { isStandard }, set: { style = $0 ? .standard : .rolling })) {
                    Text("Calendar")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                }
                .toggleStyle(.switch)
                .tint(Thermyx.Ink.signal)
                .fixedSize()
                .accessibilityLabel("Calendar periods")
                .accessibilityHint(isStandard
                    ? "Aligned to the calendar. Turn off for a rolling window."
                    : "A rolling window. Turn on to align to the calendar.")
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
        }
    }

    /// Says what the current combination actually means.
    private var explanation: String {
        switch (range, style) {
        case (.day, .standard): return "Since midnight today"
        case (.week, .standard): return "Since the start of this week"
        case (.month, .standard): return "Since the first of the month"
        case (.day, .rolling): return "The last 24 hours"
        case (.week, .rolling): return "The last 7 days"
        case (.month, .rolling): return "The last 30 days"
        }
    }
}
