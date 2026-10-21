import Foundation

/// The wearer's own normal, learned on this phone, and the conservative
/// layer built on it.
///
/// Rules this layer keeps:
/// - It can only **add** caution. It never lowers a level set by the fixed
///   thresholds in `ThermyxRiskEngine`, and on its own it never goes past
///   Caution.
/// - It learns only from calm minutes (level Normal, no heating), so a hot
///   afternoon cannot teach it that hot is normal. Learned values are also
///   clamped well inside the fixed limits.
/// - Wild minutes are rejected rather than learned (see `learn`), and a
///   new wearer's usual starts from what is typical across wearers and lets
///   go of it as their own minutes accumulate (see `posterior`).
/// - It is one baseline per wearer. A session label is a note on the
///   current session, not a separate baseline.
/// - It stays on this phone and expires if unused for 90 days.
struct PersonalBaseline: Codable, Equatable {
    /// Exponentially weighted mean and variance of calm-minute foot
    /// temperature (°C) and steadiness (0–1).
    var footMeanC: Double?
    var footVar: Double = 0
    var gaitMean: Double?
    var gaitVar: Double = 0
    /// Calm minutes learned from so far.
    var minutesLearned: Int = 0
    var startedAt: Date?
    var updatedAt: Date?

    /// Recent accepted minute means, for robust (median/MAD) summaries and
    /// for judging whether a new minute is an outlier. Optional so baselines
    /// saved before these existed still load.
    var footSamples: RollingSeries?
    var gaitSamples: RollingSeries?
    /// Calm minutes in a row that looked nothing like the usual and were not
    /// learned. Enough of them in a row means the usual has really moved.
    var rejectedStreak: Int?
    var rejectedMinutes: Int?
    /// Running drift tallies (see `DriftState`).
    var drift: DriftState?

    /// Minutes of calm wear before personal warnings switch on.
    static let calibrationMinutes = 10
    /// Weight of each new minute after calibration (~1–2 hours of memory).
    static let learningRate = 0.02
    /// Discarded after this long without an update.
    static let expiry: TimeInterval = 90 * 24 * 3600
    /// Learned values are kept inside these bounds, well within the fixed
    /// limits, so the baseline cannot drift toward a dangerous "normal".
    static let footClampC = 28.0...36.0
    static let gaitClamp = 0.8...1.0
    /// A minute this many robust spreads from the median is not learned ...
    static let outlierSpreads = 4.0
    /// ... with at least these spreads, so a very steady wearer isn't
    /// brittle.
    static let footSpreadFloorC = 0.5
    static let gaitSpreadFloor = 0.02
    /// Rejected minutes in a row after which the departure is accepted as the
    /// wearer's new usual (a change of season, new shoes).
    static let regimeChangeMinutes = 20
    /// Consecutive minutes of a body signal are strongly alike, so n minutes
    /// count as about n / this many independent looks when blending with the
    /// population.
    static let correlationFactor = 5.0
    /// However odd a downloaded prior is, it can move the usual by at most
    /// this far from the wearer's own measurement.
    static let maxPriorPullC = 1.0
    static let maxPriorPullGait = 0.05

    var isCalibrated: Bool { minutesLearned >= Self.calibrationMinutes }

    var calibrationProgress: Double {
        min(1, Double(minutesLearned) / Double(Self.calibrationMinutes))
    }

