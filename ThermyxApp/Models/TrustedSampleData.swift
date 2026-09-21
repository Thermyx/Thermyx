import Foundation

/// A worked example of a shift, for a trusted member to read before a real one
/// arrives.
///
/// A watcher's screens are empty until the person they watch is out working,
/// which is exactly the wrong moment to be learning what the numbers mean. This
/// fills the screens with a plausible shift so they can find the alert, the
/// instruction, and the buttons while nothing is wrong.
///
/// **Everything here is fabricated, and the UI says so on every screen while it
/// is showing.** It is opt-in, never the default, and one tap to leave.
enum TrustedSampleData {

    /// A caution-then-recovery shift: an ordinary morning, heat building
    /// through the afternoon, one escalation, then cooling off.
    ///
    /// Generated for both feet, with the right running slightly hotter and
    /// carrying slightly more load — a realistic asymmetry, and the thing a
    /// watcher most needs practice reading.
    static func shift(endingAt end: Date = .now) -> [ThermyxHistorySample] {
        Foot.allCases.flatMap { shift(for: $0, endingAt: end) }
    }

    static func shift(for foot: Foot, endingAt end: Date = .now) -> [ThermyxHistorySample] {
        let start = end.addingTimeInterval(-8 * 3600)
        var samples: [ThermyxHistorySample] = []

        for minute in stride(from: 0, to: 8 * 60, by: 4) {
            let date = start.addingTimeInterval(Double(minute) * 60)
            let progress = Double(minute) / Double(8 * 60)

            // A hump peaking around two-thirds through the shift.
            let heatCurve = sin(progress * .pi * 0.92)
            let jitter = sin(Double(minute) / 7) * 0.18

            // The right foot runs a touch hotter and takes a little more
            // load, so the bilateral signals have something to show.
            let bias = foot == .right ? 1.0 : 0.0
            let ambient = 24 + heatCurve * 13 + jitter
            let contact = 30.5 + heatCurve * 7.6 + jitter + bias * 1.4
            let gait = 0.92 - heatCurve * 0.19 + jitter * 0.02 - bias * 0.05
            let balance = 0.48 + heatCurve * 0.11 + bias * 0.07
            let cadence = 104 - heatCurve * 14 + jitter * 2
            let standing = 0.32 + heatCurve * 0.24

            let reading = ThermyxReading(
                foot: foot,
                timestamp: date,
                footTemperatureC: contact,
                ambientTemperatureC: ambient,
                pressureBalance: balance,
                gaitStability: gait,
                batteryPercent: max(38, 96 - Int(progress * 58)),
                thermalMode: heatCurve > 0.55 ? .cooling : .ventilation,
                zones: FootZoneTemperatures(
                    forefootC: contact + 1.9,
                    archC: contact,
                    heelC: contact - 3.1
                ),
                cadenceStepsPerMinute: cadence,
                standingFraction: min(1, standing)
            )

            var sample = ThermyxHistorySample(foot: foot, start: date)
            sample.accumulate(reading, risk: ThermyxRiskEngine.assess(reading).level)
            samples.append(sample)
        }
        return samples
    }

    /// The escalations that shift produced.
    static func events(endingAt end: Date = .now) -> [ThermyxRiskEvent] {
        let base = end.addingTimeInterval(-8 * 3600)
        var caution = ThermyxRiskEvent(
            foot: .right,
            timestamp: base.addingTimeInterval(4.6 * 3600),
            level: .caution,
            reasons: ["Ambient temperature is elevated."],
            footTemperatureC: 36.4
        )
        caution.endedAt = base.addingTimeInterval(5.1 * 3600)

        var high = ThermyxRiskEvent(
            foot: .right,
            timestamp: base.addingTimeInterval(5.4 * 3600),
            level: .high,
            reasons: ["Ambient temperature is elevated.", "Movement stability is below baseline."],
            footTemperatureC: 38.1
        )
        high.endedAt = base.addingTimeInterval(6.0 * 3600)

        return [high, caution]
    }

    /// A bilateral snapshot for the watcher's metric grid.
    static func bilateral(endingAt end: Date = .now) -> BilateralReading {
        var pair = BilateralReading.empty
        for foot in Foot.allCases {
            let bias = foot == .right ? 1.0 : 0.0
            pair[foot] = ThermyxReading(
                foot: foot,
                timestamp: end.addingTimeInterval(-120),
                footTemperatureC: 36.4 + bias * 1.3,
                ambientTemperatureC: 35.9,
                pressureBalance: 0.52 + bias * 0.08,
                gaitStability: 0.81 - bias * 0.06,
                batteryPercent: foot == .left ? 64 : 58,
                thermalMode: .cooling,
                zones: FootZoneTemperatures(
                    forefootC: 38.1 + bias * 1.3,
                    archC: 36.4 + bias * 1.3,
                    heelC: 33.2 + bias * 1.3
                ),
                cadenceStepsPerMinute: 92,
                standingFraction: 0.44
            )
        }
        return pair
    }

    /// The status a watcher would be looking at mid-shift.
    static func latestEvent(deviceID: String, endingAt end: Date = .now) -> ThermyxAlertEvent {
        ThermyxAlertEvent(
            deviceID: deviceID,
            level: ThermyxRiskLevel.caution.rawValue,
            reasons: [
                "Ambient temperature is elevated.",
                "Right foot is running 1.3° warmer than the other."
            ],
            recipients: [],
            timestamp: end.addingTimeInterval(-120),
            readings: .init(
                footTemperatureC: 36.8,
                ambientTemperatureC: 35.9,
                gaitStability: 0.78,
                pressureBalance: 0.56,
                batteryPercent: 61
            )
        )
    }
}
