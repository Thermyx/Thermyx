import Foundation

/// Both insoles at one moment.
///
/// Either foot may be absent, and that is an ordinary state — one insole
/// charging, one out of range, or only one paired so far. Nothing here ever
/// substitutes one foot's reading for the other's.
struct BilateralReading: Equatable {
    var left: ThermyxReading?
    var right: ThermyxReading?

    static let empty = BilateralReading(left: nil, right: nil)

    subscript(foot: Foot) -> ThermyxReading? {
        get { foot == .left ? left : right }
        set { if foot == .left { left = newValue } else { right = newValue } }
    }

    var present: [ThermyxReading] { [left, right].compactMap { $0 } }
    var feet: [Foot] { present.map(\.foot) }
    var hasAny: Bool { !present.isEmpty }
    var hasBoth: Bool { left != nil && right != nil }

    // MARK: Aggregates
    //
    // Each of these is nil unless at least one foot reports the channel, and
    // each says plainly whether it is an average of two feet or a single
    // foot's value — the UI labels them differently.

    private func mean(_ value: (ThermyxReading) -> Double?) -> Double? {
        let values = present.compactMap(value)
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var footTemperatureC: Double? { mean(\.footTemperatureC) }
    var ambientTemperatureC: Double? { mean(\.ambientTemperatureC) }
    var gaitStability: Double? { mean(\.gaitStability) }
    var pressureBalance: Double? { mean(\.pressureBalance) }
    var cadenceStepsPerMinute: Double? { mean(\.cadenceStepsPerMinute) }

    /// The hotter foot's temperature — the one that matters for a warning.
    var peakFootTemperatureC: Double? {
        present.compactMap(\.footTemperatureC).max()
    }

    /// Lowest battery across connected insoles, because that is when you have
    /// to act.
    var batteryPercent: Int? {
        present.compactMap(\.batteryPercent).min()
    }

    /// The mode both feet agree on, or nil when they differ — which is itself
    /// worth showing rather than picking one.
    var thermalMode: ThermalMode? {
        let modes = Set(present.map(\.thermalMode))
        return modes.count == 1 ? modes.first : nil
    }

    // MARK: Bilateral signals
    //
    // These are the whole reason for running two insoles. A single foot can
    // only be compared against its own past; a pair can be compared against
    // each other right now, which is a far faster and more specific signal.

    /// Difference in contact temperature between feet, in °C. A persistent
    /// gap can mean a fit problem, a blocked duct, or — as a research
    /// direction, not a claim this app makes — a circulatory difference.
    var temperatureAsymmetryC: Double? {
        guard let l = left?.footTemperatureC, let r = right?.footTemperatureC else { return nil }
        return l - r
    }

    /// Difference in load level between feet, as a proportion. Favouring one
    /// foot shows up here long before the wearer notices it.
    ///
    /// This is one instant. Walking swings it by tens of points with every
    /// step, so never judge a person by a single value: `AsymmetryMonitor`
    /// averages whole step cycles over minutes before it says anything.
    var loadAsymmetry: Double? {
        guard let l = left?.pressureBalance, let r = right?.pressureBalance else { return nil }
        return l - r
    }

    /// Left-minus-right load as a share of the total, (L − R) / (L + R), in
    /// −1…1; positive leans left. Unlike the raw difference it doesn't depend
    /// on how hard the person is pressing, which is what makes it comparable
    /// between standing and walking and across people.
    var loadLean: Double? {
        guard let l = left?.pressureBalance, let r = right?.pressureBalance, l + r > 0.1 else { return nil }
        return (l - r) / (l + r)
    }

    /// Difference in gait stability between feet.
    var gaitAsymmetry: Double? {
        guard let l = left?.gaitStability, let r = right?.gaitStability else { return nil }
        return l - r
    }

    /// How lopsided things are overall, 0 (even) to 1 (very uneven). Nil
    /// unless both feet are reporting — asymmetry is meaningless from one.
    var asymmetryIndex: Double? {
        guard hasBoth else { return nil }
        var parts: [Double] = []
        if let t = temperatureAsymmetryC { parts.append(min(1, abs(t) / 4.0)) }
        if let l = loadAsymmetry { parts.append(min(1, abs(l) / 0.30)) }
        if let g = gaitAsymmetry { parts.append(min(1, abs(g) / 0.25)) }
        guard !parts.isEmpty else { return nil }
        return parts.reduce(0, +) / Double(parts.count)
    }

    /// Mean steps per minute at or above this counts as walking (the same
    /// line the history buckets use).
    static let walkingCadence = 30.0

    /// Whether the pair is walking right now. Nil when no cadence is reported.
    var isWalking: Bool? {
        cadenceStepsPerMinute.map { $0 >= Self.walkingCadence }
    }

    /// Which foot is carrying clearly more weight *right now*, for labels
    /// that need a name in the moment. Never while walking, because then the
    /// load alternates between the feet by design, and only for a lean of
    /// 15 points or more, well past ordinary standing sway. Whether someone
    /// is genuinely favouring a foot is `AsymmetryMonitor`'s question, and it
    /// takes minutes of evidence to answer.
    var favouredFoot: Foot? {
        guard isWalking != true, let lean = loadLean, abs(lean) >= 0.15 else { return nil }
        return lean > 0 ? .left : .right
    }

    /// Which foot is running hotter, when the gap is big enough to name.
    var hotterFoot: Foot? {
        guard let delta = temperatureAsymmetryC, abs(delta) > 1.0 else { return nil }
        return delta > 0 ? .left : .right
    }
}
