import Foundation

// Heavy one-sided leaning, limping, and a persistently warmer foot, judged
// over minutes rather than packets.
//
// Why the old rule fired on every walk: when you walk, weight moves from one
// foot to the other with every step, so the *instantaneous* left-minus-right
// load swings by tens of points about 1.7 times a second even for a perfectly
// even gait. Any per-packet threshold, held for any length of time, is
// eventually crossed by that swing. The monitor below instead
//
//  1. averages each foot over whole 20 s bins (many complete step cycles), so
//     the alternation cancels and what is left is the real left/right bias;
//  2. compares that bias with the wearer's own usual bias, learned on this
//     phone from calm wear (some people always lean a little), shrunk toward
//     the population until their own data is plentiful;
//  3. requires the departure to hold for at least 3 of the last 5 minutes;
//  4. uses a lower bar to stay on than to come on, so it can't flap; and
//  5. treats walking and standing as different situations, and calls
//     something a *limp* only when walking shows uneven loading together with
//     corroborating evidence (uneven steadiness, or a clearly slower pace).
//
// Like everything personal in Thermyx it only adds caution, and it never
// goes past Caution by itself (see `ThermyxRiskEngine.assess`).

/// Every tunable in one place, so tests, the report and the code agree.
enum AsymmetryConfig {
    /// Packets are averaged into bins this long. At a normal 1.7 steps/s that
    /// is about 30 steps, comfortably many whole cycles.
    static let binSeconds: TimeInterval = 20
    /// Evidence is judged over this rolling window.
    static let windowSeconds: TimeInterval = 300
    /// A finding switches on when this much of the window shows it ...
    static let enterSeconds: TimeInterval = 180
    /// ... and at least this share of the usable time in the window does.
    static let enterFraction = 0.6
    /// Once on, it stays on until the last `exitLookbackSeconds` show it for
    /// less than `exitSeconds` (judged against the lower exit bars) ...
    static let exitLookbackSeconds: TimeInterval = 120
    static let exitSeconds: TimeInterval = 40
    /// ... and never clears sooner than this after switching on.
    static let minimumHoldSeconds: TimeInterval = 120
    /// ... and at least this much of the last `exitLookbackSeconds` shows it
    /// too, so a pattern that has already stopped can't switch it on.
    static let enterRecentSeconds: TimeInterval = 60
    /// A bin needs this many packets from each foot to count.
    static let minimumSamplesPerFoot = 3
    /// No fresh bin for this long and nothing is reported: stale evidence is
    /// not a finding.
    static let staleAfter: TimeInterval = 90
    /// Same walking line the history buckets use.
    static let walkingCadence = 30.0
    /// Between this and `walkingCadence` a bin is a start or a stop, not a
    /// steady state, and is left out.
    static let transitionCadence = 10.0

    /// Walking load only counts when the packets can resolve the stride: the
    /// stride, sampled at the packet rate, must not alias to a beat slower than
    /// this many cycles per bin. Sampled once a second, a 120 steps/min stride
    /// (1 Hz per foot) lands on the same phase every packet and looks like a
    /// constant lean; averaging whole cycles needs several beats per bin.
    static let minimumBeatsPerBin = 1.5

    /// Exit bars are this share of the entry bars.
    static let exitRatio = 0.6
    /// A bin only teaches the baseline if it is within this share of the
    /// entry bar of what is already usual (and never while a finding is on).
    static let learnRatio = 0.8

    // Entry bars, before widening for a wearer whose own readings are noisy.
    /// Heavy lean: 10 points of left-minus-right load share beyond the usual
    /// (a 55/45 split), standing or walking.
    static let leanEnter = 0.10
    static let leanEnterMax = 0.16
    /// Limp, walking only. Looser per channel because two channels must agree.
    static let limpLoadEnter = 0.07
    static let limpGaitEnter = 0.06
    static let limpGaitEnterMax = 0.12
    /// Slower than usual by this share counts as the corroborating channel.
    static let cadenceDropEnter = 0.12
    static let cadenceDropEnterMax = 0.25
    /// A foot warmer than usual by this many °C.
    static let tempEnter = 1.0
    static let tempEnterMax = 2.0

    /// Robust spreads are widened to this many times the wearer's own
    /// spread before an entry bar is considered.
    static let spreadMultiple = 3.2

    /// Neighbouring 20 s bins are strongly alike, so n bins count as roughly
    /// n / this many independent looks when blending with the prior.
    static let correlationFactor = 6.0

    /// Minimum bins before the wearer's own series is treated as established.
    static let establishedBins = 15

