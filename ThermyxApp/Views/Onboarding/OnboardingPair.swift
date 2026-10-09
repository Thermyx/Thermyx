import SwiftUI

/// Step three. For the wearer this is a live scan with a radar sweep; for a
/// watcher it is the pairing code and backend the two phones share.
struct OnboardingPair: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    let role: ThermyxRole
    @Binding var name: String
    @Binding var watchedName: String
    @Binding var pairingCode: String
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var showingBackend = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                if role == .user {
                    RadarSweep()
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .riseIn(delay: 0)
                }

                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    Text(role == .user ? "Looking for your insole" : "Connect to your user")
                        .font(ThermyxFont.onboardingHeadline)
                        .tracking(ThermyxTracking.onboardingHeadline)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(role == .user
                         ? "Hold the insole button for three seconds until the light pulses blue."
                         : "Use the same pairing code and backend address on both phones.")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .riseIn(delay: 0.1)

                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    field("Your name", text: $name, placeholder: "Name")

                    if role == .trustedMember {
                        field("Who you're watching", text: $watchedName, placeholder: "Their name")
                    }

                    if role == .user { discoveryList }

                    backendDisclosure
                }
                .riseIn(delay: 0.2)
            }
            .padding(.bottom, Thermyx.Space.m)
        }
        .scrollIndicators(.hidden)
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        emphasized: Bool = false,
        tracking: CGFloat = 0
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            TextField(placeholder, text: text)
                .font(ThermyxFont.bodyLarge)
                .tracking(tracking)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .autocorrectionDisabled()
                .padding(.horizontal, Thermyx.Space.xl)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                        .strokeBorder(
                            emphasized ? Thermyx.Ink.signal : Thermyx.Tint.neutralBorder,
                            lineWidth: emphasized ? Thermyx.Stroke.emphasis : Thermyx.Stroke.hairline
                        )
                }
        }
    }

    // MARK: - Discovery
    //
    // Two insoles, paired independently. Neither is required to move on: a
    // wearer who only has one today should not be blocked at onboarding.

    @ViewBuilder
    private var discoveryList: some View {
        VStack(spacing: Thermyx.Space.s) {
            HStack(spacing: Thermyx.Space.s) {
                ForEach(Foot.allCases) { foot in
                    footStatus(foot)
                }
            }

            if viewModel.ble.discovered.isEmpty {
                HStack(spacing: Thermyx.Space.m) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Thermyx.Ink.ice)
                    Text(viewModel.isScanning ? "Searching for nearby insoles…" : "Not scanning")
                        .font(ThermyxFont.bodySmall)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                    Spacer(minLength: 0)
                    if !viewModel.isScanning {
                        Button("Scan") { viewModel.toggleScan() }
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.ice)
                    }
                }
                .padding(Thermyx.Space.xl)
                .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                .background(Thermyx.Tint.liveFill.opacity(0.6), in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                        .strokeBorder(Thermyx.Tint.liveBorder.opacity(0.7), lineWidth: Thermyx.Stroke.hairline)
                }
            } else {
                ForEach(viewModel.ble.discovered) { device in
                    DiscoveredDeviceRow(device: device) { foot in
                        viewModel.connect(to: device, as: foot)
                    }
                    .opacity(device.isStrong ? 1 : 0.65)
                }
            }

            Text("You can pair one insole now and the other later. Thermyx never shows one foot's reading for the other.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-foot pairing control.
    ///
    /// These used to be status pills with button chrome and no action, which
    /// is the worst of both: they looked tappable and were not. Now the two
    /// states are visibly different things — an unconnected foot is a button
    /// that scans for it, a connected one is a settled status that does not
    /// invite a tap.
    @ViewBuilder
    private func footStatus(_ foot: Foot) -> some View {
        if viewModel.isConnected(foot) {
            footPill(foot, isOn: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(foot.label) insole connected")
        } else {
            Button {
                viewModel.scanFor(foot)
            } label: {
                footPill(foot, isOn: false)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan for the \(foot.label.lowercased()) insole")
            .accessibilityHint("Not connected yet")
        }
    }

    private func footPill(_ foot: Foot, isOn: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Thermyx.Ink.ice : Thermyx.Ink.ice)
            VStack(spacing: 0) {
                Text(foot.label)
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel,
                                 color: isOn ? Thermyx.Ink.ice : Thermyx.Ink.textPrimary)
                Text(isOn ? "Connected" : "Tap to scan")
                    .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel,
                                 color: isOn ? Thermyx.Ink.textSupporting : Thermyx.Ink.ice)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(isOn ? Thermyx.Tint.liveFill : Thermyx.Tint.neutralFill, in: Capsule())
        .overlay {
            Capsule().strokeBorder(isOn ? Thermyx.Tint.liveBorder : Thermyx.Tint.neutralBorder,
                                   lineWidth: Thermyx.Stroke.hairline)
        }
    }

    // MARK: - Backend

    private var backendDisclosure: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { showingBackend.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text(role == .user ? "Optional: connect to a relay" : "Connect to their relay")
                        .narrowLabel(ThermyxFont.statusPill, tracking: 1.8, color: Thermyx.Ink.textSupporting)
                    Image(systemName: showingBackend ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Thermyx.minimumTapTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showingBackend ? [.isButton, .isSelected] : .isButton)

            if showingBackend {
                RelayConnectionCard(settings: settings, role: role == .user ? "wearer" : "watcher", watcherName: name)
                    .transition(.opacity)
            }
        }
    }
}

