import Foundation

/// One aggregated bucket of telemetry.
///
/// Live packets arrive several times a second; nothing useful is gained by
/// keeping them all. Readings fold into minute buckets (retained a week) and
/// hour buckets (retained six months), which is enough for the day, week, and
/// month ranges on Insights.
struct ThermyxHistorySample: Codable, Equatable, Identifiable {
    /// Which insole these readings came from.
    var foot: Foot = .left
    /// Start of the bucket.
    let start: Date
    /// How many raw packets folded into this bucket.
    var sampleCount: Int

    var footMeanC: Double?
    var footMinC: Double?
    var footMaxC: Double?
    var ambientMeanC: Double?
    var gaitMean: Double?
    var balanceMean: Double?
    var forefootMeanC: Double?
    var archMeanC: Double?
    var heelMeanC: Double?
    var cadenceMean: Double?
    var standingMean: Double?
    /// The most severe risk level seen during the bucket.
    var peakRisk: String?

    var id: String { "\(foot.rawValue)-\(start.timeIntervalSince1970)" }

    var peakRiskLevel: ThermyxRiskLevel? {
        peakRisk.flatMap(ThermyxRiskLevel.init(rawValue:))
    }

    var zones: FootZoneTemperatures? {
        guard let forefootMeanC, let archMeanC, let heelMeanC else { return nil }
        return FootZoneTemperatures(forefootC: forefootMeanC, archC: archMeanC, heelC: heelMeanC)
    }

    init(foot: Foot, start: Date) {
        self.foot = foot
        self.start = start
        self.sampleCount = 0
    }

    /// Fold a reading into this bucket as a running mean.
    mutating func accumulate(_ reading: ThermyxReading, risk: ThermyxRiskLevel?) {
        let n = Double(sampleCount)
        func mean(_ current: Double?, _ next: Double?) -> Double? {
            guard let next else { return current }
            guard let current else { return next }
            return (current * n + next) / (n + 1)
        }

        footMeanC = mean(footMeanC, reading.footTemperatureC)
        ambientMeanC = mean(ambientMeanC, reading.ambientTemperatureC)
        gaitMean = mean(gaitMean, reading.gaitStability)
        balanceMean = mean(balanceMean, reading.pressureBalance)
        forefootMeanC = mean(forefootMeanC, reading.zones?.forefootC)
        archMeanC = mean(archMeanC, reading.zones?.archC)
        heelMeanC = mean(heelMeanC, reading.zones?.heelC)
        cadenceMean = mean(cadenceMean, reading.cadenceStepsPerMinute)
        standingMean = mean(standingMean, reading.standingFraction)

        if let foot = reading.footTemperatureC {
            footMinC = min(footMinC ?? foot, foot)
            footMaxC = max(footMaxC ?? foot, foot)
        }

        if let risk, risk != .unavailable {
            if let existing = peakRiskLevel {
                if risk.severity > existing.severity { peakRisk = risk.rawValue }
            } else {
                peakRisk = risk.rawValue
            }
        }

        sampleCount += 1
    }
}

/// A single recorded escalation, for the events list on the temperature detail.
struct ThermyxRiskEvent: Codable, Equatable, Identifiable {
    let id: UUID
    var foot: Foot = .left
    let timestamp: Date
    let level: String
    let reasons: [String]
    let footTemperatureC: Double?
    /// Populated when the event resolves, so the list can say "held 18 minutes".
    var endedAt: Date?

    var riskLevel: ThermyxRiskLevel? { ThermyxRiskLevel(rawValue: level) }

    var duration: TimeInterval? {
        guard let endedAt else { return nil }
        return endedAt.timeIntervalSince(timestamp)
    }

    init(foot: Foot, timestamp: Date, level: ThermyxRiskLevel, reasons: [String], footTemperatureC: Double?) {
        self.id = UUID()
        self.foot = foot
        self.timestamp = timestamp
        self.level = level.rawValue
        self.reasons = reasons
        self.footTemperatureC = footTemperatureC
        self.endedAt = nil
    }
}