    // Fixed defaults used when there is no usable population prior.
    static let defaultLean = (mean: 0.0, between: 0.06, within: 0.03)
    static let defaultGaitGap = (mean: 0.0, between: 0.03, within: 0.02)
    static let defaultTempGap = (mean: 0.0, between: 0.4, within: 0.25)
    /// A prior may move the baseline by at most this far from the wearer's
    /// own median.
    static let maxPullLean = 0.05
    static let maxPullGait = 0.03
    static let maxPullTemp = 0.5
    /// Learned baselines are kept inside these bounds, so "usual" can never
    /// drift to somewhere an alert should have fired.
    static let leanClamp = -0.12...0.12
    static let gaitGapClamp = -0.08...0.08
    static let tempGapClamp = -1.0...1.0
}

/// What the wearer is doing during a bin.
enum MovementContext: String, Codable, Equatable {
    case walking, standing, resting
    /// Starting, stopping, or not enough signal to tell.
    case transition
}

/// 20 s of both feet, averaged.
struct PairBin: Equatable {
    var start: Date
    var duration: TimeInterval
    var context: MovementContext
    /// (L − R) / (L + R) of the mean load on each foot; positive leans left.
    /// Nil without a usable load channel.
    var lean: Double?
    /// Left minus right steadiness.
    var gaitGap: Double?
    /// Mean steps per minute across the feet.
    var cadence: Double?
    /// Left minus right foot temperature, °C.
    var tempGap: Double?
    /// Whether both insoles were doing the same thing (both passive, both
    /// cooling, ...). A gap while one is heating is the insole's doing.
    var modesMatch: Bool
    /// Every packet in the bin was calm (Normal level, no heating).
    var calm: Bool
}

/// What a finding was based on, so it can be named in "Why am I seeing this?".
struct AsymmetryContribution: Equatable {
    enum Feature: String, Equatable {
        case loadShare, steadinessGap, pace, temperatureGap
    }
    var feature: Feature
    /// The observed departure from the wearer's usual (a share, a score, or °C).
    var observed: Double
    /// The bar it had to reach.
    var threshold: Double
    /// The wearer's usual, when there is one worth quoting.
    var usual: Double?
}

/// What the monitor currently reports.
struct AsymmetryStatus: Equatable {
    enum Kind: String, Codable, Equatable {
        case lean, limp, warmerFoot
    }

    struct Finding: Equatable, Identifiable {
        var kind: Kind
        /// The foot carrying more (lean, limp), or running warmer.
        var foot: Foot
        /// How long the pattern has been present.
        var heldSeconds: TimeInterval
        /// Whether walking was involved (always for a limp).
        var whileWalking: Bool
        var contributions: [AsymmetryContribution]
        var id: String { kind.rawValue }
    }

    /// Windowed figures behind the plain-English `pressure` and `gait`
    /// readouts and the explanation panel, present whether or not anything is
    /// flagged.
    struct Metrics: Equatable {
        /// Median left-minus-right share of the arch pressure over the
        /// window, loaded bins. Positive leans left.
        var lean: Double?
        var usualLean: Double?
        /// How far the window's median is beyond the usual (signed, same
        /// direction as `lean`), and how many bins it rests on.
        var leanBeyondUsual: Double?
        var leanBins = 0
        var leanBar: Double
        /// Median left-minus-right steadiness over the window's walking bins.
        /// Positive means the left foot is the steadier one.
        var gaitGap: Double?
        var usualGaitGap: Double?
        var gaitBeyondUsual: Double?
        var gaitBins = 0
        var gaitBar = AsymmetryConfig.limpGaitEnter
        /// Median left-minus-right temperature, °C, matched-mode bins.
        var tempGap: Double?
        var usualTempGap: Double?
        var tempBar: Double
    }

    var findings: [Finding]
    var metrics: Metrics?

    static let none = AsymmetryStatus(findings: [], metrics: nil)

    var isEmpty: Bool { findings.isEmpty }
    func finding(_ kind: Kind) -> Finding? { findings.first { $0.kind == kind } }
}

// MARK: - Plain-English readouts

extension AsymmetryStatus {
    /// Fewer bins than this (about a minute) and a readout says nothing yet.
    static let readoutMinimumBins = 3
    /// Beyond-usual differences under this many points read as "even".
    static let evenWithinPoints = 3

    /// Left versus right arch pressure: which foot is carrying more than
    /// usual, by how much, and whether it has been flagged.
    struct PressureReadout: Equatable {
        /// The foot carrying more weight than is usual for this wearer. Nil
        /// when the balance is within a few points of their usual.
        var carryingMore: Foot?
        /// Whole points beyond the wearer's usual balance (0 when even).
        var pointsBeyondUsual: Int
        /// The split right now: points more on the left (positive) or the
        /// right (negative), and the wearer's usual.
        var currentPoints: Int
        var usualPoints: Int
        /// Held long enough to count as heavy leaning or an uneven walk.
        var isFlagged: Bool
        /// One sentence for the screen.
        var sentence: String
    }

