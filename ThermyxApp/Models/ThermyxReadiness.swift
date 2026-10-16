import Foundation

// The end of the recovery loop: what the wearer's own recoveries say about
// what works (the safety plan), and what's normal for their own feet (the
// readiness profile), so the question is "is today different for me?" and not
// just "is my temperature high?".
//
// Both are descriptions of this wearer's own history, in plain words. They
// don't diagnose, they never lower a risk level, and with too little data
// they say so instead of guessing.

// MARK: - Safety plan

/// What the wearer's recoveries say worked, from the ones that were measured.
struct SafetyPlan: Equatable {
    struct Finding: Equatable, Identifiable {
        let action: RecoveryAction
        let text: String
        /// How many times faster the foot cooled with it than without.
        let ratio: Double
        let withCount: Int
        let withoutCount: Int
        var id: String { action.rawValue }
    }

    var findings: [Finding]
    /// Recoveries that were measured, and how many it takes to compare.
    var measured: Int
    var needed: Int
    /// The actions that went with faster cooling, so the test can say
    /// "helped before" beside those steps.
    var helped: Set<RecoveryAction> { Set(findings.map(\.action)) }

    var isReady: Bool { measured >= needed }

    static let needed = 5
    /// Each side of a comparison needs at least this many recoveries.
    static let minimumPerSide = 2
    /// Faster by at least this much to be worth saying.
    static let worthSaying = 1.3

    static func build(_ records: [RecoveryRecord]) -> SafetyPlan {
        let usable = records.filter { $0.coolingRate != nil }
        guard usable.count >= needed else {
            return SafetyPlan(findings: [], measured: usable.count, needed: needed)
        }
        func mean(_ rs: [RecoveryRecord]) -> Double { rs.compactMap(\.coolingRate).reduce(0, +) / Double(max(rs.count, 1)) }
        var findings: [Finding] = []
        for action in RecoveryAction.allCases {
            let with = usable.filter { $0.actions.contains(action) }
            let without = usable.filter { !$0.actions.contains(action) }
            guard with.count >= minimumPerSide, without.count >= minimumPerSide else { continue }
            let a = mean(with), b = mean(without)
            // Compared as a ratio when the slower side is really cooling,
            // else by whether it's cooling at a useful rate at all.
            let ratio = b > 0.02 ? a / b : (a >= 0.1 ? 2 : 0)
            guard a > 0, ratio >= worthSaying else { continue }
            findings.append(Finding(action: action, text: sentence(action, ratio: ratio, with: with.count, without: without.count),
                                    ratio: ratio, withCount: with.count, withoutCount: without.count))
        }
        findings.sort { $0.ratio > $1.ratio }
        return SafetyPlan(findings: Array(findings.prefix(3)), measured: usable.count, needed: needed)
    }

    /// "about twice as fast as", "about 40% faster than".
    static func speed(_ ratio: Double) -> String {
        if ratio >= 2 { return "about twice as fast as" }
        let percent = Int(((ratio - 1) * 10).rounded()) * 10
        return "about \(max(10, percent))% faster than"
    }

    private static func sentence(_ action: RecoveryAction, ratio: Double, with: Int, without: Int) -> String {
        "After \(action.afterPhrase), your foot cooled \(speed(ratio)) when \(action.without) (\(with) recoveries with it, \(without) without)."
    }
}

// MARK: - Readiness

/// What's normal for this wearer, and whether today is different.
struct ReadinessProfile: Equatable {
    enum Status: Equatable {
        /// Not enough of the wearer's own history yet.
        case learning
        case typical
        case warmer
        case cooler
    }

    struct Range: Equatable, Identifiable {
        let activity: CalibrationActivity
        let lowC: Double
        let highC: Double
        /// Days (or "calibration") the range comes from.
        let fromHistory: Bool
        var id: String { activity.rawValue }
    }

    enum RecoveryTrend: Equatable {
        case notEnough, faster, slower, steady
    }

    var status: Status
    /// What the wearer is doing now, when known.
    var activity: CalibrationActivity?
    /// The warmer foot now, °C.
    var nowC: Double?
    var ranges: [Range]
    /// Left minus right load share, usually: positive leans left.
    var usualLean: Double?
    /// Left minus right load share now.
    var leanNow: Double?
    var comfortTargetC: Double?
    var recoveryTrend: RecoveryTrend
    /// Worth saying about today, most important first.
    var notes: [String]
    var hoursOfHistory: Int

    var range: Range? { activity.flatMap { a in ranges.first { $0.activity == a } } }
    var isResting: Bool { activity == .sitting || activity == .standing }

    static let learning = ReadinessProfile(status: .learning, activity: nil, nowC: nil, ranges: [], usualLean: nil, leanNow: nil,
                                           comfortTargetC: nil, recoveryTrend: .notEnough, notes: [], hoursOfHistory: 0)

    // MARK: Building it

    /// Hours of calm wear an activity needs before its range comes from
    /// history rather than calibration.
    static let minimumHours = 12
    /// Past this far outside the usual range counts as different.
    static let slackC = 0.3
    static let historyDays = 28

