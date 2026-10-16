import Charts
import SwiftUI

// MARK: - Plan
//
// Three minutes: sit, stand and walk for 30 seconds each indoors, then the
// same outside. Each second of readings is recorded, and the on-device model
// in PersonalBaseline.swift is trained from the result: usual temperatures
// indoors and out, how fast the foot warms (dT/dt) and how far it moves
// (∫ dT/dt dt), load, cadence and walking steadiness.

struct CalibrationStep: Equatable {
    let activity: CalibrationActivity
    let outdoor: Bool
    let title: String
    let instruction: String
}

enum CalibrationPlan {
    static let secondsPerStep = 30
    /// A step counts only with at least this many seconds of readings.
    static let minimumSeconds = 20

    static let steps: [CalibrationStep] = [
        .init(activity: .sitting, outdoor: false, title: "Sit", instruction: "Sit comfortably with both feet flat on the floor."),
        .init(activity: .standing, outdoor: false, title: "Stand", instruction: "Stand still, weight on both feet."),
        .init(activity: .walking, outdoor: false, title: "Walk", instruction: "Walk around at your normal pace."),
        .init(activity: .sitting, outdoor: true, title: "Sit", instruction: "Sit or rest outside without moving much."),
        .init(activity: .standing, outdoor: true, title: "Stand", instruction: "Stand still outside."),
        .init(activity: .walking, outdoor: true, title: "Walk", instruction: "Walk outside at your normal pace."),
    ]

    static var indoorCount: Int { steps.filter { !$0.outdoor }.count }
    static var totalSeconds: Int { steps.count * secondsPerStep }
}

// MARK: - Engine

@MainActor
final class CalibrationEngine: ObservableObject {
    enum Phase: Equatable {
        /// Readouts live, waiting for Start.
        case ready
        case running
        /// Indoor half done; waiting for the wearer to step outside.
        case outside
        case done
    }

    struct TracePoint: Identifiable {
        let id: Int
        let second: Int
        let footC: Double
    }

    @Published private(set) var phase: Phase = .ready
    @Published private(set) var index = 0
    @Published private(set) var elapsed = 0
    @Published private(set) var isPaused = false
    /// "How do your feet feel?" −1 cold … +1 warm, asked while sitting.
    @Published var comfort: Double?
    @Published private(set) var model: PersonalThermalModel?
    /// This step's readings so far.
    @Published private(set) var current: [CalibrationSample] = []
    /// Foot temperature over the whole session, for the chart.
    @Published private(set) var trace: [TracePoint] = []
    /// One summary per step that had enough readings.
    @Published private(set) var summaries: [CalibrationPhaseSummary] = []
    /// Each finished step's readings, by summary id, for showing the math.
    @Published private(set) var phaseSamples: [String: [CalibrationSample]] = [:]
    /// Steps that ended without enough readings.
    @Published private(set) var skipped: Set<Int> = []
    /// Local weather while outside: the insole has no air sensor.
    @Published private(set) var outdoorAir: ThermyxWeather.Current?
    /// Set once any step ran on the fake insole; the model is then test data.
    @Published private(set) var usedTestData = false

    var step: CalibrationStep { CalibrationPlan.steps[min(index, CalibrationPlan.steps.count - 1)] }
    var remaining: Int { max(0, CalibrationPlan.secondsPerStep - elapsed) }
    var stepProgress: Double { Double(elapsed) / Double(CalibrationPlan.secondsPerStep) }
    var liveRate: Double? { ThermalCalculus.rate(current) }
    var liveAccumulated: Double? { ThermalCalculus.accumulatedChange(current) }
    var isFakeInsole: Bool { viewModel?.ble.isFakeInsole == true }
    var asksComfort: Bool { phase == .running && index == 0 && elapsed >= 8 && comfort == nil }

    private var segments: [CalibrationTrainer.Segment] = []
    private var timer: Timer?
    /// The wearer's thermal setting before calibration paused it.
    private var pausedSetting: ThermalSetting?
    private var traceSecond = 0
    private weak var viewModel: ThermyxViewModel?
    private let settings: ThermyxSettingsStore

    private static let indoorKey = "thermyx.calibration.indoor"
    private static let comfortKey = "thermyx.calibration.comfort"

    init(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore, outdoorOnly: Bool = false) {
        self.viewModel = viewModel
        self.settings = settings
        if outdoorOnly, let saved = Self.loadIndoor() {
            segments = saved
            summaries = saved.map { CalibrationPhaseSummary(activity: $0.activity, outdoor: false, samples: $0.samples) }
            index = CalibrationPlan.indoorCount
            traceSecond = CalibrationPlan.indoorCount * CalibrationPlan.secondsPerStep
            comfort = UserDefaults.standard.object(forKey: Self.comfortKey) as? Double
        }
    }

    func start() {
        phase = .running
        pauseThermal()
        beginStep()
    }

