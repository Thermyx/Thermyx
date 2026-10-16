import Foundation

// The recovery loop.
//
//   Thermal Recovery Test   an alert becomes a short guided protocol, and
//                           Thermyx measures whether the foot is cooling
//   Safety Plan             what the wearer did, and which of it was followed
//                           by faster recovery, from their own recoveries
//   Readiness Profile       what's normal for this wearer, so "is today
//                           different for me?" has an answer (ThermyxReadiness)
//
// None of it is medical advice, and none of it diagnoses anything. The
// protocol is the comfort and safety steps anyone would be told (stop, cool,
// loosen, sip water, stay still), and what Thermyx adds is a measurement.
// Nothing here ever lowers a risk level or delays an alert.

// MARK: - The steps

/// The guided steps, in order.
enum RecoveryStep: String, CaseIterable, Identifiable, Codable {
    case pause, coolDown, loosenFootwear, hydrate

    var id: String { rawValue }

    var title: String {
        switch self {
        case .pause: return "Stop and sit down"
        case .coolDown: return "Cool your feet"
        case .loosenFootwear: return "Loosen your shoes"
        case .hydrate: return "Sip some water"
        }
    }

    var detail: String {
        switch self {
        case .pause: return "Get out of the sun or off the job if you can."
        case .coolDown: return "Switch the insoles to Cool, and take any extra layer off."
        case .loosenFootwear: return "Loosen the laces, or take your shoes off if it's safe to."
        case .hydrate: return "A few sips, unless you've been told to limit fluids."
        }
    }

    var symbol: String {
        switch self {
        case .pause: return "figure.seated.side"
        case .coolDown: return "snowflake"
        case .loosenFootwear: return "shoe"
        case .hydrate: return "drop.fill"
        }
    }

    /// What doing this step counts as in the safety plan.
    var actions: [RecoveryAction] {
        switch self {
        case .pause: return [.rested, .stoppedActivity]
        case .coolDown: return [.cooledDown]
        case .loosenFootwear: return [.loosenedLaces]
        case .hydrate: return [.hydrated]
        }
    }
}

/// What the wearer did, for the safety plan.
enum RecoveryAction: String, CaseIterable, Identifiable, Codable {
    case rested, cooledDown, changedFootwear, loosenedLaces, hydrated, stoppedActivity

    var id: String { rawValue }

    var label: String {
        switch self {
        case .rested: return "Rested"
        case .cooledDown: return "Cooled down"
        case .changedFootwear: return "Changed footwear"
        case .loosenedLaces: return "Loosened laces"
        case .hydrated: return "Hydrated"
        case .stoppedActivity: return "Stopped activity"
        }
    }

    /// For a sentence: "Resting was followed by …".
    var phrase: String {
        switch self {
        case .rested: return "Resting"
        case .cooledDown: return "Cooling down"
        case .changedFootwear: return "Changing footwear"
        case .loosenedLaces: return "Loosening laces"
        case .hydrated: return "Drinking water"
        case .stoppedActivity: return "Stopping activity"
        }
    }

    /// For "After …, your foot cooled faster".
    var afterPhrase: String {
        switch self {
        case .rested: return "short rest breaks"
        case .cooledDown: return "cooling down"
        case .changedFootwear: return "changing footwear"
        case .loosenedLaces: return "loosening laces"
        case .hydrated: return "drinking water"
        case .stoppedActivity: return "stopping activity"
        }
    }

    /// What doing nothing of this kind looks like, for the comparison.
    var without: String {
        switch self {
        case .rested, .stoppedActivity: return "carrying on"
        case .cooledDown: return "not cooling down"
        case .changedFootwear, .loosenedLaces: return "leaving footwear as it was"
        case .hydrated: return "not drinking"
        }
    }

    var symbol: String {
        switch self {
        case .rested: return "figure.seated.side"
        case .cooledDown: return "snowflake"
        case .changedFootwear: return "shoe.2"
        case .loosenedLaces: return "shoe"
        case .hydrated: return "drop.fill"
        case .stoppedActivity: return "hand.raised.fill"
        }
    }
}

// MARK: - A recovery

enum RecoveryOutcome: String, Codable {
    /// Back to normal, or well on the way.
    case recovered
    /// Cooling, not there yet.
    case improving
    /// The foot isn't cooling.
    case notImproving
    /// Too much movement to tell.
    case inconclusive