    func isExpired(now: Date = .now) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > Self.expiry
    }

    /// Folds one calm minute in. During calibration this is a plain running
    /// mean; afterwards an exponentially weighted one. Once there is enough
    /// history to judge, a minute that sits far outside the wearer's usual is
    /// not learned (a sensor glitch or a bump in a calm minute must not move
    /// "normal"); if that keeps happening for 20 minutes it is accepted, since
    /// then it is the wearer's new usual and not a glitch.
    mutating func learn(footC: Double?, gait: Double?, now: Date = .now) {
        guard footC != nil || gait != nil else { return }
        var foot = footC.map { $0.clamped(to: Self.footClampC) }
        var steadiness = gait.map { $0.clamped(to: Self.gaitClamp) }

        if isCalibrated {
            let footOut = foot.map { Self.isOutlier($0, in: footSamples, floor: Self.footSpreadFloorC) } ?? false
            let gaitOut = steadiness.map { Self.isOutlier($0, in: gaitSamples, floor: Self.gaitSpreadFloor) } ?? false
            if footOut { foot = nil }
            if gaitOut { steadiness = nil }
            if foot == nil, steadiness == nil {
                rejectedStreak = (rejectedStreak ?? 0) + 1
                rejectedMinutes = (rejectedMinutes ?? 0) + 1
                guard (rejectedStreak ?? 0) >= Self.regimeChangeMinutes else { return }
                // The usual has really moved: start the robust history afresh.
                foot = footC.map { $0.clamped(to: Self.footClampC) }
                steadiness = gait.map { $0.clamped(to: Self.gaitClamp) }
                footSamples = nil
                gaitSamples = nil
            }
            rejectedStreak = 0
        }

        let n = Double(minutesLearned + 1)
        let rate = isCalibrated ? Self.learningRate : 1 / n
        if let foot {
            (footMeanC, footVar) = Self.update(mean: footMeanC, variance: footVar, x: foot, rate: rate)
            var series = footSamples ?? RollingSeries(capacity: 240)
            series.append(foot)
            footSamples = series
        }
        if let steadiness {
            (gaitMean, gaitVar) = Self.update(mean: gaitMean, variance: gaitVar, x: steadiness, rate: rate)
            var series = gaitSamples ?? RollingSeries(capacity: 240)
            series.append(steadiness)
            gaitSamples = series
        }
        minutesLearned += 1
        if startedAt == nil { startedAt = now }
        updatedAt = now
    }

    private static func isOutlier(_ x: Double, in series: RollingSeries?, floor: Double) -> Bool {
        guard let series, series.count >= 20, let m = series.median else { return false }
        let spread = max(series.robustSD ?? 0, floor)
        return abs(x - m) > outlierSpreads * spread
    }

    private static func update(mean: Double?, variance: Double, x: Double, rate: Double) -> (Double, Double) {
        guard let mean else { return (x, 0) }
        let delta = x - mean
        let newMean = mean + rate * delta
        let newVar = (1 - rate) * (variance + rate * delta * delta)
        return (newMean, newVar)
    }

    // MARK: Warnings

    /// How far above the usual foot temperature counts: three spreads, and
    /// never less than 2 °C so ordinary variation stays quiet.
    var footMargin: Double { max(2.0, 3 * footSpread) }
    /// How far below usual steadiness counts: three spreads, at least 8 points.
    var gaitMargin: Double { max(0.08, 3 * gaitSpread) }

    /// The wearer's own minute-to-minute spread. The median-based estimate is
    /// used once there is a history to take it from, because a few unusual
    /// minutes inflate a standard deviation but barely move a MAD.
    var footSpread: Double {
        if let robust = footSamples?.robustSD, (footSamples?.count ?? 0) >= 20 { return robust }
        return footVar.squareRoot()
    }
    var gaitSpread: Double {
        if let robust = gaitSamples?.robustSD, (gaitSamples?.count ?? 0) >= 20 { return robust }
        return gaitVar.squareRoot()
    }

    /// The wearer's usual after blending with the population.
    struct Posterior: Equatable {
        var footMean: Double?
        var footPriorWeight: Double
        var gaitMean: Double?
        var gaitPriorWeight: Double
    }

    /// A new wearer's usual starts from what is typical across wearers, and
    /// lets go of it as their own minutes accumulate. See `Shrinkage` for the
    /// maths: the prior's weight is the share of the combined precision that
    /// comes from the population, so it is large for the first few minutes and
    /// falls roughly as 1/n, and it falls more slowly for a narrow population
    /// than for a wide one.
    ///
    /// With no prior, or a stat that fails `PopulationPriors.usable`, the
    /// wearer's own numbers are used as they are. The result is always inside
    /// the clamps and within a fixed distance of the wearer's own measurement.
    func posterior(priors: PopulationPriors?) -> Posterior {
        let nEff = Shrinkage.effectiveCount(minutesLearned, correlationFactor: Self.correlationFactor)
        var result = Posterior(footMean: footMeanC, footPriorWeight: 0, gaitMean: gaitMean, gaitPriorWeight: 0)

        if let own = footMeanC, let prior = Self.footPrior(priors) {
            let blend = Shrinkage.bounded(
                Shrinkage.blend(sampleMean: own, withinSD: max(footSpread, 0.3), effectiveN: nEff,
                                priorMean: prior.mean, priorSD: max(prior.sd, 0.3)),
                around: own, maxPull: Self.maxPriorPullC)
            result.footMean = blend.mean.clamped(to: Self.footClampC)
            result.footPriorWeight = blend.priorWeight
        }
        if let own = gaitMean, let prior = PopulationPriors.usable(priors?.steadiness) {
            let blend = Shrinkage.bounded(
                Shrinkage.blend(sampleMean: own, withinSD: max(gaitSpread, 0.02), effectiveN: nEff,
                                priorMean: prior.mean, priorSD: max(prior.sd, 0.02)),
                around: own, maxPull: Self.maxPriorPullGait)
            result.gaitMean = blend.mean.clamped(to: Self.gaitClamp)
            result.gaitPriorWeight = blend.priorWeight
        }
        return result
    }

    /// The population's calm foot temperature across activities: the
    /// contributor-weighted mixture of the usable per-activity stats. The
    /// baseline learns from calm minutes of every activity, so the matching
    /// prior is the mixture, whose spread includes the differences between
    /// activities as well as between wearers.
    static func footPrior(_ priors: PopulationPriors?) -> PopulationPriors.Stats? {
        let usable = (priors?.footByActivity ?? [:]).values.compactMap { PopulationPriors.usable($0) }
        let total = usable.reduce(0) { $0 + $1.count }
        guard total > 0 else { return nil }
        let mean = usable.reduce(0.0) { $0 + Double($1.count) * $1.mean } / Double(total)
        let variance = usable.reduce(0.0) { $0 + Double($1.count) * ($1.sd * $1.sd + ($1.mean - mean) * ($1.mean - mean)) } / Double(total)
        guard mean.isFinite, variance.isFinite else { return nil }
        return PopulationPriors.Stats(mean: mean, sd: variance.squareRoot(), count: total)
    }
}

/// Short-term direction of the foot temperature, from the minute history.
struct TemperatureTrend: Equatable {
    /// Signed change in °C over the last 5 and 10 minutes, when known.
    var delta5: Double?
    var delta10: Double?

    /// A fast rise: at least 1 °C in 5 minutes or 1.5 °C in 10.
    var isRisingFast: Bool {
        (delta5 ?? 0) >= 1.0 || (delta10 ?? 0) >= 1.5
    }

    /// Cooling off: at least 0.5 °C down over 5 minutes.
    var isRecovering: Bool { (delta5 ?? 0) <= -0.5 }
}

/// Combines the fixed assessment with the personal layer. Pure, so it can be
/// tested without a phone.
enum PersonalLayer {
    struct Result: Equatable {
        let assessment: ThermyxRiskAssessment
        let signals: [RiskExplanation.Signal]
    }

