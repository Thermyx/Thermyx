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

                // Today and this week at the top, each a way into its page.
                InsightsSummaryCards(settings: settings)
                SteadinessCard(baseline: viewModel.baseline)

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
                case .days:
                    DailySummaryListView(settings: settings)
                case .day(let day):
                    DailySummaryView(settings: settings, day: day)
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
                            SectionLabel("Steadiness over time")
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

    // MARK: - Daily summaries

    @ViewBuilder
    private var dailySummariesRow: some View {
        let days = ThermyxDailySummary.days(hourSamples: viewModel.history.hourSamples, events: viewModel.history.events)
        if let latest = days.first {
            NavigationLink(value: InsightsDestination.days) {
                ThermyxNavigationRow(
                    title: "Daily summaries",
                    detail: "\(DailySummaryView.dayTitle(latest.day)) · worn \(DurationFormat.long(latest.wornSeconds))"
                        + " · \(days.count) day\(days.count == 1 ? "" : "s")",
                    systemImage: "calendar"
                )
            }
            .buttonStyle(.plain)
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
    case days
    case day(Date)
}

// MARK: - Daily summaries

/// Every day with history, newest first.
struct DailySummaryListView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    var body: some View {
        let days = ThermyxDailySummary.days(hourSamples: viewModel.history.hourSamples, events: viewModel.history.events)
        ThermyxDetailScreen(title: "Daily summaries") {
            if days.isEmpty {
                ThermyxEmptyState(
                    title: "No days yet",
                    message: "Wear a connected insole and each day gets a summary here.",
                    systemImage: "calendar"
                )
            }
            ForEach(days) { day in
                NavigationLink(value: InsightsDestination.day(day.day)) {
                    ThermyxNavigationRow(
                        title: DailySummaryView.dayTitle(day.day),
                        detail: detail(day),
                        systemImage: day.peakRisk.map { $0.severity >= ThermyxRiskLevel.caution.severity } == true
                            ? "exclamationmark.triangle.fill" : "checkmark.circle.fill",
                        iconTint: day.peakRisk?.tint ?? Thermyx.Ink.ice
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .hidesThermalControlBar()
    }

    private func detail(_ day: ThermyxDailySummary) -> String {
        var parts = ["Worn \(DurationFormat.long(day.wornSeconds))"]
        if let peak = day.peakFootC { parts.append("peak \(TemperatureFormat.degrees(peak, in: settings.temperatureUnit))") }
        if let h = day.heatingSeconds, h >= 60 { parts.append("heated \(DurationFormat.long(h))") }
        if let c = day.coolingSeconds, c >= 60 { parts.append("cooled \(DurationFormat.long(c))") }
        return parts.joined(separator: " · ")
    }
}

/// One day: time worn, how long the insole heated and cooled, temperatures,
/// movement, the worst risk level, and an optional AI summary.
struct DailySummaryView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    let day: Date

    @State private var aiSummary: String?
    @State private var aiError: String?
    @State private var aiLoading = false

    static func dayTitle(_ day: Date, calendar: Calendar = .current) -> String {
        if calendar.isDateInToday(day) { return "Today" }
        if calendar.isDateInYesterday(day) { return "Yesterday" }
        return day.formatted(.dateTime.weekday(.wide).month(.abbreviated).day())
    }

    private var summary: ThermyxDailySummary? {
        let calendar = Calendar.current
        let samples = viewModel.history.hourSamples.filter { calendar.isDate($0.start, inSameDayAs: day) }
        guard !samples.isEmpty else { return nil }
        return ThermyxDailySummary.summary(
            day: calendar.startOfDay(for: day),
            samples: samples,
            events: viewModel.history.events.filter { calendar.isDate($0.timestamp, inSameDayAs: day) }
        )
    }

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private func temp(_ c: Double?) -> String? { c.map { TemperatureFormat.degrees($0, in: unit) } }
    private func duration(_ s: TimeInterval?) -> String? { s.map(DurationFormat.long) }

    var body: some View {
        ThermyxDetailScreen(title: Self.dayTitle(day)) {
            if let s = summary {
                let performance = settings.profile.focus == .performance
                if performance {
                    movement(s)
                    thermal(s)
                    temperatures(s)
                } else {
                    temperatures(s)
                    thermal(s)
                    movement(s)
                }
                safety(s)
                aiCard(s)
            } else {
                ThermyxEmptyState(title: "No data for this day", message: "Nothing was recorded.", systemImage: "calendar")
            }
        }
        .hidesThermalControlBar()
    }

    private func grid<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Thermyx.Space.s), GridItem(.flexible(), spacing: Thermyx.Space.s)],
                  spacing: Thermyx.Space.s, content: content)
    }

    private func temperatures(_ s: ThermyxDailySummary) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Foot temperature")
            grid {
                MetricTile(label: "Average", value: temp(s.averageFootC))
                MetricTile(label: "Peak", value: temp(s.peakFootC), tint: Thermyx.Ink.amber)
                MetricTile(label: "Lowest", value: temp(s.lowFootC), tint: Thermyx.Ink.ice)
                MetricTile(label: "Hours warm or hot", value: "\(s.hotHours)")
            }
        }
    }

    private func thermal(_ s: ThermyxDailySummary) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Insole")
            grid {
                MetricTile(label: "Worn", value: duration(s.wornSeconds))
                MetricTile(label: "Air around you", value: temp(s.averageAmbientC))
                MetricTile(label: "Heating", value: duration(s.heatingSeconds), tint: Thermyx.Ink.amber)
                MetricTile(label: "Cooling", value: duration(s.coolingSeconds), tint: Thermyx.Ink.ice)
            }
            if s.heatingSeconds == nil {
                Text("Heating and cooling time is recorded from this version of the app on.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
        }
    }

    private func movement(_ s: ThermyxDailySummary) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Movement")
            grid {
                MetricTile(label: "Steps (est.)", value: s.steps.map { Int($0.rounded()).formatted() })
                MetricTile(label: "Cadence", value: s.cadenceAverage.map { "\(Int($0.rounded())) spm" })
                MetricTile(label: "Steadiness", value: s.gaitAverage.map { "\(Int(($0 * 100).rounded()))%" })
                MetricTile(label: "Insoles", value: s.feet.map(\.label).joined(separator: " + "))
            }
            SectionLabel("Activity")
            ActivitySplitBar(sitting: s.sittingSeconds, standing: s.standingSeconds, walking: s.walkingSeconds)
        }
    }

    private func safety(_ s: ThermyxDailySummary) -> some View {
        ThermyxCard {
            HStack(spacing: Thermyx.Space.m) {
                Circle().fill(s.peakRisk?.tint ?? Thermyx.Ink.textFaint).frame(width: 10, height: 10)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Highest level: \(s.peakRisk?.rawValue ?? "No assessment")")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(s.events == 0 ? "No safety events." : "\(s.events) safety event\(s.events == 1 ? "" : "s").")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                }
                Spacer()
            }
        }
    }

    // MARK: AI summary

    private func aiCard(_ s: ThermyxDailySummary) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("AI summary")
                if let aiSummary = aiSummary ?? ThermyxAlertCoordinator.storedSummary(for: day) {
                    Text(aiSummary)
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("Written by AI from this day's numbers. Not medical advice.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                } else if settings.isPairedWithRelay, settings.relayRole == "wearer" {
                    Button(aiLoading ? "Writing…" : "Summarize this day") { Task { await requestSummary(s) } }
                        .buttonStyle(ThermyxSecondaryButtonStyle())
                        .disabled(aiLoading)
                    Text("A summary also arrives as a notification after you finish wearing the insoles. It uses only this day's totals and averages (no readings, name, or location), sent to your relay, which asks an AI model. The relay stores nothing.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Connect to a relay in Profile → Advanced to get a short AI-written summary of each day.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let aiError {
                    Text(aiError).font(ThermyxFont.caption).foregroundStyle(Thermyx.Ink.amber)
                }
            }
        }
    }

    private func requestSummary(_ s: ThermyxDailySummary) async {
        aiLoading = true
        aiError = nil
        defer { aiLoading = false }
        do {
            aiSummary = try await ThermyxAlertAPIClient().summary(
                .init(s, unit: unit, focus: settings.profile.focus),
                baseURL: settings.backendURL,
                token: settings.backendToken
            )
        } catch {
            aiError = error.localizedDescription
        }
    }
}

