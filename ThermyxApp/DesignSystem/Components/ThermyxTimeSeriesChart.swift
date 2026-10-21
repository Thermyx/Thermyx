import Charts
import SwiftUI

/// One point on a Thermyx time series.
struct SeriesPoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    var id: Date { date }
}

extension SeriesPoint {
    /// Means over fixed windows of time, each at its window's start. Keeps a
    /// day's chart to a few hundred points, so minute-to-minute flicker (the
    /// two insoles regulating a few seconds apart) doesn't read as noise, and
    /// the newest point moves smoothly as it fills instead of jumping as
    /// each minute starts. Windows with no data stay out: no point is made
    /// up for time that wasn't worn.
    static func averaged(_ points: [SeriesPoint], window: TimeInterval) -> [SeriesPoint] {
        guard window > 0, points.count > 2 else { return points }
        var sums: [Double: (total: Double, count: Int)] = [:]
        for point in points {
            let key = (point.date.timeIntervalSince1970 / window).rounded(.down) * window
            let current = sums[key] ?? (0, 0)
            sums[key] = (current.total + point.value, current.count + 1)
        }
        return sums.keys.sorted().map { key in
            let entry = sums[key]!
            return SeriesPoint(date: Date(timeIntervalSince1970: key), value: entry.total / Double(entry.count))
        }
    }
}

extension InsightsRange {
    /// How much time one chart point covers.
    var chartWindow: TimeInterval {
        switch self {
        case .day: return 5 * 60
        case .week: return 30 * 60
        case .month: return 6 * 3600
        }
    }
}

/// A shaded stretch of time behind a chart, e.g. when the insole heated.
struct ChartShade: Identifiable, Equatable {
    let start: Date
    let end: Date
    let color: Color
    var id: Date { start }
}

/// A named series drawn on a shared time axis.
struct ChartSeries: Identifiable, Equatable {
    let id: String
    let name: String
    let points: [SeriesPoint]
    let color: Color
    /// Dashed lines read as reference or secondary data.
    var isDashed: Bool = false
    /// Only the primary series gets a gradient fill beneath it.
    var isFilled: Bool = false
    /// Colours the line by value, so it reads hot where the values are hot.
    /// Without one, the series is drawn in `color`.
    var scale: ChartValueScale?
    /// Set on per-foot series. With both feet on one chart they're drawn in
    /// `Foot.chartColor`, solid and thick, so the two lines stay apart.
    var foot: Foot? = nil

    var values: [Double] { points.map(\.value) }
}

/// The chart used everywhere a value changes over time.
///
/// Three things the plain `Chart` did not give us, and that the screens kept
/// needing separately:
///
/// - **Extremes made findable.** The high and low are marked and labelled, so
///   the question "how bad did it get, and when" is answered by looking rather
///   than by reading a separate stat row.
/// - **An average to read against.** A dashed rule across the mean turns the
///   curve from a shape into a comparison.
/// - **Scrubbing.** Press and drag to read the value at a moment, with the
///   timestamp formatted for the range being viewed — minutes for a day, days
///   for a month.
struct ThermyxTimeSeriesChart: View {
    let series: [ChartSeries]
    var range: InsightsRange = .day
    var height: CGFloat = 180
    /// Formats a value for the scrubber and the extreme labels.
    var format: (Double) -> String = { String(format: "%.1f", $0) }
    /// Drawn behind the plot, e.g. the temperature comfort band.
    var band: ClosedRange<Double>?
    var bandLabel: String?
    /// Time ranges shaded behind the plot.
    var shading: [ChartShade] = []
    var showsExtremes: Bool = true
    var showsAverage: Bool = true
    var averageLabel: String = "Average"
    /// The extremes' marks when the primary series has no value scale.
    /// With one, each mark takes the scale's colour at its value.
    var highTint: Color = Thermyx.Ink.ember
    var lowTint: Color = Thermyx.Ink.ice
    /// The smallest y range drawn, so a nearly flat line isn't blown up
    /// into noise with every axis label rounding to the same number.
    var minimumSpan: Double = 4

    @State private var scrubDate: Date?
    /// Pinch to zoom in on time: 1 shows the whole range.
    @State private var zoom: CGFloat = 1
    @State private var zoomAtStart: CGFloat = 1
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static let maxZoom: CGFloat = 12

    private var primary: ChartSeries? { series.first(where: \.isFilled) ?? series.first }

    /// Both feet on one chart: draw them apart, by colour.
    private var comparesFeet: Bool { Set(series.compactMap(\.foot)).count > 1 }

    private var firstDate: Date? { series.compactMap { $0.points.first?.date }.min() }
    private var lastDate: Date? { series.compactMap { $0.points.last?.date }.max() }
    private var span: TimeInterval {
        guard let firstDate, let lastDate else { return 3600 }
        return max(60, lastDate.timeIntervalSince(firstDate))
    }

    private var allValues: [Double] {
        series.flatMap(\.values) + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
    }