    /// - Parameter priors: What's typical across wearers. A new wearer's usual
    ///   is blended with it until their own data builds up; nil, or stats with
    ///   too few contributors, mean the wearer's own numbers are used alone.
    static func apply(
        _ assessment: ThermyxRiskAssessment,
        reading: BilateralReading,
        baseline: PersonalBaseline?,
        trend: TemperatureTrend,
        unit: TemperatureUnit,
        model: PersonalThermalModel? = nil,
        activity: [CalibrationActivity: Double]? = nil,
        priors: PopulationPriors? = nil
    ) -> Result {
        guard assessment.level != .unavailable else { return Result(assessment: assessment, signals: []) }

        var signals: [RiskExplanation.Signal] = []
        var reasons = assessment.reasons
        var causes = assessment.causes
        var level = assessment.level
        let footC = reading.present.compactMap(\.footTemperatureC).max()
        let gait = reading.present.compactMap(\.gaitStability).min()

        func raise(_ reason: String, _ cause: ThermyxRiskCause) {
            reasons.append(reason)
            if !causes.contains(cause) { causes.append(cause) }
            // Only ever upward, and personal signals alone stop at Caution.
            if level == .normal { level = .caution }
        }

        func blendNote(_ weight: Double) -> String {
            weight >= 0.05 ? " (partly from typical wearers until your own data builds up)" : ""
        }

        if let baseline, baseline.isCalibrated {
            let post = baseline.posterior(priors: priors)
            if let footC, let mean = post.footMean {
                let over = footC - mean
                let margin = baseline.footMargin
                let counts = over >= margin
                signals.append(.init(
                    kind: .personalBaseline,
                    title: "Above your usual foot temperature",
                    value: (over >= 0 ? "+" : "−") + TemperatureFormat.delta(over, in: unit),
                    rule: "Caution at \(TemperatureFormat.delta(margin, in: unit)) or more above your usual \(TemperatureFormat.degrees(mean, in: unit))\(blendNote(post.footPriorWeight))",
                    contributes: counts
                ))
                if counts { raise("Foot temperature is well above your usual.", .hot) }
            }
            if let gait, let mean = post.gaitMean {
                let under = mean - gait
                let margin = baseline.gaitMargin
                let counts = under >= margin
                if counts {
                    signals.append(.init(
                        kind: .personalBaseline,
                        title: "Less steady than usual",
                        value: "\(Int((gait * 100).rounded()))%",
                        rule: "Caution at \(Int((margin * 100).rounded())) points below your usual \(Int((mean * 100).rounded()))%\(blendNote(post.gaitPriorWeight))",
                        contributes: true
                    ))
                    raise("Steadiness is well below your usual.", .unsteady)
                }
            }

            // Slow changes: a small departure that keeps going.
            if let report = baseline.drift?.report() {
                if let foot = report.feature(.footTemperature), foot.run > 0, foot.tally > 0 {
                    signals.append(.init(
                        kind: .personalBaseline,
                        title: "Foot temperature staying above your usual",
                        value: "+\(TemperatureFormat.delta(foot.meanDeparture, in: unit)) for \(foot.run) min",
                        rule: "Caution when your foot stays a little above your usual for several minutes in a row, even if no single minute is high enough on its own",
                        contributes: foot.contributes
                    ))
                    if foot.contributes { raise("Foot temperature has stayed above your usual for \(foot.run) minutes.", .hot) }
                }
                if let steadiness = report.feature(.steadiness), steadiness.run > 0, steadiness.tally > 0 {
                    signals.append(.init(
                        kind: .personalBaseline,
                        title: "Steadiness staying below your usual",
                        value: "−\(Int((steadiness.meanDeparture * 100).rounded())) points for \(steadiness.run) min",
                        rule: "Caution when your steps stay a little less steady than usual for several minutes in a row",
                        contributes: steadiness.contributes
                    ))
                    if steadiness.contributes { raise("Steadiness has stayed below your usual for \(steadiness.run) minutes.", .unsteady) }
                }
            }
        }

        // Calibration model: usual temperature for what the wearer is doing.
        if let model, let footC, let expected = model.expectedFoot(probabilities: activity) {
            let over = footC - expected.mean
            let margin = model.margin(expected)
            let counts = over >= margin
            let doing = activity?.max(by: { $0.value < $1.value })?.key.label.lowercased()
            signals.append(.init(
                kind: .personalBaseline,
                title: doing.map { "Compared with your usual while \($0)" } ?? "Compared with your calibration",
                value: (over >= 0 ? "+" : "−") + TemperatureFormat.delta(over, in: unit),
                rule: "Caution at \(TemperatureFormat.delta(margin, in: unit)) or more above your usual \(TemperatureFormat.degrees(expected.mean, in: unit))",
                contributes: counts
            ))
            if counts { raise("Foot temperature is well above your usual for this activity.", .hot) }
        }

        if let d = trend.delta5 ?? trend.delta10 {
            let fast = trend.isRisingFast
            let recovering = trend.isRecovering
            signals.append(.init(
                kind: .trend,
                title: recovering ? "Cooling down" : "Temperature trend",
                value: (d >= 0 ? "+" : "−") + TemperatureFormat.delta(d, in: unit) + (trend.delta5 != nil ? " / 5 min" : " / 10 min"),
                rule: "Caution on a rise of \(TemperatureFormat.delta(1.0, in: unit)) in 5 min or \(TemperatureFormat.delta(1.5, in: unit)) in 10. Cooling never lowers a level.",
                contributes: fast
            ))
            if fast { raise("Foot temperature is rising quickly.", .hot) }
        }

        return Result(
            assessment: ThermyxRiskAssessment(level: level, reasons: reasons, foot: assessment.foot, causes: causes,
                                              asymmetryFoot: assessment.asymmetryFoot),
            signals: signals
        )
    }
}

/// Keeps the baseline on this phone and decides which minutes it learns from.
@MainActor
final class PersonalBaselineStore: ObservableObject {
    @Published private(set) var baseline: PersonalBaseline
    /// An optional note on the current session ("long run", "work shift").
    /// It labels history; it does not split the baseline.
    @Published var sessionLabel: String {
        didSet { defaults.set(sessionLabel, forKey: Self.labelKey) }
    }
    /// Personal warnings on or off. Learning continues either way so turning
    /// them back on does not start from scratch.
    @Published var isEnabled: Bool {
        didSet { defaults.set(isEnabled, forKey: Self.enabledKey) }
    }

    /// The model trained in calibration, if the wearer has calibrated.
    @Published private(set) var model: PersonalThermalModel?
    /// The classifier's view of what the wearer is doing now, from the last
    /// 10 seconds of readings. Nil without a usable model or features.
    @Published private(set) var activity: [CalibrationActivity: Double]?

    /// What's typical across wearers, from the cloud layer. Nil until it
    /// arrives (or when the cohort is too small): everything then uses its
    /// fixed defaults. Setting it re-blends the calibration model and the
    /// left/right norms; the wearer's own measurements are never discarded.
    var priors: PopulationPriors? {
        didSet {
            asymmetryMonitor.priors = priors
            if let current = model {
                let blended = current.shrunk(toward: priors)
                if blended != current {
                    model = blended
                    if let data = try? JSONEncoder().encode(blended) { defaults.set(data, forKey: Self.modelKey) }
                }
            }
        }
    }

    private let defaults: UserDefaults
    private var recent: [CalibrationSample] = []
    private var minuteFoot: [Double] = []
    private var minuteGait: [Double] = []
    private var minuteCalm = true
    private var minuteHeating = false
    private var minuteStart: Date?
    private var asymmetryMonitor: AsymmetryMonitor
    private var asymmetrySavedAt = 0

