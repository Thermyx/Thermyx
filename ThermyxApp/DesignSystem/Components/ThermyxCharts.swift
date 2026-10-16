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

// MARK: - Colour by value

// `ChartValueScale` itself (stops, colour at a value, gradients) lives in
// Shared/ThermyxScales.swift so the widgets colour their charts the same way.
extension ChartValueScale {
    /// Foot temperature: the maps' thermal ramp, 28–38 °C, in `unit`.
    static func footTemperature(_ unit: TemperatureUnit) -> ChartValueScale {
        let span = FootScale.thermalRangeC
        return ChartValueScale(FootScale.thermal.map { position, rgb in
            (unit.convert(span.lowerBound + position * (span.upperBound - span.lowerBound)), rgb)
        })
    }

    /// Air temperature runs far wider than skin: freezing to a heat wave.
    static func air(_ unit: TemperatureUnit) -> ChartValueScale {
        ChartValueScale([(0, deep), (12, signal), (21, ice), (28, peach), (33, amber), (40, ember)]
            .map { (unit.convert($0.0), $0.1) })
    }

    /// A left-minus-right temperature gap. Even reads ice; a gap either way
    /// warms through amber to ember, the way the risk rules read it.
    static func temperatureGap(_ unit: TemperatureUnit) -> ChartValueScale {
        let k = unit.convertDelta(1)
        return ChartValueScale([(-3, ember), (-1.5, amber), (-0.4, ice), (0.4, ice), (1.5, amber), (3, ember)]
            .map { ($0.0 * k, $0.1) })
    }

    /// Load, 0–100 %: the pressure maps' clinical ramp.
    static let load = ChartValueScale(stride(from: 0.0, through: 100, by: 12.5).map { ($0, FootScale.jet($0 / 100)) })

    /// A left-minus-right load gap in points: the pressure ramp by size,
    /// blue when even, red when one foot carries far more.
    static let loadGap: ChartValueScale = {
        let magnitudes = stride(from: 0.0, through: 30, by: 5).map { m in (m, FootScale.jet(0.12 + 0.88 * m / 30)) }
        return ChartValueScale(magnitudes.map { (-$0.0, $0.1) } + magnitudes.dropFirst())
    }()

    /// Steps per minute: still, walking, brisk.
    static let cadence = ChartValueScale([(0, deep), (50, signal), (100, ice), (140, peach), (170, amber)])

    /// A share of time, 0–100 %, where more is neither good nor bad.
    static let share = ChartValueScale([(0, deep), (50, signal), (100, ice)])

    /// A rate or an accumulated change, either way from zero: cooling reads
    /// blue, holding reads grey, warming reads amber to ember. `unitSize` is
    /// how big a change counts as large (1 °C, or 1 °C a minute).
    static func change(unitSize: Double = 1) -> ChartValueScale {
        let still: FootScale.RGB = (161, 168, 179)
        return ChartValueScale([(-1, signal), (-0.25, ice), (0, still), (0.25, amber), (1, ember)]
            .map { ($0.0 * unitSize, $0.1) })
    }

    /// Low to high across a range with no meaning of its own (a raw sensor
    /// trace): the cool end of the ramp to the warm end.
    static func intensity(over range: ClosedRange<Double>) -> ChartValueScale {
        let span = max(range.upperBound - range.lowerBound, .ulpOfOne)
        return ChartValueScale([(0, signal), (0.4, ice), (0.75, peach), (1, amber)]
            .map { (range.lowerBound + $0.0 * span, $0.1) })
    }
}

/// The colour key under a chart coloured by value: a thin gradient bar
/// between its two end labels.
struct ChartScaleKey: View {
    let scale: ChartValueScale
    let low: Double
    let high: Double
    let lowLabel: String
    let highLabel: String

