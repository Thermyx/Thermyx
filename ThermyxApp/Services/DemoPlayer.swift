import Foundation

/// Plays a `DemoScript` on the simulated pair: the playhead moves in real
/// seconds (the video's), the pair's physics runs `pace` seconds for each,
/// conditions follow the events under the playhead, and one-off events fire
/// as it passes them.
///
/// Scrubbing is a replay: the pair goes back to how it was at minute zero
/// and runs forward, silently, to the new playhead. The simulator's physics
/// is seeded, so a moment reached by scrubbing is the same moment reached by
/// playing. One-off events passed while scrubbing change the feet (a battery
/// falls) but don't fire (no SOS is sent).
@MainActor
final class DemoPlayer: ObservableObject {
    @Published var script: DemoScript { didSet { if script != oldValue { save() } } }
    /// Seconds into the timeline.
    @Published private(set) var playhead: Double = 0
    @Published private(set) var isPlaying = false
    /// Whether the timeline is driving the pair (else it's the usual day).
    @Published private(set) var isLoaded = false

    /// Physics seconds per timeline second: fast enough that heat builds in
    /// the length of a video, slow enough that it still looks like a foot.
    static let pace = 20

    /// A one-off event the playhead just passed while playing.
    var onInstant: ((DemoEvent) -> Void)?
    /// The phone going quiet (and coming back) under a "Phone goes quiet" event.
    var onQuietChange: ((Bool) -> Void)?
    /// The playhead jumped; anything that watches a reading's history should
    /// start again.
    var onJump: (() -> Void)?

    private weak var simulator: ThermyxInsoleSimulator?
    private var start: ThermyxInsoleSimulator.Snapshot?
    private var replaying = false
    private var quiet = false
    private static let key = "thermyx.demo.script.v2"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let saved = try? JSONDecoder().decode(DemoScript.self, from: data) {
            script = saved
        } else {
            script = DemoScript.presets[0].script
        }
    }

    // MARK: Pair

    func attach(_ simulator: ThermyxInsoleSimulator) {
        self.simulator = simulator
    }

    /// The demo ended: back to nothing.
    func detach() {
        unload()
        simulator = nil
    }

    // MARK: Loading

    /// The timeline takes over the pair at minute zero, paused.
    func load() {
        guard let simulator else { return }
        start = simulator.snapshot()
        playhead = 0
        quiet = false
        simulator.timelineEpoch = .now
        simulator.timelineMinute = 0
        simulator.conditions = script.conditions(at: 0)
        simulator.stepsPerTick = 0
        simulator.onStep = { [weak self] in self?.advance() ?? false }
        isLoaded = true
        isPlaying = false
        onJump?()
    }

    /// Back to the usual day.
    func unload() {
        guard isLoaded else { return }
        if quiet { quiet = false; onQuietChange?(false) }
        simulator?.onStep = nil
        simulator?.conditions = nil
        simulator?.timelineMinute = nil
        simulator?.timelineEpoch = nil
        simulator?.stepsPerTick = 1
        isLoaded = false
        isPlaying = false
        onJump?()
    }

    // MARK: Playing

    func play() {
        if !isLoaded { load() }
        if playhead >= script.length - 0.01 { seek(to: 0) }
        isPlaying = true
        simulator?.stepsPerTick = Self.pace
    }

    func pause() {
        isPlaying = false
        simulator?.stepsPerTick = 0
    }

    /// Jumps to a minute by replaying from the start.
    func seek(to minute: Double) {
        guard let simulator, let start else { return }
        let target = min(max(0, minute), script.length)
        // Evidence from before the jump doesn't count; the replay rebuilds it.
        onJump?()
        replaying = true
        simulator.restore(start)
        playhead = 0
        simulator.timelineMinute = 0
        simulator.conditions = script.conditions(at: 0)
        simulator.fastForward(seconds: Int((target * Double(Self.pace)).rounded()))
        replaying = false
        simulator.publishNow()
        let nowQuiet = script.conditions(at: playhead).quiet
        if nowQuiet != quiet { quiet = nowQuiet; onQuietChange?(nowQuiet) }
    }

    /// One physics second. False at the end of the timeline.
    private func advance() -> Bool {
        guard playhead < script.length else {
            if isPlaying { pause() }
            return false
        }
        let previous = playhead
        playhead = min(script.length, playhead + 1 / Double(Self.pace))
        let conditions = script.conditions(at: playhead)
        // The pair's clock is the story's: `pace` times the timeline.
        simulator?.timelineMinute = playhead * Double(Self.pace) / 60
        simulator?.conditions = conditions
        for event in script.instants(after: previous, through: playhead) {
            switch event.kind {
            case .battery9: simulator?.setBattery(9, for: event.foot)
            case .battery4: simulator?.setBattery(4, for: event.foot)
            default: break
            }
            if !replaying { onInstant?(event) }
        }
        if !replaying, conditions.quiet != quiet {
            quiet = conditions.quiet
            onQuietChange?(quiet)
        }
        return true
    }

    // MARK: Editing

    func add(_ kind: DemoEventKind, foot: Foot = .right) {
        let at = min(max(0, playhead.rounded()), script.length - (kind.defaultLength ?? 1))
        script.events.append(DemoEvent(kind, at: max(0, at), foot: foot))
    }

    func remove(_ id: UUID) {
        script.events.removeAll { $0.id == id }
    }

    func move(_ id: UUID, to start: Double) {
        guard let i = script.events.firstIndex(where: { $0.id == id }) else { return }
        let length = script.events[i].length
        script.events[i].start = min(max(0, start.rounded()), max(0, script.length - max(length, 1)))
    }

    func use(_ preset: DemoScript.Preset) {
        script = preset.script
        if isLoaded { pause(); seek(to: 0) }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(script) { UserDefaults.standard.set(data, forKey: Self.key) }
    }
}