    /// Left versus right steadiness while walking.
    struct GaitReadout: Equatable {
        /// The foot that is less steady than usual relative to the other.
        /// Nil when even.
        var lessSteady: Foot?
        var pointsBeyondUsual: Int
        /// Left minus right steadiness right now, in points (positive: the
        /// left foot is steadier), and the wearer's usual.
        var currentPoints: Int
        var usualPoints: Int
        var isFlagged: Bool
        var sentence: String
    }

    /// Nil until about a minute of standing or walking has been seen.
    var pressure: PressureReadout? {
        guard let m = metrics, m.leanBins >= Self.readoutMinimumBins,
              let beyond = m.leanBeyondUsual, let lean = m.lean else { return nil }
        let points = Int((abs(beyond) * 100).rounded())
        let heavier: Foot? = points > Self.evenWithinPoints ? (beyond > 0 ? .left : .right) : nil
        let flagging = finding(.lean) ?? finding(.limp)
        let sentence: String
        if let flagging {
            sentence = AsymmetryWording.reason(flagging)
        } else if let heavier {
            sentence = "A little more weight on your \(heavier.label.lowercased()) foot than usual (\(points) points)."
        } else {
            sentence = "Your weight is balanced the way it usually is."
        }
        return PressureReadout(
            carryingMore: flagging?.foot ?? heavier, pointsBeyondUsual: points,
            currentPoints: Int((lean * 100).rounded()), usualPoints: Int(((m.usualLean ?? 0) * 100).rounded()),
            isFlagged: flagging != nil, sentence: sentence
        )
    }

    /// Nil until about a minute of walking has been seen.
    var gait: GaitReadout? {
        guard let m = metrics, m.gaitBins >= Self.readoutMinimumBins,
              let beyond = m.gaitBeyondUsual, let gap = m.gaitGap else { return nil }
        let points = Int((abs(beyond) * 100).rounded())
        // A positive gap means the left foot is the steadier one.
        let less: Foot? = points > Self.evenWithinPoints ? (beyond > 0 ? .right : .left) : nil
        let flagged = finding(.limp)?.contributions.contains { $0.feature == .steadinessGap } == true
        let sentence: String
        if flagged, let less {
            sentence = "Your \(less.label.lowercased()) foot has been less steady than usual for a few minutes."
        } else if let less {
            sentence = "Your \(less.label.lowercased()) foot is a little less steady than usual (\(points) points)."
        } else {
            sentence = "Your steps are as even between your feet as usual."
        }
        return GaitReadout(
            lessSteady: less, pointsBeyondUsual: points,
            currentPoints: Int((gap * 100).rounded()), usualPoints: Int(((m.usualGaitGap ?? 0) * 100).rounded()),
            isFlagged: flagged, sentence: sentence
        )
    }
}

/// The wearer's learned left/right norms. Persisted on the phone and expired
/// like the rest of the personal data.
struct AsymmetryBaseline: Codable, Equatable {
    var standingLean = RollingSeries(capacity: 180)
    var walkingLean = RollingSeries(capacity: 180)
    var walkingGaitGap = RollingSeries(capacity: 180)
    var walkingCadence = RollingSeries(capacity: 180)
    var temperatureGap = RollingSeries(capacity: 180)
    var updatedAt: Date?

    /// Bins learned from, all series together.
    var binsLearned: Int { standingLean.count + walkingLean.count + walkingGaitGap.count + temperatureGap.count }

    func isExpired(now: Date = .now) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > PersonalBaseline.expiry
    }
}

struct AsymmetryMonitor {
    private(set) var baseline = AsymmetryBaseline()
    /// What's typical across wearers. Nil, or any stat that fails
    /// `PopulationPriors.usable`, means the fixed defaults are used.
    var priors: PopulationPriors?

    // MARK: Transient state

    private var builder = AsymmetryBinBuilder()
    private var evidence: [BinEvidence] = []
    private var lastDataEnd: Date?
    private var leanState = DetectorState()
    private var limpState = DetectorState()
    private var tempState = DetectorState()
    /// Bumped whenever the baseline changes, so a store knows when to save.
    private(set) var learnedBins = 0

    init(baseline: AsymmetryBaseline = AsymmetryBaseline(), priors: PopulationPriors? = nil) {
        self.baseline = baseline
        self.priors = priors
    }

    mutating func reset() {
        self = AsymmetryMonitor(baseline: AsymmetryBaseline(), priors: priors)
    }

    /// Forget the evidence in flight (an insole dropped out, say) but keep
    /// what has been learned about the wearer.
    mutating func resetEvidence() {
        builder = AsymmetryBinBuilder()
        evidence.removeAll()
        lastDataEnd = nil
        leanState = DetectorState()
        limpState = DetectorState()
        tempState = DetectorState()
    }

    // MARK: Feeding