    /// After the indoor half: the wearer is outside.
    func goOutside() {
        Task { [weak self] in
            let weather = await ThermyxWeather.shared.current()
            self?.outdoorAir = weather
            if let air = weather?.airC, self?.model != nil { self?.model?.outdoorAirC = air }
        }
        phase = .running
        pauseThermal()
        beginStep()
    }

    func togglePause() { isPaused.toggle() }

    func skipStep() { finishStep(keep: false) }

    func stop() {
        timer?.invalidate()
        timer = nil
        restoreThermal()
    }

    /// Heating and cooling pause while calibration records, so it learns
    /// the feet's own temperature, not the insole's. The insoles keep
    /// sensing, and every safety rule keeps running.
    private func pauseThermal() {
        guard let viewModel, pausedSetting == nil, viewModel.isControlAvailable else { return }
        pausedSetting = viewModel.thermalSetting
        if viewModel.thermalSetting != .off { viewModel.select(.off) }
    }

    private func restoreThermal() {
        guard let viewModel, let setting = pausedSetting else { return }
        pausedSetting = nil
        if setting != .off { viewModel.select(setting) }
    }

    private func beginStep() {
        if isFakeInsole {
            usedTestData = true
            viewModel?.ble.simulator?.setScript(activity: step.activity, outdoor: step.outdoor)
        }
        elapsed = 0
        current = []
        isPaused = false
        traceSecond = index * CalibrationPlan.secondsPerStep
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard phase == .running, !isPaused, let viewModel else { return }
        let reading = viewModel.reading
        if reading.hasAny {
            let sample = CalibrationSample(reading)
            current.append(sample)
            if let c = sample.footC { trace.append(TracePoint(id: trace.count, second: traceSecond, footC: c)) }
        }
        traceSecond += 1
        elapsed += 1
        if elapsed >= CalibrationPlan.secondsPerStep { finishStep(keep: true) }
    }

    private func finishStep(keep: Bool) {
        timer?.invalidate()
        timer = nil
        if keep, current.count >= CalibrationPlan.minimumSeconds {
            segments.append(.init(activity: step.activity, outdoor: step.outdoor, samples: current))
            let summary = CalibrationPhaseSummary(activity: step.activity, outdoor: step.outdoor, samples: current)
            summaries.append(summary)
            phaseSamples[summary.id] = current
        } else {
            skipped.insert(index)
        }
        current = []
        let next = index + 1
        if next == CalibrationPlan.indoorCount {
            restoreThermal()
            train()
            if !usedTestData { Self.saveIndoor(segments.filter { !$0.outdoor }) }
            index = next
            phase = .outside
        } else if next >= CalibrationPlan.steps.count {
            restoreThermal()
            train()
            phase = .done
        } else {
            index = next
            beginStep()
        }
    }

    private func train() {
        if let comfort, !usedTestData { UserDefaults.standard.set(comfort, forKey: Self.comfortKey) }
        guard var trained = CalibrationTrainer.train(segments: segments, comfort: comfort) else {
            model = nil
            return
        }
        if usedTestData { trained.fromTestData = true }
        trained.outdoorAirC = outdoorAir?.airC
        model = trained
        let indoor = segments.filter { !$0.outdoor }.flatMap(\.samples)
        viewModel?.applyCalibration(trained, indoorSamples: indoor, settings: settings)
    }

    /// A full calibration trained on the scripted insole's data, marked as
    /// test data, for the demo. It never seeds the baseline, and leaving the
    /// demo clears it.
    static func demoModel() -> PersonalThermalModel? {
        let segments = CalibrationPlan.steps.map { step in
            CalibrationTrainer.Segment(activity: step.activity, outdoor: step.outdoor,
                                       samples: FakeInsoleScript.samples(activity: step.activity, outdoor: step.outdoor,
                                                                         seconds: CalibrationPlan.secondsPerStep))
        }
        guard var model = CalibrationTrainer.train(segments: segments, comfort: 0) else { return nil }
        model.fromTestData = true
        return model
    }

    #if DEBUG
    /// Debug builds only (the preview harness's scripted insole): fills this
    /// and every remaining step with the script instead of waiting.
    func useFakeRecording() {
        guard isFakeInsole else { return }
        stop()
        usedTestData = true
        current = []
        if comfort == nil { comfort = 0 }
        for (offset, step) in CalibrationPlan.steps.enumerated() where offset >= index {
            let samples = FakeInsoleScript.samples(activity: step.activity, outdoor: step.outdoor, seconds: CalibrationPlan.secondsPerStep)
            segments.append(.init(activity: step.activity, outdoor: step.outdoor, samples: samples))
            let summary = CalibrationPhaseSummary(activity: step.activity, outdoor: step.outdoor, samples: samples)
            summaries.append(summary)
            phaseSamples[summary.id] = samples
            for (second, sample) in samples.enumerated() {
                if let c = sample.footC {
                    trace.append(TracePoint(id: trace.count, second: offset * CalibrationPlan.secondsPerStep + second, footC: c))
                }
            }
        }
        index = CalibrationPlan.steps.count - 1
        elapsed = CalibrationPlan.secondsPerStep
        restoreThermal()
        train()
        phase = .done
    }
    #endif

