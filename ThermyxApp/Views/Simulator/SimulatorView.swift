import Charts
import SwiftUI

/// Runs a `ThermalSimulation` in time: a simulated minute every so often,
/// faster at higher speeds.
@MainActor
final class SimulatorController: ObservableObject {
    @Published private(set) var sim: ThermalSimulation
    @Published private(set) var scenario: ThermalSimulation.Scenario
    @Published private(set) var isRunning = false
    /// Simulated minutes per second.
    @Published var speed: Double = 2 { didSet { if isRunning { start() } } }

    private var clock: Task<Void, Never>?

    static let speeds: [Double] = [1, 2, 6]
    /// Stops on its own after this, so a forgotten tab doesn't run forever.
    static let maxMinutes = 240

    init(scenario: ThermalSimulation.Scenario = ThermalSimulation.Scenario.all[0]) {
        self.scenario = scenario
        self.sim = ThermalSimulation(scenario: scenario)
    }

    func load(_ scenario: ThermalSimulation.Scenario) {
        let running = isRunning
        pause()
        self.scenario = scenario
        sim = ThermalSimulation(scenario: scenario)
        if running { start() }
    }

    func reset() { load(scenario) }

    func toggle() { isRunning ? pause() : start() }

    func start() {
        clock?.cancel()
        isRunning = true
        clock = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                try? await Task.sleep(for: .seconds(1 / self.speed))
                guard !Task.isCancelled else { return }
                if self.sim.minute >= Self.maxMinutes { self.pause(); return }
                self.sim.step()
            }
        }
    }

    func pause() {
        clock?.cancel()
        clock = nil
        isRunning = false
    }

    /// Runs `minutes` simulated minutes at once.
    func advance(minutes: Int) {
        for _ in 0..<min(minutes, Self.maxMinutes) { sim.step() }
    }

    func update(_ change: (inout ThermalSimulation.Conditions) -> Void) { sim.update(change) }
    func perform(_ recovery: ThermalSimulation.Recovery) { sim.perform(recovery) }
    func setBattery(_ percent: Double) { sim.setBattery(percent) }
}

/// The Simulator tab.
struct SimulatorTab: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @StateObject private var controller = SimulatorController()

    var body: some View {
        SimulatorView(controller: controller, settings: settings)
            .onDisappear { controller.pause() }
            #if DEBUG
            // `-ThermyxSimulatorAdvance <minutes>`: opens part-way through a
            // run, so the charts can be reviewed without waiting.
            .task {
                let arguments = ProcessInfo.processInfo.arguments
                guard let i = arguments.firstIndex(of: "-ThermyxSimulatorAdvance"), i + 1 < arguments.count,
                      let minutes = Int(arguments[i + 1]), controller.sim.minute == 0 else { return }
                controller.advance(minutes: minutes)
            }
            #endif
    }
}

/// The Thermal Safety Simulator: conditions on one side, Thermyx's real
/// decision engine on the other. Labelled simulated throughout.
struct SimulatorView: View {
    @ObservedObject var controller: SimulatorController
    @ObservedObject var settings: ThermyxSettingsStore

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var map: HomeMap = .pressure
    @State private var showsAllEvents = false
    @State private var showsModel = false
    @State private var conditionsGroup: ConditionsGroup = .weather

    /// The conditions, one group at a time, so the page stays short.
    enum ConditionsGroup: String, CaseIterable, Identifiable {
        case weather, activity, footwear, wearer, insoles
        var id: String { rawValue }
        var label: String {
            switch self {
            case .weather: return "Weather"
            case .activity: return "Activity"
            case .footwear: return "Shoes"
            case .wearer: return "You"
            case .insoles: return "Insoles"
            }
        }
    }

