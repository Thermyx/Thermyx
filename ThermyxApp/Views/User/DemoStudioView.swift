import SwiftUI

/// Home, admins only: the demo, its timeline, test alerts and the relay.
/// Exiting the demo is the orange banner's job, so there's no second exit here.
struct DemoStudio: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var player: DemoPlayer
    @ObservedObject var ble: ThermyxBLEService
    @ObservedObject var alerts: ThermyxAlertCoordinator
    @ObservedObject var settings: ThermyxSettingsStore

    @AppStorage("thermyx.studio.alertsOpen") private var alertsOpen = false
    @AppStorage("thermyx.studio.relayOpen") private var relayOpen = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            HStack(alignment: .firstTextBaseline) {
                Text("Demo")
                    .font(ThermyxFont.sectionTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("Team only")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                Spacer()
                if !ble.isDemoMode {
                    Button {
                        Task { await viewModel.startDemo() }
                    } label: {
                        if viewModel.isStartingDemo { ProgressView() } else { Text("Start") }
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(Thermyx.Ink.ember)
                    .disabled(viewModel.isStartingDemo)
                }
            }

            if ble.isDemoMode {
                DemoTimelineSection(player: player)
                DisclosureGroup(isExpanded: $alertsOpen) {
                    DemoAlertsSection(alerts: alerts, settings: settings)
                        .padding(.top, Thermyx.Space.m)
                } label: {
                    Text("Test alerts").font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Ink.textPrimary)
                }
                .tint(Thermyx.Ink.textMuted)
            }

            DisclosureGroup(isExpanded: $relayOpen) {
                RelayConnectionCard(settings: settings, role: "wearer")
                    .padding(.top, Thermyx.Space.m)
            } label: {
                HStack {
                    Text("Relay").font(ThermyxFont.rowTitle).foregroundStyle(Thermyx.Ink.textPrimary)
                    Spacer()
                    Text(settings.isPairedWithRelay ? "Connected" : "Not connected")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(settings.isPairedWithRelay ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
                }
            }
            .tint(Thermyx.Ink.textMuted)
        }
        .padding(.top, Thermyx.Space.l)
        .overlay(alignment: .top) { ThermyxDivider() }
        #if DEBUG
        .task(id: ble.isDemoMode) {
            // `-ThermyxUIPreview studioPlaying`: Hot shift playing, for review.
            guard ThermyxPreviewHarness.state == .studioPlaying, ble.isDemoMode, !player.isLoaded else { return }
            try? await Task.sleep(for: .seconds(1))
            player.use(DemoScript.presets[0])
            player.play()
        }
        #endif
    }
}

// MARK: - Timeline

struct DemoTimelineSection: View {
    @ObservedObject var player: DemoPlayer
    @State private var selected: UUID?
    @State private var scrub: Double?

    private var script: DemoScript { player.script }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.m) {
            HStack(spacing: Thermyx.Space.s) {
                Menu {
                    ForEach(DemoScript.presets) { preset in
                        Button(preset.name) { player.use(preset); selected = nil }
                    }
                } label: {
                    Label(presetName, systemImage: "list.bullet")
                }
                .buttonStyle(.bordered)
                Spacer()
                Menu {
                    Picker("Length", selection: $player.script.length) {
                        ForEach(DemoScript.lengths, id: \.self) { Text(DemoClock.label($0)).tag($0) }
                    }
                } label: {
                    Label(DemoClock.label(script.length), systemImage: "timer")
                }
                .buttonStyle(.bordered)
            }
            .font(ThermyxFont.controlLabel)
            .tint(Thermyx.Ink.link)

            DemoTimelineTrack(player: player, selected: $selected, scrub: $scrub)
                .frame(height: trackHeight)

            HStack(spacing: Thermyx.Space.m) {
                Button {
                    player.isPlaying ? player.pause() : player.play()
                } label: {
                    Image(systemName: player.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(Thermyx.Ink.onPrimary)
                        .frame(width: 48, height: 48)
                        .background(Thermyx.Ink.textPrimary, in: Circle())
                        .contentTransition(.symbolEffect(.replace))
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(player.isPlaying ? "Pause" : "Play")

                Text("\(DemoClock.label(scrub ?? player.playhead)) / \(DemoClock.label(script.length))")
                    .font(ThermyxFont.monoCaption)
                    .monospacedDigit()
                    .foregroundStyle(Thermyx.Ink.textPrimary)

                Spacer(minLength: 0)

                Menu {
                    ForEach(DemoEventKind.allCases) { kind in
                        Button {
                            player.add(kind)
                            selected = player.script.events.last?.id
                        } label: {
                            Label(kind.label, systemImage: kind.symbol)
                        }
                    }
                } label: {
                    Label("Event", systemImage: "plus")
                        .font(ThermyxFont.controlLabel)
                }
                .buttonStyle(.bordered)
                .tint(Thermyx.Ink.textPrimary)
            }

            if let id = selected, let event = script.events.first(where: { $0.id == id }) {
                DemoEventEditor(player: player, event: event) { selected = nil }
                    .transition(.opacity)
            }
        }
        .animation(SiteMotion.settle, value: selected)
    }

    private var presetName: String {
        DemoScript.presets.first { $0.script == script }?.name ?? "Custom"
    }

    private var trackHeight: CGFloat {
        let lanes = DemoTimelineTrack.lanes(for: script.events.filter { !$0.isInstant }).values.max().map { $0 + 1 } ?? 1
        return 40 + CGFloat(max(1, lanes)) * 28 + 18
    }
}