    /// Folds in a pair reading. Each insole's packets are used once, by
    /// timestamp, so the same latest-reading-per-foot arriving again with the
    /// other foot's update does not count twice.
    ///
    /// - Parameters:
    ///   - learn: Whether this wearer's data may teach the baseline. False for
    ///     Demo Mode and anything simulated; detection still runs.
    ///   - calm: Whether the fixed rules see a calm moment (Normal, not
    ///     heating). Elevated or heating minutes never teach the baseline.
    mutating func observe(_ pair: BilateralReading, learn: Bool = true, calm: Bool = true) {
        for reading in pair.present {
            guard let bin = builder.add(reading, calm: calm) else { continue }
            ingest(bin, learn: learn)
        }
    }

    // MARK: Status

    /// The current findings. Stale evidence reports nothing.
    func status(now: Date = .now) -> AsymmetryStatus {
        guard let end = lastDataEnd, now.timeIntervalSince(end) <= AsymmetryConfig.staleAfter else { return .none }
        let estimates = self.estimates()
        let window = windowBins(endingAt: end)
        var findings: [AsymmetryStatus.Finding] = []

        if leanState.active, let side = leanState.side {
            let loaded = window.filter { $0.leanExcess != nil }
            let walkingShare = Double(loaded.filter { $0.context == .walking }.count) / Double(max(1, loaded.count))
            let flagged = loaded.compactMap { $0.leanExcess }.filter { side == .left ? $0 > 0 : $0 < 0 }
            findings.append(.init(
                kind: .lean, foot: side,
                heldSeconds: held(leanState, until: end),
                whileWalking: walkingShare >= 0.5,
                contributions: [.init(feature: .loadShare, observed: RobustStats.median(flagged).map(abs) ?? 0,
                                      threshold: estimates.thresholds.lean, usual: nil)]
            ))
        }
        if limpState.active, let side = limpState.side {
            let walking = window.filter { $0.context == .walking }
            var contributions: [AsymmetryContribution] = []
            let sign: (Double) -> Bool = { side == .left ? $0 > 0 : $0 < 0 }
            let load = walking.compactMap { $0.leanExcess }.filter(sign)
            if let m = RobustStats.median(load), abs(m) >= estimates.thresholds.limpLoad * AsymmetryConfig.exitRatio {
                contributions.append(.init(feature: .loadShare, observed: abs(m), threshold: estimates.thresholds.limpLoad, usual: nil))
            }
            let gait = walking.compactMap { $0.gaitExcess }.filter(sign)
            if let m = RobustStats.median(gait), abs(m) >= estimates.thresholds.limpGait * AsymmetryConfig.exitRatio {
                contributions.append(.init(feature: .steadinessGap, observed: abs(m), threshold: estimates.thresholds.limpGait, usual: nil))
            }
            let pace = walking.compactMap { $0.cadenceDrop }
            if let m = RobustStats.median(pace), m >= estimates.thresholds.cadenceDrop * AsymmetryConfig.exitRatio {
                contributions.append(.init(feature: .pace, observed: m, threshold: estimates.thresholds.cadenceDrop,
                                           usual: estimates.cadenceUsual))
            }
            findings.append(.init(kind: .limp, foot: side, heldSeconds: held(limpState, until: end), whileWalking: true,
                                  contributions: contributions))
        }
        if tempState.active, let side = tempState.side {
            let flagged = window.compactMap { $0.tempExcess }.filter { side == .left ? $0 > 0 : $0 < 0 }
            findings.append(.init(
                kind: .warmerFoot, foot: side,
                heldSeconds: held(tempState, until: end),
                whileWalking: false,
                contributions: [.init(feature: .temperatureGap, observed: RobustStats.median(flagged).map(abs) ?? 0,
                                      threshold: estimates.thresholds.temp, usual: estimates.tempGap.mean)]
            ))
        }

        // Windowed figures for the readouts and the "Why" panel.
        let leanExcesses = window.compactMap(\.leanExcess)
        let leanNow = RobustStats.median(window.compactMap { bin -> Double? in
            guard let excess = bin.leanExcess else { return nil }
            return excess + (bin.context == .walking ? estimates.walkingLean.mean : estimates.standingLean.mean)
        })
        let usualLean = window.last(where: { $0.leanExcess != nil }).map {
            $0.context == .walking ? estimates.walkingLean.mean : estimates.standingLean.mean
        }
        let gaitExcesses = window.compactMap(\.gaitExcess)
        let tempNow = RobustStats.median(window.compactMap { $0.tempExcess.map { $0 + estimates.tempGap.mean } })
        let metrics = AsymmetryStatus.Metrics(
            lean: leanNow, usualLean: usualLean,
            leanBeyondUsual: RobustStats.median(leanExcesses), leanBins: leanExcesses.count,
            leanBar: estimates.thresholds.lean,
            gaitGap: RobustStats.median(gaitExcesses).map { $0 + estimates.gaitGap.mean }, usualGaitGap: estimates.gaitGap.mean,
            gaitBeyondUsual: RobustStats.median(gaitExcesses), gaitBins: gaitExcesses.count,
            gaitBar: estimates.thresholds.limpGait,
            tempGap: tempNow, usualTempGap: estimates.tempGap.mean, tempBar: estimates.thresholds.temp
        )
        return AsymmetryStatus(findings: findings, metrics: metrics)
    }

