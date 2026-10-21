import Charts
import SwiftUI

struct TemperatureDetailView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    var footFilter: FootFilter = .both

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var digest: BilateralDigest {
        BilateralDigest(
            range: settings.insightsRange,
            style: settings.insightsStyle,
            samples: viewModel.history.samples(for: settings.insightsRange, style: settings.insightsStyle, now: settings.insightsNow)
        )
    }
    private var pairs: [(Foot, InsightsDigest)] { digest.digests(for: footFilter) }

    var body: some View {
        ThermyxDetailScreen(
            title: "Temperature",
            caption: settings.insightsCaption
        ) {
            let digest = digest

            if digest.hasAny {
                ForEach(pairs, id: \.0) { foot, footDigest in
                    if pairs.count > 1 {
                        SectionLabel("\(foot.label) foot")
                            .padding(.top, Thermyx.Space.xs)
                    }
                    statRow(footDigest)
                    chartCard(footDigest, foot: foot)
                    if let series = footDigest.zoneSeries() {
                        ZoneHeatMap(
                            series: series,
                            columnLabels: footDigest.columnLabels(),
                            unit: unit,
                            title: pairs.count > 1 ? "\(foot.label) zones · by hour" : "Zone heat map · by hour"
                        )
                    }
                    timeInZone(footDigest)
                }
                events
            } else {
                ThermyxEmptyState(
                    title: "No temperature history yet",
                    message: "Readings are retained as they arrive. Once there are a few minutes of them, the full curve, comfort band, zone map, and time-in-zone split appear here.",
                    systemImage: "thermometer.medium"
                )
            }
        }
    }

    // MARK: - Peak / average / low

    private func statRow(_ digest: InsightsDigest) -> some View {
        HStack(alignment: .bottom, spacing: Thermyx.Space.xl) {
            stat("Peak", digest.peakC, tint: Thermyx.Ink.ember)
            stat("Average", digest.averageC, tint: Thermyx.Ink.textPrimary)
            stat("Low", digest.lowC, tint: Thermyx.Ink.ice)
            Spacer(minLength: 0)
        }
    }

    private func stat(_ label: String, _ celsius: Double?, tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .narrowLabel(ThermyxFont.zoneLabel, tracking: 1.8, color: Thermyx.Ink.textSupporting)
            Text(celsius.map { TemperatureFormat.degrees($0, in: unit) } ?? "—")
                .font(ThermyxFont.statNumeral)
                .tracking(ThermyxTracking.statNumeral)
                .monospacedDigit()
                .foregroundStyle(celsius == nil ? Thermyx.Ink.textFaint : tint)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(celsius.map { TemperatureFormat.full($0, in: unit) } ?? "No reading")
    }

    /// The comfort range expressed in the unit currently on screen.
    private var comfortBand: ClosedRange<Double> {
        let low = unit.convert(ThermyxTemperatureScale.comfortRange.lowerBound)
        let high = unit.convert(ThermyxTemperatureScale.comfortRange.upperBound)
        return low...high
    }

    // MARK: - Curve

    private func chartCard(_ digest: InsightsDigest, foot: Foot) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SectionLabel("\(foot.label) foot temperature") {
                    Text("Touch and hold to read")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
                }

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "foot-\(foot.rawValue)", name: "\(foot.label) foot temperature",
                            points: digest.points { $0.footMeanC.map(unit.convert) },
                            color: Thermyx.Ink.ember, isFilled: true,
                            scale: .footTemperature(unit)
                        )
                    ],
                    range: settings.insightsRange,
                    height: 190,
                    format: { String(format: "%.1f°", $0) },
                    band: comfortBand,
                    bandLabel: "Comfort band",
                    shading: digest.thermalShading(heat: Thermyx.Ink.ember, cool: Thermyx.Ink.signal)
                )

                FlowRow(spacing: Thermyx.Space.m) {
                    ChartLegendChip(color: Thermyx.Ink.ember.opacity(0.4), label: "Heating")
                    ChartLegendChip(color: Thermyx.Ink.signal.opacity(0.4), label: "Cooling")
                    ChartLegendChip(color: Thermyx.Tint.comfortKey, label: "Comfort band")
                }
                ChartScaleKey(
                    scale: .footTemperature(unit),
                    low: unit.convert(FootScale.thermalRangeC.lowerBound),
                    high: unit.convert(FootScale.thermalRangeC.upperBound),
                    lowLabel: TemperatureFormat.degrees(FootScale.thermalRangeC.lowerBound, in: unit, decimals: 0),
                    highLabel: TemperatureFormat.degrees(FootScale.thermalRangeC.upperBound, in: unit, decimals: 0)
                )
            }
        }
    }

    // MARK: - Time in zone

    private func timeInZone(_ digest: InsightsDigest) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Time in zone")
            TimeInZoneBar(seconds: digest.timeInZone)
        }
    }

    // MARK: - Events

    @ViewBuilder
    private var events: some View {
        let recorded = viewModel.history.events(for: settings.insightsRange, style: settings.insightsStyle, foot: footFilter.foot, now: settings.insightsNow)
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Events")
            if recorded.isEmpty {
                ThermyxEmptyState(
                    title: "No escalations recorded",
                    message: "Nothing has crossed into caution or above during this period.",
                    systemImage: "checkmark.shield"
                )
            } else {
                ForEach(recorded) { event in
                    EventRow(event: event, unit: unit, showsFoot: footFilter == .both)
                }
            }
        }
    }
}

struct EventRow: View {
    let event: ThermyxRiskEvent
    let unit: TemperatureUnit
    var showsFoot: Bool = false

    private var tint: Color { event.riskLevel?.tint ?? Thermyx.Ink.textFaint }

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Circle().fill(tint).frame(width: 8, height: 8)

            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(ThermyxFont.rowTitleRegular)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(subtitle)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
            }

            Spacer(minLength: Thermyx.Space.xs)

            if let temperature = event.footTemperatureC {
                Text(TemperatureFormat.degrees(temperature, in: unit))
                    .font(ThermyxFont.rowNumeral)
                    .monospacedDigit()
                    .foregroundStyle(tint)
            }
        }
        .padding(.horizontal, Thermyx.Space.l)
        .padding(.vertical, 13)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous)
                .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    private var title: String {
        let level = event.riskLevel?.rawValue ?? "Event"
        guard let reason = event.reasons.first else { return level }
        return "\(level) · \(reason.replacingOccurrences(of: ".", with: "").lowercased())"
    }

    private var subtitle: String {
        var parts: [String] = []
        if showsFoot { parts.append("\(event.foot.label) foot") }
        parts.append(event.timestamp.formatted(date: .omitted, time: .shortened))
        if let duration = event.duration, duration >= 60 {
            parts.append("held \(DurationFormat.long(duration))")
        }
        return parts.joined(separator: " · ")
    }
}
