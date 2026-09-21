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
            style: settings.periodStyle,
            samples: viewModel.history.samples(for: settings.insightsRange, style: settings.periodStyle)
        )
    }

    var body: some View {
        ThermyxDetailScreen(
            title: "Left vs right",
            caption: settings.insightsRange.caption(style: settings.periodStyle)
        ) {
            let digest = digest

            if digest.hasBoth {
                summary(digest)
                temperatureCard(digest)
                loadCard(digest)
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
        .hidesThermalControlBar()
    }

    // MARK: - Summary

    private func summary(_ digest: BilateralDigest) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("What the pair shows")
                Text(headline(digest))
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(3)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)

                HStack(spacing: Thermyx.Space.xs) {
                    MetricTile(
                        label: "Mean gap",
                        value: digest.meanTemperatureGapC.map { TemperatureFormat.delta($0, in: unit) },
                        tint: (digest.meanTemperatureGapC ?? 0) > 1.5 ? Thermyx.Ink.amber : Thermyx.Ink.ice,
                        numeralFont: ThermyxFont.metricNumeral
                    )
                    MetricTile(
                        label: "Warmer",
                        value: digest.consistentlyHotterFoot?.label ?? "Neither",
                        tint: digest.consistentlyHotterFoot == nil ? Thermyx.Ink.ice : Thermyx.Ink.amber,
                        numeralFont: ThermyxFont.metricNumeral
                    )
                    MetricTile(
                        label: "Loaded",
                        value: digest.consistentlyLoadedFoot?.label ?? "Even",
                        tint: digest.consistentlyLoadedFoot == nil ? Thermyx.Ink.ice : Thermyx.Ink.amber,
                        numeralFont: ThermyxFont.metricNumeral
                    )
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
            return "You have been carrying more weight on your \(loaded.label.lowercased()) foot. Worth noticing if it persists across shifts."
        case (let hot?, let loaded?) where hot == loaded:
            return "Your \(hot.label.lowercased()) foot is both warmer and carrying more load. Those usually travel together — check the fit on that side."
        case (let hot?, let loaded?):
            return "Your \(hot.label.lowercased()) foot is warmer while your \(loaded.label.lowercased()) carries more load. Worth watching across a few shifts."
        }
    }

    // MARK: - Charts

    private func temperatureCard(_ digest: BilateralDigest) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                SectionLabel("Temperature gap") {
                    Text("Left minus right")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
                }

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "tempGap", name: "Temperature gap",
                            points: digest.temperatureAsymmetry.map {
                                SeriesPoint(date: $0.date, value: unit.convertDelta($0.value))
                            },
                            color: Thermyx.Ink.amber, isFilled: true
                        )
                    ],
                    range: settings.insightsRange,
                    height: 150,
                    format: { String(format: "%+.1f°", $0) },
                    averageLabel: "Mean gap",
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
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                SectionLabel("Load gap") {
                    Text("Left minus right")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textFaint)
                }

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "loadGap", name: "Load gap",
                            points: digest.loadAsymmetry,
                            color: Thermyx.Ink.signal, isFilled: true
                        )
                    ],
                    range: settings.insightsRange,
                    height: 150,
                    format: { String(format: "%+.0f pts", $0) },
                    averageLabel: "Mean gap",
                    highTint: Thermyx.Ink.signal,
                    lowTint: Thermyx.Ink.signal
                )

                Text("Percentage points of forefoot load. Above the line, the left foot carries more.")
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
        Text("A small, steady difference between feet is normal. What is worth acting on is a gap that grows across a shift, or one that appears alongside a change in how you are walking. Thermyx does not diagnose the cause of an asymmetry.")
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
