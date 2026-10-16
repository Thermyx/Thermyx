import SwiftUI

/// Which map Home shows under the feet.
enum HomeMap: String, CaseIterable, Identifiable {
    case pressure, temperature, gait
    var id: String { rawValue }

    var label: String {
        switch self {
        case .pressure: return "Pressure"
        case .temperature: return "Temperature"
        case .gait: return "Gait"
        }
    }
}

/// Home, after the v2 design's "Instrument" direction: the warmer foot's
/// temperature, where it sits on the four risk levels, and both feet drawn
/// in their real outlines. Only measured values are drawn: one temperature
/// per foot (or three zones), and the arch sensor's load.
struct HomeView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @EnvironmentObject private var account: ThermyxAccountStore
    @Environment(\.isThermyxAdmin) private var isAdmin
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @AppStorage("thermyx.home.map") private var mapRaw = HomeMap.pressure.rawValue
    @State private var showingWhy = false
    @State private var showingRecovery = false
    @State private var showingDevice: Bool = {
        #if DEBUG
        return ThermyxPreviewHarness.opensProfileSheet
        #else
        return false
        #endif
    }()
    @State private var air: ThermyxWeather.Current?
    @State private var lesson: LearningArticle?

    private var map: HomeMap { HomeMap(rawValue: mapRaw) ?? .pressure }
    private var reading: BilateralReading { viewModel.reading }
    private var assessment: ThermyxRiskAssessment { viewModel.assessment }
    private var unit: TemperatureUnit { settings.temperatureUnit }
    /// The hero is the **warmer** foot, never the average: an average hides
    /// the case that matters, one foot running hot.
    private var heroC: Double? { reading.peakFootTemperatureC }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                    .padding(.bottom, Thermyx.Space.m)
                if !viewModel.anyConnected, viewModel.ble.boardState.isConnected || !viewModel.board.table.connected.isEmpty {
                    // An admin's single-sensor test board, with no insole on.
                    SensorMainView(board: viewModel.board, ble: viewModel.ble, unit: unit) { _ in showingDevice = true }
                        .frame(minHeight: 480)
                } else {
                    hero
                    riskScale
                        .padding(.top, Thermyx.Space.xl)
                    reason
                    mapTabs
                        .padding(.top, Thermyx.Space.group)
                    maps
                        .padding(.top, Thermyx.Space.xl)
                    if viewModel.anyConnected {
                        metrics
                            .padding(.top, Thermyx.Space.section)
                        LowBatteryCard(reading: reading)
                            .padding(.top, Thermyx.Space.m)
                        CalibrationPromptCard(baseline: viewModel.baseline, settings: settings)
                            .padding(.top, Thermyx.Space.m)
                    } else {
                        connectPrompt
                            .padding(.top, Thermyx.Space.section)
                    }
                }
            }
            .padding(.horizontal, Thermyx.Space.screen)
            .padding(.bottom, Thermyx.Space.xxl)
        }
        .scrollIndicators(.hidden)
        .thermyxTopScrim()
        .task(id: viewModel.anyConnected) { await refreshAir() }
        .sheet(isPresented: $showingDevice) {
            DeviceProfileSheet(roles: roles, settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingWhy) {
            RiskExplanationSheet(settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingRecovery, onDismiss: { viewModel.coach.close() }) {
            RecoverySheet(coach: viewModel.coach, settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        #if DEBUG
        .task {
            // `-ThermyxUIPreview recoveryTest|recoveryHold|recoveryResult`
            guard let state = ThermyxPreviewHarness.state,
                  [.recoveryTest, .recoveryHold, .recoveryResult].contains(state) else { return }
            try? await Task.sleep(for: .seconds(3))
            viewModel.coach.start(level: assessment.level, reading: reading)
            viewModel.coach.toggle(.pause)
            if state != .recoveryTest {
                viewModel.coach.beginHold()
                if state == .recoveryResult {
                    try? await Task.sleep(for: .seconds(RecoveryEvaluator.holdSeconds + 3))
                }
            }
            showingRecovery = true
        }
        #endif
        .sheet(item: $lesson) { article in
            NavigationStack { ArticleView(article: article) }
                .presentationDragIndicator(.visible)
        }
    }

    /// The Learn lesson for what's happening now, from the same rules the
    /// Learn tab uses.
    private var suggestion: LearningSuggestion? {
        LearningSuggestion.current(.init(
            reading: reading, assessment: assessment, connected: viewModel.connectedFeet,
            pairExpected: viewModel.pairExpected, trend10: trend?.delta, recentPeak: nil,
            airC: air?.airC, daysOfHistory: 30, unit: unit
        ))
    }

    // MARK: Header

    /// The Thermyx mark and name, and each insole's battery drawn to scale.
    /// Tapping it opens the insoles and device settings.
    private var header: some View {
        Button {
            showingDevice = true
        } label: {
            HStack(alignment: .center) {
                HStack(spacing: Thermyx.Space.xs) {
                    Image("ThermyxMark")
                        .resizable()
                        .scaledToFit()
                        .frame(width: 26, height: 26)
                        .accessibilityHidden(true)
                    Text("Thermyx")
                        .font(.custom(ThermyxFont.Family.bold, size: 21, relativeTo: .title3))
                        .tracking(-0.4)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                }
                Spacer(minLength: Thermyx.Space.s)
                batteries
            }
            .frame(minHeight: 44)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .padding(.top, 6)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Thermyx. \(batteryAccessibility)")
        .accessibilityHint("Opens your insoles and device settings.")
    }

    /// "L ▭ 82%   R ▭ 79%": each foot's battery as a glyph filled to its
    /// charge, amber at 10% and ember at 5%.
    private var batteries: some View {
        HStack(spacing: Thermyx.Space.m) {
            ForEach(Foot.allCases) { foot in
                let percent = reading[foot]?.batteryPercent
                HStack(spacing: 5) {
                    Text(foot.shortLabel)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                    BatteryGlyph(percent: percent)
                    Text(percent.map { "\($0)%" } ?? "—")
                        .foregroundStyle(percent == nil ? Thermyx.Ink.textFaint
                                         : percent! <= ThermyxBattery.low ? ThermyxBattery.tint(percent) : Thermyx.Ink.textPrimary)
                        .monospacedDigit()
                }
            }
        }
        .font(ThermyxFont.monoCaption)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(batteryAccessibility)
    }

    private var batteryAccessibility: String {
        let parts = Foot.allCases.compactMap { foot -> String? in
            guard let r = reading[foot] else { return nil }
            return "\(foot.label) insole \(r.batteryPercent.map { "\($0) percent" } ?? "battery unknown")"
        }
        return parts.isEmpty ? "No insoles connected" : parts.joined(separator: ", ")
    }

    // MARK: Hero

    private var hero: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 2) {
                    Text(heroC.map { TemperatureFormat.value($0, in: unit) } ?? "—")
                        .font(ThermyxFont.heroNumeral)
                        .tracking(ThermyxTracking.heroNumeral)
                        .monospacedDigit()
                        .foregroundStyle(heroC == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                        .contentTransition(.numericText(value: heroC ?? 0))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text(unit.symbol)
                        .font(ThermyxFont.heroDegree)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .padding(.top, 6)
                }
                Text(heroCaption)
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            Spacer(minLength: Thermyx.Space.m)
            VStack(alignment: .trailing, spacing: 4) {
                Text(assessment.level == .unavailable ? "—" : assessment.level.rawValue)
                    .font(ThermyxFont.riskHeadline)
                    .foregroundStyle(assessment.level.tint)
                Text(trendText)
                    .font(ThermyxFont.monoCaption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            .padding(.bottom, 4)
        }
        .animation(SiteMotion.settle, value: heroC)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(heroAccessibility)
        .spotlightTarget(.hero)
    }

    private var heroCaption: String {
        guard viewModel.anyConnected else { return "No insoles connected" }
        guard heroC != nil else { return "Foot sensor not reporting" }
        guard viewModel.bothConnected else {
            return viewModel.connectedFeet.first.map { "\($0.label) foot" } ?? "Foot"
        }
        guard let hotter = reading.hotterFoot else { return "Both feet" }
        return "Warmer foot · \(hotter.label.lowercased())"
    }

    private var trend: ThermyxHistoryStore.Trend? {
        viewModel.history.footTrend(over: 10 * 60, current: heroC)
    }

    private var trendText: String {
        guard viewModel.anyConnected else { return " " }
        guard let trend else { return "Building trend" }
        return "\(trend.delta >= 0 ? "+" : "−")\(TemperatureFormat.delta(abs(trend.delta), in: unit)) / 10 min"
    }

    private var heroAccessibility: String {
        var parts = [heroCaption]
        if let heroC { parts.append(TemperatureFormat.full(heroC, in: unit)) }
        if assessment.level != .unavailable { parts.append("Risk level \(assessment.level.rawValue)") }
        if let trend { parts.append("\(TemperatureFormat.delta(trend.delta, in: unit)) over 10 minutes") }
        return parts.joined(separator: ". ")
    }

    // MARK: Risk scale

    /// The four levels as a scale, the current one lit in its colour.
    private var riskScale: some View {
        HStack(spacing: 4) {
            ForEach(ThermyxRiskLevel.ladder, id: \.self) { level in
                let current = level == assessment.level
                VStack(alignment: .leading, spacing: 6) {
                    Capsule()
                        .fill(current ? level.tint : Thermyx.Tint.track)
                        .frame(height: 3)
                    Text(level.rawValue)
                        .font(ThermyxFont.zoneLabel)
                        .foregroundStyle(current ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(SiteMotion.settle, value: assessment.level)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Risk scale")
        .accessibilityValue(assessment.level == .unavailable ? "No reading" : "\(assessment.level.rawValue), of Normal, Caution, High risk, Critical")
    }

    /// At Caution and above, the reason in a line and a way into "why".
    @ViewBuilder
    private var reason: some View {
        if assessment.level.severity >= ThermyxRiskLevel.caution.severity {
            Button {
                showingWhy = true
            } label: {
                HStack(alignment: .firstTextBaseline, spacing: Thermyx.Space.s) {
                    Text(assessment.reasons.first ?? assessment.level.shortGuidance)
                        .font(ThermyxFont.bodySmall)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Text("Why?")
                        .font(ThermyxFont.controlLabel)
                        .foregroundStyle(assessment.level.tint)
                }
                .padding(.top, 14)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityHint("Shows what raised the level.")
            if viewModel.anyConnected {
                Button {
                    viewModel.coach.start(level: assessment.level, reading: reading)
                    showingRecovery = true
                } label: {
                    Label("Start a recovery test", systemImage: "arrow.down.right.circle")
                }
                .buttonStyle(ThermyxSecondaryButtonStyle(tint: assessment.level.tint, border: assessment.level.border))
                .padding(.top, Thermyx.Space.m)
                .accessibilityHint("Guides you through cooling down and measures whether your feet are cooling.")
            }
            if let suggestion {
                Button {
                    lesson = suggestion.article
                } label: {
                    HStack(spacing: 8) {
                        Image(systemName: "newspaper")
                            .font(.system(size: 13, weight: .semibold))
                        Text("Read: \(suggestion.article.title)")
                            .font(ThermyxFont.captionSmall)
                            .multilineTextAlignment(.leading)
                        Spacer(minLength: 0)
                    }
                    .foregroundStyle(Thermyx.Ink.ice)
                    .padding(.top, 8)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityHint("Opens the Learn lesson for this situation.")
            }
        } else if settings.aiSuggestionsEnabled, viewModel.anyConnected,
                  let next = ThermyxSuggestion.nextStep(for: assessment, reading: reading) {
            Text(next)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .padding(.top, 12)
        }
    }

    // MARK: Maps

    private var mapTabs: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 22) {
                ForEach(HomeMap.allCases) { option in
                    let selected = option == map
                    Button {
                        withAnimation(SiteMotion.settle) { mapRaw = option.rawValue }
                    } label: {
                        Text(option.label)
                            .font(ThermyxFont.controlLabel)
                            .foregroundStyle(selected ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle()
                                    .fill(selected ? Thermyx.Ink.ice : .clear)
                                    .frame(height: 2)
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            .spotlightTarget(.mapTabs)
            Spacer(minLength: Thermyx.Space.s)
            Text(activityLine)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.ice)
                .lineLimit(1)
                .padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) { ThermyxDivider() }
        .sensoryFeedback(.selection, trigger: mapRaw)
    }

    private var activityLine: String {
        guard viewModel.anyConnected else { return "" }
        var parts: [String] = []
        if let best = viewModel.baseline.activity?.max(by: { $0.value < $1.value }), best.value >= 0.6 {
            parts.append(best.key.label)
        }
        if let cadence = reading.cadenceStepsPerMinute, cadence > 0 {
            parts.append("\(Int(cadence.rounded())) spm")
        }
        return parts.joined(separator: " · ")
    }

    private var maps: some View {
        HStack(alignment: .top, spacing: 0) {
            Spacer(minLength: 0)
            HStack(alignment: .top, spacing: 30) {
                ForEach(Foot.allCases) { foot in
                    VStack(spacing: 10) {
                        FootMap(foot: foot, content: mapContent(foot))
                            .frame(width: 113, height: 270)
                            .animation(SiteMotion.settle, value: mapRaw)
                        VStack(spacing: 1) {
                            Text(mapKey(foot))
                                .font(ThermyxFont.captionSmall)
                                .foregroundStyle(Thermyx.Ink.textMuted)
                            Text(mapValue(foot))
                                .font(.custom(ThermyxFont.Family.monoMedium, size: 16, relativeTo: .body))
                                .foregroundStyle(reading[foot] == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(foot.label) foot, \(map.label.lowercased())")
                    .accessibilityValue(mapValue(foot) == "—" ? "No reading" : "\(mapKey(foot)), \(mapValue(foot))")
                }
            }
            Spacer(minLength: 0)
        }
        .overlay(alignment: .topTrailing) { legend.padding(.top, 30) }
        .overlay(alignment: .bottom) {
            if viewModel.anyConnected, map == .pressure {
                Text(pressureNote)
                    .font(ThermyxFont.zoneLabel)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .offset(y: 22)
            }
        }
        .padding(.bottom, viewModel.anyConnected && map == .pressure ? 22 : 0)
        .spotlightTarget(.maps)
    }

    private func mapContent(_ foot: Foot) -> FootMap.Content {
        guard let r = reading[foot] else { return .outline(dimmed: true) }
        switch map {
        case .pressure:
            if r.loadIsArchLevel { return .archLoad(r.pressureBalance) }
            if r.pressureBalance != nil { return .forefootShare(r.pressureBalance) }
            return .archLoad(nil)
        case .temperature:
            if let zones = r.zones { return .zones(zones) }
            return .temperature(r.footTemperatureC)
        case .gait:
            return .outline(dimmed: false)
        }
    }

    private func mapKey(_ foot: Foot) -> String {
        guard let r = reading[foot] else { return foot.label }
        switch map {
        case .pressure: return "\(foot.label) · \(r.loadIsArchLevel ? "arch" : "forefoot")"
        case .temperature: return foot.label
        case .gait: return "\(foot.label) · steadiness"
        }
    }

    private func mapValue(_ foot: Foot) -> String {
        guard let r = reading[foot] else { return viewModel.anyConnected ? "Not connected" : "—" }
        switch map {
        case .pressure: return r.pressureBalance.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        case .temperature: return r.footTemperatureC.map { TemperatureFormat.degrees($0, in: unit) } ?? "—"
        case .gait: return r.gaitStability.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        }
    }

    private var pressureNote: String {
        reading.present.contains(where: \.loadIsArchLevel)
            ? "One sensor per insole, at the arch. The rest isn't measured."
            : "Load from the insole's sensors. The rest isn't measured."
    }

    @ViewBuilder
    private var legend: some View {
        switch map {
        case .pressure:
            FootScaleLegend(colors: FootScale.loadGradient, top: "High", bottom: "Low")
        case .temperature:
            FootScaleLegend(colors: FootScale.thermalGradient,
                            top: TemperatureFormat.degrees(FootScale.thermalRangeC.upperBound, in: unit, decimals: 0),
                            bottom: TemperatureFormat.degrees(FootScale.thermalRangeC.lowerBound, in: unit, decimals: 0))
        case .gait:
            EmptyView()
        }
    }

    // MARK: Metrics

    private var metrics: some View {
        HStack(alignment: .top, spacing: Thermyx.Space.xl) {
            MetricTile(
                label: "Air outside",
                value: air.map { TemperatureFormat.degrees($0.airC, in: unit) },
                accessibilityValue: air.map { "\(TemperatureFormat.full($0.airC, in: unit)), from local weather" }
            )
            MetricTile(
                label: "Steps today",
                value: stepsToday.map { Int($0.rounded()).formatted() }
            )
            if viewModel.bothConnected {
                MetricTile(label: "Left–right gap", value: reading.asymmetryIndex.map { "\(Int(($0 * 100).rounded()))%" },
                           tint: (reading.asymmetryIndex ?? 0) > 0.5 ? Thermyx.Ink.amber : Thermyx.Ink.textPrimary)
            } else {
                MetricTile(label: "Cadence", value: reading.cadenceStepsPerMinute.map { "\(Int($0.rounded())) spm" })
            }
        }
        .padding(.top, 14)
        .overlay(alignment: .top) { ThermyxDivider() }
    }

    /// Steps so far today, from the foot that recorded more of them.
    private var stepsToday: Double? {
        let calendar = Calendar.current
        let today = viewModel.history.hourSamples.filter { calendar.isDateInToday($0.start) }
        let byFoot = Dictionary(grouping: today, by: \.foot).compactMapValues { samples -> Double? in
            let steps = samples.compactMap(\.steps)
            return steps.isEmpty ? nil : steps.reduce(0, +)
        }
        return byFoot.values.max()
    }

    /// Local weather for the "Air outside" tile, only when location is
    /// already allowed: Home never prompts for it.
    private func refreshAir() async {
        guard viewModel.anyConnected, ThermyxWeather.shared.isAuthorized else { return }
        air = await ThermyxWeather.shared.current()
    }

    // MARK: Not connected

    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            Text("Thermyx shows only what your insoles measure, so nothing appears until they're connected.")
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            Button("Pair insoles") { showingDevice = true }
                .buttonStyle(ThermyxPrimaryButtonStyle())
            if isAdmin {
                Button {
                    Task { await viewModel.startDemo() }
                } label: {
                    Label(viewModel.isStartingDemo ? "Starting demo…" : "Start demo · admin", systemImage: "play.fill")
                }
                .buttonStyle(SiteTextButtonStyle(tint: Thermyx.Ink.ember))
                .disabled(viewModel.isStartingDemo)
                .accessibilityHint("Simulated insoles with made-up history, for showing Thermyx without hardware.")
            }
            if let error = viewModel.ble.errorMessage {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { ThermyxDivider() }
    }
}

/// Home: shown while any connected insole is at or below 10%.
struct LowBatteryCard: View {
    let reading: BilateralReading

    private var low: [ThermyxReading] {
        reading.present.filter { ($0.batteryPercent ?? 100) <= ThermyxComfortWatch.batteryLow }
    }

    var body: some View {
        if !low.isEmpty {
            HStack(spacing: Thermyx.Space.m) {
                Image(systemName: "battery.25percent")
                    .foregroundStyle(Thermyx.Ink.amber)
                Text(low.map { "\($0.foot.label) insole \($0.batteryPercent ?? 0)%" }.joined(separator: " · ") + ". Charge soon.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(Thermyx.Space.m)
            .background(Thermyx.Tint.amberFill, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .strokeBorder(Thermyx.Tint.amberBorder, lineWidth: Thermyx.Stroke.hairline)
            }
            .accessibilityElement(children: .combine)
        }
    }
}