    var title: String {
        switch self {
        case .recovered: return "Recovered"
        case .improving: return "Improving"
        case .notImproving: return "Not improving yet"
        case .inconclusive: return "Hard to tell"
        }
    }
}

/// One recovery: a guided test, or something the wearer logged after an
/// event. Kept on this phone.
struct RecoveryRecord: Codable, Identifiable, Equatable {
    let id: UUID
    var startedAt: Date
    var startLevel: String
    var startFootC: Double?
    var endFootC: Double?
    /// How long the foot was watched, in seconds.
    var seconds: Double?
    var outcome: RecoveryOutcome
    /// Share of the hold spent still, 0…1, when the insole could tell.
    var stillFraction: Double?
    /// Whether weight on the two feet got more even.
    var loadEvened: Bool?
    var actions: [RecoveryAction]
    /// True for the guided test; false for something logged afterwards.
    var guided: Bool

    var dropC: Double? {
        guard let startFootC, let endFootC else { return nil }
        return startFootC - endFootC
    }

    /// Degrees the foot cooled per minute while it was watched: the one
    /// number recoveries are compared by, because a guided test and an event
    /// logged afterwards both have it. Nil without a start, an end and time.
    var coolingRate: Double? {
        guard let dropC, let seconds, seconds >= 30 else { return nil }
        return min(2, max(-1, dropC / (seconds / 60)))
    }

    var level: ThermyxRiskLevel { ThermyxRiskLevel(rawValue: startLevel) ?? .caution }
}

// MARK: - Measuring it

struct RecoverySample: Equatable {
    /// Seconds since the hold began.
    var t: TimeInterval
    /// The warmer foot's temperature, °C.
    var footC: Double
    /// Whether the wearer was still; nil when the insole can't tell.
    var still: Bool?
    /// Left minus right load share, when both feet report it.
    var loadGap: Double?
    var level: ThermyxRiskLevel
}

struct RecoveryResult: Equatable {
    var outcome: RecoveryOutcome
    var startC: Double?
    var endC: Double?
    var stillFraction: Double?
    var loadEvened: Bool?
    var endLevel: ThermyxRiskLevel
    /// Minutes until the foot had cooled by half a degree, when it did.
    var minutesToImprove: Double?
    var seconds: Double

    var dropC: Double? {
        guard let startC, let endC else { return nil }
        return startC - endC
    }
}

enum RecoveryEvaluator {
    /// How long the wearer holds still.
    static var holdSeconds: TimeInterval {
        #if DEBUG
        if let i = ProcessInfo.processInfo.arguments.firstIndex(of: "-ThermyxRecoveryHold"),
           i + 1 < ProcessInfo.processInfo.arguments.count,
           let seconds = Double(ProcessInfo.processInfo.arguments[i + 1]) { return seconds }
        #endif
        return 180
    }

    /// A drop this big counts as cooling. Foot sensors wander a little, so
    /// anything smaller is noise.
    static let improvesAtC = 0.4
    /// A drop this big, ending below the heat threshold, counts as recovered
    /// even when the level hasn't come all the way down yet.
    static let recoversAtC = 1.0
    /// Below this share of the hold spent still, the test can't say.
    static let minimumStill = 0.6

