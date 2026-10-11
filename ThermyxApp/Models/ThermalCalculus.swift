import Foundation

/// Calculus on the foot-temperature series, used by calibration.
///
/// Calibration describes how the wearer's foot temperature *moves*, not only
/// where it sits:
///
/// - **Rate of change, dT/dt.** The least-squares slope over the last few
///   seconds, in °C per minute. A fitted slope rather than the difference of
///   two readings, so one noisy sample can't swing it.
/// - **Accumulated change, ∫ (dT/dt) dt.** The rate integrated over time with
///   the trapezoid rule: how far the temperature has moved since a phase
///   began. Integrating the fitted rate, rather than subtracting two raw
///   readings, keeps single-sample noise out of it.
enum ThermalCalculus {
    /// Seconds of readings each rate is fitted over.
    static let window: TimeInterval = 10

    /// Least-squares slope of `values` against `times`, per second. Nil with
    /// fewer than three points or no spread in time.
    static func slope(times: [TimeInterval], values: [Double]) -> Double? {
        guard times.count == values.count, times.count >= 3 else { return nil }
        let n = Double(times.count)
        let meanT = times.reduce(0, +) / n
        let meanV = values.reduce(0, +) / n
        var covariance = 0.0, spread = 0.0
        for (t, v) in zip(times, values) {
            covariance += (t - meanT) * (v - meanV)
            spread += (t - meanT) * (t - meanT)
        }
        guard spread > 0 else { return nil }
        return covariance / spread
    }

    /// The foot temperatures in `samples` as (seconds from the first sample,
    /// °C), skipping seconds with no temperature.
    static func series(_ samples: [CalibrationSample]) -> [(t: TimeInterval, c: Double)] {
        guard let start = samples.first?.time else { return [] }
        return samples.compactMap { s in s.footC.map { (s.time.timeIntervalSince(start), $0) } }
    }

    /// dT/dt at the end of `samples`, in °C per minute, fitted over the
    /// trailing `window` seconds.
    static func rate(_ samples: [CalibrationSample], window: TimeInterval = window) -> Double? {
        let points = series(samples)
        guard let end = points.last?.t else { return nil }
        let recent = points.filter { end - $0.t <= window }
        return slope(times: recent.map(\.t), values: recent.map(\.c)).map { $0 * 60 }
    }

    /// dT/dt at every second that has at least three readings behind it in
    /// the window, in °C per minute.
    static func rateSeries(_ samples: [CalibrationSample], window: TimeInterval = window) -> [(t: TimeInterval, perMinute: Double)] {
        let points = series(samples)
        var result: [(TimeInterval, Double)] = []
        var lower = 0
        for upper in points.indices {
            while points[upper].t - points[lower].t > window { lower += 1 }
            let span = points[lower...upper]
            if let s = slope(times: span.map(\.t), values: span.map(\.c)) {
                result.append((points[upper].t, s * 60))
            }
        }
        return result
    }

    /// ∫ y dt over the points by the trapezoid rule, with t in seconds.
    static func integral(_ points: [(t: TimeInterval, y: Double)]) -> Double {
        zip(points, points.dropFirst()).reduce(0) { total, pair in
            total + (pair.1.t - pair.0.t) * (pair.0.y + pair.1.y) / 2
        }
    }

    /// The accumulated change across `samples`, in °C: the rate of change
    /// integrated over time. Nil until there is a rate to integrate.
    static func accumulatedChange(_ samples: [CalibrationSample], window: TimeInterval = window) -> Double? {
        let rates = rateSeries(samples, window: window)
        guard rates.count >= 2 else { return nil }
        // The rates are per minute; the integral runs over seconds.
        return integral(rates.map { ($0.t, $0.perMinute / 60) })
    }
}

/// What one calibration phase measured: where the foot sat, how it moved,
/// and how the wearer stood and walked.
struct CalibrationPhaseSummary: Codable, Equatable, Identifiable {
    var activity: CalibrationActivity
    var outdoor: Bool
    /// Mean foot temperature, °C.
    var footMeanC: Double?
    /// dT/dt across the whole phase, °C per minute.
    var ratePerMinute: Double?
    /// ∫ dT/dt dt across the phase, °C.
    var accumulatedC: Double?
    /// Mean forefoot share of the load, 0–1.
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
        let points = ThermalCalculus.series(samples)
        footMeanC = mean(points.map(\.c))
        ratePerMinute = ThermalCalculus.slope(times: points.map(\.t), values: points.map(\.c)).map { $0 * 60 }
        accumulatedC = ThermalCalculus.accumulatedChange(samples)
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

// MARK: - Showing the work

/// The calculus at one second, with every number that went into it, so the
/// app can show the math for any timestamp.
struct CalculusStep: Identifiable, Equatable {
    var id: Int { index }
    let index: Int
    /// Seconds since the series began.
    let t: TimeInterval
    /// Foot temperature at t, °C.
    let c: Double
    /// The readings the rate at t was fitted to: (seconds, °C).
    let window: [Point]
    /// Mean time and temperature of the window.
    let tBar: Double
    let cBar: Double
    /// Σ(tᵢ − t̄)(Tᵢ − T̄) and Σ(tᵢ − t̄)².
    let covariance: Double
    let spread: Double
    /// dT/dt at t, °C per minute. Nil until three readings are in.
    let ratePerMinute: Double?
    /// ½(r₍ₖ₋₁₎ + rₖ)(tₖ − t₍ₖ₋₁₎): this second's trapezoid, °C.
    let area: Double?
    /// ∫ dT/dt dt from the first rate to t, °C.
    let accumulated: Double?

    struct Point: Equatable {
        let t: TimeInterval
        let c: Double
    }
}

extension ThermalCalculus {
    /// Every second of `samples` with its derivative and running integral,
    /// computed the same way as `rate` and `accumulatedChange`.
    static func steps(_ samples: [CalibrationSample], window: TimeInterval = window) -> [CalculusStep] {
        let points = series(samples)
        var result: [CalculusStep] = []
        var lower = 0
        var lastRate: (t: TimeInterval, perSecond: Double)?
        var total = 0.0
        var integrating = false
        for upper in points.indices {
            while points[upper].t - points[lower].t > window { lower += 1 }
            let span = points[lower...upper].map { CalculusStep.Point(t: $0.t, c: $0.c) }
            let n = Double(span.count)
            let tBar = span.map(\.t).reduce(0, +) / n
            let cBar = span.map(\.c).reduce(0, +) / n
            let covariance = span.reduce(0) { $0 + ($1.t - tBar) * ($1.c - cBar) }
            let spread = span.reduce(0) { $0 + ($1.t - tBar) * ($1.t - tBar) }
            let perSecond: Double? = span.count >= 3 && spread > 0 ? covariance / spread : nil
            var area: Double?
            if let perSecond {
                if let last = lastRate {
                    let a = (points[upper].t - last.t) * (last.perSecond + perSecond) / 2
                    area = a
                    total += a
                }
                integrating = true
                lastRate = (points[upper].t, perSecond)
            }
            result.append(CalculusStep(index: upper, t: points[upper].t, c: points[upper].c, window: span,
                                       tBar: tBar, cBar: cBar, covariance: covariance, spread: spread,
                                       ratePerMinute: perSecond.map { $0 * 60 }, area: area,
                                       accumulated: integrating ? total : nil))
        }
        return result
    }
}