    var body: some View {
        HStack(spacing: Thermyx.Space.xs) {
            Text(lowLabel)
            Capsule()
                .fill(scale.horizontal(from: low, to: high))
                .frame(width: 64, height: 4)
            Text(highLabel)
        }
        .font(ThermyxFont.monoSmall)
        .foregroundStyle(Thermyx.Ink.textMuted)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Colour shows the value, from \(lowLabel) to \(highLabel)")
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
    /// A swatch for a fill or a band; a short stroke for a line, dashed for
    /// the dashed series.
    enum Glyph { case swatch, line, dashed }

    let fill: AnyShapeStyle
    let label: String
    var glyph: Glyph = .swatch

    init(color: Color, label: String, glyph: Glyph = .swatch) {
        self.fill = AnyShapeStyle(color)
        self.label = label
        self.glyph = glyph
    }

    /// A chip for a series coloured by value: its stroke shows the ramp.
    init(scale: ChartValueScale, over range: ClosedRange<Double>, label: String, glyph: Glyph = .line) {
        self.fill = AnyShapeStyle(scale.horizontal(from: range.lowerBound, to: range.upperBound))
        self.label = label
        self.glyph = glyph
    }

    var body: some View {
        HStack(spacing: 6) {
            switch glyph {
            case .swatch:
                RoundedRectangle(cornerRadius: 2, style: .continuous)
                    .fill(fill)
                    .frame(width: 8, height: 8)
            case .line:
                Capsule().fill(fill).frame(width: 16, height: 3)
            case .dashed:
                HStack(spacing: 2) {
                    ForEach(0..<3, id: \.self) { _ in Capsule().frame(width: 4, height: 3) }
                }
                .foregroundStyle(fill)
                .frame(width: 16)
            }
            Text(label)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Heat exposure bars

/// Heat exposure over time: a bar per hour (Day) or per day (Week, Month),
/// as tall as the hottest the foot got and coloured by it on the thermal
/// ramp, against a dashed 38° "elevated" line. Hold and drag to read a bar.
struct HeatExposureBars: View {
    let bars: [ExposureBar]
    let range: InsightsRange
    let unit: TemperatureUnit
    var height: CGFloat = 150

    @State private var selected: ExposureBar?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let elevatedC = 38.0
    private var component: Calendar.Component { range == .day ? .hour : .day }
    private var scale: ChartValueScale { .footTemperature(unit) }

    /// From a little under the coolest peak (never above the comfort band's
    /// bottom) to just over the elevated line or the hottest peak.
    private var domain: ClosedRange<Double> {
        let peaks = bars.map { unit.convert($0.peakC) }
        let low = min(unit.convert(ThermyxTemperatureScale.cool), (peaks.min() ?? 0) - unit.convertDelta(1))
        let high = max(unit.convert(Self.elevatedC + 0.6), (peaks.max() ?? 0) + unit.convertDelta(0.5))
        return low.rounded(.down)...high.rounded(.up)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            readout
            chart
        }
    }

    private var readout: some View {
        HStack(spacing: Thermyx.Space.xs) {
            if let bar = selected ?? bars.max(by: { $0.peakC < $1.peakC }) {
                Text(TemperatureFormat.degrees(bar.peakC, in: unit))
                    .font(ThermyxFont.metricNumeral)
                    .monospacedDigit()
                    .foregroundStyle(FootScale.thermalColor(bar.peakC))
                Text(selected == nil ? "Peak · \(label(bar))" : "\(label(bar)) · \(DurationFormat.long(bar.hotSeconds)) above comfort")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
            } else {
                Text("Bars appear as you wear the insoles")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: selected)
    }

    private var chart: some View {
        let floor = domain.lowerBound
        return Chart {
            ForEach(bars) { bar in
                let peak = unit.convert(bar.peakC)
                BarMark(
                    x: .value("Time", bar.start, unit: component),
                    yStart: .value("Floor", floor),
                    yEnd: .value("Peak", peak),
                    width: .ratio(0.72)
                )
                .foregroundStyle(scale.gradient(from: floor, to: peak))
                .cornerRadius(3)
                .opacity(selected == nil || selected == bar ? 1 : 0.35)
            }
            RuleMark(y: .value("Elevated", unit.convert(Self.elevatedC)))
                .foregroundStyle(Thermyx.Ink.ember.opacity(0.75))
                .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                .annotation(position: .top, alignment: .leading, spacing: 2) {
                    Text("Elevated \(TemperatureFormat.degrees(Self.elevatedC, in: unit, decimals: 0))")
                        .font(ThermyxFont.monoSmall)
                        .foregroundStyle(Thermyx.Ink.ember)
                }
        }
        .chartYScale(domain: domain)
        .chartXAxis {
            AxisMarks(values: .stride(by: component, count: xStride)) { value in
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisText(date))
                            .font(ThermyxFont.axisLabel)
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }
                }
            }
        }
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                AxisGridLine().foregroundStyle(Thermyx.Ink.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text("\(Int(v.rounded()))°").font(ThermyxFont.axisLabel).foregroundStyle(Thermyx.Ink.textFaint)
                    }
                }
            }
        }
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plot = proxy.plotFrame,
                                      let date: Date = proxy.value(atX: value.location.x - geometry[plot].minX) else { return }
                                selected = bars.min { abs($0.start.timeIntervalSince(date)) < abs($1.start.timeIntervalSince(date)) }
                            }
                            .onEnded { _ in selected = nil }
                    )
            }
        }
        .frame(height: height)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Heat exposure")
        .accessibilityValue(accessibilitySummary)
    }

    private var xStride: Int {
        switch range {
        case .day: return 3
        case .week: return 1
        case .month: return 7
        }
    }

    private func label(_ bar: ExposureBar) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = range == .day ? "HH:00" : (range == .week ? "EEEE" : "d MMM")
        return formatter.string(from: bar.start)
    }

    private func axisText(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = range == .day ? "HH" : (range == .week ? "EEEEE" : "d")
        return formatter.string(from: date)
    }

    private var accessibilitySummary: String {
        guard let peak = bars.max(by: { $0.peakC < $1.peakC }) else { return "No data yet" }
        let over = bars.filter { $0.peakC >= Self.elevatedC }.count
        return "Hottest \(TemperatureFormat.full(peak.peakC, in: unit)) at \(label(peak)). \(over) of \(bars.count) reached the elevated line."
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

/// The labelled pressure-distribution bars. With a value scale, the bar
/// fills along it, so a heavier share reads warmer, as on the pressure map.
struct LabeledProgressBar: View {
    let label: String
    /// 0...1
    let value: Double
    let tint: Color
    var scale: ChartValueScale?

    private var fill: AnyShapeStyle {
        guard let scale else { return AnyShapeStyle(tint) }
        return AnyShapeStyle(scale.horizontal(from: 0, to: max(value, 0.001) * 100))
    }

    private var valueTint: Color { scale?.color(at: value * 100) ?? tint }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack {
                Text(label)
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                Spacer()
                Text("\(Int((value * 100).rounded()))%")
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: valueTint)
                    .monospacedDigit()
            }
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Thermyx.Tint.track)
                    Capsule()
                        .fill(fill)
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