    private static let key = "thermyx.personalBaseline"
    private static let modelKey = "thermyx.calibrationModel"
    private static let labelKey = "thermyx.sessionLabel"
    private static let enabledKey = "thermyx.personalBaselineEnabled"
    private static let asymmetryKey = "thermyx.asymmetryBaseline"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        sessionLabel = defaults.string(forKey: Self.labelKey) ?? ""
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        if let data = defaults.data(forKey: Self.key),
           let stored = try? JSONDecoder().decode(PersonalBaseline.self, from: data),
           !stored.isExpired() {
            baseline = stored
        } else {
            baseline = PersonalBaseline()
            defaults.removeObject(forKey: Self.key)
        }
        if let data = defaults.data(forKey: Self.modelKey) {
            model = try? JSONDecoder().decode(PersonalThermalModel.self, from: data)
        }
        if let data = defaults.data(forKey: Self.asymmetryKey),
           let stored = try? JSONDecoder().decode(AsymmetryBaseline.self, from: data),
           !stored.isExpired() {
            asymmetryMonitor = AsymmetryMonitor(baseline: stored)
        } else {
            asymmetryMonitor = AsymmetryMonitor()
            defaults.removeObject(forKey: Self.asymmetryKey)
        }
    }

    /// Stores a freshly trained model and teaches the baseline from the
    /// calibration's indoor minutes, so personal warnings start right away
    /// instead of after ten minutes of wear.
    func adopt(_ model: PersonalThermalModel, indoorSamples: [CalibrationSample]) {
        let adopted = model.shrunk(toward: priors)
        self.model = adopted
        if let data = try? JSONEncoder().encode(adopted) { defaults.set(data, forKey: Self.modelKey) }
        let minutes = stride(from: 0, to: indoorSamples.count, by: 60).map { Array(indoorSamples[$0..<min($0 + 60, indoorSamples.count)]) }
        for minute in minutes where minute.count >= 30 {
            let foot = minute.compactMap(\.footC)
            let gait = minute.compactMap(\.gait)
            baseline.learn(
                footC: foot.isEmpty ? nil : foot.reduce(0, +) / Double(foot.count),
                gait: gait.isEmpty ? nil : gait.reduce(0, +) / Double(gait.count),
                now: minute.last?.time ?? .now
            )
        }
        persist()
    }

    func clearModel() {
        model = nil
        activity = nil
        defaults.removeObject(forKey: Self.modelKey)
    }

    /// Called with each pair reading. Readings are gathered per minute and a
    /// minute is learned only if every reading in it was calm.
    func observe(_ reading: BilateralReading, fixedLevel: ThermyxRiskLevel, now: Date = .now) {
        guard reading.hasAny else { return }
        // The classifier was trained on one sample per second over 10 s
        // windows. A pair reading arrives once per packet from either foot,
        // so keep one sample a second and trim by time, not by count; counting
        // would make the live window 5 s long with two insoles.
        if recent.last.map({ now.timeIntervalSince($0.time) >= 0.9 }) ?? true {
            recent.append(CalibrationSample(reading, at: now))
        }
        recent.removeAll { now.timeIntervalSince($0.time) >= Double(ActivityFeatures.windowSeconds) }
        let next = model.flatMap { $0.classifier.probabilities(ActivityFeatures(window: recent)) }
        if next != activity { activity = next }
        let start = minuteStart ?? now
        if now.timeIntervalSince(start) >= 60 {
            let footMean = minuteFoot.isEmpty ? nil : minuteFoot.reduce(0, +) / Double(minuteFoot.count)
            let gaitMean = minuteGait.isEmpty ? nil : minuteGait.reduce(0, +) / Double(minuteGait.count)
            // Drift is tracked through every minute the insole wasn't heating
            // (heating moves the foot by design), not only the calm ones,
            // because a slow rise is exactly what stops a minute being calm.
            if baseline.isCalibrated, !minuteHeating {
                updateDrift(footC: footMean, gait: gaitMean)
            }
            if minuteCalm, footMean != nil || gaitMean != nil {
                baseline.learn(footC: footMean, gait: gaitMean, now: now)
            }
            persist()
            minuteFoot.removeAll()
            minuteGait.removeAll()
            minuteCalm = true
            minuteHeating = false
            minuteStart = now
        } else if minuteStart == nil {
            minuteStart = now
        }

        let heating = reading.present.contains { $0.thermalMode == .heating }
        if fixedLevel != .normal || heating { minuteCalm = false }
        if heating { minuteHeating = true }
        if let f = reading.present.compactMap(\.footTemperatureC).max() { minuteFoot.append(f) }
        if let g = reading.present.compactMap(\.gaitStability).min() { minuteGait.append(g) }
    }

    /// Feeds the drift detector one minute. The reference is the calibration
    /// model's usual for what the wearer is doing when there is one, else the
    /// baseline's own usual.
    private func updateDrift(footC: Double?, gait: Double?) {
        let post = baseline.posterior(priors: priors)
        var expected: (mean: Double, sd: Double)?
        if isEnabled, let model, let e = model.expectedFoot(probabilities: activity) {
            expected = (e.mean, e.sd)
        } else if let mean = post.footMean {
            expected = (mean, baseline.footSpread)
        }
        var usualGait: (mean: Double, sd: Double)?
        if let mean = post.gaitMean { usualGait = (mean, baseline.gaitSpread) }
        var drift = baseline.drift ?? DriftState()
        drift.update(footC: footC, footExpected: expected, gait: gait, gaitUsual: usualGait)
        baseline.drift = drift
    }

    func reset() {
        baseline = PersonalBaseline()
        minuteFoot.removeAll()
        minuteGait.removeAll()
        minuteStart = nil
        minuteCalm = true
        minuteHeating = false
        defaults.removeObject(forKey: Self.key)
        asymmetryMonitor.reset()
        defaults.removeObject(forKey: Self.asymmetryKey)
    }

    func deleteAll() {
        reset()
        clearModel()
        // Saved calibration minutes and answers.
        defaults.removeObject(forKey: "thermyx.calibration.indoor")
        defaults.removeObject(forKey: "thermyx.calibration.comfort")
        sessionLabel = ""
        defaults.removeObject(forKey: Self.labelKey)
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(baseline) { defaults.set(data, forKey: Self.key) }
    }

    // MARK: Left / right norms

    /// Feeds the left/right monitor one pair reading. Call it for every
    /// reading, Demo Mode included, with `learn: false` for anything
    /// simulated: detection works from the fixed defaults and the priors, but
    /// nothing is learned about the wearer.
    ///
    /// A moment counts as calm for learning when the fixed rules (without the
    /// left/right layer) say Normal and no insole is heating, so a minute that
    /// was elevated never teaches what "usual" looks like.
    func observeAsymmetry(_ reading: BilateralReading, learn: Bool) {
        guard reading.hasAny else { return }
        let calm = ThermyxRiskEngine.assess(reading).level == .normal
            && !reading.present.contains { $0.thermalMode == .heating }
        asymmetryMonitor.observe(reading, learn: learn, calm: calm)
        // Save about every five minutes of new learning, not on every bin.
        if asymmetryMonitor.learnedBins - asymmetrySavedAt >= 15 {
            asymmetrySavedAt = asymmetryMonitor.learnedBins
            persistAsymmetry()
        }
    }

    /// What the left/right monitor currently reports. It does not follow the
    /// Guidance switch: it replaces the fixed per-packet left/right rules, so
    /// it stays on whether or not the personal layer is.
    func asymmetryStatus(now: Date = .now) -> AsymmetryStatus {
        asymmetryMonitor.status(now: now)
    }

    /// The blended left/right norms and the bars they set, for a debug screen.
    var asymmetryEstimates: AsymmetryMonitor.Estimates { asymmetryMonitor.estimates() }

    /// Drops in-flight left/right evidence (an insole disconnected) but keeps
    /// what has been learned.
    func resetAsymmetryEvidence() { asymmetryMonitor.resetEvidence() }

    private func persistAsymmetry() {
        if let data = try? JSONEncoder().encode(asymmetryMonitor.baseline) { defaults.set(data, forKey: Self.asymmetryKey) }
    }
}