    private var domain: ClosedRange<Double> {
        ThermyxChartStyle.domain(for: allValues, minimumSpan: minimumSpan)
    }

    private var average: Double? {
        guard showsAverage, let values = primary?.values, !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var maxPoint: SeriesPoint? {
        guard showsExtremes, !comparesFeet else { return nil }
        return primary?.points.max { $0.value < $1.value }
    }

    private var minPoint: SeriesPoint? {
        guard showsExtremes, !comparesFeet else { return nil }
        return primary?.points.min { $0.value < $1.value }
    }

    /// The point nearest the finger while scrubbing.
    private var scrubbed: SeriesPoint? {
        guard let scrubDate, let points = primary?.points, !points.isEmpty else { return nil }
        return points.min {
            abs($0.date.timeIntervalSince(scrubDate)) < abs($1.date.timeIntervalSince(scrubDate))
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            scrubReadout
            chart
            if comparesFeet || zoom > 1.01 {
                HStack(spacing: Thermyx.Space.m) {
                    if comparesFeet { FootLegend(feet: Foot.allCases.filter { f in series.contains { $0.foot == f } }) }
                    Spacer(minLength: 0)
                    if zoom > 1.01 {
                        Button("Show all") {
                            withAnimation(SiteMotion.settle) { zoom = 1; zoomAtStart = 1 }
                        }
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(Thermyx.Ink.link)
                        .frame(minHeight: Thermyx.minimumTapTarget)
                    }
                }
            }
        }
    }

    // MARK: - Readout
    //
    // Reserves its own row so the chart does not jump when scrubbing starts.

    private var scrubReadout: some View {
        HStack(spacing: Thermyx.Space.xs) {
            if let scrubbed {
                Text(format(scrubbed.value))
                    .font(ThermyxFont.metricNumeral)
                    .monospacedDigit()
                    .foregroundStyle(tint(scrubbed.value, fallback: primary?.color ?? Thermyx.Ink.textPrimary))
                Text(range.scrubFormatter.string(from: scrubbed.date))
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
            } else if let average {
                Text("\(averageLabel) \(format(average))")
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                    .monospacedDigit()
            } else {
                Text("Hold to read a value · pinch to zoom")
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
            }
            Spacer(minLength: 0)
        }
        .frame(height: 26)
        .animation(reduceMotion ? nil : .easeOut(duration: 0.12), value: scrubbed)
    }

    // MARK: - Plot

    private var chart: some View {
        Chart {
            ForEach(shading) { shade in
                RectangleMark(
                    xStart: .value("Start", shade.start),
                    xEnd: .value("End", shade.end)
                )
                .foregroundStyle(shade.color.opacity(0.18))
            }

            if let band {
                RectangleMark(
                    yStart: .value("Band low", band.lowerBound),
                    yEnd: .value("Band high", band.upperBound)
                )
                .foregroundStyle(Thermyx.Tint.comfortBand)
            }

            if let average {
                RuleMark(y: .value(averageLabel, average))
                    .foregroundStyle(Thermyx.Ink.textSupporting.opacity(0.55))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [5, 4]))
            }

            ForEach(series) { item in
                ForEach(item.points) { point in
                    if item.isFilled, !comparesFeet {
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Base", domain.lowerBound),
                            yEnd: .value(item.name, point.value),
                            series: .value("Series", item.id)
                        )
                        .foregroundStyle(areaStyle(item))
                        .interpolationMethod(.monotone)
                    }

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(item.name, point.value),
                        series: .value("Series", item.id)
                    )
                    .foregroundStyle(lineStyle(item))
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: comparesFeet && item.foot != nil ? 3 : (item.isDashed ? 2.2 : ThermyxChartStyle.lineWidth),
                            lineCap: .round,
                            lineJoin: .round,
                            dash: item.isDashed && !(comparesFeet && item.foot != nil) ? [5, 5] : []
                        )
                    )
                    .interpolationMethod(.monotone)
                }
            }

            if let maxPoint {
                extremeMark(maxPoint, tint: tint(maxPoint.value, fallback: highTint), isHigh: true)
            }
            if let minPoint, minPoint.date != maxPoint?.date {
                extremeMark(minPoint, tint: tint(minPoint.value, fallback: lowTint), isHigh: false)
            }

            if let scrubbed {
                RuleMark(x: .value("Scrub", scrubbed.date))
                    .foregroundStyle(Thermyx.Ink.textPrimary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Scrub", scrubbed.date),
                    y: .value("Value", scrubbed.value)
                )
                .foregroundStyle(tint(scrubbed.value, fallback: primary?.color ?? Thermyx.Ink.textPrimary))
                .symbolSize(110)
            }
        }
        .frame(height: height)
        .chartYScale(domain: domain)
        .chartXScale(range: .plotDimension(startPadding: 8, endPadding: 8))
        .chartYAxis {
            AxisMarks(position: .trailing, values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Thermyx.Ink.hairline)
                AxisValueLabel {
                    if let v = value.as(Double.self) {
                        Text(format(v)).font(ThermyxFont.axisLabel).foregroundStyle(Thermyx.Ink.textFaint)
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .automatic(desiredCount: 4)) { value in
                AxisGridLine().foregroundStyle(Thermyx.Ink.hairline.opacity(0.6))
                AxisValueLabel {
                    if let date = value.as(Date.self) {
                        Text(axisLabel(date)).font(ThermyxFont.axisLabel).foregroundStyle(Thermyx.Ink.textFaint)
                    }
                }
            }
        }
        .chartLegend(.hidden)
        // Apple's own selection: hold to read a value (it waits for a hold
        // when the chart scrolls, so scrolling and reading don't fight).
        .chartXSelection(value: $scrubDate)
        .chartScrollableAxes(zoom > 1.01 ? .horizontal : [])
        .chartXVisibleDomain(length: span / Double(zoom))
        .chartScrollPosition(initialX: lastDate ?? .now)
        .simultaneousGesture(
            MagnifyGesture()
                .onChanged { value in zoom = min(Self.maxZoom, max(1, zoomAtStart * value.magnification)) }
                .onEnded { _ in zoomAtStart = zoom }
        )
        .accessibilityZoomAction { action in
            zoom = min(Self.maxZoom, max(1, action.direction == .zoomIn ? zoom * 2 : zoom / 2))
            zoomAtStart = zoom
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(primary?.name ?? "Chart")
        .accessibilityValue(accessibilitySummary)
    }

    // MARK: - Colour

    /// The primary series' colour at `value`.
    private func tint(_ value: Double, fallback: Color) -> Color {
        primary?.scale?.color(at: value) ?? fallback
    }

    /// The line: the value scale stretched over the series' own range, so
    /// every point sits on its colour.
    private func lineStyle(_ item: ChartSeries) -> AnyShapeStyle {
        if comparesFeet, let foot = item.foot { return AnyShapeStyle(foot.chartColor) }
        guard let scale = item.scale, let low = item.values.min(), let high = item.values.max() else {
            return AnyShapeStyle(item.color)
        }
        return AnyShapeStyle(scale.gradient(from: low, to: high))
    }

    /// The fill runs from the floor of the plot to the series' high, fading
    /// out toward the floor.
    private func areaStyle(_ item: ChartSeries) -> AnyShapeStyle {
        guard let scale = item.scale, let high = item.values.max() else {
            return AnyShapeStyle(LinearGradient(colors: [item.color.opacity(0.34), item.color.opacity(0)],
                                                startPoint: .top, endPoint: .bottom))
        }
        return AnyShapeStyle(scale.gradient(from: domain.lowerBound, to: high) { t in 0.02 + 0.34 * t * t })
    }

    @ChartContentBuilder
    private func extremeMark(_ point: SeriesPoint, tint: Color, isHigh: Bool) -> some ChartContent {
        PointMark(
            x: .value("Time", point.date),
            y: .value(isHigh ? "High" : "Low", point.value)
        )
        .foregroundStyle(tint)
        .symbolSize(70)
        .annotation(position: isHigh ? .top : .bottom, spacing: 3) {
            Text(format(point.value))
                .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: tint)
                .monospacedDigit()
        }
    }

    /// Axis labels at the resolution the zoom shows: hours on a day, and
    /// finer as it zooms in.
    private func axisLabel(_ date: Date) -> String {
        let visible = span / Double(zoom)
        if visible <= 3 * 3600 { return date.formatted(.dateTime.hour().minute()) }
        if visible <= 36 * 3600 { return date.formatted(.dateTime.hour()) }
        if visible <= 10 * 86_400 { return date.formatted(.dateTime.weekday(.abbreviated)) }
        return date.formatted(.dateTime.day().month(.abbreviated))
    }

    private var accessibilitySummary: String {
        var parts: [String] = []
        if let average { parts.append("average \(format(average))") }
        if let maxPoint { parts.append("high \(format(maxPoint.value)) at \(range.scrubFormatter.string(from: maxPoint.date))") }
        if let minPoint { parts.append("low \(format(minPoint.value)) at \(range.scrubFormatter.string(from: minPoint.date))") }
        return parts.isEmpty ? "No data" : parts.joined(separator: ", ")
    }
}

extension InsightsRange {
    /// Timestamp granularity while scrubbing: a day is read to the minute, a
    /// month to the day. Reading "14:03" on a month chart would be a lie about
    /// the resolution of an hourly bucket.
    var scrubFormatter: DateFormatter {
        let formatter = DateFormatter()
        switch self {
        case .day: formatter.dateFormat = "HH:mm"
        case .week: formatter.dateFormat = "EEE HH:mm"
        case .month: formatter.dateFormat = "d MMM"
        }
        return formatter
    }

    var axisFormatter: DateFormatter {
        let formatter = DateFormatter()
        switch self {
        case .day: formatter.dateFormat = "HH:mm"
        case .week: formatter.dateFormat = "EEE"
        case .month: formatter.dateFormat = "d MMM"
        }
        return formatter
    }
}
