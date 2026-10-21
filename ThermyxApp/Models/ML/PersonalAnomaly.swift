import Foundation

// Explainable drift detection for the personal baseline.
//
// The fixed personal rule ("three spreads above your usual") reacts to one
// big departure. A slow, steady slide, 1 °C warmer than usual and staying
// there, never trips it, yet it is exactly what a blocked duct, a tight shoe or
// building heat strain looks like. A one-sided CUSUM catches that: each
// minute it adds how far the reading is beyond a small allowance, and takes
// nothing away except by returning to normal, so small departures that
// *persist* build up while noise does not.
//
// Each channel is named, carries its own tally and how many minutes the drift
// has been running, so "Why am I seeing this?" can say exactly which signal
// moved, by how much, and for how long.

/// One feature's running tally.
struct DriftChannel: Codable, Equatable {
    /// The CUSUM tally, in spreads.
    var tally = 0.0
    /// Consecutive minutes the tally has been above zero.
    var run = 0
    /// Sum of the raw departures over that run, in the signal's own units.
    var departureSum = 0.0

    /// Folds in one minute. `z` is the departure in spreads, positive in the
    /// direction that matters (warmer, less steady).
    mutating func update(z: Double, departure: Double) {
        let capped = min(max(z, -DriftState.zCap), DriftState.zCap)
        tally = min(max(0, tally + capped - DriftState.allowance), DriftState.tallyCap)
        if tally > 0 {
            run += 1
            departureSum += departure
        } else {
            run = 0
            departureSum = 0
        }
    }

    var meanDeparture: Double { run > 0 ? departureSum / Double(run) : 0 }
    var isAlarmed: Bool { tally >= DriftState.alarm }
}

struct DriftState: Codable, Equatable {
    /// Departures smaller than this many spreads add nothing: ordinary
    /// minute-to-minute variation.
    static let allowance = 0.75
    /// The tally at which a drift is reported. With this allowance, a steady
    /// 2-spread shift is caught in about five minutes and a 1.5-spread shift
    /// in about eight, while ordinary noise averages about a month between
    /// false alarms.
    static let alarm = 6.0
    /// One minute can add at most this many spreads, so a single glitchy
    /// minute can never alarm on its own.
    static let zCap = 4.0
    static let tallyCap = 12.0

    /// Spread floors: a wearer who is very steady is not alarmed by noise.
    static let footSpreadFloorC = 0.75
    static let steadinessSpreadFloor = 0.04

    var foot = DriftChannel()
    var steadiness = DriftChannel()

    /// Folds in one minute of non-heating wear.
    ///
    /// - Parameters:
    ///   - footExpected: The usual foot temperature for what the wearer is
    ///     doing, and its spread.
    ///   - gaitUsual: The usual steadiness and its spread.
    mutating func update(
        footC: Double?,
        footExpected: (mean: Double, sd: Double)?,
        gait: Double?,
        gaitUsual: (mean: Double, sd: Double)?
    ) {
        if let footC, let footExpected {
            let spread = max(footExpected.sd, Self.footSpreadFloorC)
            let departure = footC - footExpected.mean
            foot.update(z: departure / spread, departure: departure)
        }
        if let gait, let gaitUsual {
            let spread = max(gaitUsual.sd, Self.steadinessSpreadFloor)
            let departure = gaitUsual.mean - gait
            steadiness.update(z: departure / spread, departure: departure)
        }
    }

    func report() -> AnomalyReport {
        AnomalyReport(features: [
            .init(name: .footTemperature, channel: foot),
            .init(name: .steadiness, channel: steadiness)
        ])
    }
}

/// What the drift detector currently sees, feature by feature.
struct AnomalyReport: Equatable {
    struct Feature: Equatable, Identifiable {
        enum Name: String, Equatable {
            case footTemperature, steadiness
        }
        var name: Name
        var tally: Double
        /// Minutes the drift has been running.
        var run: Int
        /// Average departure over that run: °C warmer, or steadiness points
        /// (0–1) lower.
        var meanDeparture: Double
        var contributes: Bool
        var id: String { name.rawValue }

        init(name: Name, channel: DriftChannel) {
            self.name = name
            tally = channel.tally
            run = channel.run
            meanDeparture = channel.meanDeparture
            contributes = channel.isAlarmed
        }
    }

    var features: [Feature]

    var isAnomalous: Bool { features.contains(where: \.contributes) }
    var contributing: [Feature] { features.filter(\.contributes) }

    /// 0…1: how close the strongest channel is to alarming.
    var score: Double {
        min(1, (features.map(\.tally).max() ?? 0) / DriftState.alarm)
    }

    func feature(_ name: Feature.Name) -> Feature? { features.first { $0.name == name } }
}