private extension Double {
    func clamped(to range: ClosedRange<Double>) -> Double { Swift.min(Swift.max(self, range.lowerBound), range.upperBound) }
}

// MARK: - Calibration model
//
// A small model trained on this phone from the wearer's own calibration
// session. Nothing is pre-trained and nothing leaves the phone.
//
// - An activity classifier (Gaussian naive Bayes) learns what sitting,
//   standing and walking look like in this wearer's sensor data.
// - A thermal profile learns their usual foot temperature for each activity
//   and their comfortable resting temperature, which becomes Auto's target.
//
// Like the baseline, the model can only add caution. It never lowers a
// level, never moves the fixed limits, and its Auto target stays inside the
// 26–38 °C range the firmware accepts.

/// What the wearer is doing during a calibration segment, and what the
/// classifier predicts afterwards.
enum CalibrationActivity: String, Codable, CaseIterable, Identifiable {
    case sitting, standing, walking
    var id: String { rawValue }

    var label: String {
        switch self {
        case .sitting: return "Sitting"
        case .standing: return "Standing"
        case .walking: return "Walking"
        }
    }
}

/// One second of sensor data captured during calibration.
struct CalibrationSample: Codable, Equatable {
    var time: Date
    var footC: Double?
    var ambientC: Double?
    var load: Double?
    var gait: Double?
    var cadence: Double?
    var standing: Double?

    init(time: Date, footC: Double?, ambientC: Double?, load: Double?, gait: Double?, cadence: Double?, standing: Double?) {
        self.time = time
        self.footC = footC
        self.ambientC = ambientC
        self.load = load
        self.gait = gait
        self.cadence = cadence
        self.standing = standing
    }

    /// The pair's reading as one sample: the warmer foot's temperature, the
    /// less steady foot's gait, and averages for the rest.
    init(_ reading: BilateralReading, at time: Date = .now) {
        let present = reading.present
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        self.init(
            time: time,
            footC: present.compactMap(\.footTemperatureC).max(),
            ambientC: mean(present.compactMap(\.ambientTemperatureC)),
            load: mean(present.compactMap(\.pressureBalance)),
            gait: present.compactMap(\.gaitStability).min(),
            cadence: mean(present.compactMap(\.cadenceStepsPerMinute)),
            standing: mean(present.compactMap(\.standingFraction))
        )
    }
}

/// The features the classifier sees for one window of samples. A feature is
/// nil when the insole doesn't measure it; the model then simply ignores it.
struct ActivityFeatures: Equatable {
    static let count = 5
    /// Mean steps per minute.
    var cadence: Double?
    /// Mean share of time loaded but not stepping.
    var standing: Double?
    /// Mean arch pressure level.
    var load: Double?
    /// Spread of the load share: shifting weight while walking moves it.
    var loadSpread: Double?
    /// Mean gait steadiness.
    var gait: Double?

    var values: [Double?] { [cadence, standing, load, loadSpread, gait] }

    /// Plain names for each feature, in `values` order, so an explanation can
    /// say what pushed a guess one way.
    static let names = ["Step rate", "Time loaded without stepping", "Load", "Load swing", "Steadiness"]

    /// Seconds of data per window.
    static let windowSeconds = 10

    init(cadence: Double?, standing: Double?, load: Double?, loadSpread: Double?, gait: Double?) {
        self.cadence = cadence
        self.standing = standing
        self.load = load
        self.loadSpread = loadSpread
        self.gait = gait
    }

    init(window: [CalibrationSample]) {
        func mean(_ v: [Double]) -> Double? { v.isEmpty ? nil : v.reduce(0, +) / Double(v.count) }
        let loads = window.compactMap(\.load)
        var spread: Double?
        if loads.count >= 3, let m = mean(loads) {
            spread = (loads.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(loads.count)).squareRoot()
        }
        self.init(
            cadence: mean(window.compactMap(\.cadence)),
            standing: mean(window.compactMap(\.standing)),
            load: mean(loads),
            loadSpread: spread,
            gait: mean(window.compactMap(\.gait))
        )
    }

    /// Splits a segment into consecutive windows of `windowSeconds` samples.
    static func windows(_ samples: [CalibrationSample]) -> [ActivityFeatures] {
        stride(from: 0, to: samples.count - windowSeconds + 1, by: windowSeconds).map {
            ActivityFeatures(window: Array(samples[$0..<$0 + windowSeconds]))
        }
    }
}

