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

    var isCalibrated: Bool { minutesLearned >= Self.calibrationMinutes }

    var calibrationProgress: Double {
        min(1, Double(minutesLearned) / Double(Self.calibrationMinutes))
    }

    func isExpired(now: Date = .now) -> Bool {
        guard let updatedAt else { return false }
        return now.timeIntervalSince(updatedAt) > Self.expiry
    }

    /// Folds one calm minute in. During calibration this is a plain running
    /// mean; afterwards an exponentially weighted one.
    mutating func learn(footC: Double?, gait: Double?, now: Date = .now) {
        guard footC != nil || gait != nil else { return }
        let n = Double(minutesLearned + 1)
        let rate = isCalibrated ? Self.learningRate : 1 / n
        if let footC {
            let x = footC.clamped(to: Self.footClampC)
            (footMeanC, footVar) = Self.update(mean: footMeanC, variance: footVar, x: x, rate: rate)
        }
        if let gait {
            let x = gait.clamped(to: Self.gaitClamp)
            (gaitMean, gaitVar) = Self.update(mean: gaitMean, variance: gaitVar, x: x, rate: rate)
        }
        minutesLearned += 1
        if startedAt == nil { startedAt = now }
        updatedAt = now
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
    var footMargin: Double { max(2.0, 3 * footVar.squareRoot()) }
    /// How far below usual steadiness counts: three spreads, at least 8 points.
    var gaitMargin: Double { max(0.08, 3 * gaitVar.squareRoot()) }
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

    static func apply(
        _ assessment: ThermyxRiskAssessment,
        reading: BilateralReading,
        baseline: PersonalBaseline?,
        trend: TemperatureTrend,
        unit: TemperatureUnit,
        model: PersonalThermalModel? = nil,
        activity: [CalibrationActivity: Double]? = nil
    ) -> Result {
        guard assessment.level != .unavailable else { return Result(assessment: assessment, signals: []) }

        var signals: [RiskExplanation.Signal] = []
        var reasons = assessment.reasons
        var level = assessment.level
        let footC = reading.present.compactMap(\.footTemperatureC).max()
        let gait = reading.present.compactMap(\.gaitStability).min()

        func raise(_ reason: String) {
            reasons.append(reason)
            // Only ever upward, and personal signals alone stop at Caution.
            if level == .normal { level = .caution }
        }

        if let baseline, baseline.isCalibrated {
            if let footC, let mean = baseline.footMeanC {
                let over = footC - mean
                let counts = over >= baseline.footMargin
                signals.append(.init(
                    kind: .personalBaseline,
                    title: "Above your usual foot temperature",
                    value: (over >= 0 ? "+" : "−") + TemperatureFormat.delta(over, in: unit),
                    rule: "Caution at \(TemperatureFormat.delta(baseline.footMargin, in: unit)) or more above your usual \(TemperatureFormat.degrees(mean, in: unit))",
                    contributes: counts
                ))
                if counts { raise("Foot temperature is well above your usual.") }
            }
            if let gait, let mean = baseline.gaitMean {
                let under = mean - gait
                let counts = under >= baseline.gaitMargin
                if counts {
                    signals.append(.init(
                        kind: .personalBaseline,
                        title: "Less steady than usual",
                        value: "\(Int((gait * 100).rounded()))%",
                        rule: "Caution at \(Int((baseline.gaitMargin * 100).rounded())) points below your usual \(Int((mean * 100).rounded()))%",
                        contributes: true
                    ))
                    raise("Steadiness is well below your usual.")
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
            if counts { raise("Foot temperature is well above your usual for this activity.") }
        }

        // Calibration model: steadiness against this wearer's usual walk,
        // checked only while they're walking.
        if let model, let gait, let usual = model.walkingSteadiness, let margin = model.steadinessMargin {
            let walking = (activity?[.walking] ?? 0) >= 0.5
                || (activity == nil && (reading.present.compactMap(\.cadenceStepsPerMinute).max() ?? 0) >= 30)
            if walking {
                let under = usual.mean - gait
                let counts = under >= margin
                signals.append(.init(
                    kind: .personalBaseline,
                    title: "Steadiness compared with your usual walk",
                    value: "\(Int((gait * 100).rounded()))%",
                    rule: "Caution at \(Int((margin * 100).rounded())) points below your usual \(Int((usual.mean * 100).rounded()))%",
                    contributes: counts
                ))
                if counts { raise("Steadiness is well below your usual walk.") }
            }
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
            if fast { raise("Foot temperature is rising quickly.") }
        }

        return Result(
            assessment: ThermyxRiskAssessment(level: level, reasons: reasons, foot: assessment.foot),
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

    private let defaults: UserDefaults
    private var recent: [CalibrationSample] = []
    private var minuteFoot: [Double] = []
    private var minuteGait: [Double] = []
    private var minuteCalm = true
    private var minuteStart: Date?

    private static let key = "thermyx.personalBaseline"
    private static let modelKey = "thermyx.calibrationModel"
    private static let labelKey = "thermyx.sessionLabel"
    private static let enabledKey = "thermyx.personalBaselineEnabled"

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
    }

    /// Stores a freshly trained model and teaches the baseline from the
    /// calibration's indoor minutes, so personal warnings start right away
    /// instead of after ten minutes of wear.
    func adopt(_ model: PersonalThermalModel, indoorSamples: [CalibrationSample]) {
        self.model = model
        if let data = try? JSONEncoder().encode(model) { defaults.set(data, forKey: Self.modelKey) }
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
        recent.append(CalibrationSample(reading, at: now))
        if recent.count > ActivityFeatures.windowSeconds { recent.removeFirst(recent.count - ActivityFeatures.windowSeconds) }
        let next = model.flatMap { $0.classifier.probabilities(ActivityFeatures(window: recent)) }
        if next != activity { activity = next }
        let start = minuteStart ?? now
        if now.timeIntervalSince(start) >= 60 {
            if minuteCalm, !minuteFoot.isEmpty || !minuteGait.isEmpty {
                baseline.learn(
                    footC: minuteFoot.isEmpty ? nil : minuteFoot.reduce(0, +) / Double(minuteFoot.count),
                    gait: minuteGait.isEmpty ? nil : minuteGait.reduce(0, +) / Double(minuteGait.count),
                    now: now
                )
                persist()
            }
            minuteFoot.removeAll()
            minuteGait.removeAll()
            minuteCalm = true
            minuteStart = now
        } else if minuteStart == nil {
            minuteStart = now
        }

        let heating = reading.present.contains { $0.thermalMode == .heating }
        if fixedLevel != .normal || heating { minuteCalm = false }
        if let f = reading.present.compactMap(\.footTemperatureC).max() { minuteFoot.append(f) }
        if let g = reading.present.compactMap(\.gaitStability).min() { minuteGait.append(g) }
    }

    func reset() {
        baseline = PersonalBaseline()
        minuteFoot.removeAll()
        minuteGait.removeAll()
        minuteStart = nil
        minuteCalm = true
        defaults.removeObject(forKey: Self.key)
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
    /// Mean forefoot load share.
    var load: Double?
    /// Spread of the load share: shifting weight while walking moves it.
    var loadSpread: Double?
    /// Mean gait steadiness.
    var gait: Double?

    var values: [Double?] { [cadence, standing, load, loadSpread, gait] }

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
struct ActivityClassifier: Codable, Equatable {
    struct Gaussian: Codable, Equatable {
        var mean: Double
        var variance: Double
    }

    /// [activity: [feature index: distribution]]
    private(set) var distributions: [CalibrationActivity: [Int: Gaussian]] = [:]

    /// Variance floor per feature, so a perfectly still minute doesn't
    /// produce an infinitely confident model.
    static let varianceFloor: [Double] = [4, 0.0025, 0.0025, 0.0004, 0.0025]

    /// Activities and features with enough data to use.
    var activities: [CalibrationActivity] { CalibrationActivity.allCases.filter { distributions[$0] != nil } }

    /// Usable when at least two activities share at least one feature.
    var isUsable: Bool {
        let learned = activities
        guard learned.count >= 2 else { return false }
        let shared = learned.map { Set(distributions[$0]!.keys) }.reduce(Set(0..<ActivityFeatures.count)) { $0.intersection($1) }
        return !shared.isEmpty
    }

    init(training: [CalibrationActivity: [ActivityFeatures]]) {
        for (activity, rows) in training {
            var perFeature: [Int: Gaussian] = [:]
            for index in 0..<ActivityFeatures.count {
                let xs = rows.compactMap { $0.values[index] }
                guard xs.count >= 2 else { continue }
                let mean = xs.reduce(0, +) / Double(xs.count)
                let variance = xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count - 1)
                perFeature[index] = Gaussian(mean: mean, variance: max(variance, Self.varianceFloor[index]))
            }
            if !perFeature.isEmpty { distributions[activity] = perFeature }
        }
    }

    /// Probability of each learned activity for these features, or nil when
    /// the features share nothing with what the model learned.
    func probabilities(_ features: ActivityFeatures) -> [CalibrationActivity: Double]? {
        guard isUsable else { return nil }
        let values = features.values
        var logScores: [CalibrationActivity: Double] = [:]
        var usedAny = false
        for activity in activities {
            var score = 0.0
            for (index, g) in distributions[activity]! {
                // Only features every learned activity has, so the scores
                // stay comparable.
                guard let x = values[index], activities.allSatisfy({ distributions[$0]?[index] != nil }) else { continue }
                score += -0.5 * log(2 * .pi * g.variance) - (x - g.mean) * (x - g.mean) / (2 * g.variance)
                usedAny = true
            }
            logScores[activity] = score
        }
        guard usedAny, let top = logScores.values.max() else { return nil }
        let exps = logScores.mapValues { exp($0 - top) }
        let total = exps.values.reduce(0, +)
        return exps.mapValues { $0 / total }
    }

    func predict(_ features: ActivityFeatures) -> (activity: CalibrationActivity, confidence: Double)? {
        guard let p = probabilities(features), let best = p.max(by: { $0.value < $1.value }) else { return nil }
        return (best.key, best.value)
    }

    /// Leave-one-out accuracy on the training windows: an honest estimate of
    /// how well the model tells this wearer's activities apart.
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
    /// Leave-one-out accuracy of the classifier, when there was enough data.
    var classifierAccuracy: Double?
    var indoorDone: Bool
    var outdoorDone: Bool
    var trainedAt: Date
    /// Usual steadiness (gait stability, 0–1) while walking, from the
    /// walking minutes. Nil when the insole didn't report steadiness.
    var walkingSteadiness: Stats? = nil
    /// True when trained from the TEMPORARY fake insole's scripted data.
    /// Such a model never seeds the baseline, and Home asks for a real
    /// calibration once a real insole connects.
    var fromTestData: Bool? = nil

    var isTestData: Bool { fromTestData == true }

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

    /// How far below the usual walking steadiness counts: three spreads, and
    /// never less than 8 points.
    static let minimumSteadinessMargin = 0.08
    static let minimumSteadinessSD = 0.02
    var steadinessMargin: Double? {
        walkingSteadiness.map { max(Self.minimumSteadinessMargin, Self.marginSDs * $0.sd) }
    }
}

/// Builds the model from a finished calibration session.
enum CalibrationTrainer {
    struct Segment: Equatable {
        var activity: CalibrationActivity
        var outdoor: Bool
        var samples: [CalibrationSample]
    }

    static func train(segments: [Segment], comfort: Double?, now: Date = .now) -> PersonalThermalModel? {
        let indoor = segments.filter { !$0.outdoor }
        guard !indoor.isEmpty else { return nil }

        // Activity classifier: every segment, indoor and out, labelled.
        var training: [CalibrationActivity: [ActivityFeatures]] = [:]
        for segment in segments {
            training[segment.activity, default: []] += ActivityFeatures.windows(segment.samples)
        }

        // Thermal profile: indoor only, so a hot afternoon outside doesn't
        // become the usual. Values are kept inside the baseline's bounds.
        var foot: [CalibrationActivity: PersonalThermalModel.Stats] = [:]
        for activity in CalibrationActivity.allCases {
            let xs = indoor.filter { $0.activity == activity }
                .flatMap(\.samples)
                .compactMap(\.footC)
                .map { min(max($0, PersonalBaseline.footClampC.lowerBound), PersonalBaseline.footClampC.upperBound) }
            guard xs.count >= 10 else { continue }
            let mean = xs.reduce(0, +) / Double(xs.count)
            let sd = (xs.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(xs.count)).squareRoot()
            foot[activity] = .init(mean: mean, sd: max(sd, PersonalThermalModel.minimumSD))
        }
        guard !foot.isEmpty else { return nil }

        // Comfort target: resting temperature (sitting, else standing),
        // nudged by how comfortable the wearer said it felt.
        let resting = foot[.sitting]?.mean ?? foot[.standing]?.mean ?? foot.values.first!.mean

        // Steadiness while walking, indoors and out: how steady this
        // wearer's normal walk is.
        let gait = segments.filter { $0.activity == .walking }.flatMap(\.samples).compactMap(\.gait)
        var steadiness: PersonalThermalModel.Stats?
        if gait.count >= 10 {
            let mean = gait.reduce(0, +) / Double(gait.count)
            let sd = (gait.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(gait.count)).squareRoot()
            steadiness = .init(mean: mean, sd: max(sd, PersonalThermalModel.minimumSteadinessSD))
        }

        var model = PersonalThermalModel(
            classifier: ActivityClassifier(training: training),
            footByActivity: foot,
            comfortTargetC: PersonalThermalModel.comfortTarget(restingC: resting, comfort: comfort),
            classifierAccuracy: ActivityClassifier.leaveOneOutAccuracy(training),
            indoorDone: true,
            outdoorDone: segments.contains { $0.outdoor },
            trainedAt: now
        )
        model.walkingSteadiness = steadiness
        return model
    }
}