    // The indoor half is kept so the outdoor half can be added later and
    // the model retrained on both.
    private static func saveIndoor(_ segments: [CalibrationTrainer.Segment]) {
        let stored = segments.map { StoredSegment(activity: $0.activity, samples: $0.samples) }
        if let data = try? JSONEncoder().encode(stored) { UserDefaults.standard.set(data, forKey: indoorKey) }
    }

    private static func loadIndoor() -> [CalibrationTrainer.Segment]? {
        guard let data = UserDefaults.standard.data(forKey: indoorKey),
              let stored = try? JSONDecoder().decode([StoredSegment].self, from: data)
        else { return nil }
        return stored.map { .init(activity: $0.activity, outdoor: false, samples: $0.samples) }
    }

    static func clearSaved() {
        UserDefaults.standard.removeObject(forKey: indoorKey)
        UserDefaults.standard.removeObject(forKey: comfortKey)
    }

    private struct StoredSegment: Codable {
        let activity: CalibrationActivity
        let samples: [CalibrationSample]
    }
}

// MARK: - Screens

/// Onboarding's calibration page.
struct OnboardingCalibrationStep: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    let onFinish: () -> Void

    var body: some View {
        CalibrationHost(viewModel: viewModel, settings: settings, finishTitle: "Enter Thermyx", skipTitle: "Calibrate later", onFinish: onFinish)
    }
}

/// Calibration on its own, full screen, from Home or Settings.
struct CalibrationView: View {
    @ObservedObject var settings: ThermyxSettingsStore
    let viewModel: ThermyxViewModel
    var outdoorOnly = false
    @Environment(\.dismiss) private var dismiss

    init(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore, outdoorOnly: Bool = false) {
        self.viewModel = viewModel
        self.settings = settings
        self.outdoorOnly = outdoorOnly
    }

    var body: some View {
        ZStack {
            TopographyBackground().opacity(0.55)
            VStack(spacing: 0) {
                HStack {
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 15, weight: .bold))
                            .foregroundStyle(Thermyx.Site.text)
                            .frame(width: 44, height: 44)
                            .siteGlass(radius: 22)
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Close")
                }
                .padding(.horizontal, Thermyx.Space.l)
                CalibrationHost(viewModel: viewModel, settings: settings, outdoorOnly: outdoorOnly,
                                finishTitle: "Done", skipTitle: "Not now") { dismiss() }
            }
        }
        .preferredColorScheme(.dark)
        .toolbar(.hidden, for: .navigationBar)
    }
}

private struct CalibrationHost: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @StateObject private var engine: CalibrationEngine
    let finishTitle: String
    let skipTitle: String
    let onFinish: () -> Void

    init(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore, outdoorOnly: Bool = false,
         finishTitle: String, skipTitle: String, onFinish: @escaping () -> Void) {
        self.settings = settings
        self.finishTitle = finishTitle
        self.skipTitle = skipTitle
        self.onFinish = onFinish
        _engine = StateObject(wrappedValue: CalibrationEngine(viewModel: viewModel, settings: settings, outdoorOnly: outdoorOnly))
    }

    var body: some View {
        CalibrationExperience(settings: settings, engine: engine, finishTitle: finishTitle, skipTitle: skipTitle, onFinish: onFinish)
            .onDisappear { engine.stop() }
            #if DEBUG
            .task {
                guard ThermyxPreviewHarness.startsCalibration, engine.phase == .ready else { return }
                try? await Task.sleep(for: .seconds(2))
                engine.start()
                if ProcessInfo.processInfo.arguments.contains("-ThermyxFakeRecording") { engine.useFakeRecording() }
            }
            #endif
    }
}

