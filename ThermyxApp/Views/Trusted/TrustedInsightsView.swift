import Charts
import SwiftUI

/// What the watcher gets beyond "is she okay right now".
///
/// A trusted member is usually the person who will act, so they get the same
/// depth the wearer has — the zone map, the temperature curve, the gait trend —
/// rather than three summary rows. The difference is framing: this is written
/// about someone else, in the third person, with no controls.
struct TrustedInsightsView: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var member: TrustedMemberViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var name: String { roles.watchedUserName }

    private var bilateral: BilateralDigest {
        BilateralDigest(range: .day, style: .rolling, samples: member.displayedHistory)
    }

    /// Aggregate view used for the shift summary and the risk bars, where a
    /// single series is what the watcher needs.
    private var digest: InsightsDigest {
        InsightsDigest(range: .day, style: .rolling,
                       samples: member.displayedHistory.filter { $0.foot == .left })
    }

    private var hasData: Bool { bilateral.hasAny }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                    titleBlock

                    if hasData {
                        summaryCard
                        riskChart
                        temperatureCard
                        if bilateral.hasBoth { balanceCard }
                        ForEach(bilateral.feet, id: \.self) { foot in
                            if let footDigest = bilateral[foot], let series = footDigest.zoneSeries() {
                                ZoneHeatMap(
                                    series: series,
                                    columnLabels: footDigest.columnLabels(),
                                    unit: unit,
                                    title: bilateral.hasBoth ? "\(foot.label) zones · by hour" : "Zone heat map · by hour"
                                )
                            }
                        }
                        movementCard
                        signalRows
                        eventsCard
                    } else {
                        ThermyxEmptyState(
                            title: "No shared data yet",
                            message: "Charts appear here once \(name)'s insole is connected and sending status to the shared backend.",
                            systemImage: "chart.xyaxis.line"
                        )
                        samplePrompt
                    }
                }
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.bottom, Thermyx.Space.xxl)
            }
            .scrollIndicators(.hidden)
            .background(Thermyx.Ink.midnight)
            .thermyxTopScrim()
            .trustedSampleBanner(member: member, watchedName: name)
        }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Shared insights")
                .font(ThermyxFont.screenTitle)
                .tracking(ThermyxTracking.screenTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Text(member.isShowingSample ? "A worked example of a shift" : "Live signals from \(name)'s insole")
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textSupporting)
        }
        .padding(.top, Thermyx.Space.m)
    }

    private var samplePrompt: some View {
        ThermyxCard(fill: Thermyx.Tint.signalFill, border: Thermyx.Tint.signalBorder) {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("Learn the charts", color: Thermyx.Ink.ice)
                Text("Walk through a worked example so you know what a rising trend and a caution event look like before you need to read one quickly.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Show me a sample shift") {
                    withAnimation { member.isShowingSample = true }
                }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Summary

    private var summaryCard: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("The shift so far")
                Text(summaryText)
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Thermyx.Space.xs) {
                    MetricTile(
                        label: "Peak foot",
                        value: digest.peakC.map { TemperatureFormat.degrees($0, in: unit) },
                        tint: Thermyx.Ink.ember,
                        numeralFont: ThermyxFont.metricNumeral
                    )
                    MetricTile(
                        label: "Above comfort",
                        value: DurationFormat.long(digest.heatExposureSeconds),
                        numeralFont: ThermyxFont.metricNumeral
                    )
                    MetricTile(
                        label: "Escalations",
                        value: "\(member.displayedEvents.count)",
                        tint: member.displayedEvents.isEmpty ? Thermyx.Ink.ice : Thermyx.Ink.amber,
                        numeralFont: ThermyxFont.metricNumeral
                    )
                }
            }
        }
    }

    private var summaryText: String {
        let exposure = DurationFormat.long(digest.heatExposureSeconds)
        let count = member.displayedEvents.count
        if count == 0 {
            return "\(name) has spent \(exposure) above their comfort band and nothing has escalated."
        }
        return "\(name) has spent \(exposure) above their comfort band, with \(count) escalation\(count == 1 ? "" : "s")."
    }

    // MARK: - Charts

    private var riskChart: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("Risk over the shift") {
                    Text(escalationSummary)
                        .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel,
                                     color: member.displayedEvents.isEmpty ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                }

                // A ratio width needs a declared domain; without one the
                // marks collapse to nothing. The x axis is categorical here.
                Chart(riskBars) { bar in
                    BarMark(
                        x: .value("Point", String(bar.index)),
                        y: .value("Severity", bar.severity),
                        width: .ratio(0.62)
                    )
                    .foregroundStyle(bar.color)
                    .cornerRadius(4)
                }
                .frame(height: 96)
                .chartXScale(domain: riskBars.map { String($0.index) })
                .chartXAxis(.hidden)
                .chartYAxis(.hidden)
                .chartYScale(domain: 0...4)
                .chartLegend(.hidden)

                ChartAxisRow(labels: digest.axisLabels(count: 3))
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Risk over the shift")
        .accessibilityValue(escalationSummary)
    }

    private struct RiskBar: Identifiable {
        let index: Int
        let severity: Int
        let color: Color
        var id: Int { index }
    }

    /// Twelve buckets across the window, each coloured by the worst risk in it.
    private var riskBars: [RiskBar] {
        let samples = digest.samples
        guard !samples.isEmpty else { return [] }
        let columns = 12
        let chunk = Double(samples.count) / Double(columns)
        return (0..<columns).compactMap { column in
            let start = Int(Double(column) * chunk)
            let end = max(start + 1, Int(Double(column + 1) * chunk))
            let slice = samples[start..<min(end, samples.count)]
            let worst = slice.compactMap(\.peakRiskLevel).max { $0.severity < $1.severity } ?? .normal
            return RiskBar(index: column, severity: max(1, worst.severity + 1), color: barColor(for: worst))
        }
    }

    private func barColor(for level: ThermyxRiskLevel) -> Color {
        switch level {
        case .normal: return Thermyx.Ink.signal
        case .caution: return Thermyx.Ink.amber
        case .high, .critical: return Thermyx.Ink.ember
        case .unavailable: return Thermyx.Ink.textFaint
        }
    }

    private var escalationSummary: String {
        let count = member.displayedEvents.count
        return count == 0 ? "No escalations" : "\(count) escalation\(count == 1 ? "" : "s")"
    }

    private var temperatureCard: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                SectionLabel("Foot vs ambient") {
                    Text("Hold to scrub")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
                }

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "foot", name: "Foot",
                            points: digest.points { $0.footMeanC.map(unit.convert) },
                            color: Thermyx.Ink.ember, isFilled: true
                        ),
                        ChartSeries(
                            id: "ambient", name: "Ambient",
                            points: digest.points { $0.ambientMeanC.map(unit.convert) },
                            color: Thermyx.Ink.signal, isDashed: true
                        )
                    ],
                    range: .day,
                    height: 160,
                    format: { String(format: "%.1f°", $0) },
                    band: comfortBand,
                    bandLabel: "Comfort band"
                )

                FlowRow(spacing: Thermyx.Space.m) {
                    ChartLegendChip(color: Thermyx.Ink.ember, label: "Foot")
                    ChartLegendChip(color: Thermyx.Ink.signal, label: "Ambient")
                    ChartLegendChip(color: Color(hex: 0x2C9CF0, opacity: 0.5), label: "Comfort")
                    if bilateral.hasBoth { FootLegend(feet: bilateral.feet, tint: Thermyx.Ink.ember) }
                }
            }
        }
    }

    private var comfortBand: ClosedRange<Double> {
        let low = unit.convert(ThermyxTemperatureScale.comfortRange.lowerBound)
        let high = unit.convert(ThermyxTemperatureScale.comfortRange.upperBound)
        return low...high
    }

    private var movementCard: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                SectionLabel("Movement stability")

                ThermyxTimeSeriesChart(
                    series: bilateral.feet.compactMap { foot in
                        bilateral[foot].map { footDigest in
                            ChartSeries(
                                id: "gait-\(foot.rawValue)", name: "\(foot.label) stability",
                                points: footDigest.points { $0.gaitMean.map { $0 * 100 } },
                                color: Thermyx.Ink.ice,
                                isDashed: foot.isDashedInCharts,
                                isFilled: !bilateral.hasBoth
                            )
                        }
                    },
                    range: .day,
                    height: 140,
                    format: { "\(Int($0.rounded()))%" },
                    averageLabel: "Baseline",
                    highTint: Thermyx.Ink.ice,
                    lowTint: Thermyx.Ink.amber
                )

                if bilateral.hasBoth { FootLegend(feet: bilateral.feet, tint: Thermyx.Ink.ice) }

                Text("A sustained drop against their own baseline is the signal worth acting on, not a single dip.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The watcher's version of the balance view: what the difference between
    /// feet is, stated plainly, because they will be the one to mention it.
    private var balanceCard: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                SectionLabel("Left vs right") {
                    if let gap = bilateral.meanTemperatureGapC {
                        Text("\(TemperatureFormat.delta(gap, in: unit)) average gap")
                            .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel,
                                         color: gap > 1.5 ? Thermyx.Ink.amber : Thermyx.Ink.ice)
                    }
                }

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "gap", name: "Temperature gap",
                            points: bilateral.temperatureAsymmetry.map {
                                SeriesPoint(date: $0.date, value: unit.convertDelta($0.value))
                            },
                            color: Thermyx.Ink.amber, isFilled: true
                        )
                    ],
                    range: .day,
                    height: 120,
                    format: GapFormat.degrees,
                    showsExtremes: false,
                    averageLabel: "Average",
                    highTint: Thermyx.Ink.amber,
                    lowTint: Thermyx.Ink.amber
                )

                Text(balanceNote)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var balanceNote: String {
        if let hotter = bilateral.consistentlyHotterFoot {
            return "\(name)'s \(hotter.label.lowercased()) foot has run consistently warmer. Worth mentioning when you check in."
        }
        return "Both feet have been tracking each other closely."
    }

    // MARK: - Rows

    private var signalRows: some View {
        VStack(spacing: Thermyx.Space.s) {
            signalRow(
                title: "Cadence",
                detail: "Steps per minute",
                value: bilateral.byFoot.values.compactMap(\.cadenceAverage).average.map { "\(Int($0.rounded()))" },
                tint: Thermyx.Ink.signal
            )
            signalRow(
                title: "Standing",
                detail: "Loaded but not stepping",
                value: bilateral.byFoot.values.compactMap(\.standingSeconds).max().map(DurationFormat.long),
                tint: Thermyx.Ink.textPrimary
            )
            signalRow(
                title: "Pressure balance",
                detail: "Share of load on the forefoot",
                value: digest.balanceLatest.map { "\(Int(($0 * 100).rounded()))%" },
                tint: Thermyx.Ink.amber
            )
        }
    }

    private func signalRow(title: String, detail: String, value: String?, tint: Color) -> some View {
        HStack(spacing: Thermyx.Space.l) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(detail)
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
            }
            Spacer(minLength: Thermyx.Space.xs)
            Text(value ?? "—")
                .font(ThermyxFont.metricNumeral)
                .monospacedDigit()
                .foregroundStyle(value == nil ? Thermyx.Ink.textFaint : tint)
        }
        .padding(Thermyx.Space.xl)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous)
                .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var eventsCard: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            SectionLabel("Escalations")
            if member.displayedEvents.isEmpty {
                ThermyxEmptyState(
                    title: "Nothing escalated",
                    message: "\(name) has stayed in the normal band for this window.",
                    systemImage: "checkmark.shield"
                )
            } else {
                ForEach(member.displayedEvents) { event in
                    EventRow(event: event, unit: unit)
                }
            }
        }
    }
}