    static func build(
        reading: BilateralReading,
        activity probabilities: [CalibrationActivity: Double]?,
        model: PersonalThermalModel?,
        hours: [ThermyxHistorySample],
        recoveries: [RecoveryRecord],
        comfortTargetC: Double?,
        now: Date = .now
    ) -> ReadinessProfile {
        let since = now.addingTimeInterval(-Double(historyDays) * 86_400)
        let calm = hours.filter { s in
            s.start >= since && s.footMeanC != nil && (s.peakRiskLevel.map { $0.severity <= ThermyxRiskLevel.normal.severity } ?? true)
        }

        // Usual temperature for each activity: the middle 80% of the hours
        // spent doing it, else what calibration measured.
        var ranges: [Range] = []
        for activity in CalibrationActivity.allCases {
            let temps = calm.filter { dominantActivity($0) == activity }.compactMap(\.footMeanC).sorted()
            if temps.count >= minimumHours {
                ranges.append(Range(activity: activity, lowC: percentile(temps, 0.1), highC: percentile(temps, 0.9), fromHistory: true))
            } else if let stats = model?.footByActivity[activity] {
                let margin = max(1.0, 2 * stats.sd)
                ranges.append(Range(activity: activity, lowC: stats.mean - margin, highC: stats.mean + margin, fromHistory: false))
            }
        }

        // What the wearer is doing now: the classifier's best guess, else
        // what the insole's own motion says.
        let doing = probabilities?.max { $0.value < $1.value }?.key
            ?? reading.present.compactMap(ThermyxHistorySample.activity(of:)).first
        let nowC = reading.peakFootTemperatureC

        // Weight on the two feet: usually, and now.
        let pairs = Dictionary(grouping: calm.filter { $0.balanceMean != nil }, by: \.start)
            .compactMap { _, group -> Double? in
                guard let l = group.first(where: { $0.foot == .left })?.balanceMean,
                      let r = group.first(where: { $0.foot == .right })?.balanceMean else { return nil }
                return l - r
            }
        let usualLean = pairs.count >= minimumHours ? pairs.reduce(0, +) / Double(pairs.count) : nil

        var notes: [String] = []
        var status: Status = .learning
        if let nowC, let doing, let range = ranges.first(where: { $0.activity == doing }) {
            if nowC > range.highC + slackC {
                status = .warmer
                notes.append("Your warmer foot is above its usual range while you're \(doing.label.lowercased()).")
            } else if nowC < range.lowC - slackC {
                status = .cooler
                notes.append("Your warmer foot is below its usual range while you're \(doing.label.lowercased()).")
            } else {
                status = .typical
            }
        }
        let leanNow = reading.loadAsymmetry
        if let leanNow, let usualLean, abs(leanNow - usualLean) >= 0.12, reading.hasBoth {
            let side = leanNow > usualLean ? "left" : "right"
            notes.append("You're putting more weight on your \(side) foot than usual.")
        }

        return ReadinessProfile(
            status: status, activity: doing, nowC: nowC, ranges: ranges, usualLean: usualLean, leanNow: leanNow,
            comfortTargetC: model?.comfortTargetC ?? comfortTargetC, recoveryTrend: recoveryTrend(recoveries),
            notes: notes, hoursOfHistory: calm.count
        )
    }

    /// Whether recent recoveries are quicker or slower than earlier ones.
    static func recoveryTrend(_ records: [RecoveryRecord]) -> RecoveryTrend {
        let rates = records.sorted { $0.startedAt < $1.startedAt }.compactMap(\.coolingRate)
        guard rates.count >= 5 else { return .notEnough }
        let recent = Array(rates.suffix(3)), earlier = Array(rates.dropLast(3))
        let a = recent.reduce(0, +) / Double(recent.count), b = earlier.reduce(0, +) / Double(earlier.count)
        guard b > 0.02 else { return .notEnough }
        if a / b >= 1.25 { return .faster }
        if a / b <= 0.8 { return .slower }
        return .steady
    }

    /// What an hour of history was mostly spent doing.
    static func dominantActivity(_ s: ThermyxHistorySample) -> CalibrationActivity? {
        let seconds: [(CalibrationActivity, Double)] = [(.sitting, s.sittingSeconds ?? 0), (.standing, s.standingSeconds ?? 0), (.walking, s.walkingSeconds ?? 0)]
        if let best = seconds.max(by: { $0.1 < $1.1 }), best.1 > 0 { return best.0 }
        if let cadence = s.cadenceMean { return cadence >= 30 ? .walking : ((s.standingMean ?? 0) >= 0.5 ? .standing : .sitting) }
        return nil
    }

    private static func percentile(_ sorted: [Double], _ p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        let i = p * Double(sorted.count - 1)
        let lo = Int(i.rounded(.down)), hi = Int(i.rounded(.up))
        return sorted[lo] + (sorted[hi] - sorted[lo]) * (i - Double(lo))
    }
}

extension ReadinessProfile.Status {
    var title: String {
        switch self {
        case .learning: return "Still learning you"
        case .typical: return "Typical for you"
        case .warmer: return "Warmer than usual"
        case .cooler: return "Cooler than usual"
        }
    }
}
