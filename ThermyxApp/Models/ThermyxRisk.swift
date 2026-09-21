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

struct ThermyxRiskAssessment: Equatable {
    let level: ThermyxRiskLevel
    let reasons: [String]
    /// Which foot drove this, when one did. Nil for a bilateral signal or
    /// when neither foot is individually responsible.
    var foot: Foot?

    init(level: ThermyxRiskLevel, reasons: [String], foot: Foot? = nil) {
        self.level = level
        self.reasons = reasons
        self.foot = foot
    }

    static let unavailable = ThermyxRiskAssessment(level: .unavailable, reasons: [])
}

enum ThermyxRiskEngine {

    /// Assesses one foot on its own signals.
    static func assess(_ reading: ThermyxReading) -> ThermyxRiskAssessment {
        guard reading.footTemperatureC != nil, reading.ambientTemperatureC != nil, reading.gaitStability != nil else { return .unavailable }
        var reasons: [String] = []
        if let gait = reading.gaitStability, gait < 0.8 { reasons.append("Movement stability is below baseline.") }
        if let ambient = reading.ambientTemperatureC, ambient >= 35 { reasons.append("Ambient temperature is elevated.") }
        if let foot = reading.footTemperatureC, foot >= 38 { reasons.append("Foot-contact temperature is elevated.") }
        let level: ThermyxRiskLevel = reasons.count >= 3 ? .critical : reasons.count == 2 ? .high : reasons.isEmpty ? .normal : .caution
        return ThermyxRiskAssessment(level: level, reasons: reasons, foot: reading.foot)
    }

    /// Assesses the pair.
    ///
    /// The result is the worse of the two feet, plus signals that only exist
    /// because there are two: a sustained temperature gap or a lopsided load
    /// raises caution on its own, because favouring one foot is both a fit
    /// problem and a fatigue signal, and it is invisible to a single insole.
    ///
    /// Asymmetry never escalates past caution by itself. It says "look at
    /// this", not "stop" — a difference between feet is not the same kind of
    /// evidence as a foot that is simply too hot.
    static func assess(_ bilateral: BilateralReading) -> ThermyxRiskAssessment {
        let perFoot = bilateral.present.map(assess).filter { $0.level != .unavailable }
        guard let worst = perFoot.max(by: { $0.level.severity < $1.level.severity }) else {
            return .unavailable
        }

        var reasons = worst.reasons
        var level = worst.level

        if let hotter = bilateral.hotterFoot, let delta = bilateral.temperatureAsymmetryC {
            reasons.append("\(hotter.label) foot is running \(String(format: "%.1f", abs(delta)))° warmer than the other.")
            if level == .normal { level = .caution }
        }
        if let favoured = bilateral.favouredFoot, let load = bilateral.loadAsymmetry {
            reasons.append("Load is \(Int(abs(load) * 100)) points heavier on the \(favoured.label.lowercased()) foot.")
            if level == .normal { level = .caution }
        }

        return ThermyxRiskAssessment(level: level, reasons: reasons, foot: worst.foot)
    }
}
