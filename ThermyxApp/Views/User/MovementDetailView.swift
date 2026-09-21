import Charts
import SwiftUI

struct MovementDetailView: View {
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
            title: "Movement",
            caption: settings.insightsRange.caption(style: settings.periodStyle)
        ) {
            if pairs.contains(where: { $0.1.hasGait || $0.1.hasBalance }) {
                ForEach(pairs, id: \.0) { foot, footDigest in
                    if pairs.count > 1 {
                        SectionLabel("\(foot.label) foot")
                            .padding(.top, Thermyx.Space.xs)
                    }
                    if footDigest.hasGait { gaitCard(footDigest, foot: foot) }
                    if footDigest.hasBalance { pressureCard(footDigest, foot: foot) }
                    tileRow(footDigest)
                }
                if bilateral.hasBoth { balanceLink }
            } else {
                ThermyxEmptyState(
                    title: "No movement history yet",
                    message: "Gait stability and pressure balance come from the insole's IMU and pressure channels. Connect it and this fills in as readings arrive.",
                    systemImage: "figure.walk"
                )
            }

            articleLink
        }
        .hidesThermalControlBar()
    }

    // MARK: - Gait

    private func gaitCard(_ digest: InsightsDigest, foot: Foot) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(pairs.count > 1 ? "\(foot.label) gait stability" : "Gait stability")
                    Spacer(minLength: Thermyx.Space.xs)
                    if let delta = digest.gaitDelta {
                        Text("\(delta >= 0 ? "+" : "−")\(String(format: "%.0f", abs(delta)))% vs baseline")
                            .font(ThermyxFont.bodySmall)
                            .monospacedDigit()
                            .foregroundStyle(delta >= 0 ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                    }
                }

                ThermyxTimeSeriesChart(
                    series: [
                        ChartSeries(
                            id: "gait-\(foot.rawValue)", name: "\(foot.label) gait stability",
                            points: digest.points { $0.gaitMean.map { $0 * 100 } },
                            color: Thermyx.Ink.ice, isFilled: true
                        )
                    ],
                    range: settings.insightsRange,
                    height: 150,
                    format: { "\(Int($0.rounded()))%" },
                    averageLabel: "Baseline",
                    highTint: Thermyx.Ink.ice,
                    lowTint: Thermyx.Ink.amber
                )
            }
        }
    }

    // MARK: - Pressure

    @ViewBuilder
    private func pressureCard(_ digest: InsightsDigest, foot: Foot) -> some View {
        if let split = digest.pressureSplit {
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    SectionLabel(pairs.count > 1 ? "\(foot.label) pressure" : "Pressure distribution")

                    VStack(spacing: Thermyx.Space.s) {
                        LabeledProgressBar(label: "Forefoot", value: split.forefoot, tint: Thermyx.Ink.amber)
                        LabeledProgressBar(label: "Arch", value: split.arch, tint: Thermyx.Ink.textSupporting)
                        LabeledProgressBar(label: "Heel", value: split.heel, tint: Thermyx.Ink.ice)
                    }

                    Text(interpretation(split))
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Forefoot and heel are measured. The arch share is inferred from the balance channel, not sensed directly.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private func interpretation(_ split: (forefoot: Double, arch: Double, heel: Double)) -> String {
        if split.forefoot > 0.5 { return "Load is sitting forward on the foot — a common pattern late in a shift." }
        if split.heel > 0.5 { return "Load is sitting back on the heel." }
        return "Load is spread fairly evenly between forefoot and heel."
    }

    // MARK: - Cadence, standing, advanced

    private func tileRow(_ digest: InsightsDigest) -> some View {
        HStack(spacing: Thermyx.Space.s) {
            MetricTile(
                label: "Cadence",
                value: digest.cadenceAverage.map { "\(Int($0.rounded()))" },
                tint: Thermyx.Ink.ice,
                numeralFont: ThermyxFont.metricNumeral,
                accessibilityValue: digest.cadenceAverage.map { "\(Int($0.rounded())) steps per minute" } ?? "No reading"
            )
            MetricTile(
                label: "Standing",
                value: digest.standingSeconds.map(DurationFormat.long),
                numeralFont: ThermyxFont.metricNumeral
            )

            NavigationLink(value: InsightsDestination.movementAdvanced) {
                ThermyxCard(padding: Thermyx.Space.m, radius: Thermyx.Radius.control) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Advanced")
                            .narrowLabel(ThermyxFont.zoneLabel, tracking: 1.4, color: Thermyx.Ink.textSupporting)
                        HStack(spacing: 4) {
                            Text("Data")
                                .font(ThermyxFont.metricNumeral)
                                .foregroundStyle(Thermyx.Ink.ice)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Thermyx.Ink.ice)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Advanced data")
            .accessibilityHint("Opens every movement channel over time")
        }
    }

    private var balanceLink: some View {
        NavigationLink(value: InsightsDestination.balance) {
            ThermyxNavigationRow(
                title: "Left vs right",
                detail: "How the two feet compare",
                systemImage: "shoeprints.fill",
                iconTint: Thermyx.Ink.amber,
                iconFill: Thermyx.Tint.amberFill
            )
        }
        .buttonStyle(.plain)
    }

    private var articleLink: some View {
        NavigationLink(value: InsightsDestination.article("fatigue-gait")) {
            ThermyxNavigationRow(
                title: "Read: fatigue and gait",
                detail: "Why stability drops late in a shift",
                systemImage: "book.closed.fill",
                emphasized: true
            )
        }
        .buttonStyle(.plain)
    }
}
