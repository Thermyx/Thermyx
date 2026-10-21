import SwiftUI

enum ThermyxRiskLevel: String, CaseIterable {
    case unavailable = "Waiting for data"
    case normal = "Normal"
    case caution = "Caution"
    case high = "High risk"
    case critical = "Critical"

    var explanation: String {
        switch self {
        case .unavailable: return "Connect your Thermyx insole to begin monitoring."
        case .normal: return "No abnormal pattern detected from the available signals."
        case .caution: return "Conditions or movement patterns deserve attention."
        case .high: return "Pause, hydrate, and move to a cooler environment."
        case .critical: return "Stop activity and seek immediate help."
        }
    }

    /// The one-line guidance shown beside the status on the Home risk band.
    var shortGuidance: String {
        switch self {
        case .unavailable: return "No live signals"
        case .normal: return "Monitoring quietly"
        case .caution: return "Hydrate and check your fit"
        case .high: return "Stop and cool down"
        case .critical: return "Get help now"
        }
    }

    /// Ordering for "most severe seen" comparisons.
    var severity: Int {
        switch self {
        case .unavailable: return -1
        case .normal: return 0
        case .caution: return 1
        case .high: return 2
        case .critical: return 3
        }
    }

    var tint: Color {
        switch self {
        case .unavailable: return Thermyx.Ink.textFaint
        case .normal: return Thermyx.Ink.ice
        case .caution: return Thermyx.Ink.amber
        case .high: return Thermyx.Ink.ember
        case .critical: return Thermyx.Ink.ember
        }
    }

    var fill: Color {
        switch self {
        case .unavailable: return Thermyx.Tint.neutralFill
        case .normal: return Thermyx.Tint.liveFill
        case .caution: return Thermyx.Tint.amberFill
        case .high, .critical: return Thermyx.Tint.cautionFill
        }
    }

    var border: Color {
        switch self {
        case .unavailable: return Thermyx.Tint.neutralBorder
        case .normal: return Thermyx.Tint.liveBorder
        case .caution: return Thermyx.Tint.amberBorder
        case .high, .critical: return Thermyx.Tint.cautionBorder
        }
    }

    /// Heating is locked out from High Risk upward — a heat-strained user must
    /// not be able to command more heat, and the escalation plan says the app
    /// commands maximum ventilation at this point.
    var locksOutHeating: Bool {
        self == .high || self == .critical
    }

    /// The rungs shown on the Safety escalation ladder, in order.
    static var ladder: [ThermyxRiskLevel] { [.normal, .caution, .high, .critical] }

    var ladderDetail: String {
        switch self {
        case .unavailable: return "Waiting for live signals."
        case .normal: return "Monitoring quietly."
        case .caution: return "Notify you on the phone."
        case .high: return "Stop, hydrate, cool down. Trusted circle notified."
        case .critical: return "Full-screen alert and emergency actions."
        }
    }
}

/// Why the engine raised a level, in the same order as `reasons`. The
/// trusted circle's messages and status card are built from these, not by
/// reading the sentences back.
///
/// `warmerFoot`, `unevenLoad` and `limp` come from `AsymmetryMonitor` and are
/// only ever raised after the pattern has held for minutes. `unevenLoad` means
/// heavy one-sided leaning (standing or walking); `limp` means uneven stepping
/// while walking.
enum ThermyxRiskCause: String, Codable, Equatable, CaseIterable {
    case heatLimit, hot, cold, unsteady, hotAir, warmerFoot, unevenLoad, limp
}

struct ThermyxRiskAssessment: Equatable {
    let level: ThermyxRiskLevel
    let reasons: [String]
    /// Which foot drove this, when one did. Nil for a bilateral signal or
    /// when neither foot is individually responsible.
    var foot: Foot?
    var causes: [ThermyxRiskCause]
    /// For a sustained left/right finding: the foot carrying more weight
    /// (leaning, limping) or running warmer. Kept apart from `foot` because
    /// the worse foot for heat and the favoured foot are different questions.
    var asymmetryFoot: Foot?

    init(level: ThermyxRiskLevel, reasons: [String], foot: Foot? = nil, causes: [ThermyxRiskCause] = [], asymmetryFoot: Foot? = nil) {
        self.level = level
        self.reasons = reasons
        self.foot = foot
        self.causes = causes
        self.asymmetryFoot = asymmetryFoot
    }

    static let unavailable = ThermyxRiskAssessment(level: .unavailable, reasons: [])
}

enum ThermyxRiskEngine {

    /// Foot-contact temperature at which the insole must stop heating. Skin in
    /// prolonged contact with anything much above this can burn, and the
    /// Peltier's own rating is far higher, so the limit is set by the skin.
    static let burnLimitC = 40.0

