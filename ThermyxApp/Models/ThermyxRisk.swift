import Foundation

enum ThermyxRiskLevel: String {
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
}

struct ThermyxRiskAssessment: Equatable {
    let level: ThermyxRiskLevel
    let reasons: [String]
    static let unavailable = ThermyxRiskAssessment(level: .unavailable, reasons: [])
}

enum ThermyxRiskEngine {
    static func assess(_ reading: ThermyxReading) -> ThermyxRiskAssessment {
        guard reading.footTemperatureC != nil, reading.ambientTemperatureC != nil, reading.gaitStability != nil else { return .unavailable }
        var reasons: [String] = []
        if let gait = reading.gaitStability, gait < 0.8 { reasons.append("Movement stability is below baseline.") }
        if let ambient = reading.ambientTemperatureC, ambient >= 35 { reasons.append("Ambient temperature is elevated.") }
        if let foot = reading.footTemperatureC, foot >= 38 { reasons.append("Foot-contact temperature is elevated.") }
        let level: ThermyxRiskLevel = reasons.count >= 3 ? .critical : reasons.count == 2 ? .high : reasons.isEmpty ? .normal : .caution
        return ThermyxRiskAssessment(level: level, reasons: reasons)
    }
}
