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
        unit: TemperatureUnit
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

    private let defaults: UserDefaults
    private var minuteFoot: [Double] = []
    private var minuteGait: [Double] = []
    private var minuteCalm = true
    private var minuteStart: Date?

    private static let key = "thermyx.personalBaseline"
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
    }

    /// Called with each pair reading. Readings are gathered per minute and a
    /// minute is learned only if every reading in it was calm.
    func observe(_ reading: BilateralReading, fixedLevel: ThermyxRiskLevel, now: Date = .now) {
        guard reading.hasAny else { return }
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