    private func held(_ state: DetectorState, until end: Date) -> TimeInterval {
        max(0, end.timeIntervalSince(state.since ?? end))
    }

    // MARK: Estimates

    /// One series' blended baseline.
    struct SeriesEstimate: Equatable {
        /// The blended usual, used to judge departures.
        var mean: Double
        /// The wearer's own bin-to-bin spread (robust, shrunk).
        var within: Double
        var priorWeight: Double
        var count: Int
        /// Where a bin must be near to count as "usual" for learning: the
        /// wearer's own median once established, else the fixed default. Never
        /// the population prior, so a prior that doesn't fit a wearer can't
        /// stop them from teaching the model what is normal for them.
        var anchor: Double
    }

    struct Thresholds: Equatable {
        var lean: Double
        var limpLoad: Double
        var limpGait: Double
        var cadenceDrop: Double
        var temp: Double
    }

    struct Estimates: Equatable {
        var standingLean: SeriesEstimate
        var walkingLean: SeriesEstimate
        var gaitGap: SeriesEstimate
        var tempGap: SeriesEstimate
        /// The wearer's usual walking cadence, once established.
        var cadenceUsual: Double?
        var cadenceRelativeSD: Double?
        var thresholds: Thresholds
    }

    /// The blended baselines and the bars they set. Public so tests and the
    /// report can show how the prior fades.
    func estimates() -> Estimates {
        let d = AsymmetryConfig.self
        let standing = Self.estimate(baseline.standingLean, prior: PopulationPriors.usable(priors?.standingLean),
                                     defaults: d.defaultLean, floor: 0.02, maxPull: d.maxPullLean, clamp: d.leanClamp)
        let walking = Self.estimate(baseline.walkingLean, prior: PopulationPriors.usable(priors?.walkingLean),
                                    defaults: d.defaultLean, floor: 0.02, maxPull: d.maxPullLean, clamp: d.leanClamp)
        let gait = Self.estimate(baseline.walkingGaitGap, prior: PopulationPriors.usable(priors?.steadinessGap),
                                 defaults: d.defaultGaitGap, floor: 0.01, maxPull: d.maxPullGait, clamp: d.gaitGapClamp)
        let temp = Self.estimate(baseline.temperatureGap, prior: nil,
                                 defaults: d.defaultTempGap, floor: 0.1, maxPull: d.maxPullTemp, clamp: d.tempGapClamp)

        var cadence: Double?
        var relSD: Double?
        if baseline.walkingCadence.count >= 10, let m = baseline.walkingCadence.median, m > 0 {
            cadence = m
            relSD = (baseline.walkingCadence.robustSD ?? 0) / m
        }

        let leanWithin = max(standing.within, walking.within)
        let thresholds = Thresholds(
            lean: min(max(d.leanEnter, d.spreadMultiple * leanWithin), d.leanEnterMax),
            limpLoad: min(max(d.limpLoadEnter, d.spreadMultiple * walking.within), d.leanEnterMax),
            limpGait: min(max(d.limpGaitEnter, d.spreadMultiple * gait.within), d.limpGaitEnterMax),
            cadenceDrop: min(max(d.cadenceDropEnter, d.spreadMultiple * (relSD ?? 0)), d.cadenceDropEnterMax),
            temp: min(max(d.tempEnter, d.spreadMultiple * temp.within), d.tempEnterMax)
        )
        return Estimates(standingLean: standing, walkingLean: walking, gaitGap: gait, tempGap: temp,
                         cadenceUsual: cadence, cadenceRelativeSD: relSD, thresholds: thresholds)
    }

    private static func estimate(
        _ series: RollingSeries,
        prior: PopulationPriors.Stats?,
        defaults: (mean: Double, between: Double, within: Double),
        floor: Double,
        maxPull: Double,
        clamp: ClosedRange<Double>
    ) -> SeriesEstimate {
        let priorMean = (prior?.mean).flatMap { $0.isFinite ? $0 : nil } ?? defaults.mean
        let between = max(prior?.sd ?? defaults.between, floor)
        let within2 = Shrinkage.variance(
            sample: series.robustSD.map { $0 * $0 },
            degrees: max(0, series.count - 1),
            prior: defaults.within * defaults.within,
            priorDegrees: 10
        )
        let within = max(within2.squareRoot(), floor / 2)
        let nEff = Shrinkage.effectiveCount(series.count, correlationFactor: AsymmetryConfig.correlationFactor)
        let sample = series.count >= 3 ? series.median : nil
        var blended = Shrinkage.blend(sampleMean: sample, withinSD: within, effectiveN: nEff,
                                      priorMean: priorMean.clamped(to: clamp), priorSD: between)
        // However odd the prior is, it can move the answer at most `maxPull`
        // from the wearer's own median, or from the fixed default when there
        // is no data yet.
        blended = Shrinkage.bounded(blended, around: sample ?? defaults.mean, maxPull: maxPull)
        let established = series.count >= AsymmetryConfig.establishedBins
        return SeriesEstimate(mean: blended.mean.clamped(to: clamp), within: within,
                              priorWeight: blended.priorWeight, count: series.count,
                              anchor: established ? (sample ?? defaults.mean) : defaults.mean)
    }

