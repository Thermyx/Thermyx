import Charts
import SwiftUI

struct MovementDetailView: View {
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
            title: "Movement",
            caption: settings.insightsCaption
        ) {
            if pairs.contains(where: { $0.1.hasGait || $0.1.hasBalance }) {
                ForEach(pairs, id: \.0) { foot, footDigest in
                    if pairs.count > 1 {
                        SectionLabel("\(foot.label) foot")
                            .padding(.top, Thermyx.Space.xs)
                    }
                    if footDigest.hasGait { gaitCard(footDigest, foot: foot) }
                    tileRow(footDigest)
                }
                if bilateral.hasBoth { balanceLink }
            } else {
                ThermyxEmptyState(
                    title: "No movement history yet",
                    message: "Steadiness and pressure come from the insoles. Wear them a while and this fills in.",
                    systemImage: "figure.walk"
                )
            }

            articleLink
        }
    }

    // MARK: - Gait

    private func gaitCard(_ digest: InsightsDigest, foot: Foot) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                HStack(alignment: .firstTextBaseline) {
                    SectionLabel(pairs.count > 1 ? "\(foot.label) foot steadiness" : "Steadiness")
                    Spacer(minLength: Thermyx.Space.xs)
                    if let delta = digest.gaitDelta {
                        Text(abs(delta) < 0.5 ? "As usual" : "\(String(format: "%.0f", abs(delta)))% \(delta >= 0 ? "steadier" : "less steady") than usual")
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
                            color: Thermyx.Ink.ice, isFilled: true,
                            scale: .steadiness
                        )
                    ],
                    range: settings.insightsRange,
                    height: 150,
                    format: { "\(Int($0.rounded()))%" },
                    averageLabel: "Usual",
                    highTint: Thermyx.Ink.ice,
                    lowTint: Thermyx.Ink.amber
                )
            }
        }
    }

    // MARK: - Cadence, standing, advanced

    private func tileRow(_ digest: InsightsDigest) -> some View {
        HStack(spacing: Thermyx.Space.s) {
            MetricTile(
                label: "Steps a minute",
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
                        Text("More detail")
                            .narrowLabel(ThermyxFont.zoneLabel, tracking: 1.4, color: Thermyx.Ink.textSupporting)
                        HStack(spacing: 4) {
                            Text("Charts")
                                .font(ThermyxFont.metricNumeral)
                                .foregroundStyle(Thermyx.Ink.link)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Thermyx.Ink.link)
                        }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("More detail, charts")
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
