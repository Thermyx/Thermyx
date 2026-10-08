import Charts
import SwiftUI

/// The hub. Each card is a live preview and a tap target into its detail
/// screen. Learning lives here rather than taking a fourth tab.
///
/// With two insoles the hub gains a foot selector and a balance card. Left and
/// right are never averaged into one line: the whole reason for a pair is that
/// the difference between them is the finding.
struct InsightsHubView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var health: ThermyxHealthService

    @State private var path: [InsightsDestination] = {
        #if DEBUG
        return ThermyxPreviewHarness.initialInsightsPath
        #else
        return []
        #endif
    }()
    @State private var footFilter: FootFilter = .both

    private var digest: BilateralDigest {
        BilateralDigest(
            range: settings.insightsRange,
            style: settings.periodStyle,
            samples: viewModel.history.samples(for: settings.insightsRange, style: settings.periodStyle)
        )
    }

    private var unit: TemperatureUnit { settings.temperatureUnit }

    var body: some View {
        NavigationStack(path: $path) {
            ThermyxScreen(title: "Insights") {
                let digest = digest

                InsightsRangeBar(
                    range: $settings.insightsRange,
                    style: $settings.periodStyle,
                    footFilter: $footFilter,
                    availableFeet: digest.feet
                )

                // Test-board sensors, beside (never inside) the body charts.
                BoardSensorCards(board: viewModel.board, history: viewModel.history, ble: viewModel.ble)

                if digest.hasAny {
                    heatExposureCard(digest)
                    if digest.hasBoth { balanceCard(digest) }
                    footVsAmbientCard(digest)
                    zoneMaps(digest)
                    movementCard(digest)
                    if settings.healthKitEnabled { activityCard }
                } else {
                    ThermyxEmptyState(
                        title: "Not enough history yet",
                        message: "Insights need a few minutes of live readings before a trend means anything. Keep an insole connected and charts will fill in here.",
                        systemImage: "chart.xyaxis.line"
                    )
                    if !settings.healthKitEnabled { healthPrompt }
                }

                learningRow
            }
            .navigationDestination(for: InsightsDestination.self) { destination in
                switch destination {
                case .temperature:
                    TemperatureDetailView(settings: settings, footFilter: footFilter)
                case .movement:
                    MovementDetailView(settings: settings, footFilter: footFilter)
                case .movementAdvanced:
                    MovementAdvancedView(settings: settings, footFilter: footFilter)
                case .balance:
                    BalanceDetailView(settings: settings)
                case .learning:
                    LearningCenterView()
                case .article(let id):
                    if let article = ThermyxLearningLibrary.article(id: id) {
                        ArticleView(article: article)
                    }
                }
            }
        }
        .task(id: settings.healthKitEnabled) {
            guard settings.healthKitEnabled else { return }
            if health.availability == .notDetermined { await health.requestAuthorization() }
            await health.refreshContext()
        }
    }

    // MARK: - Heat exposure

    private func heatExposureCard(_ digest: BilateralDigest) -> some View {
        ThermyxCard {
            HStack(alignment: .center, spacing: Thermyx.Space.xxl) {
                HeatExposureDonut(fraction: digest.heatExposureFraction)

                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    SectionLabel("Heat exposure")
                    Text(exposureSummary(digest))
                        .font(ThermyxFont.rowTitleRegular)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Thermyx.Space.s) {
                        ChartLegendChip(color: Thermyx.Ink.ember, label: "Hot \(digest.heatExposureSeconds.map(DurationFormat.long) ?? "—")")
                        ChartLegendChip(color: Thermyx.Ink.signal, label: "Comfort \(digest.comfortSeconds.map(DurationFormat.long) ?? "—")")
                    }
                }
            }
        }
    }

    /// Reports the worse foot rather than an average, and says which one.
    private func exposureSummary(_ digest: BilateralDigest) -> String {
        let period = settings.insightsRange.caption(style: settings.periodStyle).lowercased()
        guard let exposureSeconds = digest.heatExposureSeconds else {
            return "No comfort-band history yet, \(period)."
        }
        let exposure = DurationFormat.long(exposureSeconds)
        guard digest.hasBoth,
              let worst = digest.feet.max(by: { (digest[$0]?.heatExposureSeconds ?? 0) < (digest[$1]?.heatExposureSeconds ?? 0) })
        else {
            return "\(exposure) above your comfort band, \(period)."
        }
        return "\(exposure) above your comfort band on the \(worst.label.lowercased()) foot, \(period)."
    }

    // MARK: - Balance
    //
    // The card that only exists because there are two insoles.

    private func balanceCard(_ digest: BilateralDigest) -> some View {
        NavigationLink(value: InsightsDestination.balance) {
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    HStack(alignment: .firstTextBaseline) {
                        SectionLabel("Left vs right")
                        Spacer(minLength: Thermyx.Space.xs)
                        if let gap = digest.meanTemperatureGapC {
                            Text(gapLabel(gap, warmer: digest.consistentlyHotterFoot))
                                .font(ThermyxFont.bodySmall)
                                .monospacedDigit()
                                .foregroundStyle(gap > 1.5 ? Thermyx.Ink.amber : Thermyx.Ink.ice)
                        }
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }

                    ThermyxTimeSeriesChart(
                        series: [
                            ChartSeries(
                                id: "gap", name: "Temperature gap",
                                points: digest.temperatureAsymmetry.map {
                                    SeriesPoint(date: $0.date, value: unit.convertDelta($0.value))
                                },
                                color: Thermyx.Ink.amber, isFilled: true
                            )
                        ],
                        range: settings.insightsRange,
                        height: 96,
                        format: GapFormat.degrees,
                        showsExtremes: false,
                        averageLabel: "Average",
                        highTint: Thermyx.Ink.amber,
                        lowTint: Thermyx.Ink.amber
                    )

                    Text(balanceSummary(digest))
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Left versus right. Opens balance detail.")
    }

    /// A bare magnitude leaves the reader asking "which foot?" — so say it.
    private func gapLabel(_ gap: Double, warmer: Foot?) -> String {
        guard let warmer else { return "\(TemperatureFormat.delta(gap, in: unit)) average gap" }
        return "\(warmer.label) \(TemperatureFormat.delta(gap, in: unit)) warmer"
    }

    private func balanceSummary(_ digest: BilateralDigest) -> String {
        if let hotter = digest.consistentlyHotterFoot {
            return "Above the line, the left foot is warmer; below it, the right. The \(hotter.label.lowercased()) foot has been consistently warmer this period."
        }
        return "Above the line, the left foot is warmer; below it, the right. Neither foot has been consistently warmer."
    }

    // MARK: - Foot vs ambient

    private func footVsAmbientCard(_ digest: BilateralDigest) -> some View {
        let pairs = digest.digests(for: footFilter)
        return NavigationLink(value: InsightsDestination.temperature) {
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.xs) {
                        SectionLabel("Foot vs ambient")
                        Spacer(minLength: Thermyx.Space.xs)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }

                    ThermyxTimeSeriesChart(
                        series: pairs.map { foot, footDigest in
                            ChartSeries(
                                id: "foot-\(foot.rawValue)", name: "\(foot.label) foot",
                                points: footDigest.points { $0.footMeanC.map(unit.convert) },
                                color: Thermyx.Ink.ember,
                                isDashed: foot.isDashedInCharts,
                                isFilled: foot == .left && pairs.count == 1
                            )
                        } + ambientSeries(pairs),
                        range: settings.insightsRange,
                        height: 110,
                        format: { String(format: "%.1f°", $0) },
                        showsExtremes: false,
                        showsAverage: false
                    )

                    HStack(spacing: Thermyx.Space.m) {
                        ChartLegendChip(color: Thermyx.Ink.ember, label: "Foot")
                        ChartLegendChip(color: Thermyx.Ink.signal, label: "Ambient")
                        if pairs.count > 1 { FootLegend(feet: pairs.map(\.0), tint: Thermyx.Ink.ember) }
                    }
                }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Foot versus ambient temperature. Opens temperature detail.")
    }

    /// Ambient is the same air for both feet, so it is drawn once.
    private func ambientSeries(_ pairs: [(Foot, InsightsDigest)]) -> [ChartSeries] {
        guard let first = pairs.first?.1 else { return [] }
        return [ChartSeries(
            id: "ambient", name: "Ambient",
            points: first.points { $0.ambientMeanC.map(unit.convert) },
            color: Thermyx.Ink.signal, isDashed: true
        )]
    }

    // MARK: - Zones

    @ViewBuilder
    private func zoneMaps(_ digest: BilateralDigest) -> some View {
        ForEach(digest.digests(for: footFilter), id: \.0) { foot, footDigest in
            if let series = footDigest.zoneSeries() {
                NavigationLink(value: InsightsDestination.temperature) {
                    ZoneHeatMap(
                        series: series,
                        columnLabels: footDigest.columnLabels(),
                        unit: unit,
                        title: digest.hasBoth ? "\(foot.label) zones · by hour" : "Zone heat map · by hour",
                        showsChevron: true,
                        showsScale: false
                    )
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Movement

    @ViewBuilder
    private func movementCard(_ digest: BilateralDigest) -> some View {
        let pairs = digest.digests(for: footFilter).filter { $0.1.hasGait }
        if !pairs.isEmpty {
            NavigationLink(value: InsightsDestination.movement) {
                ThermyxCard {
                    VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                        HStack(alignment: .firstTextBaseline) {
                            SectionLabel("Gait stability")
                            Spacer(minLength: Thermyx.Space.xs)
                            Image(systemName: "chevron.right")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(Thermyx.Ink.textFaint)
                        }

                        ThermyxTimeSeriesChart(
                            series: pairs.map { foot, footDigest in
                                ChartSeries(
                                    id: "gait-\(foot.rawValue)", name: "\(foot.label) stability",
                                    points: footDigest.points { $0.gaitMean.map { $0 * 100 } },
                                    color: Thermyx.Ink.ice,
                                    isDashed: foot.isDashedInCharts
                                )
                            },
                            range: settings.insightsRange,
                            height: 96,
                            format: { "\(Int($0.rounded()))%" },
                            showsExtremes: false,
                            highTint: Thermyx.Ink.ice,
                            lowTint: Thermyx.Ink.amber
                        )

                        if pairs.count > 1 { FootLegend(feet: pairs.map(\.0), tint: Thermyx.Ink.ice) }
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Gait stability. Opens movement detail.")
        }
    }

    // MARK: - Apple Health

    @ViewBuilder
    private var activityCard: some View {
        switch health.availability {
        case .authorized:
            if health.todayStepCount != nil || health.lastWorkout != nil || health.walkingSteadiness != nil {
                ThermyxCard {
                    VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                        SectionLabel("Activity context", color: Thermyx.Ink.ice)
                        Text("From Apple Health, so heat exposure sits next to what you were doing.")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)

                        HStack(spacing: Thermyx.Space.xs) {
                            MetricTile(
                                label: "Steps today",
                                value: health.todayStepCount.map { $0.formatted(.number) },
                                tint: Thermyx.Ink.ice
                            )
                            MetricTile(
                                label: "Steadiness",
                                value: health.walkingSteadiness.map { "\(Int(($0 * 100).rounded()))%" }
                            )
                            MetricTile(
                                label: "Last workout",
                                value: health.lastWorkout.map { DurationFormat.long($0.duration) }
                            )
                        }
                    }
                }
            }
        case .denied:
            ThermyxCard {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Apple Health")
                    Text("Health access is off. Thermyx works normally without it — turn it back on in the Health app if you want step and workout context here.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .notEntitled:
            ThermyxCard(fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder) {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Apple Health", color: Thermyx.Ink.amber)
                    Text("This build isn't signed with the HealthKit capability, so Health can't be reached. Everything else works normally. Sign the app with a development team to enable it.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        case .notDetermined, .unavailable:
            EmptyView()
        }
    }

    private var healthPrompt: some View {
        ThermyxCard(fill: Thermyx.Tint.signalFill, border: Thermyx.Tint.signalBorder) {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("Apple Health", color: Thermyx.Ink.ice)
                Text("Connect Health to see heat exposure alongside your steps and workouts, and to save Thermyx sessions with the rest of your health data.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("Thermyx never writes a body temperature. The insole measures contact temperature, not core temperature.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Connect Apple Health") { settings.healthKitEnabled = true }
                    .buttonStyle(ThermyxPrimaryButtonStyle())
                    .padding(.top, 2)
            }
        }
    }

    // MARK: - Learning

    @ViewBuilder
    private var learningRow: some View {
        let count = ThermyxLearningLibrary.articles.count
        if count > 0 {
            NavigationLink(value: InsightsDestination.learning) {
                ThermyxNavigationRow(
                    title: "Learning center",
                    detail: "Why foot temperature matters · \(count) articles",
                    systemImage: "book.closed.fill",
                    emphasized: true
                )
            }
            .buttonStyle(.plain)
        }
    }
}

enum InsightsDestination: Hashable {
    case temperature
    case movement
    case movementAdvanced
    case balance
    case learning
    case article(String)
}
