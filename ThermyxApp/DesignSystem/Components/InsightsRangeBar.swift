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

/// Under the title: which day (or week, or month) to look at, picked with
/// the system date picker, and which foot.
struct InsightsRangeBar: View {
    @Binding var range: InsightsRange
    @Binding var date: Date
    /// Nil hides the foot selector — used when only one insole has history,
    /// where offering a choice between one option would be noise.
    var footFilter: Binding<FootFilter>?
    var availableFeet: [Foot] = []

    private var isToday: Bool { Calendar.current.isDateInToday(date) }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            HStack(spacing: Thermyx.Space.s) {
                DatePicker("Date", selection: $date, in: ...Date.now, displayedComponents: .date)
                    .datePickerStyle(.compact)
                    .labelsHidden()
                    .tint(Thermyx.Ink.ice)
                    .accessibilityLabel("Show a \(range.label.lowercased()) around this date")
                if !isToday {
                    Button("Today") { withAnimation(SiteMotion.settle) { date = .now } }
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(Thermyx.Ink.link)
                        .frame(minHeight: Thermyx.minimumTapTarget)
                }
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
        }
    }
}