/// The calibration page: the six steps, the step in progress, and live
/// insight containers that are on screen from the start and fill in as
/// readings arrive.
private struct CalibrationExperience: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var engine: CalibrationEngine
    let finishTitle: String
    let skipTitle: String
    let onFinish: () -> Void

    @Environment(\.isThermyxAdmin) private var isAdmin
    @ObservedObject private var weather = ThermyxWeather.shared
    /// The checklist starts folded: its summary says whether it's done.
    @State private var showingChecklist = false

    private var unit: TemperatureUnit { settings.temperatureUnit }
    private var receiving: Bool { viewModel.reading.hasAny }

    /// Location, for the outdoor half's local weather.
    private var locationPrompt: some View {
        PermissionPrompt(symbol: "location.fill", title: "Location",
                         detail: "For the local air temperature outside. Only a rough area is used.",
                         status: .init(weather.authorization)) { weather.requestPermission() }
            .animation(SiteMotion.settle, value: weather.authorization)
    }
    /// Nil when the insole can't sense a foot.
    private var footOn: Bool? {
        let flags = viewModel.reading.present.compactMap(\.footDetected)
        return flags.isEmpty ? nil : flags.contains(true)
    }

    var body: some View {
        OnboardingPage(title: "Learn your feet",
                       subtitle: "Six 30-second segments, about three minutes. Thermyx learns your usual temperature and stride for each one, on this phone.") {
            stage
            SegmentTable(engine: engine)
            LiveInsights(engine: engine, reading: viewModel.reading, unit: unit)
            SessionChart(engine: engine, unit: unit)
            if !engine.summaries.isEmpty {
                LearnedSoFar(summaries: engine.summaries, samples: engine.phaseSamples, unit: unit)
            }
        } actions: {
            if engine.phase != .done {
                LiveStrip(engine: engine, reading: viewModel.reading, unit: unit)
            }
            actions
        }
        .sensoryFeedback(.success, trigger: engine.summaries.count)
        .sensoryFeedback(.impact(weight: .light), trigger: engine.index)
    }

    // MARK: Stage

    @ViewBuilder
    private var stage: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            switch engine.phase {
            case .ready:
                ThermyxDisclosure(title: "Before you start", isExpanded: $showingChecklist) {
                    ChecklistSummary(done: checklistDone, total: 3)
                } content: {
                    check(viewModel.anyConnected, "Insoles connected",
                          viewModel.anyConnected ? viewModel.connectedFeet.map(\.label).joined(separator: " and ") : "Connect your insoles first.")
                    check(receiving, "Readings arriving", receiving ? "Live data is coming in." : "Waiting for the first reading…")
                    switch footOn {
                    case .some(true): check(true, "Feet in", "You're standing on them.")
                    case .some(false): check(false, "Step in", "Put the insoles in your shoes and stand on them.")
                    case .none: check(receiving, "Insoles in your shoes", "Check they're in your shoes and you're wearing them.")
                    }
                }
                locationPrompt
            case .running:
                runningStage
            case .outside:
                SiteEyebrow("Inside done")
                Text("Now step outside")
                    .font(ThermyxFont.displaySmall)
                    .tracking(ThermyxTracking.displaySmall)
                    .foregroundStyle(Thermyx.Site.text)
                Text("The second half teaches Thermyx how your feet respond outdoors: the same three, 30 seconds each. Thermyx checks the local weather for the air temperature, since the insole has no air sensor.")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Site.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                locationPrompt
            case .done:
                doneStage
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(SiteMotion.settle, value: engine.phase)
    }

    private var runningStage: some View {
        let step = engine.step
        return VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            HStack(alignment: .center, spacing: 22) {
                HStack(spacing: 8) {
                    ForEach(Foot.allCases) { foot in
                        FootMap(foot: foot, content: liveContent(foot))
                            .frame(width: 84, height: 200)
                    }
                }
                .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Now")
                        .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .footnote))
                        .foregroundStyle(Thermyx.Ink.ice)
                    Text("\(step.outdoor ? "Outdoors" : "Indoors"), \(step.activity.label.lowercased())")
                        .font(.custom(ThermyxFont.Family.semibold, size: 20, relativeTo: .title3))
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .contentTransition(.opacity)
                    Text(verbatim: String(format: "0:%02d", engine.remaining))
                        .font(ThermyxFont.monoDisplay)
                        .tracking(ThermyxTracking.monoDisplay)
                        .foregroundStyle(engine.isPaused ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                        .contentTransition(.numericText(countsDown: true))
                        .animation(SiteMotion.settle, value: engine.remaining)
                        .padding(.top, 6)
                        .accessibilityLabel("\(engine.remaining) seconds left")
                    ProgressLine(value: engine.stepProgress)
                        .frame(height: 3)
                        .padding(.top, 4)
                }
            }
            Text(step.instruction)
                .font(ThermyxFont.bodySmall)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if step.outdoor, let air = engine.outdoorAir {
                Text("Outside air \(TemperatureFormat.degrees(air.airC, in: settings.temperatureUnit))\(air.feelsLikeC.map { " · feels like " + TemperatureFormat.degrees($0, in: settings.temperatureUnit) } ?? "") · local weather")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textMuted)
            }
            if engine.asksComfort { comfortQuestion }
            if engine.isPaused {
                Text("Paused")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textFaint)
            } else if receiving {
                Text("Heating and cooling are paused while Thermyx learns. Safety checks keep running.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text("No readings right now. Only seconds with data count.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
            }
        }
    }

    /// The live maps: only what the insole measures (the arch sensor's
    /// load, or the foot temperature when there's no load reading).
    private func liveContent(_ foot: Foot) -> FootMap.Content {
        guard let r = viewModel.reading[foot] else { return .outline(dimmed: true) }
        if r.loadIsArchLevel { return .archLoad(r.pressureBalance) }
        if r.pressureBalance != nil { return .forefootShare(r.pressureBalance) }
        return .temperature(r.footTemperatureC)
    }

    private var comfortQuestion: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            Text("How do your feet feel?")
                .font(ThermyxFont.rowTitle)
                .foregroundStyle(Thermyx.Site.text)
            HStack(spacing: Thermyx.Space.xs) {
                ForEach([(-1.0, "Cold"), (0.0, "Just right"), (1.0, "Warm")], id: \.0) { value, label in
                    Button(label) { withAnimation(SiteMotion.settle) { engine.comfort = value } }
                        .buttonStyle(SiteSecondaryButtonStyle())
                }
            }
        }
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    @ViewBuilder
    private var doneStage: some View {
        SiteEyebrow(engine.model?.outdoorDone == true ? "Inside and outside" : "Calibration")
        if let model = engine.model {
            Text("You're calibrated")
                .font(ThermyxFont.displaySmall)
                .tracking(ThermyxTracking.displaySmall)
                .foregroundStyle(Thermyx.Site.text)
            CalibrationNorms(model: model, unit: unit)
            Text("Learned on this phone from your own readings. It can only add caution, and Auto stays within 26–38 °C.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Site.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Not enough readings came in to learn from. Check the insoles are connected and try again.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// How many of the three checks pass.
    private var checklistDone: Int {
        [viewModel.anyConnected, receiving, footOn ?? receiving].filter { $0 }.count
    }

    private func check(_ done: Bool, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .font(.system(size: 20))
                .foregroundStyle(done ? Thermyx.Ink.ice : Thermyx.Site.textFaint)
                .contentTransition(.symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Site.text)
                Text(detail).font(ThermyxFont.caption).foregroundStyle(Thermyx.Site.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    // MARK: Actions

    @ViewBuilder
    private var actions: some View {
        switch engine.phase {
        case .ready:
            Button("Start calibration") { withAnimation(SiteMotion.settle) { engine.start() } }
                .buttonStyle(SitePrimaryButtonStyle())
                .disabled(!receiving || footOn == false)
            Button(skipTitle, action: onFinish)
                .buttonStyle(SiteTextButtonStyle())
        case .running:
            HStack(spacing: Thermyx.Space.s) {
                Button(engine.isPaused ? "Resume" : "Pause") { engine.togglePause() }
                    .buttonStyle(SiteSecondaryButtonStyle())
                Button("Skip step") { withAnimation(SiteMotion.settle) { engine.skipStep() } }
                    .buttonStyle(SiteSecondaryButtonStyle())
            }
        case .outside:
            Button("I'm outside") { withAnimation(SiteMotion.settle) { engine.goOutside() } }
                .buttonStyle(SitePrimaryButtonStyle())
            Button("Finish outside later", action: onFinish)
                .buttonStyle(SiteTextButtonStyle())
        case .done:
            Button(finishTitle) {
                CalibrationEngine.clearSaved()
                onFinish()
            }
            .buttonStyle(SitePrimaryButtonStyle())
        }
    }
}

// MARK: - Pieces

/// The six segments as the design's table: sitting, standing and walking,
/// indoors and outdoors, each done, running, skipped or still to come.
private struct SegmentTable: View {
    @ObservedObject var engine: CalibrationEngine

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("").frame(maxWidth: .infinity, alignment: .leading)
                Text("Indoors").frame(maxWidth: .infinity, alignment: .leading)
                Text("Outdoors").frame(maxWidth: .infinity, alignment: .leading)
            }
            .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .footnote))
            .foregroundStyle(Thermyx.Ink.textFaint)
            .padding(.bottom, 10)
            ForEach(Array(CalibrationActivity.allCases.enumerated()), id: \.offset) { row, activity in
                HStack {
                    Text(activity.label)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    cell(row)
                    cell(CalibrationPlan.indoorCount + row)
                }
                .font(.custom(ThermyxFont.Family.medium, size: 15, relativeTo: .subheadline))
                .frame(height: 48)
                .overlay(alignment: .top) { ThermyxDivider() }
            }
            ThermyxDivider()
            Text(engine.phase == .done ? "Done. Thermyx now knows your normal." : "Afterward, one question: how did your feet feel?")
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .padding(.top, 14)
        }
        .animation(SiteMotion.settle, value: engine.index)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Calibration segments")
        .accessibilityValue(accessibilityText)
    }

    @ViewBuilder
    private func cell(_ i: Int) -> some View {
        Group {
            if engine.skipped.contains(i) {
                Text("Skipped").foregroundStyle(Thermyx.Ink.amber)
            } else if engine.phase == .done || i < engine.index || (engine.phase == .outside && i < CalibrationPlan.indoorCount) {
                HStack(spacing: 6) {
                    Image(systemName: "checkmark").font(.system(size: 13, weight: .bold))
                    Text("Done")
                }
                .foregroundStyle(Thermyx.Ink.ice)
            } else if i == engine.index, engine.phase == .running {
                Text(verbatim: String(format: "0:%02d", engine.remaining))
                    .font(ThermyxFont.monoBody)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
            } else {
                Text("30 s")
                    .font(ThermyxFont.monoBody)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var accessibilityText: String {
        switch engine.phase {
        case .ready: return "Six segments, 30 seconds each. Not started."
        case .running: return "Segment \(engine.index + 1) of 6, \(engine.remaining) seconds left."
        case .outside: return "Indoor half done. Outdoor half next."
        case .done: return "All segments done."
        }
    }
}

private struct ProgressLine: View {
    let value: Double

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                Capsule().fill(Thermyx.Site.hairlineStrong)
                Capsule().fill(Thermyx.Ink.signal)
                    .frame(width: proxy.size.width * min(1, max(0, value)))
            }
        }
        .frame(height: 4)
        .animation(.linear(duration: 1), value: value)
        .accessibilityHidden(true)
    }
}