    private var sim: ThermalSimulation { controller.sim }
    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var c: ThermalSimulation.Conditions { sim.conditions }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                scenarios.padding(.top, Thermyx.Space.titleGap)
                    .spotlightTarget(.simulatorControls)
                transport.padding(.top, Thermyx.Space.m)
                hero.padding(.top, Thermyx.Space.group)
                riskScale.padding(.top, Thermyx.Space.xl)
                recovery.padding(.top, Thermyx.Space.group)
                mapTabs.padding(.top, Thermyx.Space.group)
                maps.padding(.top, Thermyx.Space.xl)
                controls.padding(.top, Thermyx.Space.section).id("controls")
                comparison.padding(.top, Thermyx.Space.section).id("comparison")
                decisions.padding(.top, Thermyx.Space.section)
                model.padding(.top, Thermyx.Space.section)
                Color.clear.frame(height: 1).id("end")
            }
            .padding(.horizontal, Thermyx.Space.screen)
            .padding(.bottom, Thermyx.Space.section)
        }
        .debugScroll(proxy)
        }
        .scrollIndicators(.hidden)
        .thermyxTopScrim()
    }

    // MARK: Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.item) {
            HStack(alignment: .center) {
                Text("Simulator")
                    .font(ThermyxFont.screenTitle)
                    .tracking(ThermyxTracking.screenTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .accessibilityAddTraits(.isHeader)
            }
            .padding(.top, Thermyx.Space.titleTop)
            Text("Try conditions you can't safely create for real, and watch Thermyx's actual decision engine respond. Nothing here is your data, and none of it is medical advice.")
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var scenarios: some View {
        ScrollView(.horizontal) {
            HStack(spacing: 8) {
                ForEach(ThermalSimulation.Scenario.all) { s in
                    let selected = s.id == controller.scenario.id
                    Button {
                        withAnimation(SiteMotion.settle) { controller.load(s) }
                    } label: {
                        Text(s.title)
                            .font(.custom(ThermyxFont.Family.medium, size: 14, relativeTo: .subheadline))
                            .foregroundStyle(selected ? Thermyx.Ink.onPrimary : Thermyx.Ink.textPrimary)
                            .padding(.horizontal, 16)
                            .frame(height: 40)
                            .background(selected ? Thermyx.Ink.textPrimary : .clear, in: Capsule())
                            .overlay { Capsule().strokeBorder(selected ? .clear : Thermyx.Tint.neutralBorder, lineWidth: 1) }
                            .contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                    .accessibilityHint(s.summary)
                }
            }
        }
        .scrollIndicators(.hidden)
        .sensoryFeedback(.selection, trigger: controller.scenario.id)
        .overlay(alignment: .bottomLeading) {
            Text(controller.scenario.summary)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .offset(y: 24)
                .animation(SiteMotion.settle, value: controller.scenario.id)
        }
        .padding(.bottom, 24)
    }

    private var transport: some View {
        HStack(spacing: Thermyx.Space.m) {
            Button {
                controller.toggle()
            } label: {
                Image(systemName: controller.isRunning ? "pause.fill" : "play.fill")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Thermyx.Ink.onPrimary)
                    .frame(width: 48, height: 48)
                    .background(Thermyx.Ink.textPrimary, in: Circle())
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel(controller.isRunning ? "Pause simulation" : "Run simulation")

            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Minute \(sim.minute)")
                    .font(ThermyxFont.monoBody)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .contentTransition(.numericText(value: Double(sim.minute)))
                    .lineLimit(1)
                    .fixedSize()
                Text(controller.isRunning ? "Running" : sim.minute == 0 ? "Ready" : "Paused")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            Spacer(minLength: 0)
            ThermyxSegmentedControl(options: SimulatorController.speeds, label: { "\(Int($0))×" },
                                    selection: $controller.speed, accessibilityPrefix: "Speed ")
                .fixedSize()
            Button {
                controller.reset()
            } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(PressScaleStyle())
            .accessibilityLabel("Restart scenario")
        }
    }

    // MARK: Readout

    private var hero: some View {
        HStack(alignment: .bottom) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 2) {
                    Text(sim.reportedPeak.map { TemperatureFormat.value($0, in: unit) } ?? "—")
                        .font(ThermyxFont.heroNumeral)
                        .tracking(ThermyxTracking.heroNumeral)
                        .monospacedDigit()
                        .foregroundStyle(sim.reportedPeak == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                        .contentTransition(.numericText(value: sim.reportedPeak ?? 0))
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
                Text(sim.assessment.level == .unavailable ? "No reading" : sim.assessment.level.rawValue)
                    .font(ThermyxFont.riskHeadline)
                    .foregroundStyle(sim.assessment.level.tint)
                Text(actionText)
                    .font(ThermyxFont.monoCaption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            .padding(.bottom, 4)
        }
        .animation(SiteMotion.settle, value: sim.minute)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Simulated reading")
        .accessibilityValue([heroCaption, sim.reportedPeak.map { TemperatureFormat.full($0, in: unit) },
                             sim.assessment.level.rawValue, actionText].compactMap { $0 }.joined(separator: ", "))
    }

    private var heroCaption: String {
        let reading = sim.reading
        guard reading.hasAny else { return "Simulated · no insoles reporting" }
        guard sim.reportedPeak != nil else { return "Simulated · temperature not reporting" }
        if let hotter = reading.hotterFoot { return "Simulated · warmer foot, \(hotter.label.lowercased())" }
        return "Simulated · warmer foot"
    }

    private var actionText: String {
        switch sim.action {
        case .cooling, .ventilation: return "Insoles cooling"
        case .heating: return "Insoles heating"
        case .off: return sim.setting == .off ? "Thermal off" : "Insoles idle"
        }
    }

    private var riskScale: some View {
        HStack(spacing: 4) {
            ForEach(ThermyxRiskLevel.ladder, id: \.self) { level in
                let current = level == sim.assessment.level
                VStack(alignment: .leading, spacing: 6) {
                    Capsule().fill(current ? level.tint : Thermyx.Tint.track).frame(height: 3)
                    Text(level.rawValue)
                        .font(ThermyxFont.zoneLabel)
                        .foregroundStyle(current ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .animation(SiteMotion.settle, value: sim.assessment.level)
        .accessibilityHidden(true)
    }

    // MARK: Maps

    private var mapTabs: some View {
        HStack(alignment: .bottom) {
            HStack(spacing: 22) {
                ForEach(HomeMap.allCases) { option in
                    let selected = option == map
                    Button {
                        withAnimation(SiteMotion.settle) { map = option }
                    } label: {
                        Text(option.label)
                            .font(ThermyxFont.controlLabel)
                            .foregroundStyle(selected ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(selected ? Thermyx.Ink.ice : .clear).frame(height: 2)
                            }
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
            }
            Spacer(minLength: Thermyx.Space.s)
            Text(gaitLine)
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.ice)
                .padding(.bottom, 10)
        }
        .overlay(alignment: .bottom) { ThermyxDivider() }
    }

    private var gaitLine: String {
        let a = sim.effectiveActivity
        return a.cadence > 0 ? "\(a.label) · \(Int(a.cadence)) spm" : a.label
    }

    private var maps: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 15.0, paused: reduceMotion || map == .temperature)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            HStack(alignment: .top, spacing: 0) {
                Spacer(minLength: 0)
                HStack(alignment: .top, spacing: 30) {
                    ForEach(Foot.allCases) { foot in
                        VStack(spacing: 10) {
                            FootMap(foot: foot, content: content(foot, time: t))
                                .frame(width: 126, height: 300)
                            VStack(spacing: 1) {
                                Text(mapKey(foot))
                                    .font(ThermyxFont.captionSmall)
                                    .foregroundStyle(Thermyx.Ink.textMuted)
                                Text(mapValue(foot))
                                    .font(.custom(ThermyxFont.Family.monoMedium, size: 16, relativeTo: .body))
                                    .foregroundStyle(Thermyx.Ink.textPrimary)
                            }
                        }
                    }
                }
                Spacer(minLength: 0)
            }
        }
        .overlay(alignment: .topTrailing) { legend.padding(.top, 40) }
        .overlay(alignment: .bottom) {
            Text("Simulated across the whole sole. Your insoles measure the arch and one temperature.")
                .font(ThermyxFont.zoneLabel)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .multilineTextAlignment(.center)
                .offset(y: 30)
        }
        .padding(.bottom, 30)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Simulated \(map.label.lowercased()) maps")
        .accessibilityValue(Foot.allCases.map { "\($0.label): \(mapValue($0))" }.joined(separator: ", "))
    }

    private func content(_ foot: Foot, time: TimeInterval) -> FootMap.Content {
        guard sim.reading[foot] != nil else { return .outline(dimmed: true) }
        let activity = sim.effectiveActivity
        let loading = SimulatedFoot.Loading(
            intensity: (activity == .resting ? 0.35 : 0.75 + 0.5 * sim.archLoad(foot)) * (reduceMotion ? 1 : 1),
            fit: c.fit
        )
        switch map {
        case .pressure:
            let phase = reduceMotion ? nil : SimulatedFoot.phase(time: time, cadence: activity.cadence, foot: foot)
            return .field(SimulatedFoot.pressureField(phase: phase, loading: loading),
                          centreOfPressure: activity.cadence > 0 ? SimulatedFoot.centreOfPressure : nil, copProgress: phase)
        case .temperature:
            let mean = sim.footC[foot] ?? 30
            return .field(SimulatedFoot.temperatureField(meanC: mean, foot: foot), centreOfPressure: nil, copProgress: nil)
        case .gait:
            let phase = reduceMotion ? nil : SimulatedFoot.phase(time: time, cadence: activity.cadence, foot: foot)
            return .field(FootField(value: { m, v in
                let p = SimulatedFoot.pressure(m: m, v: v, weights: SimulatedFoot.weights(phase: phase), loading: loading)
                return p * 0.45
            }, scale: .load, bands: 8), centreOfPressure: SimulatedFoot.centreOfPressure, copProgress: phase)
        }
    }

    private func mapKey(_ foot: Foot) -> String {
        guard let r = sim.reading[foot] else { return "\(foot.label) · off" }
        switch map {
        case .pressure: return "\(foot.label) · arch"
        case .temperature: return foot.label
        case .gait: return r.cadenceStepsPerMinute.map { $0 > 0 ? "\(foot.label) · \(Int($0)) spm" : "\(foot.label) · still" } ?? foot.label
        }
    }

    private func mapValue(_ foot: Foot) -> String {
        guard let r = sim.reading[foot] else { return "—" }
        switch map {
        case .pressure: return r.pressureBalance.map { "\(Int(($0 * 100).rounded()))%" } ?? "—"
        case .temperature: return r.footTemperatureC.map { TemperatureFormat.degrees($0, in: unit) } ?? "—"
        case .gait: return r.gaitStability.map { "\(Int(($0 * 100).rounded()))% steady" } ?? "—"
        }
    }

    @ViewBuilder
    private var legend: some View {
        switch map {
        case .pressure, .gait:
            FootScaleLegend(colors: FootScale.loadGradient, top: "High", bottom: "Low")
        case .temperature:
            FootScaleLegend(colors: FootScale.thermalGradient,
                            top: TemperatureFormat.degrees(FootScale.thermalRangeC.upperBound, in: unit, decimals: 0),
                            bottom: TemperatureFormat.degrees(FootScale.thermalRangeC.lowerBound, in: unit, decimals: 0))
        }
    }

    // MARK: With and without

    private var comparison: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            HStack(alignment: .firstTextBaseline) {
                Text("With and without Thermyx")
                    .font(ThermyxFont.sectionTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                HStack(spacing: 12) {
                    ChartLegendChip(scale: .footTemperature(unit), over: thermalKey, label: "With", glyph: .line)
                    ChartLegendChip(color: Thermyx.Ink.textMuted, label: "Without", glyph: .dashed)
                }
            }
            if sim.samples.count < 2 {
                Text("Press play. The same feet run twice: once with the insoles heating and cooling, once with them off.")
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .topLeading)
            } else {
                Chart {
                    RuleMark(y: .value("Hot", unit.convert(38)))
                        .foregroundStyle(Thermyx.Ink.ember.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    RuleMark(y: .value("Cold", unit.convert(ThermyxRiskEngine.coldFootC)))
                        .foregroundStyle(Thermyx.Ink.signal.opacity(0.5))
                        .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                    ForEach(sim.samples, id: \.minute) { s in
                        LineMark(x: .value("Minute", s.minute), y: .value("Without", unit.convert(s.passiveC)), series: .value("Run", "Without"))
                            .foregroundStyle(runStyle(\.passiveC, opacity: 0.5))
                            .lineStyle(StrokeStyle(lineWidth: 1.5, dash: [4, 4]))
                        LineMark(x: .value("Minute", s.minute), y: .value("With", unit.convert(s.trueC)), series: .value("Run", "With"))
                            .foregroundStyle(runStyle(\.trueC, opacity: 1))
                            .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                    }
                }
                .chartYScale(domain: .automatic(includesZero: false))
                .chartXAxis {
                    AxisMarks(values: .automatic(desiredCount: 4)) { value in
                        AxisValueLabel {
                            if let m = value.as(Int.self) { Text("\(m) min").font(ThermyxFont.axisLabel).foregroundStyle(Thermyx.Ink.textFaint) }
                        }
                    }
                }
                .chartYAxis {
                    AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) { value in
                        AxisGridLine().foregroundStyle(Thermyx.Ink.hairline)
                        AxisValueLabel {
                            if let y = value.as(Double.self) { Text("\(Int(y.rounded()))°").font(ThermyxFont.axisLabel).foregroundStyle(Thermyx.Ink.textFaint) }
                        }
                    }
                }
                .frame(height: 150)
                .accessibilityLabel("Foot temperature with and without Thermyx")
                .accessibilityValue(comparisonSummary)

                levelStrip
                Text(comparisonSummary)
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 16)
        .overlay(alignment: .top) { ThermyxDivider() }
    }

    private var comparisonSummary: String {
        let m = sim.minutesOutsideBand
        let with = m.with == 1 ? "1 minute" : "\(m.with) minutes"
        let without = m.without == 1 ? "1 minute" : "\(m.without) minutes"
        return "Foot outside the safe band: \(with) with Thermyx, \(without) without."
    }

    /// One tick per simulated minute, in that minute's level colour.
    private var levelStrip: some View {
        GeometryReader { proxy in
            let samples = sim.samples
            let w = proxy.size.width / CGFloat(max(samples.count, 1))
            HStack(spacing: 0) {
                ForEach(samples, id: \.minute) { s in
                    Rectangle().fill(s.level == .unavailable ? Thermyx.Tint.track : s.level.tint).frame(width: w)
                }
            }
        }
        .frame(height: 4)
        .clipShape(Capsule())
        .accessibilityHidden(true)
    }

    private var thermalKey: ClosedRange<Double> {
        unit.convert(FootScale.thermalRangeC.lowerBound)...unit.convert(FootScale.thermalRangeC.upperBound)
    }

    /// A run's line, coloured by temperature over its own range, as every
    /// temperature chart in the app is.
    private func runStyle(_ path: KeyPath<ThermalSimulation.Sample, Double>, opacity: Double) -> LinearGradient {
        let values = sim.samples.map { unit.convert($0[keyPath: path]) }
        return ChartValueScale.footTemperature(unit).gradient(from: values.min() ?? 0, to: values.max() ?? 0) { _ in opacity }
    }

    // MARK: Decisions

    private var decisions: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("What Thermyx decided")
                    .font(ThermyxFont.sectionTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                if sim.events.count > 3 {
                    Button(showsAllEvents ? "Fewer" : "All \(sim.events.count)") {
                        withAnimation(SiteMotion.settle) { showsAllEvents.toggle() }
                    }
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.ice)
                }
            }
            .padding(.bottom, 6)
            let events = Array(sim.events.reversed().prefix(showsAllEvents ? 60 : 3))
            ForEach(events) { event in
                HStack(alignment: .top, spacing: 14) {
                    Text(verbatim: "\(event.minute)′")
                        .font(ThermyxFont.monoCaption)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .frame(width: 34, alignment: .trailing)
                    Circle()
                        .fill(dot(event.kind))
                        .frame(width: 7, height: 7)
                        .padding(.top, 6)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(event.title)
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(event.detail)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 8)
                .accessibilityElement(children: .combine)
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .padding(.top, Thermyx.Space.xl)
        .overlay(alignment: .top) { ThermyxDivider() }
        .animation(SiteMotion.settle, value: sim.events.count)
    }

    // MARK: Recovery

    /// What the simulated wearer can do mid-run, one tap each, kept by the
    /// readout so the effect is right there.
    private var recovery: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.item) {
            Text("Try a recovery")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
            ScrollView(.horizontal) {
                HStack(spacing: Thermyx.Space.xs) {
                    ForEach(ThermalSimulation.Recovery.allCases) { action in
                        Button {
                            controller.perform(action)
                        } label: {
                            Label(action.label, systemImage: action.symbol)
                                .font(.custom(ThermyxFont.Family.medium, size: 14, relativeTo: .subheadline))
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                                .padding(.horizontal, 14)
                                .frame(height: 40)
                                .overlay { Capsule().strokeBorder(Thermyx.Site.hairlineStrong, lineWidth: 1) }
                                .contentShape(Capsule())
                        }
                        .buttonStyle(PressScaleStyle())
                    }
                }
            }
            .scrollIndicators(.hidden)
        }
    }

    private func dot(_ kind: ThermalSimulation.Event.Kind) -> Color {
        switch kind {
        case .level(let level): return level.tint
        case .device: return Thermyx.Ink.signal
        case .alert: return Thermyx.Ink.ember
        case .wearer: return Thermyx.Ink.textPrimary
        case .note: return Thermyx.Ink.textFaint
        }
    }

    // MARK: Controls

    private var controls: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            Text("Conditions")
                .font(ThermyxFont.sectionTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .accessibilityAddTraits(.isHeader)
            HStack(spacing: 18) {
                ForEach(ConditionsGroup.allCases) { group in
                    let selected = group == conditionsGroup
                    Button {
                        withAnimation(SiteMotion.settle) { conditionsGroup = group }
                    } label: {
                        Text(group.label)
                            .font(ThermyxFont.controlLabel)
                            .foregroundStyle(selected ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.bottom, 10)
                            .overlay(alignment: .bottom) {
                                Rectangle().fill(selected ? Thermyx.Ink.ice : .clear).frame(height: 2)
                            }
                            .frame(minHeight: 36, alignment: .bottom)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
                }
                Spacer(minLength: 0)
            }
            .overlay(alignment: .bottom) { ThermyxDivider() }
            .sensoryFeedback(.selection, trigger: conditionsGroup)

            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                conditions(conditionsGroup)
            }
            .padding(Thermyx.Space.xl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .siteGlass(radius: Thermyx.Radius.list)
            .id(conditionsGroup)
            .transition(.opacity)
        }
        .padding(.top, Thermyx.Space.xl)
        .overlay(alignment: .top) { ThermyxDivider() }
    }

    @ViewBuilder
    private func conditions(_ group: ConditionsGroup) -> some View {
        switch group {
        case .weather:
            sliderRow("Air", value: c.airC, range: -20...45, step: 1,
                      display: TemperatureFormat.degrees(c.airC, in: unit, decimals: 0)) { v in controller.update { $0.airC = v } }
            sliderRow("Humidity", value: c.humidity * 100, range: 0...100, step: 5,
                      display: "\(Int((c.humidity * 100).rounded()))%") { v in controller.update { $0.humidity = v / 100 } }
            toggleRow("In the sun", isOn: c.sun) { v in controller.update { $0.sun = v } }
        case .activity:
            ThermyxSegmentedControl(options: ThermalSimulation.Activity.allCases, label: \.label,
                                    selection: binding(\.activity))
            sliderRow("Pack", value: c.packKg, range: 0...40, step: 2, display: "\(Int(c.packKg)) kg") { v in controller.update { $0.packKg = v } }
        case .footwear:
            ThermyxSegmentedControl(options: ThermalSimulation.Footwear.allCases, label: \.label,
                                    selection: binding(\.footwear))
            labeledSegment("Fit", options: ThermalSimulation.Fit.allCases, label: \.label, selection: binding(\.fit))
            toggleRow("Wet inside", isOn: c.wet) { v in controller.update { $0.wet = v } }
        case .wearer:
            toggleRow("Heat-acclimatized", isOn: c.acclimatized) { v in controller.update { $0.acclimatized = v } }
            toggleRow("Favouring the left foot", isOn: c.favouring) { v in controller.update { $0.favouring = v } }
            HStack {
                Text("Hydration")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                Text("\(Int((sim.hydration * 100).rounded()))%")
                    .font(ThermyxFont.monoBody)
                    .foregroundStyle(sim.hydration < 0.45 ? Thermyx.Ink.amber : Thermyx.Ink.textMuted)
            }
            .accessibilityElement(children: .combine)
        case .insoles:
            Text("These drive the simulation only. The bar at the bottom still controls your real insoles.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            labeledSegment("Mode", options: ThermalSetting.cycle, label: \.label, selection: binding(\.setting))
            sliderRow("Auto target", value: c.targetC, range: ThermyxSettingsStore.targetRange, step: 0.5,
                      display: TemperatureFormat.degrees(c.targetC, in: unit)) { v in controller.update { $0.targetC = v } }
            labeledSegment("Connected", options: ThermalSimulation.Connection.allCases, label: \.label, selection: binding(\.connection))
            HStack {
                Text("Fault")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                Picker("Fault", selection: binding(\.fault)) {
                    ForEach(ThermalSimulation.Fault.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                .tint(Thermyx.Ink.ice)
            }
            sliderRow("Battery", value: sim.battery, range: 0...100, step: 5,
                      display: "\(Int(sim.battery.rounded()))%") { v in controller.setBattery(v) }
        }
    }

    private func binding<V>(_ key: WritableKeyPath<ThermalSimulation.Conditions, V>) -> Binding<V> {
        Binding(get: { controller.sim.conditions[keyPath: key] }, set: { v in controller.update { $0[keyPath: key] = v } })
    }

    private func labeledSegment<V: Hashable>(_ title: String, options: [V], label: @escaping (V) -> String, selection: Binding<V>) -> some View {
        HStack {
            Text(title)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            Spacer(minLength: Thermyx.Space.m)
            ThermyxSegmentedControl(options: options, label: label, selection: selection, accessibilityPrefix: "\(title) ")
                .fixedSize()
        }
    }

    private func toggleRow(_ title: String, isOn: Bool, set: @escaping (Bool) -> Void) -> some View {
        Toggle(isOn: Binding(get: { isOn }, set: set)) {
            Text(title)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
        }
        .tint(Thermyx.Ink.signal)
    }

    private func sliderRow(_ title: String, value: Double, range: ClosedRange<Double>, step: Double,
                           display: String, set: @escaping (Double) -> Void) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                Text(display)
                    .font(ThermyxFont.monoBody)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            Slider(value: Binding(get: { value }, set: set), in: range, step: step)
                .tint(Thermyx.Ink.signal)
                .accessibilityLabel(title)
                .accessibilityValue(display)
        }
    }

    // MARK: Model

    private var model: some View {
        ThermyxDisclosure(title: "How the simulator works", isExpanded: $showsModel) {
            EmptyView()
        } content: {
            paragraph("Each simulated minute, a simple model moves your feet toward a temperature set by the air, your shoes, how hard you're working and how heat-strained you are. It's illustrative, not a physiological model.")
            paragraph("What's real is everything after that. The simulated insoles report only what real ones measure: foot temperature, one arch load and motion. Thermyx's actual risk engine and personal trend rules decide the level, the heat lockout works as in the app, and Auto, Cool, Heat and the 40° burn cutoff behave as the firmware does.")
            paragraph("The insoles don't sense the air or your core temperature. Hot weather reaches the decision only through your feet, which is why the level can lag the weather.")
            paragraph("Nothing is sent from the simulator: no notifications, no alerts to your circle, no calls.")
        }
    }

    private func paragraph(_ text: String) -> some View {
        Text(text)
            .font(ThermyxFont.bodySmall)
            .foregroundStyle(Thermyx.Ink.textMuted)
            .fixedSize(horizontal: false, vertical: true)
    }
}