/// The scanning radar: static rings, a rotating conic sweep, a core, and one
/// expanding ring. Under Reduce Motion the sweep and ring stop and the core
/// stays lit — the screen still says "scanning", it just doesn't spin.
struct RadarSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion)) { context in
            let angle = reduceMotion
                ? 0
                : (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8) * 360

            ZStack {
                ForEach([170.0, 112.0, 56.0], id: \.self) { diameter in
                    Circle()
                        .strokeBorder(Thermyx.Ink.ice.opacity(diameter == 56 ? 0.4 : (diameter == 112 ? 0.3 : 0.22)), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                }

                if !reduceMotion {
                    Circle()
                        .fill(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Thermyx.Ink.ice.opacity(0.42), location: 0),
                                    .init(color: Thermyx.Ink.ice.opacity(0), location: 0.28)
                                ]),
                                center: .center
                            )
                        )
                        .frame(width: 170, height: 170)
                        .rotationEffect(.degrees(angle))

                    ExpandingRings(color: Thermyx.Ink.ice.opacity(0.4), baseSize: 190, count: 1, duration: 3.2, stagger: 0)
                }

                Circle()
                    .fill(Thermyx.Ink.ice)
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Scanning for nearby insoles")
    }
}

// MARK: - Calibration
//
// About 6 minutes: three indoor minutes (sitting, standing, walking), then
// three outdoor ones that can be done later. Each minute records one sample
// a second and asks one question. The on-device model in
// PersonalBaseline.swift is trained from the result.

struct CalibrationStep: Equatable {
    let activity: CalibrationActivity
    let outdoor: Bool
    let title: String
    let instruction: String
    let question: CalibrationQuestion
}

enum CalibrationQuestion: Equatable {
    /// Yes / No.
    case yesNo(String)
    /// −1 "too cold" … +1 "too warm".
    case comfort(String)

    var text: String {
        switch self {
        case .yesNo(let t), .comfort(let t): return t
        }
    }
}

enum CalibrationPlan {
    static let secondsPerStep = 60
    /// The question appears this many seconds into a step.
    static let questionAt = 20

    static let steps: [CalibrationStep] = [
        .init(activity: .sitting, outdoor: false, title: "Sit down",
              instruction: "Sit comfortably indoors with both feet on the floor.",
              question: .comfort("How do your feet feel right now?")),
        .init(activity: .standing, outdoor: false, title: "Stand still",
              instruction: "Stand up and stay where you are, as you normally would.",
              question: .yesNo("Is this how you usually stand?")),
        .init(activity: .walking, outdoor: false, title: "Walk around",
              instruction: "Walk around the room at your normal pace.",
              question: .yesNo("Is the insole getting in the way of your walking?")),
        .init(activity: .sitting, outdoor: true, title: "Rest outside",
              instruction: "Go outside and sit or rest without moving much.",
              question: .comfort("How does it feel outside compared with inside?")),
        .init(activity: .standing, outdoor: true, title: "Stand outside",
              instruction: "Stand still outside.",
              question: .yesNo("Is this how you usually stand outside?")),
        .init(activity: .walking, outdoor: true, title: "Walk outside",
              instruction: "Walk outside at your normal pace.",
              question: .yesNo("Is the insole getting in the way of your walking?")),
    ]

    static var indoorCount: Int { steps.filter { !$0.outdoor }.count }
}

@MainActor
final class CalibrationSession: ObservableObject {
    enum Phase: Equatable {
        case checks
        case running
        case indoorDone
        case done
    }

