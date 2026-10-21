import Charts
import SwiftUI

/// Left against right, over time.
///
/// This screen exists only because Thermyx runs as a pair. A single insole can
/// compare a foot against its own past; two can compare them against each
/// other right now, which is both faster and more specific. Favouring one foot
/// shows up here long before the wearer notices it.
///
/// Every chart is a **difference**, left minus right, so zero is even and the
/// sign says which side. Buckets where only one foot reported are left out —
/// a difference computed against a gap in coverage is not a difference.
struct BalanceDetailView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var digest: BilateralDigest {
        BilateralDigest(
            range: settings.insightsRange,
            style: settings.insightsStyle,
            samples: viewModel.history.samples(for: settings.insightsRange, style: settings.insightsStyle, now: settings.insightsNow)
        )
    }

    var body: some View {
        ThermyxDetailScreen(
            title: "Left vs right",
            caption: settings.insightsCaption
        ) {
            let digest = digest

            if digest.hasBoth {
                summary(digest)
                temperatureCard(digest)
                loadCard(digest)
                steadinessCard(digest)
                zoneComparison(digest)
                note
            } else {
                ThermyxEmptyState(
                    title: "Both insoles needed",
                    message: "Comparing feet needs readings from both at the same time. Pair the second insole and this fills in as they report together.",
                    systemImage: "shoeprints.fill"
                )
            }
        }
    }

    // MARK: - Summary

    private func summary(_ digest: BilateralDigest) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SectionLabel("What the pair shows")
                Text(headline(digest))
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                Grid(horizontalSpacing: Thermyx.Space.xs, verticalSpacing: Thermyx.Space.m) {
                    GridRow {
                        MetricTile(
                            label: "Average gap",
                            value: digest.meanTemperatureGapC.map { TemperatureFormat.delta($0, in: unit) },
                            tint: (digest.meanTemperatureGapC ?? 0) > 1.5 ? Thermyx.Ink.amber : Thermyx.Ink.textPrimary,
                            numeralFont: ThermyxFont.metricNumeral
                        )
                        MetricTile(
                            label: "Warmer",
                            value: digest.consistentlyHotterFoot?.label ?? "Neither",
                            tint: digest.consistentlyHotterFoot == nil ? Thermyx.Ink.textPrimary : Thermyx.Ink.amber,
                            numeralFont: ThermyxFont.metricNumeral
                        )
                    }
                    GridRow {
                        MetricTile(
                            label: "Leaning on",
                            value: digest.consistentlyLoadedFoot?.label ?? "Even",
                            tint: digest.consistentlyLoadedFoot == nil ? Thermyx.Ink.textPrimary : Thermyx.Ink.amber,
                            numeralFont: ThermyxFont.metricNumeral
                        )
                        MetricTile(
                            label: "Less steady",
                            value: digest.consistentlyUnsteadyFoot?.label ?? "Neither",
                            tint: digest.consistentlyUnsteadyFoot == nil ? Thermyx.Ink.textPrimary : Thermyx.Ink.amber,
                            numeralFont: ThermyxFont.metricNumeral
                        )
                    }
                }
            }
        }
    }

    private func headline(_ digest: BilateralDigest) -> String {
        switch (digest.consistentlyHotterFoot, digest.consistentlyLoadedFoot) {
        case (nil, nil):
            return "Your feet have been tracking each other closely this period. Nothing here needs attention."
        case (let hot?, nil):
            return "Your \(hot.label.lowercased()) foot has run consistently warmer. Check the fit and that the vent on that side is clear."
        case (nil, let loaded?):
            return "You've been putting more weight on your \(loaded.label.lowercased()) foot. Worth noticing if it keeps happening across shifts."
        case (let hot?, let loaded?) where hot == loaded:
            return "Your \(hot.label.lowercased()) foot is both warmer and taking more of your weight. Those often go together, so check the fit on that side."
        case (let hot?, let loaded?):
            return "Your \(hot.label.lowercased()) foot is warmer, while your \(loaded.label.lowercased()) foot takes more of your weight. Worth watching over a few shifts."
        }
    }

    // MARK: - Charts

    private func temperatureCard(_ digest: BilateralDigest) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SectionLabel("Temperature difference")

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "tempGap", name: "Temperature difference",
                            points: digest.temperatureAsymmetry.map {
                                SeriesPoint(date: $0.date, value: unit.convertDelta($0.value))
                            },
                            color: Thermyx.Ink.amber, isFilled: true,
                            scale: .temperatureGap(unit)
                        )
                    ],
                    range: settings.insightsRange,
                    height: 150,
                    format: GapFormat.degrees,
                    averageLabel: "Average",
                    highTint: Thermyx.Ink.ember,
                    lowTint: Thermyx.Ink.ice
                )

                Text("Above the line, the left foot is warmer. Below it, the right.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
        }
    }

    private func loadCard(_ digest: BilateralDigest) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SectionLabel("Pressure difference")

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "loadGap", name: "Pressure difference",
                            points: digest.loadAsymmetry,
                            color: Thermyx.Ink.signal, isFilled: true,
                            scale: .loadGap
                        )
                    ],
                    range: settings.insightsRange,
                    height: 150,
                    format: GapFormat.points,
                    averageLabel: "Average",
                    highTint: Thermyx.Ink.signal,
                    lowTint: Thermyx.Ink.signal,
                    minimumSpan: 10
                )

                Text("Above the line, you're pressing harder on your left foot. Below it, your right.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func steadinessCard(_ digest: BilateralDigest) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SectionLabel("Steadiness difference")

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "steadyGap", name: "Steadiness difference",
                            points: digest.steadinessAsymmetry,
                            color: Thermyx.Ink.ice, isFilled: true,
                            scale: .loadGap
                        )
                    ],
                    range: settings.insightsRange,
                    height: 150,
                    format: GapFormat.points,
                    averageLabel: "Average",
                    highTint: Thermyx.Ink.ice,
                    lowTint: Thermyx.Ink.ice,
                    minimumSpan: 10
                )

                Text("Above the line, your left foot steps more steadily. Below it, your right. A limp shows up here as a gap that holds for minutes.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// Side-by-side zone temperatures, so a gap can be traced to a region of
    /// the foot rather than left as a single number.
    @ViewBuilder
    private func zoneComparison(_ digest: BilateralDigest) -> some View {
        let rows = FootZone.allCases.compactMap { zone -> (FootZone, Double, Double)? in
            guard let l = digest[.left]?.samples.compactMap({ $0.zones?[zone] }).average,
                  let r = digest[.right]?.samples.compactMap({ $0.zones?[zone] }).average
            else { return nil }
            return (zone, l, r)
        }

        if !rows.isEmpty {
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    SectionLabel("By zone")
                    ForEach(rows, id: \.0) { zone, left, right in
                        zoneRow(zone, left: left, right: right)
                    }
                }
            }
        }
    }

    private func zoneRow(_ zone: FootZone, left: Double, right: Double) -> some View {
        let gap = left - right
        return HStack(spacing: Thermyx.Space.m) {
            Text(zone.label)
                .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                .frame(width: 76, alignment: .leading)

            Text(TemperatureFormat.degrees(left, in: unit))
                .font(ThermyxFont.rowNumeral)
                .monospacedDigit()
                .foregroundStyle(ThermyxTemperatureScale.tint(for: left))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(TemperatureFormat.degrees(right, in: unit))
                .font(ThermyxFont.rowNumeral)
                .monospacedDigit()
                .foregroundStyle(ThermyxTemperatureScale.tint(for: right))
                .frame(maxWidth: .infinity, alignment: .leading)

            Text(String(format: "%+.1f°", unit.convertDelta(gap)))
                .font(ThermyxFont.rowNumeral)
                .monospacedDigit()
                .foregroundStyle(abs(gap) > 1.5 ? Thermyx.Ink.amber : Thermyx.Ink.textSupporting)
                .frame(width: 66, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(zone.label)
        .accessibilityValue("Left \(TemperatureFormat.full(left, in: unit)), right \(TemperatureFormat.full(right, in: unit))")
    }

    private var note: some View {
        Text("Almost everyone favours one side a little, and that's normal. What's worth a look is a difference that grows over a shift, or one that shows up with a change in how you walk. Thermyx can point it out, but it can't tell you why it's happening.")
            .font(ThermyxFont.captionSmall)
            .foregroundStyle(Thermyx.Ink.textFaint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

extension Collection where Element == Double {
    var average: Double? {
        isEmpty ? nil : reduce(0, +) / Double(count)
    }
}