/// The live numbers, pinned above the buttons so they stay in view while
/// the wearer sits, stands and walks: each foot's temperature, how fast it's
/// moving, and load or cadence. Each is coloured on its own scale, and shows
/// a dash until the insoles report it.
private struct LiveStrip: View {
    @ObservedObject var engine: CalibrationEngine
    let reading: BilateralReading
    let unit: TemperatureUnit

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Circle()
                    .fill(reading.hasAny ? Thermyx.Ink.ice : Thermyx.Site.textFaint)
                    .frame(width: 6, height: 6)
                Text(reading.hasAny ? "Live" : "Waiting for readings")
                    .font(.custom(ThermyxFont.Family.medium, size: 12, relativeTo: .caption2))
                    .foregroundStyle(reading.hasAny ? Thermyx.Ink.ice : Thermyx.Site.textFaint)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Thermyx.Space.m)
            cells
        }
        .padding(.vertical, Thermyx.Space.s)
        .background {
            RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous).fill(.black)
        }
        .siteGlass(radius: Thermyx.Radius.compact)
        .padding(.bottom, Thermyx.Space.xs)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Live readings")
    }

    private var cells: some View {
        HStack(spacing: 0) {
            ForEach(Foot.allCases) { foot in
                cell(foot.label, value: reading[foot]?.footTemperatureC.map { TemperatureFormat.degrees($0, in: unit) },
                     tint: reading[foot]?.footTemperatureC.map(FootScale.thermalColor))
                divider
            }
            cell("dT/dt", value: engine.liveRate.map { rate in signed(unit.convertDelta(rate)) },
                 tint: engine.liveRate.map { ChartValueScale.change(unitSize: 1).color(at: $0) }, math: true)
            divider
            if let load = reading.pressureBalance {
                cell(reading.present.first?.loadIsArchLevel == true ? "Arch" : "Load", value: "\(Int((load * 100).rounded()))%",
                     tint: FootScale.loadColor(load))
            } else {
                cell("Steps", value: reading.cadenceStepsPerMinute.map { "\(Int($0.rounded()))" },
                     tint: reading.cadenceStepsPerMinute.map { ChartValueScale.cadence.color(at: $0) })
            }
        }
    }

    private var divider: some View {
        Rectangle().fill(Thermyx.Site.hairline).frame(width: 1, height: 30)
    }

    private func cell(_ label: String, value: String?, tint: Color?, math: Bool = false) -> some View {
        VStack(spacing: 2) {
            Group {
                if math { Text(label).mathNotation(size: 12) } else {
                    Text(label)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Site.textMuted)
                }
            }
            .lineLimit(1)
            Text(value ?? "—")
                .font(.custom(ThermyxFont.Family.monoMedium, size: 16, relativeTo: .body))
                .monospacedDigit()
                .foregroundStyle(value == nil ? Thermyx.Site.textFaint : (tint ?? Thermyx.Site.text))
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .contentTransition(.numericText())
        }
        .frame(maxWidth: .infinity)
        .animation(SiteMotion.settle, value: value)
    }

    private func signed(_ value: Double) -> String {
        let text = String(format: "%.2f", abs(value))
        return (Double(text) == 0 ? "" : (value > 0 ? "+" : "−")) + text
    }
}