    /// Foot-contact temperature at or below which the foot counts as cold.
    /// Cold raises Caution on its own but never more: High would lock out
    /// heating, which is exactly what a cold foot needs.
    static let coldFootC = 25.0

    /// How long a left/right gap had to hold under the old per-packet rule.
    /// Superseded by `AsymmetryMonitor`, which judges whole minutes of both
    /// feet; kept so older call sites still compile.
    static let sustainedAsymmetrySeconds: TimeInterval = 120

    /// Assesses one foot on its own signals.
    ///
    /// Works with whatever the insole reports: a missing channel removes that
    /// channel's reason, it does not blank the whole assessment. Only a
    /// reading with no foot, ambient, or gait value at all is "waiting".
    static func assess(_ reading: ThermyxReading) -> ThermyxRiskAssessment {
        let foot = reading.footTemperatureC
        let ambient = reading.ambientTemperatureC
        let gait = reading.gaitStability
        guard foot != nil || ambient != nil || gait != nil else { return .unavailable }

        var reasons: [String] = []
        var causes: [ThermyxRiskCause] = []
        if let gait, gait < 0.8 { reasons.append("Movement stability is below baseline."); causes.append(.unsteady) }
        if let ambient, ambient >= 35 { reasons.append("Ambient temperature is elevated."); causes.append(.hotAir) }
        if let foot, foot >= 38 { reasons.append("Foot-contact temperature is elevated."); causes.append(.hot) }
        var level: ThermyxRiskLevel = reasons.count >= 3 ? .critical : reasons.count == 2 ? .high : reasons.isEmpty ? .normal : .caution

        // Burn protection stands on its own: a foot at the limit is High
        // whatever the other signals say, which also locks out heating.
        let hottest = ([foot] + [reading.zones?.forefootC, reading.zones?.archC, reading.zones?.heelC])
            .compactMap { $0 }
            .max()
        if let hottest, hottest >= burnLimitC {
            reasons.insert("Foot contact has reached the burn-protection limit. Heating is off.", at: 0)
            causes.insert(.heatLimit, at: 0)
            if level.severity < ThermyxRiskLevel.high.severity { level = .high }
        }
        if let foot, foot <= coldFootC {
            reasons.append("Foot-contact temperature is low. Warm up with Auto or Heat.")
            causes.append(.cold)
            if level == .normal { level = .caution }
        }
        return ThermyxRiskAssessment(level: level, reasons: reasons, foot: reading.foot, causes: causes)
    }

    /// Assesses the pair, folding in what `AsymmetryMonitor` has found.
    ///
    /// The result is the worse of the two feet, plus signals that only exist
    /// because there are two: heavy one-sided leaning, uneven stepping while
    /// walking, or a foot that has run warmer than the other for minutes.
    /// These are favouring-one-foot signals, both a fit problem and a fatigue
    /// signal, and invisible to a single insole. The monitor only reports them
    /// after the pattern has held for minutes, against the wearer's own usual
    /// left/right balance, so the weight swinging from foot to foot with every
    /// step never trips them.
    ///
    /// Asymmetry never escalates past caution by itself. It says "look at
    /// this", not "stop" — a difference between feet is not the same kind of
    /// evidence as a foot that is simply too hot. It also never lowers a level.
    static func assess(_ bilateral: BilateralReading, asymmetry: AsymmetryStatus) -> ThermyxRiskAssessment {
        let perFoot = bilateral.present.map(assess).filter { $0.level != .unavailable }
        guard let worst = perFoot.max(by: { $0.level.severity < $1.level.severity }) else {
            return .unavailable
        }

        var reasons = worst.reasons
        var causes = worst.causes
        var level = worst.level
        var foot = worst.foot
        var asymmetryFoot: Foot?

        // A limp is the more specific description of the same uneven loading,
        // so it replaces a lean rather than adding to it.
        let ordered = [asymmetry.finding(.limp) ?? asymmetry.finding(.lean), asymmetry.finding(.warmerFoot)].compactMap { $0 }
        for finding in ordered {
            reasons.append(AsymmetryWording.reason(finding))
            causes.append(finding.kind.cause)
            asymmetryFoot = asymmetryFoot ?? finding.foot
            if level == .normal { level = .caution }
        }
        // When nothing else is wrong the asymmetry is the whole story, and
        // the foot it names is the one to talk about.
        if worst.level == .normal, let asymmetryFoot { foot = asymmetryFoot }

        return ThermyxRiskAssessment(level: level, reasons: reasons, foot: foot, causes: causes, asymmetryFoot: asymmetryFoot)
    }