    @Published private(set) var phase: Phase = .checks
    @Published private(set) var index = 0
    @Published private(set) var remaining = CalibrationPlan.secondsPerStep
    @Published var isPaused = false
    /// Answers by step index: yes = 1, no = 0, comfort −1…1.
    @Published var answers: [Int: Double] = [:]
    @Published private(set) var model: PersonalThermalModel?
    /// Samples this step that actually had sensor data.
    @Published private(set) var samplesThisStep = 0

    private var segments: [CalibrationTrainer.Segment] = []
    private var current: [CalibrationSample] = []
    private var timer: Timer?
    private weak var viewModel: ThermyxViewModel?
    private let settings: ThermyxSettingsStore

    private static let indoorKey = "thermyx.calibration.indoor"
    private static let comfortKey = "thermyx.calibration.comfort"

    var step: CalibrationStep { CalibrationPlan.steps[index] }
    var showsQuestion: Bool { CalibrationPlan.secondsPerStep - remaining >= CalibrationPlan.questionAt && answers[index] == nil }
    var progress: Double { Double(CalibrationPlan.secondsPerStep - remaining) / Double(CalibrationPlan.secondsPerStep) }

    init(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore, outdoorOnly: Bool = false) {
        self.viewModel = viewModel
        self.settings = settings
        if outdoorOnly, let saved = Self.loadIndoor() {
            segments = saved
            index = CalibrationPlan.indoorCount
        }
    }

    func start() {
        phase = .running
        beginStep()
    }

    func togglePause() { isPaused.toggle() }

    func skipStep() { finishStep(keep: false) }

    func answer(_ value: Double) { answers[index] = value }