/// Gaussian naive Bayes over `ActivityFeatures`, trained on labelled windows.
/// Each feature is modelled per activity as a normal distribution; missing
/// features are skipped at training and prediction time.
///
/// What makes it sturdier than a textbook fit, given that a calibration is
/// only a minute or two of data:
/// - Each feature's per-activity mean and variance are fitted after rejecting
///   outlying windows (a stumble in the "standing" minute shouldn't widen
///   what standing looks like).
/// - Variances are shrunk toward the variance pooled over all activities, by
///   an amount that shrinks as an activity gets more windows, so three
///   windows can't claim a variance of nearly zero.
/// - Class priors are uniform, deliberately: a calibration records the same
///   time per activity, but a day of wear is mostly one of them, and the
///   classifier shouldn't carry that bias in.
/// - Probabilities are softened by a temperature fitted on held-out windows
///   (see `ClassifierEvaluation`), because naive Bayes counts correlated
///   evidence several times and is wildly overconfident otherwise.
struct ActivityClassifier: Codable, Equatable {
    struct Gaussian: Codable, Equatable {
        var mean: Double
        var variance: Double
    }

    /// [activity: [feature index: distribution]]
    private(set) var distributions: [CalibrationActivity: [Int: Gaussian]] = [:]
    /// Softening applied to the raw log scores; nil or 1 means none. Fitted
    /// on held-out windows by `ClassifierEvaluation`.
    private(set) var temperature: Double?
    /// Training windows kept per activity (after outlier rejection).
    private(set) var windowCounts: [CalibrationActivity: Int]?

    /// Variance floor per feature, so a perfectly still minute doesn't
    /// produce an infinitely confident model.
    static let varianceFloor: [Double] = [4, 0.0025, 0.0025, 0.0004, 0.0025]
    /// Pooled variance counts as this many windows when shrinking.
    static let pooledVarianceDegrees = 2.0

    /// Activities and features with enough data to use.
    var activities: [CalibrationActivity] { CalibrationActivity.allCases.filter { distributions[$0] != nil } }

    /// Feature indices every learned activity has, so scores stay comparable.
    private var sharedFeatures: [Int] {
        let learned = activities
        guard let first = learned.first, let initial = distributions[first].map({ Set($0.keys) }) else { return [] }
        return learned.dropFirst().reduce(initial) { $0.intersection(distributions[$1]!.keys) }.sorted()
    }

    /// Usable when at least two activities share at least one feature.
    var isUsable: Bool {
        activities.count >= 2 && !sharedFeatures.isEmpty
    }

    init(training: [CalibrationActivity: [ActivityFeatures]]) {
        var kept: [CalibrationActivity: Int] = [:]
        for index in 0..<ActivityFeatures.count {
            let floor = Self.varianceFloor[index]
            var fits: [CalibrationActivity: (mean: Double, variance: Double, degrees: Int)] = [:]
            for (activity, rows) in training {
                let raw = rows.compactMap { $0.values[index] }
                guard raw.count >= 2 else { continue }
                let xs = RobustStats.rejectingOutliers(raw, k: 3.5, floor: floor.squareRoot()).kept
                guard xs.count >= 2, let mean = RobustStats.mean(xs), let sd = RobustStats.sd(xs) else { continue }
                fits[activity] = (mean, sd * sd, xs.count - 1)
                kept[activity] = max(kept[activity] ?? 0, xs.count)
            }
            let totalDegrees = fits.values.reduce(0) { $0 + $1.degrees }
            let pooled = totalDegrees > 0
                ? fits.values.reduce(0.0) { $0 + Double($1.degrees) * $1.variance } / Double(totalDegrees)
                : floor
            for (activity, fit) in fits {
                let variance = fits.count >= 2
                    ? Shrinkage.variance(sample: fit.variance, degrees: fit.degrees,
                                         prior: max(pooled, floor), priorDegrees: Self.pooledVarianceDegrees)
                    : fit.variance
                distributions[activity, default: [:]][index] = Gaussian(mean: fit.mean, variance: max(variance, floor))
            }
        }
        windowCounts = kept.isEmpty ? nil : kept
    }

    /// Applies the temperature fitted by `ClassifierEvaluation.evaluate`.
    mutating func calibrate(temperature: Double) {
        self.temperature = temperature.isFinite && temperature > 1.000001 ? temperature : nil
    }

    /// Log-likelihood of these features under each learned activity (equal
    /// priors), or nil when they share nothing with what the model learned.
    func logScores(_ features: ActivityFeatures) -> [CalibrationActivity: Double]? {
        guard isUsable else { return nil }
        let values = features.values
        let shared = sharedFeatures
        var scores: [CalibrationActivity: Double] = [:]
        var usedAny = false
        for activity in activities {
            var score = 0.0
            for index in shared {
                guard let x = values[index], let g = distributions[activity]?[index] else { continue }
                score += -0.5 * log(2 * .pi * g.variance) - (x - g.mean) * (x - g.mean) / (2 * g.variance)
                usedAny = true
            }
            scores[activity] = score
        }
        return usedAny ? scores : nil
    }

    /// Probability of each learned activity for these features, or nil when
    /// the features share nothing with what the model learned.
    func probabilities(_ features: ActivityFeatures) -> [CalibrationActivity: Double]? {
        guard let scores = logScores(features) else { return nil }
        let t = temperature ?? 1
        let scaled = scores.mapValues { $0 / t }
        guard let top = scaled.values.max() else { return nil }
        let exps = scaled.mapValues { exp($0 - top) }
        let total = exps.values.reduce(0, +)
        return exps.mapValues { $0 / total }
    }