/// The top of Insights: today's summary as tap-through cards, then the week
/// with the streak, each opening its own page.
struct InsightsSummaryCards: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore

    var body: some View {
        let days = ThermyxDailySummary.days(hourSamples: viewModel.history.hourSamples, events: viewModel.history.events)
        let today = days.first { Calendar.current.isDateInToday($0.day) }
        let week = ThermyxWeeklyReport.make(days: days)
        let unit = settings.temperatureUnit

        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            HStack {
                SectionLabel("Today")
                Spacer()
                NavigationLink(value: InsightsDestination.days) {
                    Text("All days")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.ice)
                        .frame(minHeight: Thermyx.minimumTapTarget)
                }
                .buttonStyle(.plain)
            }
            NavigationLink(value: InsightsDestination.day(Calendar.current.startOfDay(for: .now))) {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: Thermyx.Space.s), GridItem(.flexible(), spacing: Thermyx.Space.s)],
                          spacing: Thermyx.Space.s) {
                    MetricTile(label: "Worn", value: today.map { DurationFormat.long($0.wornSeconds) })
                    MetricTile(label: "Avg foot temp", value: today?.averageFootC.map { TemperatureFormat.degrees($0, in: unit) })
                    MetricTile(label: "Heating", value: today?.heatingSeconds.map(DurationFormat.long), tint: Thermyx.Ink.ember)
                    MetricTile(label: "Cooling", value: today?.coolingSeconds.map(DurationFormat.long), tint: Thermyx.Ink.signal)
                }
            }
            .buttonStyle(.plain)
            .disabled(today == nil)
            .accessibilityHint("Opens today's summary")

            NavigationLink(value: InsightsDestination.days) {
                ThermyxCard {
                    HStack(spacing: Thermyx.Space.l) {
                        VStack(spacing: 0) {
                            Text("\(week.streak)")
                                .font(ThermyxFont.metricNumeralCompact)
                                .foregroundStyle(week.streak > 0 ? Thermyx.Ink.amber : Thermyx.Ink.textFaint)
                            Text(week.streak == 1 ? "day" : "days")
                                .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                        }
                        .frame(width: 56)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(week.streak > 0 ? "Streak: \(week.streak) day\(week.streak == 1 ? "" : "s") in a row" : "This week")
                                .font(ThermyxFont.rowTitle)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text(weekLine(week))
                                .font(ThermyxFont.caption)
                                .foregroundStyle(Thermyx.Ink.textSupporting)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        Spacer(minLength: 0)
                        Image(systemName: "chevron.right").foregroundStyle(Thermyx.Ink.textFaint)
                    }
                }
            }
            .buttonStyle(.plain)
        }
    }

    private func weekLine(_ w: ThermyxWeeklyReport) -> String {
        var parts = ["\(w.daysWorn) of 7 days", "worn \(DurationFormat.long(w.wornSeconds))"]
        if let steps = w.steps { parts.append("\(Int(steps).formatted()) steps") }
        if let change = w.wornChange { parts.append("\(change >= 0 ? "+" : "")\(Int((change * 100).rounded()))% vs last week") }
        return parts.joined(separator: " · ")
    }
}

