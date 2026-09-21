import Charts
import SwiftUI

/// Every movement channel over time, one chart each.
///
/// The Movement screen answers "how am I moving"; this answers "show me the
/// raw shape of it". Channels the insole did not report are listed as absent
/// rather than omitted silently, so it is clear whether a signal is flat or
/// simply not being measured by this firmware.
struct MovementAdvancedView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    var footFilter: FootFilter = .both

    private var bilateral: BilateralDigest {
        BilateralDigest(
            range: settings.insightsRange,
            style: settings.periodStyle,
            samples: viewModel.history.samples(for: settings.insightsRange, style: settings.periodStyle)
        )
    }
    private var pairs: [(Foot, InsightsDigest)] { bilateral.digests(for: footFilter) }

    var body: some View {
        ThermyxDetailScreen(
            title: "Advanced",
            caption: settings.insightsRange.caption(style: settings.periodStyle)
        ) {
            Text("Every movement channel the insoles reported over this window. Hold any chart to read a value.")
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(pairs, id: \.0) { foot, digest in
                if pairs.count > 1 {
                    SectionLabel("\(foot.label) foot")
                        .padding(.top, Thermyx.Space.xs)
                }
                channel(
                    "Gait stability", unit: "%",
                    points: digest.points { $0.gaitMean.map { $0 * 100 } },
                    color: Thermyx.Ink.ice,
                    format: { "\(Int($0.rounded()))%" },
                    note: "Higher is steadier. Your own rolling baseline, not a population norm."
                )
                channel(
                    "Pressure balance", unit: "%",
                    points: digest.points { $0.balanceMean.map { $0 * 100 } },
                    color: Thermyx.Ink.amber,
                    format: { "\(Int($0.rounded()))%" },
                    note: "Share of load carried on the forefoot. 50% is an even split front to back."
                )
                channel(
                    "Cadence", unit: "spm",
                    points: digest.points(\.cadenceMean),
                    color: Thermyx.Ink.signal,
                    format: { "\(Int($0.rounded())) spm" },
                    note: "Steps per minute from the controller's IMU. Needs firmware protocol v3."
                )
                channel(
                    "Standing", unit: "%",
                    points: digest.points { $0.standingMean.map { $0 * 100 } },
                    color: Thermyx.Ink.textSecondary,
                    format: { "\(Int($0.rounded()))%" },
                    note: "Share of each interval spent loaded but not stepping. Needs firmware protocol v3."
                )
                zoneChannels(digest, foot: foot)
            }

            if pairs.isEmpty {
                ThermyxEmptyState(
                    title: "No history for this window",
                    message: "Connect an insole and these charts fill in as readings arrive.",
                    systemImage: "waveform.path.ecg"
                )
            }
        }
        .hidesThermalControlBar()
    }

    @ViewBuilder
    private func channel(
        _ title: String,
        unit: String,
        points: [SeriesPoint],
        color: Color,
        format: @escaping (Double) -> String,
        note: String
    ) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                SectionLabel(title)

                if points.count >= 3 {
                    ThermyxTimeSeriesChart(
                        series: [ChartSeries(id: "\(title)-\(points.count)", name: title, points: points, color: color, isFilled: true)],
                        range: settings.insightsRange,
                        height: 130,
                        format: format,
                        highTint: color,
                        lowTint: color
                    )
                } else {
                    Text("Not measured by the connected insole.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, Thermyx.Space.m)
                }

                Text(note)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    @ViewBuilder
    private func zoneChannels(_ digest: InsightsDigest, foot: Foot) -> some View {
        if digest.hasZones {
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    SectionLabel(pairs.count > 1 ? "\(foot.label) zone temperatures" : "Zone temperatures")

                    ThermyxTimeSeriesChart(
                        series: [
                            ChartSeries(
                                id: "forefoot-\(foot.rawValue)", name: "Forefoot",
                                points: digest.points { $0.forefootMeanC.map(settings.temperatureUnit.convert) },
                                color: Thermyx.Ink.ember, isFilled: true
                            ),
                            ChartSeries(
                                id: "arch-\(foot.rawValue)", name: "Arch",
                                points: digest.points { $0.archMeanC.map(settings.temperatureUnit.convert) },
                                color: Thermyx.Ink.amber
                            ),
                            ChartSeries(
                                id: "heel-\(foot.rawValue)", name: "Heel",
                                points: digest.points { $0.heelMeanC.map(settings.temperatureUnit.convert) },
                                color: Thermyx.Ink.ice
                            )
                        ],
                        range: settings.insightsRange,
                        height: 150,
                        format: { String(format: "%.1f°", $0) },
                        showsExtremes: false
                    )

                    HStack(spacing: Thermyx.Space.m) {
                        ChartLegendChip(color: Thermyx.Ink.ember, label: "Forefoot")
                        ChartLegendChip(color: Thermyx.Ink.amber, label: "Arch")
                        ChartLegendChip(color: Thermyx.Ink.ice, label: "Heel")
                    }
                }
            }
        }
    }
}