    /// After the indoor minutes: do the outdoor part now.
    func continueOutdoor() {
        phase = .running
        beginStep()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func beginStep() {
        remaining = CalibrationPlan.secondsPerStep
        current = []
        samplesThisStep = 0
        isPaused = false
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func tick() {
        guard phase == .running, !isPaused, let viewModel else { return }
        let reading = viewModel.reading
        if reading.hasAny {
            current.append(CalibrationSample(reading))
            samplesThisStep = current.count
        }
        remaining -= 1
        if remaining <= 0 { finishStep(keep: true) }
    }

    private func finishStep(keep: Bool) {
        timer?.invalidate()
        timer = nil
        if keep, current.count >= 20 {
            segments.append(.init(activity: step.activity, outdoor: step.outdoor, samples: current))
        }
        current = []
        let next = index + 1
        if next == CalibrationPlan.indoorCount {
            train()
            Self.saveIndoor(segments.filter { !$0.outdoor })
            phase = .indoorDone
            index = next
        } else if next >= CalibrationPlan.steps.count {
            train()
            phase = .done
        } else {
            index = next
            beginStep()
        }
    }

    private func train() {
        let comfort: Double? = answers[0] ?? UserDefaults.standard.object(forKey: Self.comfortKey) as? Double
        if let first = answers[0] { UserDefaults.standard.set(first, forKey: Self.comfortKey) }
        guard let model = CalibrationTrainer.train(segments: segments, comfort: comfort) else {
            self.model = nil
            return
        }
        self.model = model
        let indoor = segments.filter { !$0.outdoor }.flatMap(\.samples)
        viewModel?.applyCalibration(model, indoorSamples: indoor, settings: settings)
    }

    // The indoor minutes are kept so the outdoor part can be added later
    // and the model retrained on everything.
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

/// The calibration screens, shown full screen from onboarding, Home, or
/// Safety → Advanced.
struct CalibrationView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var settings: ThermyxSettingsStore
    @StateObject private var session: CalibrationSession
    @Environment(\.dismiss) private var dismiss
    @State private var showingConnect = false

    init(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore, outdoorOnly: Bool = false) {
        self.settings = settings
        _session = StateObject(wrappedValue: CalibrationSession(viewModel: viewModel, settings: settings, outdoorOnly: outdoorOnly))
    }

    var body: some View {
        ThermyxDetailScreen(title: "Calibration") {
            switch session.phase {
            case .checks: checks
            case .running: running
            case .indoorDone: indoorDone
            case .done: done
            }
        }
        .onDisappear { session.stop() }
        .sheet(isPresented: $showingConnect) {
            NavigationStack { ConnectDeviceView(ble: viewModel.ble) }
                .presentationDetents([.large])
        }
    }

    // MARK: Checks

    private var footState: Bool? {
        viewModel.reading.present.compactMap(\.footDetected).first.map { _ in
            viewModel.reading.present.contains { $0.footDetected == true }
        }
    }

    @ViewBuilder
    private var checks: some View {
        let connected = viewModel.anyConnected
        let receiving = viewModel.reading.hasAny
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            Text("Thermyx learns your normal: how warm your feet run when you sit, stand and walk, and what feels comfortable. It takes about 6 minutes. The outdoor half can be done later.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            checkRow(done: connected, title: "Insole connected",
                     detail: connected ? (viewModel.ble.names.values.first ?? "Connected") : "Connect your Thermyx first.")
            if !connected {
                Button("Connect a device") { showingConnect = true }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
            }

            checkRow(done: receiving, title: "Readings arriving",
                     detail: receiving ? "Live data is coming in." : "Waiting for the first reading…")

            switch footState {
            case .some(true):
                checkRow(done: true, title: "Foot detected", detail: "The insole is in and you're on it.")
            case .some(false):
                checkRow(done: false, title: "Step on it", detail: "Put the insole in your shoe and stand on it.")
            case .none:
                checkRow(done: receiving, title: "Insole in your shoe",
                         detail: "This insole can't sense a foot yet, so check it's in your shoe and you're wearing it.")
            }

            Button("Start calibration") { session.start() }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .disabled(!receiving || footState == false)
        }
    }

    private func checkRow(done: Bool, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            Image(systemName: done ? "checkmark.circle.fill" : "circle.dashed")
                .foregroundStyle(done ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
                .font(.system(size: 20))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Ink.textPrimary)
                Text(detail).font(ThermyxFont.caption).foregroundStyle(Thermyx.Ink.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Running

    private var running: some View {
        let step = session.step
        return VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            Text(verbatim: "Step \(session.index + 1) of \(CalibrationPlan.steps.count)\(step.outdoor ? " · outside" : "")")
                .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: Thermyx.Ink.textSupporting)
            Text(step.title)
                .font(ThermyxFont.featureHeadline)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            Text(step.instruction)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            ProgressView(value: session.progress)
                .tint(Thermyx.Ink.ice)
            HStack {
                Text(verbatim: "\(session.remaining) s left")
                    .font(ThermyxFont.rowTitle)
                    .monospacedDigit()
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                Text(verbatim: session.isPaused ? "Paused" : "\(session.samplesThisStep) readings")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }

            if session.showsQuestion {
                question(step.question)
            }

            if !viewModel.reading.hasAny {
                Text("No readings right now. This step only counts the seconds with data.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.amber)
            }

            HStack(spacing: Thermyx.Space.m) {
                Button(session.isPaused ? "Resume" : "Pause") { session.togglePause() }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
                Button("Skip this step") { session.skipStep() }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
            }
        }
    }

    @ViewBuilder
    private func question(_ q: CalibrationQuestion) -> some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                Text(q.text)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                switch q {
                case .yesNo:
                    HStack(spacing: Thermyx.Space.m) {
                        Button("Yes") { session.answer(1) }.buttonStyle(ThermyxSecondaryButtonStyle())
                        Button("No") { session.answer(0) }.buttonStyle(ThermyxSecondaryButtonStyle())
                    }
                case .comfort:
                    ComfortAnswer { session.answer($0) }
                }
            }
        }
    }

    // MARK: Results

    private var indoorDone: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            Text("Indoor part done")
                .font(ThermyxFont.featureHeadline)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            summary
            Text("The outdoor part teaches Thermyx how you run outside. You can do it now or later from Home.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Do the outdoor part now") { session.continueOutdoor() }
                .buttonStyle(ThermyxPrimaryButtonStyle())
            Button("Finish later") { dismiss() }
                .buttonStyle(ThermyxSecondaryButtonStyle())
        }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            Text("Calibration complete")
                .font(ThermyxFont.featureHeadline)
                .foregroundStyle(Thermyx.Ink.textPrimary)
            summary
            Button("Done") {
                CalibrationSession.clearSaved()
                dismiss()
            }
            .buttonStyle(ThermyxPrimaryButtonStyle())
        }
    }

    @ViewBuilder
    private var summary: some View {
        if let model = session.model {
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    if let target = model.comfortTargetC {
                        row("Auto target", TemperatureFormat.degrees(target, in: settings.temperatureUnit))
                    }
                    ForEach(CalibrationActivity.allCases) { activity in
                        if let stats = model.footByActivity[activity] {
                            row("Usual foot temp · \(activity.label.lowercased())", TemperatureFormat.degrees(stats.mean, in: settings.temperatureUnit))
                        }
                    }
                    if let accuracy = model.classifierAccuracy {
                        row("Activity model accuracy", "\(Int((accuracy * 100).rounded()))%")
                    } else {
                        Text("Activity detection needs the pressure and motion sensors, so it will switch on once they report.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textFaint)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if session.answers[2] == 1 || session.answers[5] == 1 {
                        Text("You said the insole gets in the way of walking. Check that it sits flat and the shoe isn't too tight.")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(Thermyx.Ink.amber)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            Text("Learned on this phone from your own data. It can only add caution, and Auto stays within 26–38 °C.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("Not enough readings came in to learn from. Check the insole is connected and sending, then try again.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.amber)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(ThermyxFont.caption).foregroundStyle(Thermyx.Ink.textSupporting)
            Spacer()
            Text(verbatim: value).font(ThermyxFont.rowTitle).monospacedDigit().foregroundStyle(Thermyx.Ink.textPrimary)
        }
    }
}

/// "Too cold … just right … too warm", sent once the slider is released.
private struct ComfortAnswer: View {
    let onAnswer: (Double) -> Void
    @State private var value = 0.0

    var body: some View {
        VStack(spacing: Thermyx.Space.xs) {
            Slider(value: $value, in: -1...1, step: 0.25)
                .tint(Thermyx.Ink.ice)
            HStack {
                Text("Too cold"); Spacer(); Text("Just right"); Spacer(); Text("Too warm")
            }
            .font(ThermyxFont.captionSmall)
            .foregroundStyle(Thermyx.Ink.textSupporting)
            Button("Save answer") { onAnswer(value) }
                .buttonStyle(ThermyxSecondaryButtonStyle())
        }
    }
}

/// Home: "Calibrate Thermyx" before the first calibration, "Finish
/// calibration" while the outdoor half is still to do.
struct CalibrationPromptCard: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var baseline: PersonalBaselineStore
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var presenting = false

    var body: some View {
        if viewModel.anyConnected, !viewModel.ble.isDemoMode, baseline.model?.outdoorDone != true {
            let finishing = baseline.model != nil
            Button { presenting = true } label: {
                HStack(spacing: Thermyx.Space.m) {
                    Image(systemName: "figure.walk.motion")
                        .foregroundStyle(Thermyx.Ink.ice)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(finishing ? "Finish calibration" : "Calibrate Thermyx")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(finishing ? "3 minutes outside to complete your profile." : "About 6 minutes. Learns your normal and sets Auto for you.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                    Spacer()
                    Image(systemName: "chevron.right").foregroundStyle(Thermyx.Ink.textFaint)
                }
                .padding(Thermyx.Space.m)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .fullScreenCover(isPresented: $presenting) {
                NavigationStack {
                    CalibrationView(viewModel: viewModel, settings: settings, outdoorOnly: finishing)
                }
                .environmentObject(viewModel)
            }
        }
    }
}

/// Home: what the activity model thinks the wearer is doing.
struct ActivityGuessLabel: View {
    @ObservedObject var baseline: PersonalBaselineStore

    var body: some View {
        if let best = baseline.activity?.max(by: { $0.value < $1.value }), best.value >= 0.6 {
            Text(verbatim: "\(best.key.label) · \(Int((best.value * 100).rounded()))%")
                .narrowLabel(ThermyxFont.statusPill, tracking: 0.6, color: Thermyx.Ink.textSupporting)
                .accessibilityLabel("Activity model: \(best.key.label), \(Int((best.value * 100).rounded())) percent")
        }
    }
}

/// Safety → Advanced: calibration status, redo, and clear.
struct CalibrationSettingsSection: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var baseline: PersonalBaselineStore
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var presenting = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Calibration")
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    if let model = baseline.model {
                        Text(model.outdoorDone ? "Calibrated indoors and outdoors" : "Calibrated indoors · outdoor part not done")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(verbatim: "Trained \(model.trainedAt.formatted(date: .abbreviated, time: .shortened))"
                             + (model.classifierAccuracy.map { " · activity model \(Int(($0 * 100).rounded()))% accurate" } ?? ""))
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    } else {
                        Text("Not calibrated yet")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                    }
                    HStack(spacing: Thermyx.Space.m) {
                        Button(baseline.model == nil ? "Calibrate" : "Calibrate again") { presenting = true }
                            .buttonStyle(ThermyxSecondaryButtonStyle())
                            .disabled(!viewModel.anyConnected || viewModel.ble.isDemoMode)
                        if baseline.model != nil {
                            Button("Clear") {
                                baseline.clearModel()
                                CalibrationSession.clearSaved()
                            }
                            .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))
                        }
                    }
                    Text("Calibration learns your usual foot temperature for sitting, standing and walking, sets Auto's target, and trains the activity model, all on this phone. It can only add caution.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .fullScreenCover(isPresented: $presenting) {
            NavigationStack { CalibrationView(viewModel: viewModel, settings: settings) }
                .environmentObject(viewModel)
        }
    }
}