    // MARK: Evidence

    private struct BinEvidence: Equatable {
        var start: Date
        var duration: TimeInterval
        var context: MovementContext
        /// Lean beyond the usual for this context; positive favours the left.
        var leanExcess: Double?
        /// Steadiness gap beyond the usual, walking only; positive favours left.
        var gaitExcess: Double?
        /// How far below the usual walking cadence, as a share; walking only.
        var cadenceDrop: Double?
        /// Temperature gap beyond the usual, matched modes only.
        var tempExcess: Double?

        var end: Date { start.addingTimeInterval(duration) }
    }

    private struct DetectorState {
        var active = false
        var side: Foot?
        /// Start of the first bin that supported the finding.
        var since: Date?
        /// When it switched on, in data time.
        var activatedAt: Date?
        /// After a finding clears, evidence from before that moment is
        /// history: without this the minutes that made the finding would
        /// switch it straight back on.
        var ignoreBefore: Date?
    }

    private func windowBins(endingAt end: Date) -> [BinEvidence] {
        let cutoff = end.addingTimeInterval(-AsymmetryConfig.windowSeconds)
        return evidence.filter { $0.start >= cutoff }
    }

    private mutating func ingest(_ bin: PairBin, learn: Bool) {
        let est = estimates()
        var e = BinEvidence(start: bin.start, duration: bin.duration, context: bin.context)
        let loaded = bin.context == .walking || bin.context == .standing
        if loaded, let lean = bin.lean {
            let usual = bin.context == .walking ? est.walkingLean.mean : est.standingLean.mean
            e.leanExcess = lean - usual
        }
        if bin.context == .walking {
            if let gap = bin.gaitGap { e.gaitExcess = gap - est.gaitGap.mean }
            if let cadence = bin.cadence, let usual = est.cadenceUsual { e.cadenceDrop = (usual - cadence) / usual }
        }
        if bin.modesMatch, let gap = bin.tempGap, bin.context != .transition { e.tempExcess = gap - est.tempGap.mean }

        evidence.append(e)
        lastDataEnd = e.end
        let cutoff = e.end.addingTimeInterval(-AsymmetryConfig.windowSeconds * 2)
        evidence.removeAll { $0.start < cutoff }

        if learn, bin.calm { teach(bin, evidence: e, estimates: est) }
        evaluate(at: e.end)
    }

    /// Teaches the baseline from a bin, only when it looks like the wearer's
    /// normal: calm, no finding switched on, and not far from what is already
    /// usual (outlier rejection, so a limp can't become "my usual limp").
    private mutating func teach(_ bin: PairBin, evidence e: BinEvidence, estimates est: Estimates) {
        let d = AsymmetryConfig.self
        var changed = false
        func near(_ value: Double?, _ anchor: Double, within band: Double) -> Bool {
            guard let value else { return false }
            return abs(value - anchor) < band
        }
        let findingOn = leanState.active || limpState.active
        if !findingOn, near(bin.lean, bin.context == .walking ? est.walkingLean.anchor : est.standingLean.anchor,
                            within: d.learnRatio * est.thresholds.lean), let lean = bin.lean, bin.context == .walking || bin.context == .standing {
            if bin.context == .walking { baseline.walkingLean.append(lean) } else { baseline.standingLean.append(lean) }
            changed = true
        }
        if bin.context == .walking, !findingOn {
            if let gap = bin.gaitGap, near(gap, est.gaitGap.anchor, within: d.learnRatio * est.thresholds.limpGait) {
                baseline.walkingGaitGap.append(gap)
                changed = true
            }
            if let cadence = bin.cadence, cadence >= d.walkingCadence, cadence <= 220 {
                // Near the usual pace, or there is no usual pace yet.
                if let usual = est.cadenceUsual, abs(cadence - usual) / usual >= 0.3 {} else {
                    baseline.walkingCadence.append(cadence)
                    changed = true
                }
            }
        }
        if !tempState.active, bin.modesMatch, bin.context != .transition, let gap = bin.tempGap {
            // Two sensors can differ by a degree or so for no reason that
            // matters, so until the wearer's own gap is established anything
            // up to 1.5 °C is taken as theirs.
            let band = est.tempGap.count >= d.establishedBins ? d.learnRatio * est.thresholds.temp : 1.5
            if near(gap, est.tempGap.anchor, within: band) {
                baseline.temperatureGap.append(gap)
                changed = true
            }
        }
        if changed {
            baseline.updatedAt = bin.start
            learnedBins += 1
        }
    }