/// The readouts, on screen before calibration starts. Each shows a dash
/// until the insoles report it; nothing here is ever estimated.
private struct LiveInsights: View {
    @ObservedObject var engine: CalibrationEngine
    let reading: BilateralReading
    let unit: TemperatureUnit
    @State private var showingMath = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SiteEyebrow(engine.phase == .running ? "Live" : "Your readings")
            LazyVGrid(columns: [GridItem(.flexible(), spacing: Thermyx.Space.s), GridItem(.flexible(), spacing: Thermyx.Space.s)],
                      spacing: Thermyx.Space.s) {
                InsightTile(title: "Foot temperature",
                            value: reading.peakFootTemperatureC.map { TemperatureFormat.degrees($0, in: unit) },
                            detail: perFoot)
                Button { showingMath = true } label: {
                    InsightTile(title: "Rate", notation: "dT/dt",
                                value: engine.liveRate.map { signed(unit.convertDelta($0), decimals: 2) + "°/min" },
                                detail: "Tap to see the math")
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Shows how the rate is calculated")
                Button { showingMath = true } label: {
                    InsightTile(title: "Change", notation: "∫ dT/dt dt",
                                value: engine.liveAccumulated.map { signed(unit.convertDelta($0), decimals: 2) + "°" },
                                detail: engine.phase == .running ? "Since this step began · tap for math" : "Builds up during each step")
                }
                .buttonStyle(PressableStyle())
                .accessibilityHint("Shows how the change is calculated")
                InsightTile(title: reading.present.first?.loadLabel ?? "Forefoot load",
                            value: reading.pressureBalance.map { "\(Int(($0 * 100).rounded()))%" },
                            detail: balance)
                InsightTile(title: "Cadence",
                            value: reading.cadenceStepsPerMinute.map { "\(Int($0.rounded()))" },
                            detail: "Steps per minute")
                InsightTile(title: "Stability",
                            value: steadiness.map { "\(Int(($0 * 100).rounded()))%" },
                            detail: stabilityDetail,
                            accent: stabilityColor)
            }
        }
        .sheet(isPresented: $showingMath) {
            LiveMathSheet(engine: engine, unit: unit)
        }
    }

    private var steadiness: Double? { reading.present.compactMap(\.gaitStability).min() }

    private var perFoot: String {
        let parts = Foot.allCases.compactMap { foot in
            reading[foot]?.footTemperatureC.map { "\(foot.shortLabel) \(TemperatureFormat.degrees($0, in: unit))" }
        }
        return parts.isEmpty ? "Warmer foot, live" : parts.joined(separator: " · ")
    }

    private var balance: String {
        guard let gap = reading.loadAsymmetry else { return "Share of weight on the toes" }
        if abs(gap) < 0.04 { return "Even, left and right" }
        return "\(gap > 0 ? "Left" : "Right") +\(Int((abs(gap) * 100).rounded())) pts"
    }

    private var level: StabilityProfile.Level? {
        guard let gait = steadiness, let profile = engine.model?.walkingStability else { return nil }
        return profile.level(gait)
    }

    private var stabilityDetail: String {
        if let level { return "\(level.label) for you" }
        if let profile = engine.model?.walkingStability {
            return "Steady above \(Int((profile.steadyFloor * 100).rounded()))% for you"
        }
        return engine.step.activity == .walking && engine.phase == .running ? "Learning your walk" : "Levels after your first walk"
    }

    private var stabilityColor: Color {
        switch level {
        case .unsteady?: return Thermyx.Ink.ember
        case .variable?: return Thermyx.Ink.amber
        default: return Thermyx.Site.text
        }
    }

    private func signed(_ value: Double, decimals: Int) -> String {
        let text = String(format: "%.\(decimals)f", abs(value))
        let zero = Double(text) == 0
        return (zero ? "" : (value > 0 ? "+" : "−")) + text
    }
}

