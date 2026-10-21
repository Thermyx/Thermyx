import Foundation

/// What one calibration phase measured: where the foot sat, and how the
/// wearer stood and walked. Plain averages only.
///
/// Models saved by earlier builds also carry a temperature rate and a running
/// total per phase; those keys are simply ignored when such a model is read.
struct CalibrationPhaseSummary: Codable, Equatable, Identifiable {
    var activity: CalibrationActivity
    var outdoor: Bool
    /// Mean foot temperature, °C.
    var footMeanC: Double?
    /// Mean arch pressure level (0–1 of the sensor's range).
    var loadMean: Double?
    /// Mean steps per minute.
    var cadenceMean: Double?
    /// Mean gait steadiness, 0–1.
    var gaitMean: Double?
    /// Seconds that had readings.
    var seconds: Int

    var id: String { "\(activity.rawValue)-\(outdoor ? "outdoor" : "indoor")" }

    init(activity: CalibrationActivity, outdoor: Bool, samples: [CalibrationSample]) {
        func mean(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0, +) / Double(values.count) }
        self.activity = activity
        self.outdoor = outdoor
        footMeanC = mean(samples.compactMap(\.footC))
        loadMean = mean(samples.compactMap(\.load))
        cadenceMean = mean(samples.compactMap(\.cadence))
        gaitMean = mean(samples.compactMap(\.gait))
        seconds = samples.count
    }
}

/// The wearer's walking steadiness from calibration, and which level a live
/// reading falls in. Levels are relative to the wearer's own walk, with
/// floors so ordinary variation stays Steady, and the fixed 80% rule in
/// `ThermyxRiskEngine` always counts as Unsteady.
struct StabilityProfile: Codable, Equatable {
    var mean: Double
    var sd: Double

    enum Level: String, CaseIterable {
        case steady, variable, unsteady

        var label: String {
            switch self {
            case .steady: return "Steady"
            case .variable: return "Variable"
            case .unsteady: return "Unsteady"
            }
        }
    }

    /// Smallest spread used, so a very even calibration walk doesn't make
    /// every later step look unusual.
    static let minimumSD = 0.02
    static let fixedUnsteadyBelow = 0.8

    init(mean: Double, sd: Double) {
        self.mean = mean
        self.sd = max(sd, Self.minimumSD)
    }

    /// Nil with fewer than ten walking seconds of gait data.
    init?(walkingGait values: [Double]) {
        guard values.count >= 10 else { return nil }
        let mean = values.reduce(0, +) / Double(values.count)
        let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / Double(values.count)).squareRoot()
        self.init(mean: mean, sd: sd)
    }

    /// At or above this is Steady.
    var steadyFloor: Double { mean - max(0.04, 1.5 * sd) }
    /// Below this is Unsteady.
    var unsteadyBelow: Double { max(mean - max(0.08, 3 * sd), Self.fixedUnsteadyBelow) }

    func level(_ gait: Double) -> Level {
        if gait < unsteadyBelow { return .unsteady }
        if gait < steadyFloor { return .variable }
        return .steady
    }
}