    // MARK: Detectors

    private mutating func evaluate(at end: Date) {
        let th = estimates().thresholds
        let window = windowBins(endingAt: end)
        Self.step(&leanState, window: window, end: end,
             eligible: { $0.leanExcess != nil },
             flag: { e, scale in Self.sign(e.leanExcess, atLeast: th.lean * scale) })
        Self.step(&limpState, window: window, end: end,
             eligible: { $0.context == .walking && ($0.leanExcess != nil || $0.gaitExcess != nil) },
             flag: { e, scale in Self.limpSide(e, th, scale: scale) })
        Self.step(&tempState, window: window, end: end,
             eligible: { $0.tempExcess != nil },
             flag: { e, scale in Self.sign(e.tempExcess, atLeast: th.temp * scale) })
    }

    /// Positive favours the left foot, negative the right.
    private static func sign(_ x: Double?, atLeast bar: Double) -> Foot? {
        guard let x, abs(x) >= bar else { return nil }
        return x > 0 ? .left : .right
    }

    /// A walking bin shows a limp when uneven loading and/or uneven steadiness
    /// agree on a side, and at least two channels (one of them lateral, the
    /// other possibly the pace) are beyond their bars.
    private static func limpSide(_ e: BinEvidence, _ th: Thresholds, scale: Double) -> Foot? {
        let load = sign(e.leanExcess, atLeast: th.limpLoad * scale)
        let gait = sign(e.gaitExcess, atLeast: th.limpGait * scale)
        if let load, let gait, load != gait { return nil }
        guard let side = load ?? gait else { return nil }
        var channels = 0
        if load != nil { channels += 1 }
        if gait != nil { channels += 1 }
        if let drop = e.cadenceDrop, drop >= th.cadenceDrop * scale { channels += 1 }
        return channels >= 2 ? side : nil
    }

    private static func step(
        _ state: inout DetectorState,
        window: [BinEvidence],
        end: Date,
        eligible: (BinEvidence) -> Bool,
        flag: (BinEvidence, Double) -> Foot?
    ) {
        let d = AsymmetryConfig.self
        if state.active {
            // Release is judged on the latest couple of minutes against the
            // lower exit bars, so correcting a lean clears the note promptly
            // without a borderline wearer flapping.
            guard let side = state.side else { state = DetectorState(); return }
            let lookback = end.addingTimeInterval(-d.exitLookbackSeconds)
            var recent: TimeInterval = 0
            for e in window where e.start >= lookback && eligible(e) && flag(e, d.exitRatio) == side { recent += e.duration }
            let held = end.timeIntervalSince(state.activatedAt ?? end)
            if recent < d.exitSeconds, held >= d.minimumHoldSeconds { state = DetectorState(ignoreBefore: end) }
            return
        }

        let lookback = end.addingTimeInterval(-d.exitLookbackSeconds)
        var usable: TimeInterval = 0
        var flagged: [Foot: TimeInterval] = [:]
        var recent: [Foot: TimeInterval] = [:]
        var earliest: [Foot: Date] = [:]
        for e in window where eligible(e) && e.start >= (state.ignoreBefore ?? .distantPast) {
            usable += e.duration
            if let side = flag(e, 1) {
                flagged[side, default: 0] += e.duration
                if e.start >= lookback { recent[side, default: 0] += e.duration }
                if earliest[side] == nil { earliest[side] = e.start }
            }
        }
        // Three minutes of the last five, and still happening now.
        if let best = flagged.max(by: { $0.value < $1.value }),
           best.value >= d.enterSeconds, usable > 0, best.value / usable >= d.enterFraction,
           (recent[best.key] ?? 0) >= d.enterRecentSeconds {
            state = DetectorState(active: true, side: best.key, since: earliest[best.key], activatedAt: end)
        }
    }
}

// MARK: - Binning

/// Collects per-foot packets into fixed 20 s bins, by packet timestamp.
struct AsymmetryBinBuilder {
    struct Accumulator {
        var count = 0
        var load = 0.0, loadN = 0
        var gait = 0.0, gaitN = 0
        var temp = 0.0, tempN = 0
        var cadence = 0.0, cadenceN = 0
        var standing = 0.0, standingN = 0
        /// Bit set: 1 passive, 2 heating, 4 cooling.
        var modes = 0
    }

    private var index: Int?
    private var feet: [Foot: Accumulator] = [:]
    private var calm = true
    private var lastStamp: [Foot: Date] = [:]
    /// Recent gaps between a foot's packets, for the packet rate. The rate is
    /// taken from these rather than from a bin's packet count, which is off by
    /// one or two and would move an alias around.
    private var intervals: [Foot: [Double]] = [:]