private struct InsightTile: View {
    let title: String
    /// Mathematical notation, set as written rather than in caps.
    var notation: String?
    let value: String?
    var detail: String?
    var accent: Color = Thermyx.Site.text

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(title)
                    .narrowLabel(ThermyxFont.zoneLabel, tracking: ThermyxTracking.zoneLabel, color: Thermyx.Site.textFaint)
                if let notation {
                    Text(notation).mathNotation()
                }
            }
            .lineLimit(1)
            Text(value ?? "—")
                .font(ThermyxFont.metricNumeral)
                .tracking(ThermyxTracking.metricNumeral)
                .monospacedDigit()
                .foregroundStyle(value == nil ? Thermyx.Site.textFaint : accent)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            if let detail {
                Text(detail)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textMuted)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(Thermyx.Space.l)
        .frame(maxWidth: .infinity, minHeight: 108, alignment: .topLeading)
        .siteGlass(radius: Thermyx.Radius.compact)
        .animation(SiteMotion.settle, value: value)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(notation == nil ? title : "\(title), \(notation == "dT/dt" ? "rate of change" : "accumulated change")")
        .accessibilityValue([value ?? "No reading", detail].compactMap { $0 }.joined(separator: ", "))
    }
}

/// Foot temperature across the session, with a rule at each step.
private struct SessionChart: View {
    @ObservedObject var engine: CalibrationEngine
    let unit: TemperatureUnit