    static func evaluate(_ samples: [RecoverySample], startLevel: ThermyxRiskLevel) -> RecoveryResult {
        let ordered = samples.sorted { $0.t < $1.t }
        guard let last = ordered.last, ordered.count >= 8, last.t >= 30 else {
            return RecoveryResult(outcome: .inconclusive, startC: nil, endC: nil, stillFraction: nil, loadEvened: nil,
                                  endLevel: ordered.last?.level ?? startLevel, minutesToImprove: nil, seconds: ordered.last?.t ?? 0)
        }
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        let head = ordered.filter { $0.t <= 15 }
        let tail = ordered.filter { $0.t >= last.t - 20 }
        let start = mean(head.map(\.footC)), end = mean(tail.map(\.footC))
        let known = ordered.compactMap(\.still)
        let still = known.isEmpty ? nil : Double(known.filter { $0 }.count) / Double(known.count)

        // The half-degree mark, on a five-second smoothing so one noisy
        // reading can't count as recovery.
        var minutes: Double?
        if let start {
            for sample in ordered where sample.t >= 15 {
                let window = ordered.filter { abs($0.t - sample.t) <= 5 }.map(\.footC)
                if let m = mean(window), start - m >= 0.5 { minutes = sample.t / 60; break }
            }
        }

        var evened: Bool?
        if let a = mean(head.compactMap(\.loadGap)), let b = mean(tail.compactMap(\.loadGap)) {
            if abs(b) <= abs(a) - 0.08 { evened = true } else if abs(b) > abs(a) + 0.08 { evened = false }
        }

        let drop = (start ?? 0) - (end ?? 0)
        let outcome: RecoveryOutcome
        if let still, still < minimumStill {
            outcome = .inconclusive
        } else if last.level == .normal, drop >= 0.3 || startLevel == .normal {
            outcome = .recovered
        } else if drop >= recoversAtC, (end ?? 99) < ThermyxRiskEngine.burnLimitC - 2 {
            outcome = .recovered
        } else if drop >= improvesAtC || last.level.severity < startLevel.severity {
            outcome = .improving
        } else {
            outcome = .notImproving
        }
        return RecoveryResult(outcome: outcome, startC: start, endC: end, stillFraction: still, loadEvened: evened,
                              endLevel: last.level, minutesToImprove: minutes, seconds: last.t)
    }
}

// MARK: - The session

/// One run of the test, from the steps to the result.
struct RecoverySession: Equatable {
    enum Phase: Equatable {
        case steps
        case holding(since: Date)
        case result(RecoveryResult)
    }

    let startedAt: Date
    let startLevel: ThermyxRiskLevel
    var phase: Phase = .steps
    var done: Set<RecoveryStep> = []
    /// Whether the wearer used the button to switch to Cool.
    var switchedToCool = false
    var samples: [RecoverySample] = []
    /// The foot the alert was about, for the record.
    var startFootC: Double?

    var holdSeconds: TimeInterval = RecoveryEvaluator.holdSeconds

    var holdStartedAt: Date? {
        if case .holding(let since) = phase { return since }
        return nil
    }

    /// The test can start once the wearer has stopped.
    var canStartHold: Bool { done.contains(.pause) }

    func remaining(now: Date) -> TimeInterval {
        guard let since = holdStartedAt else { return holdSeconds }
        return max(0, holdSeconds - now.timeIntervalSince(since))
    }

    func progress(now: Date) -> Double {
        guard holdSeconds > 0 else { return 1 }
        return min(1, max(0, 1 - remaining(now: now) / holdSeconds))
    }

    mutating func startHold(now: Date) {
        phase = .holding(since: now)
        samples = []
    }

    /// Adds a reading to the hold. Ignored outside it.
    mutating func add(_ reading: BilateralReading, level: ThermyxRiskLevel, now: Date) {
        guard let since = holdStartedAt, let c = reading.peakFootTemperatureC else { return }
        let still: Bool? = reading.present.compactMap(ThermyxHistorySample.activity(of:)).first.map { $0 != .walking }
        samples.append(RecoverySample(t: now.timeIntervalSince(since), footC: c, still: still, loadGap: reading.loadAsymmetry, level: level))
    }

    /// The foot is warming fast during the hold: worth saying so at once,
    /// not at the end.
    var isGettingWorse: Bool {
        guard let first = samples.first(where: { $0.t <= 20 }), let last = samples.last, last.t >= 40 else { return false }
        return last.footC - first.footC >= 0.5
    }

    mutating func finish(now: Date) -> RecoveryResult {
        let result = RecoveryEvaluator.evaluate(samples, startLevel: startLevel)
        phase = .result(result)
        return result
    }

    /// Which actions the steps the wearer ticked count as.
    var actions: [RecoveryAction] {
        var out: [RecoveryAction] = []
        for step in RecoveryStep.allCases where done.contains(step) {
            for a in step.actions where !out.contains(a) { out.append(a) }
        }
        if switchedToCool, !out.contains(.cooledDown) { out.append(.cooledDown) }
        return out
    }

