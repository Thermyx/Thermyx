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
            style: settings.insightsStyle,
            samples: viewModel.history.samples(for: settings.insightsRange, style: settings.insightsStyle, now: settings.insightsNow)
        )
    }
    private var pairs: [(Foot, InsightsDigest)] { bilateral.digests(for: footFilter) }

    var body: some View {
        ThermyxDetailScreen(
            title: "Advanced",
            caption: settings.insightsCaption
        ) {
            Text("Everything the insoles picked up about how you moved. Touch and hold a chart to read it; pinch to zoom.")
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(pairs, id: \.0) { foot, digest in
                if pairs.count > 1 {
                    SectionLabel("\(foot.label) foot")
                        .padding(.top, Thermyx.Space.xs)
                }
                channel(
                    "Steadiness", unit: "%",
                    points: digest.points { $0.gaitMean.map { $0 * 100 } },
                    color: Thermyx.Ink.ice,
                    scale: .steadiness,
                    format: { "\(Int($0.rounded()))%" },
                    note: "Higher means steadier steps. It's compared with your own usual, not anyone else's."
                )
                channel(
                    "Arch pressure", unit: "%",
                    points: digest.points { $0.balanceMean.map { $0 * 100 } },
                    color: Thermyx.Ink.amber,
                    scale: .load,
                    format: { "\(Int($0.rounded()))%" },
                    note: "How firmly you pressed on the sensor under your arch, from none to full."
                )
                channel(
                    "Steps a minute", unit: "steps",
                    points: digest.points(\.cadenceMean),
                    color: Thermyx.Ink.signal,
                    scale: .cadence,
                    format: { "\(Int($0.rounded()))" },
                    note: "How quickly you were walking. Older insoles don't count this."
                )
                channel(
                    "Standing", unit: "%",
                    points: digest.points { $0.standingMean.map { $0 * 100 } },
                    color: Thermyx.Ink.textSecondary,
                    scale: .share,
                    format: { "\(Int($0.rounded()))%" },
                    note: "How much of the time you were on your feet but standing still. Older insoles don't count this."
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
    }

    @ViewBuilder
    private func channel(
        _ title: String,
        unit: String,
        points: [SeriesPoint],
        color: Color,
        scale: ChartValueScale,
        format: @escaping (Double) -> String,
        note: String
    ) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SectionLabel(title)

                if points.count >= 3 {
                    ThermyxTimeSeriesChart(
                        series: [ChartSeries(id: "\(title)-\(points.count)", name: title, points: points, color: color,
                                             isFilled: true, scale: scale)],
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
                VStack(alignment: .leading, spacing: Thermyx.Space.header) {
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