    /// Coloured by temperature, as every temperature chart is.
    private var traceStyle: LinearGradient {
        let values = engine.trace.map { unit.convert($0.footC) }
        return ChartValueScale.footTemperature(unit).gradient(from: values.min() ?? 0, to: values.max() ?? 0)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SiteEyebrow("Foot temperature · this session")
            Chart {
                ForEach(1..<CalibrationPlan.steps.count, id: \.self) { i in
                    RuleMark(x: .value("Step", i * CalibrationPlan.secondsPerStep))
                        .foregroundStyle(i == CalibrationPlan.indoorCount ? Thermyx.Site.hairlineStrong : Thermyx.Site.hairline)
                }
                ForEach(engine.trace) { point in
                    LineMark(x: .value("Second", point.second), y: .value("Foot", unit.convert(point.footC)))
                        .foregroundStyle(traceStyle)
                        .interpolationMethod(.monotone)
                        .lineStyle(StrokeStyle(lineWidth: 2.4, lineCap: .round))
                }
            }
            .chartXScale(domain: 0...CalibrationPlan.totalSeconds)
            .chartYScale(domain: .automatic(includesZero: false))
            .chartXAxis {
                AxisMarks(values: [0, 90, 180]) { value in
                    AxisValueLabel {
                        if let s = value.as(Int.self) {
                            Text(s == 0 ? "Inside" : s == 90 ? "Outside" : "3 min")
                                .font(ThermyxFont.captionSmall)
                                .foregroundStyle(Thermyx.Site.textFaint)
                        }
                    }
                }
            }
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(Thermyx.Site.hairline)
                    AxisValueLabel {
                        if let v = value.as(Double.self) {
                            Text(String(format: "%.1f°", v)).font(ThermyxFont.captionSmall).foregroundStyle(Thermyx.Site.textFaint)
                        }
                    }
                }
            }
            .overlay {
                if engine.trace.isEmpty {
                    Text("Starts drawing when calibration begins")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Site.textFaint)
                }
            }
            .frame(height: 150)
            .padding(Thermyx.Space.l)
            .siteGlass(radius: Thermyx.Radius.compact)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Foot temperature chart for this session")
        }
    }
}

/// One row per finished step: where the foot sat and how it moved.
private struct LearnedSoFar: View {
    let summaries: [CalibrationPhaseSummary]
    let samples: [String: [CalibrationSample]]
    let unit: TemperatureUnit
    @State private var showing: CalibrationPhaseSummary?

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SiteEyebrow("Learned so far")
            VStack(spacing: 0) {
                ForEach(Array(summaries.enumerated()), id: \.element.id) { offset, s in
                    if offset > 0 { Rectangle().fill(Thermyx.Site.hairline).frame(height: 1) }
                    Button { showing = s } label: {
                    HStack(spacing: Thermyx.Space.m) {
                        Text("\(s.outdoor ? "Outside" : "Inside") · \(s.activity.label.lowercased())")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Site.textMuted)
                        Spacer(minLength: Thermyx.Space.s)
                        Text(s.footMeanC.map { TemperatureFormat.degrees($0, in: unit) } ?? "—")
                            .font(ThermyxFont.rowNumeral)
                            .monospacedDigit()
                            .foregroundStyle(Thermyx.Site.text)
                        Text(s.ratePerMinute.map { CalibrationNorms.rate($0, in: unit) } ?? "—")
                            .font(ThermyxFont.captionSmall)
                            .monospacedDigit()
                            .foregroundStyle(Thermyx.Site.textFaint)
                            .frame(minWidth: 76, alignment: .trailing)
                        Image(systemName: "function")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Thermyx.Ink.ice)
                    }
                    .padding(.horizontal, Thermyx.Space.l)
                    .frame(minHeight: 48)
                    .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityHint("Shows the math for this step")
                    .transition(.opacity)
                }
            }
            .siteGlass(radius: Thermyx.Radius.compact)
        }
        .animation(SiteMotion.settle, value: summaries.count)
        #if DEBUG
        // `-ThermyxShowMath`: opens the first finished step's math.
        .onAppear { if ProcessInfo.processInfo.arguments.contains("-ThermyxShowMath") { showing = summaries.first } }
        #endif
        .sheet(item: $showing) { s in
            CalculusSheet(title: "\(s.outdoor ? "Outside" : "Inside") · \(s.activity.label.lowercased())",
                          samples: samples[s.id] ?? [], unit: unit)
        }
    }
}

/// The math for the step in progress, updating as readings arrive.
private struct LiveMathSheet: View {
    @ObservedObject var engine: CalibrationEngine
    let unit: TemperatureUnit

    var body: some View {
        CalculusSheet(title: engine.phase == .running
                        ? "\(engine.step.outdoor ? "Outside" : "Inside") · \(engine.step.activity.label.lowercased()) · live"
                        : "This step",
                      samples: engine.current, unit: unit)
    }
}

extension Text {
    /// Calculus notation (dT/dt, ∫): an italic serif with the full math
    /// glyph set, never uppercased.
    func mathNotation(size: CGFloat = 13) -> some View {
        self.font(.system(size: size, design: .serif).italic())
            .foregroundStyle(Thermyx.Site.textMuted)
            .textCase(nil)
    }
}