    func predict(_ features: ActivityFeatures) -> (activity: CalibrationActivity, confidence: Double)? {
        guard let p = probabilities(features), let best = p.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    /// Which features pushed the guess toward `activity` and away from the
    /// runner-up, in log-likelihood, strongest first. A feature the window
    /// doesn't have is simply absent.
    func contributions(_ features: ActivityFeatures) -> (activity: CalibrationActivity, against: CalibrationActivity, items: [(feature: String, logOdds: Double)])? {
        guard let scores = logScores(features), scores.count >= 2 else { return nil }
        let ranked = scores.sorted { $0.value > $1.value }
        let top = ranked[0].key, second = ranked[1].key
        let values = features.values
        var items: [(String, Double)] = []
        for index in sharedFeatures {
            guard let x = values[index], let a = distributions[top]?[index], let b = distributions[second]?[index] else { continue }
            func ll(_ g: Gaussian) -> Double { -0.5 * log(2 * .pi * g.variance) - (x - g.mean) * (x - g.mean) / (2 * g.variance) }
            items.append((ActivityFeatures.names[index], ll(a) - ll(b)))
        }
        return (top, second, items.sorted { abs($0.1) > abs($1.1) })
    }

    /// Leave-one-out accuracy on the training windows. Kept for reference:
    /// neighbouring windows are nearly identical, so this is optimistic. The
    /// honest figure is `ClassifierEvaluation.evaluate`.
    static func leaveOneOutAccuracy(_ training: [CalibrationActivity: [ActivityFeatures]]) -> Double? {
        var correct = 0, total = 0
        for (activity, rows) in training {
            for i in rows.indices {
                var rest = training
                rest[activity]!.remove(at: i)
                let model = ActivityClassifier(training: rest)
                guard let guess = model.predict(rows[i]) else { continue }
                total += 1
                if guess.activity == activity { correct += 1 }
            }
        }
        return total >= 6 ? Double(correct) / Double(total) : nil
    }
}

/// The wearer's thermal profile from calibration.
struct PersonalThermalModel: Codable, Equatable {
    struct Stats: Codable, Equatable {
        var mean: Double
        var sd: Double
    }

    var classifier: ActivityClassifier
    /// Usual indoor foot temperature per activity.
    var footByActivity: [CalibrationActivity: Stats]
    /// Auto's learned target, inside the firmware's 26–38 °C range.
    var comfortTargetC: Double?
    /// Held-out accuracy of the classifier (leave-one-segment-out or blocked
    /// k-fold, see `classifierReport`), when there was enough data.
    var classifierAccuracy: Double?
    var indoorDone: Bool
    var outdoorDone: Bool
    var trainedAt: Date
    /// True when trained from the TEMPORARY fake insole's scripted data.
    /// Such a model never seeds the baseline, and Home asks for a real
    /// calibration once a real insole connects.
    var fromTestData: Bool? = nil
    /// Usual outdoor foot temperature per activity. Kept apart from the
    /// indoor profile so a hot afternoon never becomes the usual.
    var outdoorFootByActivity: [CalibrationActivity: Stats]? = nil
    /// Usual arch pressure level per activity, 0–1.
    var loadByActivity: [CalibrationActivity: Stats]? = nil
    /// Walking steadiness, from the walking phases.
    var walkingStability: StabilityProfile? = nil
    /// Walking cadence, steps per minute.
    var walkingCadence: Stats? = nil
    /// What each calibration phase measured (averages).
    var phases: [CalibrationPhaseSummary]? = nil
    /// The air outside during the outdoor half, from local weather, °C.
    var outdoorAirC: Double? = nil
    /// The full held-out evaluation behind `classifierAccuracy`: sample size,
    /// interval, per-activity recall, confusion and calibration.
    var classifierReport: ClassifierEvaluation? = nil
    /// Seconds of indoor foot-temperature data behind each `footByActivity`
    /// entry.
    var footCounts: [CalibrationActivity: Int]? = nil
    /// The wearer's own measurement before any blending with the population.
    /// `footByActivity` holds the blended values; this keeps the raw ones so
    /// the blend can be redone when better priors arrive.
    var rawFootByActivity: [CalibrationActivity: Stats]? = nil
    /// How much of each blended mean came from the population, 0…1.
    var footPriorWeight: [CalibrationActivity: Double]? = nil

    var isTestData: Bool { fromTestData == true }

    func phase(_ activity: CalibrationActivity, outdoor: Bool) -> CalibrationPhaseSummary? {
        phases?.first { $0.activity == activity && $0.outdoor == outdoor }
    }

    static let targetRange: ClosedRange<Double> = 26...38
    /// Smallest spread used for warnings, so a short, steady calibration
    /// doesn't make ordinary variation look alarming.
    static let minimumSD = 0.75
    /// How far above the usual temperature for the current activity counts:
    /// three spreads, and never less than 2 °C.
    static let marginSDs = 3.0
    static let minimumMarginC = 2.0

    /// Comfort answer: −1 "too cold" … 0 "just right" … +1 "too warm". A
    /// "too warm" answer lowers the target, "too cold" raises it.
    static let comfortAdjustmentC = 1.5

    static func comfortTarget(restingC: Double, comfort: Double?) -> Double {
        let adjusted = restingC - (comfort ?? 0) * comfortAdjustmentC
        return min(max(adjusted, targetRange.lowerBound), targetRange.upperBound)
    }

    /// The temperature expected for the current activity mix, and its spread.
    func expectedFoot(probabilities p: [CalibrationActivity: Double]?) -> Stats? {
        let weights: [CalibrationActivity: Double]
        if let p, !p.isEmpty {
            weights = p.filter { footByActivity[$0.key] != nil }
        } else {
            // No activity estimate: compare with the warmest usual, so the
            // warning stays conservative.
            guard let warmest = footByActivity.max(by: { $0.value.mean < $1.value.mean }) else { return nil }
            return warmest.value
        }
        let total = weights.values.reduce(0, +)
        guard total > 0 else { return nil }
        var mean = 0.0, second = 0.0
        for (activity, w) in weights {
            let s = footByActivity[activity]!
            mean += w / total * s.mean
            second += w / total * (s.sd * s.sd + s.mean * s.mean)
        }
        let sd = max((second - mean * mean).squareRoot(), Self.minimumSD)
        return Stats(mean: mean, sd: sd)
    }

    /// Margin above the expected temperature that raises Caution.
    func margin(_ expected: Stats) -> Double { max(Self.minimumMarginC, Self.marginSDs * expected.sd) }

    /// Seconds of 1 Hz readings that count as one independent look: a minute
    /// of foot temperature is closer to one measurement than sixty.
    static let correlationSeconds = 15.0
    /// A prior can move a usual temperature by at most this far from the
    /// wearer's own.
    static let maxPriorPullC = 1.0

