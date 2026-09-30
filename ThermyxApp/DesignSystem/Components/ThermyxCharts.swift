import Charts
import SwiftUI

/// Chart styling shared across Insights and the detail screens.
///
/// Swift Charts does the plotting; everything visual comes from the Thermyx
/// tokens. No Health-style chrome, no ring lookalikes — the palette and the
/// Archivo Narrow axis labels are what make these read as Thermyx.
enum ThermyxChartStyle {

    static let emberFill = LinearGradient(
        colors: [Thermyx.Ink.ember.opacity(0.38), Thermyx.Ink.ember.opacity(0)],
        startPoint: .top,
        endPoint: .bottom
    )

    static let lineWidth: CGFloat = 2.6

    /// A domain that frames the data instead of anchoring to zero.
    ///
    /// `AreaMark` pulls zero into the scale by default, which flattens a
    /// temperature series — every value sits in the top sliver of the plot.
    /// This brackets the actual range with a little headroom.
    static func domain(for values: [Double], minimumSpan: Double = 4) -> ClosedRange<Double> {
        guard let low = values.min(), let high = values.max() else { return 0...1 }
        let span = max(high - low, minimumSpan)
        let padding = span * 0.18
        return (low - padding)...(high + padding)
    }

    /// Axis labels in Archivo Narrow, tracked and faint.
    @ViewBuilder
    static func axisLabel(_ text: String) -> some View {
        Text(text)
            .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
    }
}

extension View {
    /// Strips Swift Charts' default grid and restyles the axes to the design.
    func thermyxChartAxes(xLabels: [String] = []) -> some View {
        chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Thermyx.Ink.hairline)
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
    }
}

/// A row of Archivo Narrow time labels beneath a chart. Kept outside the
/// chart so the plot keeps its full width.
struct ChartAxisRow: View {
    let labels: [String]

    var body: some View {
        HStack {
            ForEach(Array(labels.enumerated()), id: \.offset) { index, label in
                ThermyxChartStyle.axisLabel(label)
                if index < labels.count - 1 { Spacer(minLength: 0) }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Legend

struct ChartLegendChip: View {
    let color: Color
    let label: String

    var body: some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2, style: .continuous)
                .fill(color)
                .frame(width: 8, height: 8)
            Text(label)
                .narrowLabel(ThermyxFont.axisLabel, tracking: 1, color: Thermyx.Ink.textSupporting)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Donut

/// The heat-exposure ring. A two-segment donut with a rounded cap and a
/// centred figure — drawn as a Shape because Swift Charts' `SectorMark`
/// cannot round the end of an arc, and the rounded cap is the design.
struct HeatExposureDonut: View {
    /// 0...1 proportion of the window spent above the comfort band. Nil means
    /// the proportion could not be computed, and the ring reads as a dash
    /// rather than as a confident zero.
    let fraction: Double?
    var diameter: CGFloat = 104
    var stroke: CGFloat = 13

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Thermyx.Tint.track, lineWidth: stroke)
            if let fraction {
                Circle()
                    .inset(by: stroke / 2)
                    .trim(from: 0, to: max(0.001, min(1, fraction)))
                    .stroke(Thermyx.Ink.ember, style: StrokeStyle(lineWidth: stroke, lineCap: .round))
                    .rotationEffect(.degrees(-90))
            }
            VStack(spacing: 0) {
                Text(fraction.map { "\(Int(($0 * 100).rounded()))%" } ?? "—")
                    .font(.custom(ThermyxFont.Family.extraBold, size: 27, relativeTo: .title2))
                    .monospacedDigit()
                    .foregroundStyle(fraction == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                Text("of wear time")
                    .narrowLabel(ThermyxFont.axisLabel, tracking: 1.4, color: Thermyx.Ink.textSupporting)
            }
        }
        .frame(width: diameter, height: diameter)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heat exposure")
        .accessibilityValue(fraction.map { "\(Int(($0 * 100).rounded())) percent of wear time above your comfort band" } ?? "No reading")
    }
}

// MARK: - Stacked band bar

/// The time-in-zone split: one bar, four bands, four legend chips.
struct TimeInZoneBar: View {
    /// Seconds spent in each band, in `ThermyxTemperatureScale.Band` order.
    let seconds: [ThermyxTemperatureScale.Band: TimeInterval]

    private var total: TimeInterval {
        max(1, seconds.values.reduce(0, +))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            GeometryReader { proxy in
                HStack(spacing: 0) {
                    ForEach(ThermyxTemperatureScale.Band.allCases) { band in
                        let value = seconds[band] ?? 0
                        if value > 0 {
                            Rectangle()
                                .fill(band.color)
                                .frame(width: proxy.size.width * (value / total))
                        }
                    }
                }
            }
            .frame(height: 22)
            .clipShape(RoundedRectangle(cornerRadius: Thermyx.Space.xs, style: .continuous))

            FlowRow(spacing: Thermyx.Space.m) {
                ForEach(ThermyxTemperatureScale.Band.allCases) { band in
                    let value = seconds[band] ?? 0
                    if value > 0 {
                        ChartLegendChip(color: band.color, label: "\(band.label) \(DurationFormat.long(value))")
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Time in each temperature band")
    }
}

/// A minimal wrapping row, used for legend chips that must not clip on
/// narrow screens or at large Dynamic Type sizes.
struct FlowRow: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                x = bounds.minX
                y += rowHeight + spacing
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}

// MARK: - Progress bar

/// The labelled pressure-distribution bars.
struct LabeledProgressBar: View {
    let label: String
    /// 0...1
    let value: Double
    let tint: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: tint)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Thermyx.Tint.track)
                    Capsule()
                        .fill(tint)
                        .frame(width: max(0, min(1, value)) * proxy.size.width)
                }
            }
            .frame(height: 9)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue("\(Int((value * 100).rounded())) percent")
    }
}

// MARK: - Formatting

/// Left/right gaps are stored as left minus right. Readers should not have to
/// decode a sign, so the label names the foot instead.
enum GapFormat {
    static func degrees(_ value: Double) -> String {
        if abs(value) < 0.05 { return "Even" }
        return String(format: "%@ +%.1f°", value > 0 ? "Left" : "Right", abs(value))
    }

    static func points(_ value: Double) -> String {
        if abs(value) < 0.5 { return "Even" }
        return String(format: "%@ +%.0f pts", value > 0 ? "Left" : "Right", abs(value))
    }
}

enum DurationFormat {
    /// `4:52` for hours and minutes, `18m` below an hour.
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return String(format: "%d:%02d", hours, minutes) }
        return "\(minutes)m"
    }

    /// `4h 52m`, for standalone metric tiles.
    static func long(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return "\(hours)h \(minutes)m" }
        return "\(minutes)m"
    }
}