    /// Adds a packet; returns the bin it completed, if any.
    mutating func add(_ r: ThermyxReading, calm packetCalm: Bool) -> PairBin? {
        // Each packet is used once; a replayed or older one is ignored.
        if let last = lastStamp[r.foot] {
            if r.timestamp <= last { return nil }
            let gap = r.timestamp.timeIntervalSince(last)
            // A silence is not the packet rate.
            if gap < 5 {
                var recent = intervals[r.foot] ?? []
                recent.append(gap)
                if recent.count > 41 { recent.removeFirst(recent.count - 41) }
                intervals[r.foot] = recent
            }
        }
        lastStamp[r.foot] = r.timestamp

        let binIndex = Int((r.timestamp.timeIntervalSince1970 / AsymmetryConfig.binSeconds).rounded(.down))
        var finished: PairBin?
        if let current = index {
            // A late packet for a bin that has already closed is dropped.
            if binIndex < current { return nil }
            if binIndex > current {
                finished = finish(index: current)
                feet = [:]
                calm = true
                index = binIndex
            }
        } else {
            index = binIndex
        }

        calm = calm && packetCalm
        var a = feet[r.foot] ?? Accumulator()
        a.count += 1
        if let v = r.pressureBalance {
            a.load += v; a.loadN += 1
        }
        if let v = r.gaitStability { a.gait += v; a.gaitN += 1 }
        if let v = r.footTemperatureC { a.temp += v; a.tempN += 1 }
        if let v = r.cadenceStepsPerMinute { a.cadence += v; a.cadenceN += 1 }
        if let v = r.standingFraction { a.standing += v; a.standingN += 1 }
        a.modes |= r.thermalMode == .heating ? 2 : r.thermalMode == .cooling ? 4 : 1
        feet[r.foot] = a
        return finished
    }

    /// How many cycles of the stride, as seen through the packets, fit in a
    /// bin: the stride frequency folded to its alias at this packet rate.
    static func beatsPerBin(strideHz: Double, packetHz: Double) -> Double {
        guard packetHz > 0 else { return 0 }
        let folded = abs(strideHz - packetHz * (strideHz / packetHz).rounded())
        return folded * AsymmetryConfig.binSeconds
    }

    private func finish(index: Int) -> PairBin? {
        let minimum = AsymmetryConfig.minimumSamplesPerFoot
        guard let l = feet[.left], let r = feet[.right], l.count >= minimum, r.count >= minimum else { return nil }
        func mean(_ sum: Double, _ n: Int) -> Double? { n > 0 ? sum / Double(n) : nil }
        func both(_ pick: (Accumulator) -> Double?) -> Double? {
            guard let a = pick(l), let b = pick(r) else { return nil }
            return a - b
        }

        let loadL = mean(l.load, l.loadN), loadR = mean(r.load, r.loadN)
        var lean: Double?
        if let loadL, let loadR, l.loadN >= minimum, r.loadN >= minimum, loadL + loadR > 0.1 {
            lean = (loadL - loadR) / (loadL + loadR)
        }
        let cadences = [mean(l.cadence, l.cadenceN), mean(r.cadence, r.cadenceN)].compactMap { $0 }
        let standings = [mean(l.standing, l.standingN), mean(r.standing, r.standingN)].compactMap { $0 }
        let cadence = RobustStats.mean(cadences)
        let standing = RobustStats.mean(standings)
        let level = RobustStats.mean([loadL, loadR].compactMap { $0 })

        let context: MovementContext
        let d = AsymmetryConfig.self
        if let cadence {
            if cadence >= d.walkingCadence { context = .walking }
            else if cadence >= d.transitionCadence { context = .transition }
            else if let standing { context = standing >= 0.5 ? .standing : .resting }
            else if let level { context = level >= 0.25 ? .standing : .resting }
            else { context = .transition }
        } else if let standing {
            // Without a step count, walking can't be told from standing, so
            // only the clearly still cases are used.
            context = standing >= 0.8 ? .standing : standing <= 0.2 ? .resting : .transition
        } else {
            context = .transition
        }

        // Walking load is only an average of whole steps if the packets
        // resolve the stride.
        if context == .walking, let cadence {
            let gaps = RobustStats.median((intervals[.left] ?? []) + (intervals[.right] ?? [])) ?? 0
            let packetRate = gaps > 0 ? 1 / gaps : 0
            if Self.beatsPerBin(strideHz: cadence / 120, packetHz: packetRate) < d.minimumBeatsPerBin { lean = nil }
        }

        return PairBin(
            start: Date(timeIntervalSince1970: Double(index) * d.binSeconds),
            duration: d.binSeconds,
            context: context,
            lean: lean,
            gaitGap: both { a in mean(a.gait, a.gaitN) },
            cadence: cadence,
            tempGap: both { a in mean(a.temp, a.tempN) },
            modesMatch: l.modes == r.modes,
            calm: calm
        )
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}