    /// Blends the wearer's own per-activity usual temperatures with what is
    /// typical across wearers. A calibration is only a minute or two per
    /// activity, so this is where the prior earns its keep. The wearer's own
    /// measurement stays in `rawFootByActivity`; the spreads are the
    /// wearer's own; and an activity without a usable prior is left alone.
    /// The comfort target is not touched: it is the wearer's own measured
    /// resting temperature and their answer, not a population statistic.
    func shrunk(toward priors: PopulationPriors?) -> PersonalThermalModel {
        var result = self
        let raw = rawFootByActivity ?? footByActivity
        result.rawFootByActivity = raw
        var blended = raw
        var weights: [CalibrationActivity: Double] = [:]
        for (activity, own) in raw {
            guard let prior = PopulationPriors.usable(priors?.footByActivity[activity]) else { continue }
            let n = Double(footCounts?[activity] ?? 30)
            let estimate = Shrinkage.bounded(
                Shrinkage.blend(sampleMean: own.mean, withinSD: own.sd, effectiveN: max(1, n / Self.correlationSeconds),
                                priorMean: prior.mean, priorSD: max(prior.sd, 0.3)),
                around: own.mean, maxPull: Self.maxPriorPullC)
            blended[activity] = Stats(
                mean: min(max(estimate.mean, PersonalBaseline.footClampC.lowerBound), PersonalBaseline.footClampC.upperBound),
                sd: own.sd)
            weights[activity] = estimate.priorWeight
        }
        result.footByActivity = blended
        result.footPriorWeight = weights.isEmpty ? nil : weights
        return result
    }
}

/// Builds the model from a finished calibration session.
enum CalibrationTrainer {
    struct Segment: Equatable {
        var activity: CalibrationActivity
        var outdoor: Bool
        var samples: [CalibrationSample]
    }

    static func train(segments: [Segment], comfort: Double?, now: Date = .now, priors: PopulationPriors? = nil) -> PersonalThermalModel? {
        let indoor = segments.filter { !$0.outdoor }
        guard !indoor.isEmpty else { return nil }

        // Activity classifier: every segment, indoor and out, labelled.
        var training: [CalibrationActivity: [ActivityFeatures]] = [:]
        var labelled: [LabelledWindows] = []
        for (index, segment) in segments.enumerated() {
            let windows = ActivityFeatures.windows(segment.samples)
            training[segment.activity, default: []] += windows
            labelled.append(LabelledWindows(activity: segment.activity, segment: index, windows: windows))
        }

        // Thermal profile: indoor only, so a hot afternoon outside doesn't
        // become the usual. Values are kept inside the baseline's bounds.
        var foot: [CalibrationActivity: PersonalThermalModel.Stats] = [:]
        var counts: [CalibrationActivity: Int] = [:]
        for activity in CalibrationActivity.allCases {
            let xs = indoor.filter { $0.activity == activity }
                .flatMap(\.samples)
                .compactMap(\.footC)
                .map { min(max($0, PersonalBaseline.footClampC.lowerBound), PersonalBaseline.footClampC.upperBound) }
            guard xs.count >= 10 else { continue }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let sd = (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count)).squareRoot()
            foot[activity] = .init(mean: mean, sd: max(sd, PersonalThermalModel.minimumSD))
            counts[activity] = xs.count
        }
        guard !foot.isEmpty else { return nil }

        // Held-out evaluation, and a temperature that makes the classifier's
        // probabilities honest. Both come from the same held-out windows.
        var classifier = ActivityClassifier(training: training)
        let report = classifier.isUsable ? ClassifierEvaluation.evaluate(labelled) : nil
        if let report { classifier.calibrate(temperature: report.temperature) }

        // Comfort target: resting temperature (sitting, else standing),
        // nudged by how comfortable the wearer said it felt. From the raw
        // measurement, not the population blend.
        let resting = foot[.sitting]?.mean ?? foot[.standing]?.mean ?? foot.values.first!.mean
        var model = PersonalThermalModel(
            classifier: classifier,
            footByActivity: foot,
            comfortTargetC: PersonalThermalModel.comfortTarget(restingC: resting, comfort: comfort),
            classifierAccuracy: (report?.windows ?? 0) >= 6 ? report?.accuracy : nil,
            indoorDone: true,
            outdoorDone: segments.contains { $0.outdoor },
            trainedAt: now
        )
        model.classifierReport = report
        model.footCounts = counts

        // Outdoor temperatures, load, walking and each phase's averages.
        // Shown to the wearer; none of it moves a fixed limit.
        let outdoor = stats(segments.filter(\.outdoor)) { $0.footC }
        model.outdoorFootByActivity = outdoor.isEmpty ? nil : outdoor
        let load = stats(segments) { $0.load }
        model.loadByActivity = load.isEmpty ? nil : load
        let walking = segments.filter { $0.activity == .walking }.flatMap(\.samples)
        model.walkingStability = StabilityProfile(walkingGait: walking.compactMap(\.gait))
        model.walkingCadence = stats([CalibrationTrainer.Segment(activity: .walking, outdoor: false, samples: walking)]) { $0.cadence }[.walking]
        model.phases = segments.map { CalibrationPhaseSummary(activity: $0.activity, outdoor: $0.outdoor, samples: $0.samples) }
        return model.shrunk(toward: priors)
    }

    /// Mean and spread of one value per activity, from at least ten seconds
    /// of data.
    private static func stats(_ segments: [Segment], _ value: (CalibrationSample) -> Double?) -> [CalibrationActivity: PersonalThermalModel.Stats] {
        var result: [CalibrationActivity: PersonalThermalModel.Stats] = [:]
        for activity in CalibrationActivity.allCases {
            let xs = segments.filter { $0.activity == activity }.flatMap(\.samples).compactMap(value)
            guard xs.count >= 10 else { continue }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let sd = (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count)).squareRoot()
            result[activity] = .init(mean: mean, sd: sd)
        }
        return result
    }
}

// MARK: - Restoring on a new phone

/// The cloud backup puts a saved baseline back on a new phone. The left/right
/// norms and the calibration model are not part of it; they are learned again.
extension PersonalBaselineStore: CloudBaselineRestorable {
    func restore(baseline: PersonalBaseline) {
        guard !baseline.isExpired() else { return }
        self.baseline = baseline
        persist()
    }
}