    func record(result: RecoveryResult, actions: [RecoveryAction]) -> RecoveryRecord {
        RecoveryRecord(id: UUID(), startedAt: startedAt, startLevel: startLevel.rawValue, startFootC: result.startC ?? startFootC,
                       endFootC: result.endC, seconds: result.seconds, outcome: result.outcome, stillFraction: result.stillFraction,
                       loadEvened: result.loadEvened, actions: actions, guided: true)
    }
}

// MARK: - What the result says

extension RecoveryResult {
    /// What to do next, in plain words.
    func advice(level: ThermyxRiskLevel) -> String {
        switch outcome {
        case .recovered:
            return "Your foot has cooled and the readings are back where they should be. Ease back in, and keep drinking water."
        case .improving:
            return "It's cooling, but it isn't there yet. Keep resting, keep the insoles on Cool, and check again in a few minutes."
        case .notImproving:
            return level.severity >= ThermyxRiskLevel.high.severity
                ? "Your foot isn't cooling. Stay out of the heat, don't go back to work, and get someone to check on you. If you feel unwell, call for help."
                : "Your foot isn't cooling yet. Move somewhere cooler, take your shoes off if you can, and try again."
        case .inconclusive:
            return "You were moving for part of the test, so Thermyx can't tell. Sit still for the full time and try again."
        }
    }
}

// MARK: - Keeping them

/// The recoveries on this phone. The demo gets its own, held in memory, so
/// made-up recoveries never mix with real ones.
@MainActor
final class ThermyxRecoveryStore: ObservableObject {
    @Published private(set) var records: [RecoveryRecord] = []
    private var real: [RecoveryRecord] = []
    private(set) var inDemo = false

    private static var fileURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return base.appendingPathComponent("thermyx-recoveries.json")
    }

    init() {
        if let data = try? Data(contentsOf: Self.fileURL),
           let decoded = try? JSONDecoder().decode([RecoveryRecord].self, from: data) {
            real = decoded
        }
        records = real
    }

    func add(_ record: RecoveryRecord) {
        if inDemo { records.append(record); return }
        real.append(record)
        real = Array(real.suffix(200))
        records = real
        save()
    }

    func remove(_ id: UUID) {
        if inDemo { records.removeAll { $0.id == id }; return }
        real.removeAll { $0.id == id }
        records = real
        save()
    }

    func deleteAll() {
        real = []
        records = inDemo ? records : []
        save()
    }

    func enterDemo(_ demo: [RecoveryRecord]) {
        inDemo = true
        records = demo
    }

    func exitDemo() {
        inDemo = false
        records = real
    }

    private func save() {
        guard !inDemo else { return }
        try? JSONEncoder().encode(real).write(to: Self.fileURL, options: .atomic)
    }

    /// Recoveries for the demo: a few weeks of them, where resting, cooling
    /// and loosening laces tend to go with faster cooling, so the safety plan
    /// has something to learn. Deterministic.
    nonisolated static func demoRecords(now: Date = .now, calendar: Calendar = .current) -> [RecoveryRecord] {
        let plans: [(day: Int, level: ThermyxRiskLevel, actions: [RecoveryAction], rate: Double, start: Double)] = [
            (26, .high, [.rested, .cooledDown, .hydrated], 0.34, 38.6),
            (23, .caution, [.hydrated], 0.11, 38.1),
            (20, .high, [.stoppedActivity, .rested, .loosenedLaces], 0.31, 38.9),
            (17, .caution, [], 0.08, 38.2),
            (14, .high, [.rested, .cooledDown], 0.37, 38.7),
            (11, .caution, [.hydrated, .changedFootwear], 0.15, 38.3),
            (8, .high, [.rested, .loosenedLaces, .hydrated], 0.29, 38.8),
            (5, .caution, [], 0.10, 38.0),
            (2, .high, [.cooledDown, .rested], 0.35, 38.6),
        ]
        return plans.enumerated().map { index, p in
            let start = calendar.date(byAdding: .day, value: -p.day, to: now)?.addingTimeInterval(Double(index % 3) * 3600) ?? now
            return RecoveryRecord(id: UUID(), startedAt: start, startLevel: p.level.rawValue, startFootC: p.start,
                                  endFootC: p.start - p.rate * 3, seconds: 180,
                                  outcome: p.rate >= 0.25 ? .recovered : .improving, stillFraction: 0.95, loadEvened: p.rate >= 0.25,
                                  actions: p.actions, guided: true)
        }
    }
}