enum DemoClock {
    /// "1:05": minutes and seconds of the timeline.
    static func label(_ seconds: Double) -> String {
        let total = Int(seconds.rounded())
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// The track: lasting events as bars, one-off events as dots along the top,
/// and the playhead. Drag anywhere to scrub; letting go jumps there.
struct DemoTimelineTrack: View {
    @ObservedObject var player: DemoPlayer
    @Binding var selected: UUID?
    @Binding var scrub: Double?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    static func lanes(for events: [DemoEvent]) -> [UUID: Int] {
        var ends: [Double] = []
        var out: [UUID: Int] = [:]
        for e in events.sorted(by: { $0.start < $1.start }) {
            if let lane = ends.firstIndex(where: { $0 <= e.start }) {
                ends[lane] = e.end
                out[e.id] = lane
            } else {
                ends.append(e.end)
                out[e.id] = ends.count - 1
            }
        }
        return out
    }

    /// Tick spacing that leaves room for the labels.
    private func step(_ length: Double) -> Double { length <= 90 ? 15 : length <= 180 ? 30 : 60 }

    var body: some View {
        GeometryReader { proxy in
            let w = proxy.size.width
            let length = max(player.script.length, 1)
            let x: (Double) -> CGFloat = { s in w * CGFloat(min(max(s, 0), length) / length) }
            let lasting = player.script.events.filter { !$0.isInstant }
            let lanes = Self.lanes(for: lasting)
            let shown = scrub ?? player.playhead

            ZStack(alignment: .topLeading) {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Thermyx.Ink.deck)
                    .contentShape(Rectangle())
                    .gesture(
                        DragGesture(minimumDistance: 0)
                            .onChanged { value in
                                if player.isPlaying { player.pause() }
                                scrub = (Double(min(max(value.location.x / w, 0), 1)) * length).rounded()
                            }
                            .onEnded { _ in
                                if let target = scrub {
                                    if !player.isLoaded { player.load() }
                                    player.seek(to: target)
                                }
                                scrub = nil
                            }
                    )
                ForEach(Array(stride(from: 0.0, through: length, by: step(length))), id: \.self) { s in
                    Text(DemoClock.label(s))
                        .font(.system(size: 9, weight: .medium, design: .monospaced))
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize()
                        .offset(x: min(max(x(s) - 10, 0), w - 24), y: proxy.size.height - 14)
                        .allowsHitTesting(false)
                }

                ForEach(player.script.events.filter(\.isInstant)) { e in
                    Button { selected = e.id } label: {
                        Image(systemName: e.kind.symbol)
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(e.id == selected ? Thermyx.Ink.onPrimary : Thermyx.Ink.textPrimary)
                            .frame(width: 24, height: 24)
                            .background(e.id == selected ? e.kind.tint : Thermyx.Ink.elevated, in: Circle())
                            .frame(width: 44, height: 36)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: x(e.start) - 22, y: 2)
                    .accessibilityLabel("\(e.kind.label) at \(DemoClock.label(e.start))")
                }

                ForEach(lasting) { e in
                    Button { selected = e.id } label: {
                        Text(e.kind.label)
                            .font(.system(size: 11, weight: .semibold))
                            .lineLimit(1)
                            .foregroundStyle(e.id == selected ? Thermyx.Ink.onPrimary : Thermyx.Ink.textPrimary)
                            .padding(.horizontal, 6)
                            .frame(width: max(28, x(e.end) - x(e.start)), height: 22, alignment: .leading)
                            .background(e.kind.tint.opacity(e.id == selected ? 1 : 0.3), in: RoundedRectangle(cornerRadius: 5, style: .continuous))
                            .clipped()
                            .frame(height: 28)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .offset(x: x(e.start), y: 38 + CGFloat(lanes[e.id] ?? 0) * 28)
                    .accessibilityLabel("\(e.kind.label), \(DemoClock.label(e.start)) to \(DemoClock.label(e.end))")
                }

                Rectangle()
                    .fill(Thermyx.Ink.textPrimary)
                    .frame(width: 2, height: proxy.size.height - 16)
                    .offset(x: x(shown) - 1)
                    .opacity(player.isLoaded || scrub != nil ? 1 : 0.3)
                    .animation(reduceMotion || scrub != nil ? nil : .linear(duration: 1), value: player.playhead)
                    .allowsHitTesting(false)
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Timeline")
        .accessibilityValue(DemoClock.label(player.playhead))
        .accessibilityAdjustableAction { direction in
            if !player.isLoaded { player.load() }
            player.seek(to: player.playhead + (direction == .increment ? 5 : -5))
        }
    }
}

/// The selected event: when (to the second), how long, which foot, remove.
struct DemoEventEditor: View {
    @ObservedObject var player: DemoPlayer
    let event: DemoEvent
    let onClose: () -> Void

    private var index: Int? { player.script.events.firstIndex { $0.id == event.id } }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            HStack {
                Label(event.kind.label, systemImage: event.kind.symbol)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Spacer()
                Button(role: .destructive) { player.remove(event.id); onClose() } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityLabel("Remove")
                Button("Done", action: onClose)
                    .buttonStyle(.borderless)
                    .frame(minHeight: 44)
            }
            Stepper(value: Binding(get: { event.start }, set: { player.move(event.id, to: $0) }),
                    in: 0...max(0, player.script.length - max(event.length, 1)), step: 1) {
                row("Starts", DemoClock.label(event.start))
            }
            if !event.isInstant {
                Stepper(value: Binding(get: { event.length }, set: { v in
                    if let i = index { player.script.events[i].length = min(max(1, v), player.script.length - event.start) }
                }), in: 1...max(1, player.script.length - event.start), step: 1) {
                    row("Lasts", DemoClock.label(event.length))
                }
            }
            if event.kind.hasFoot {
                Picker("Foot", selection: Binding(get: { event.foot }, set: { foot in
                    if let i = index { player.script.events[i].foot = foot }
                })) {
                    ForEach(Foot.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
            }
        }
        .tint(Thermyx.Ink.textPrimary)
        .padding(Thermyx.Space.m)
        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
    }

    private func row(_ label: String, _ value: String) -> some View {
        HStack {
            Text(label).font(ThermyxFont.bodySmall).foregroundStyle(Thermyx.Ink.textSecondary)
            Spacer()
            Text(value).font(ThermyxFont.monoCaption).monospacedDigit().foregroundStyle(Thermyx.Ink.textPrimary)
        }
    }
}

// MARK: - Test alerts

/// Who the demo's alerts reach, and a button for each kind. They look real
/// (chosen for recordings), so texts only go to the people picked here, and
/// anything reaching another phone asks first.
struct DemoAlertsSection: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var alerts: ThermyxAlertCoordinator
    @ObservedObject var settings: ThermyxSettingsStore

    @AppStorage("thermyx.studio.recipients") private var recipientIDs = ""
    @AppStorage("thermyx.studio.routeTimeline") private var routeTimeline = false
    @AppStorage("thermyx.studio.recordingMode") private var recordingMode = true
    @State private var confirming: StudioTest?

    struct StudioTest: Identifiable {
        let title: String
        let symbol: String
        let reachesOthers: Bool
        let run: () -> Void
        var id: String { title }
    }

    private var chosen: Set<String> { Set(recipientIDs.split(separator: ",").map(String.init)) }
    private var recipients: [ThermyxContact] { settings.contacts.filter { chosen.contains($0.id.uuidString) } }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                Text("Send texts to")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                if settings.contacts.isEmpty {
                    Text("Add teammates as contacts on Safety first.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
                ForEach(settings.contacts) { contact in
                    Toggle(contact.name, isOn: Binding(get: { chosen.contains(contact.id.uuidString) }, set: { _ in toggle(contact) }))
                        .font(ThermyxFont.body)
                        .tint(Thermyx.Ink.ember)
                }
            }

            Toggle("Send the timeline's alerts too", isOn: $routeTimeline)
                .font(ThermyxFont.body)
                .tint(Thermyx.Ink.ember)
            Toggle("Hide the demo label on this phone", isOn: $recordingMode)
                .font(ThermyxFont.body)
                .tint(Thermyx.Ink.ember)

            VStack(spacing: 0) {
                ForEach(Array(tests.enumerated()), id: \.element.id) { index, test in
                    Button {
                        if test.reachesOthers { confirming = test } else { test.run() }
                    } label: {
                        HStack(spacing: Thermyx.Space.m) {
                            Image(systemName: test.symbol)
                                .frame(width: 22)
                                .foregroundStyle(test.reachesOthers ? Thermyx.Ink.amber : Thermyx.Ink.textMuted)
                            Text(test.title)
                                .font(ThermyxFont.body)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Spacer()
                            Image(systemName: test.reachesOthers ? "paperplane" : "iphone")
                                .font(.system(size: 13))
                                .foregroundStyle(Thermyx.Ink.textFaint)
                        }
                        .frame(minHeight: 48)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .overlay(alignment: .bottom) { if index < tests.count - 1 { ThermyxDivider() } }
                }
            }

            if let result = alerts.lastTestResult {
                Text(result)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear(perform: apply)
        .onChange(of: recipientIDs) { _, _ in apply() }
        .onChange(of: routeTimeline) { _, _ in apply() }
        .onChange(of: recordingMode) { _, _ in apply() }
        .confirmationDialog(confirming?.title ?? "", isPresented: Binding(get: { confirming != nil }, set: { if !$0 { confirming = nil } }),
                            titleVisibility: .visible) {
            Button("Send") { confirming?.run(); confirming = nil }
            Button("Cancel", role: .cancel) { confirming = nil }
        } message: {
            Text(recipients.isEmpty
                 ? "Watchers get it as a real alert."
                 : "\(recipients.map(\.name).joined(separator: ", ")) and watchers get it as a real alert.")
        }
    }

    private func toggle(_ contact: ThermyxContact) {
        var ids = chosen
        if ids.contains(contact.id.uuidString) { ids.remove(contact.id.uuidString) } else { ids.insert(contact.id.uuidString) }
        recipientIDs = ids.sorted().joined(separator: ",")
    }

    private func apply() {
        alerts.recordingMode = recordingMode
        let numbers = recipients.map(\.phoneNumber)
        alerts.testRoute = routeTimeline ? .init(recipients: numbers) : nil
        alerts.studioRecipients = numbers
    }

    private var tests: [StudioTest] {
        let reading = viewModel.reading
        func circle(_ kind: ThermyxAlertEvent.Kind, _ level: ThermyxRiskLevel, _ adjust: @escaping (inout ThermyxCircleDetail) -> Void = { _ in }) {
            alerts.sendStudioTest(kind, level: level, reading: reading, settings: settings, adjust: adjust)
        }
        return [
            StudioTest(title: "Notification: High risk", symbol: "bell", reachesOthers: false) { alerts.testWearerNotification(.high) },
            StudioTest(title: "Notification: Critical", symbol: "bell.badge", reachesOthers: false) { alerts.testWearerNotification(.critical) },
            StudioTest(title: "Critical in 3 seconds", symbol: "timer", reachesOthers: false) { alerts.testWearerNotification(.critical, after: 3) },
            StudioTest(title: "Critical screen", symbol: "exclamationmark.triangle", reachesOthers: false) { alerts.criticalTestRequest = .now },
            StudioTest(title: "Lock Screen at Critical", symbol: "lock", reachesOthers: false) {
                viewModel.widgets.showTest(level: .critical, concern: "Foot temperature elevated")
            },
            StudioTest(title: "High-risk alert", symbol: "exclamationmark.circle", reachesOthers: true) { circle(.alert, .high) },
            StudioTest(title: "Critical alert", symbol: "exclamationmark.triangle.fill", reachesOthers: true) { circle(.alert, .critical) },
            StudioTest(title: "Still Critical", symbol: "clock", reachesOthers: true) { circle(.update, .critical) { $0.update = "still"; $0.minutes = 2 } },
            StudioTest(title: "Recovering", symbol: "arrow.down.right", reachesOthers: true) { circle(.update, .caution) { $0.update = "recovering" } },
            StudioTest(title: "Back to Normal", symbol: "checkmark", reachesOthers: true) { circle(.update, .normal) { $0.update = "resolved" } },
            StudioTest(title: "SOS", symbol: "sos", reachesOthers: true) { circle(.sos, .critical) { $0.sos = "pressed" } },
            StudioTest(title: "Help request", symbol: "hand.raised", reachesOthers: true) {
                circle(.help, .high) { $0.help = "water"; $0.note = "By the north gate" }
            },
            StudioTest(title: "I'm OK", symbol: "hand.thumbsup", reachesOthers: true) {
                circle(.ok, .normal) { $0.checkedIn = ThermyxCircleDetail.localTime(.now) }
            },
            StudioTest(title: "Phone goes quiet", symbol: "iphone.slash", reachesOthers: true) { alerts.holdPosts(for: 4 * 60) },
        ]
    }
}