/// Sitting, standing and walking time as one bar with a legend.
struct ActivitySplitBar: View {
    let sitting: TimeInterval?
    let standing: TimeInterval?
    let walking: TimeInterval?

    private var parts: [(String, TimeInterval, Color)] {
        [("Sitting", sitting ?? 0, Thermyx.Ink.textSupporting),
         ("Standing", standing ?? 0, Thermyx.Ink.signal),
         ("Walking", walking ?? 0, Thermyx.Ink.ice)]
    }

    var body: some View {
        let total = parts.reduce(0) { $0 + $1.1 }
        ThermyxCard {
            if total <= 0 {
                Text("Activity needs the insole's motion and pressure sensors. It shows here once they report.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    GeometryReader { geo in
                        HStack(spacing: 2) {
                            ForEach(parts, id: \.0) { part in
                                if part.1 > 0 {
                                    RoundedRectangle(cornerRadius: 3)
                                        .fill(part.2)
                                        .frame(width: max(4, (geo.size.width - 4) * part.1 / total))
                                }
                            }
                        }
                    }
                    .frame(height: 14)
                    HStack(spacing: Thermyx.Space.m) {
                        ForEach(parts, id: \.0) { part in
                            HStack(spacing: 4) {
                                Circle().fill(part.2).frame(width: 8, height: 8)
                                Text("\(part.0) \(DurationFormat.long(part.1))")
                                    .font(ThermyxFont.captionSmall)
                                    .foregroundStyle(Thermyx.Ink.textSecondary)
                            }
                        }
                    }
                    Text("Estimated from cadence and pressure.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// Insights: live steadiness against the wearer's usual walk from
/// calibration.
struct SteadinessCard: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var baseline: PersonalBaselineStore

    var body: some View {
        let now = viewModel.reading.gaitStability
        let usual = baseline.model?.walkingSteadiness?.mean ?? baseline.baseline.gaitMean
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("Steadiness")
                HStack(spacing: Thermyx.Space.s) {
                    MetricTile(label: "Now", value: now.map { "\(Int(($0 * 100).rounded()))%" }, tint: Thermyx.Ink.ice)
                    MetricTile(label: "Your usual", value: usual.map { "\(Int(($0 * 100).rounded()))%" })
                }
                Text(caption(now: now, usual: usual))
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func caption(now: Double?, usual: Double?) -> String {
        if now == nil {
            return "How even and regular your steps are. It shows once the insole's motion and pressure sensors report."
        }
        guard usual != nil else {
            return "How even and regular your steps are. Calibrate to learn your usual walk."
        }
        return "How even and regular your steps are, against your usual walk from calibration. Well below usual while walking raises Caution."
    }
}
