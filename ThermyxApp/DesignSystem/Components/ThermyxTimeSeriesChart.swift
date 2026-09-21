import Charts
import SwiftUI

/// One point on a Thermyx time series.
struct SeriesPoint: Identifiable, Equatable {
    let date: Date
    let value: Double
    var id: Date { date }
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
    var showsExtremes: Bool = true
    var showsAverage: Bool = true
    var averageLabel: String = "Average"
    /// Ember-high / ice-cold reads as hot and cold, which is right for
    /// temperature and wrong for everything else — a high gait score is good,
    /// not hot. Non-temperature series pass their own colour instead.
    var highTint: Color = Thermyx.Ink.ember
    var lowTint: Color = Thermyx.Ink.ice

    @State private var scrubDate: Date?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var primary: ChartSeries? { series.first(where: \.isFilled) ?? series.first }

    private var allValues: [Double] {
        series.flatMap(\.values) + (band.map { [$0.lowerBound, $0.upperBound] } ?? [])
    }

    private var domain: ClosedRange<Double> {
        ThermyxChartStyle.domain(for: allValues, minimumSpan: 4)
    }

    private var average: Double? {
        guard showsAverage, let values = primary?.values, !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    private var maxPoint: SeriesPoint? {
        guard showsExtremes else { return nil }
        return primary?.points.max { $0.value < $1.value }
    }

    private var minPoint: SeriesPoint? {
        guard showsExtremes else { return nil }
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
            axisRow
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
                    .foregroundStyle(primary?.color ?? Thermyx.Ink.textPrimary)
                Text(range.scrubFormatter.string(from: scrubbed.date))
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
            } else if let average {
                Text("\(averageLabel) \(format(average))")
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                    .monospacedDigit()
            } else {
                Text("Hold to read a value")
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
                    if item.isFilled {
                        AreaMark(
                            x: .value("Time", point.date),
                            yStart: .value("Base", domain.lowerBound),
                            yEnd: .value(item.name, point.value),
                            series: .value("Series", item.id)
                        )
                        .foregroundStyle(
                            LinearGradient(
                                colors: [item.color.opacity(0.34), item.color.opacity(0)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .interpolationMethod(.monotone)
                    }

                    LineMark(
                        x: .value("Time", point.date),
                        y: .value(item.name, point.value),
                        series: .value("Series", item.id)
                    )
                    .foregroundStyle(item.color)
                    .lineStyle(
                        StrokeStyle(
                            lineWidth: item.isDashed ? 2.2 : ThermyxChartStyle.lineWidth,
                            lineCap: .round,
                            lineJoin: .round,
                            dash: item.isDashed ? [5, 5] : []
                        )
                    )
                    .interpolationMethod(.monotone)
                }
            }

            if let maxPoint {
                extremeMark(maxPoint, tint: highTint, isHigh: true)
            }
            if let minPoint, minPoint.date != maxPoint?.date {
                extremeMark(minPoint, tint: lowTint, isHigh: false)
            }

            if let scrubbed {
                RuleMark(x: .value("Scrub", scrubbed.date))
                    .foregroundStyle(Thermyx.Ink.textPrimary.opacity(0.45))
                    .lineStyle(StrokeStyle(lineWidth: 1))
                PointMark(
                    x: .value("Scrub", scrubbed.date),
                    y: .value("Value", scrubbed.value)
                )
                .foregroundStyle(primary?.color ?? Thermyx.Ink.textPrimary)
                .symbolSize(110)
            }
        }
        .frame(height: height)
        .chartYScale(domain: domain)
        .chartXScale(range: .plotDimension(startPadding: 14, endPadding: 14))
        .chartYAxis {
            AxisMarks(position: .leading) { _ in
                AxisGridLine().foregroundStyle(Thermyx.Ink.hairline)
            }
        }
        .chartXAxis(.hidden)
        .chartLegend(.hidden)
        .chartOverlay { proxy in
            GeometryReader { geometry in
                Rectangle()
                    .fill(.clear)
                    .contentShape(.rect)
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                guard let plot = proxy.plotFrame else { return }
                                let x = value.location.x - geometry[plot].minX
                                scrubDate = proxy.value(atX: x, as: Date.self)
                            }
                            .onEnded { _ in scrubDate = nil }
                    )
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(primary?.name ?? "Chart")
        .accessibilityValue(accessibilitySummary)
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

    private var axisRow: some View {
        ChartAxisRow(labels: axisLabels)
    }

    private var axisLabels: [String] {
        guard let points = primary?.points, let first = points.first?.date, let last = points.last?.date else { return [] }
        let formatter = range.axisFormatter
        let count = 4
        let span = last.timeIntervalSince(first)
        return (0..<count).map { index in
            formatter.string(from: first.addingTimeInterval(span * Double(index) / Double(count - 1)))
        }
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