    /// The older instantaneous form: the caller says whether each gap has
    /// held. Nothing is reported unless the caller asks for it, so a call with
    /// no arguments is just the worse of the two feet. Prefer
    /// `assess(_:asymmetry:)`.
    static func assess(
        _ bilateral: BilateralReading,
        sustainedTemperatureGap: Bool = false,
        sustainedLoadGap: Bool = false
    ) -> ThermyxRiskAssessment {
        let perFoot = bilateral.present.map(assess).filter { $0.level != .unavailable }
        guard let worst = perFoot.max(by: { $0.level.severity < $1.level.severity }) else {
            return .unavailable
        }

        var reasons = worst.reasons
        var causes = worst.causes
        var level = worst.level
        var asymmetryFoot: Foot?

        if sustainedTemperatureGap, let hotter = bilateral.hotterFoot, let delta = bilateral.temperatureAsymmetryC {
            reasons.append("\(hotter.label) foot is running \(String(format: "%.1f", abs(delta))) °C warmer than the other.")
            causes.append(.warmerFoot)
            asymmetryFoot = hotter
            if level == .normal { level = .caution }
        }
        if sustainedLoadGap, let favoured = bilateral.favouredFoot, let load = bilateral.loadAsymmetry {
            reasons.append("Load is \(Int(abs(load) * 100)) points heavier on the \(favoured.label.lowercased()) foot.")
            causes.append(.unevenLoad)
            asymmetryFoot = asymmetryFoot ?? favoured
            if level == .normal { level = .caution }
        }

        return ThermyxRiskAssessment(level: level, reasons: reasons, foot: worst.foot, causes: causes, asymmetryFoot: asymmetryFoot)
    }
}

extension AsymmetryStatus.Kind {
    var cause: ThermyxRiskCause {
        switch self {
        case .lean: return .unevenLoad
        case .limp: return .limp
        case .warmerFoot: return .warmerFoot
        }
    }
}

/// Plain, non-diagnostic sentences for what the monitor found.
enum AsymmetryWording {
    /// "about 4 minutes", never less than a minute.
    static func duration(_ seconds: TimeInterval) -> String {
        let minutes = max(1, Int((seconds / 60).rounded()))
        return minutes == 1 ? "about a minute" : "about \(minutes) minutes"
    }

    static func reason(_ finding: AsymmetryStatus.Finding) -> String {
        let foot = finding.foot.label.lowercased()
        let held = duration(finding.heldSeconds)
        switch finding.kind {
        case .lean:
            return finding.whileWalking
                ? "You've been favouring your \(foot) foot while walking for \(held)."
                : "You've been leaning on your \(foot) foot for \(held)."
        case .limp:
            return "Your steps have been uneven for \(held), with more weight on your \(foot) foot."
        case .warmerFoot:
            let gap = finding.contributions.first.map { String(format: "%.1f", abs($0.observed)) }
            return "Your \(foot) foot has been running \(gap.map { "about \($0) °C " } ?? "")warmer than the other for \(held)."
        }
    }
}

/// On-device next-step suggestions, shown on Home when the wearer turns them
/// on. Plain rules over the live readings — nothing leaves the phone and no
/// model is involved — so each suggestion can be traced to the signal that
/// prompted it.
enum ThermyxSuggestion {
    static func nextStep(for assessment: ThermyxRiskAssessment, reading: BilateralReading) -> String? {
        let level = assessment.level
        guard level != .unavailable else { return nil }
        let hottest = reading.present.compactMap(\.footTemperatureC).max()
        let ambient = reading.present.compactMap(\.ambientTemperatureC).max()
        let steadiness = reading.present.compactMap(\.gaitStability).min()

        if let hottest, hottest >= ThermyxRiskEngine.burnLimitC {
            return "Your insole reached its heat limit. Step out of the shoes for a few minutes and let your feet cool."
        }
        if level == .critical {
            return "Stop now, get to shade or air conditioning, drink water, and call for help if you feel dizzy or confused."
        }
        if level == .high {
            return "Stop and rest in the shade, drink water, and switch the insoles to Cool."
        }
        if let steadiness, steadiness < 0.8 {
            return "Your steps are less steady than usual. Slow down and take a break."
        }
        if let ambient, ambient >= 35 {
            return "It's hot. Take regular shade and water breaks, and keep the insoles on Cool or Auto."
        }
        if assessment.causes.contains(.limp) {
            return "Your steps have been uneven for a while. Slow down, check your shoes fit, and rest if something hurts."
        }
        if assessment.causes.contains(.unevenLoad), let favoured = assessment.asymmetryFoot ?? reading.favouredFoot {
            return "You're favouring your \(favoured.label.lowercased()) foot. If something hurts, rest and check your shoe fit."
        }
        if assessment.causes.contains(.warmerFoot), let hotter = assessment.asymmetryFoot ?? reading.hotterFoot {
            return "Your \(hotter.label.lowercased()) foot is running warmer. Check both insoles are seated flat and your shoes fit the same."
        }
        if let hottest, let ambient, hottest < 28, ambient < 18 {
            return "Your feet are cold. Warm them gradually with Auto or Heat."
        }
        return nil
    }
}
