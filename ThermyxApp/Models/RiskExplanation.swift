import Foundation

/// Everything behind a risk level, in a form the "Why am I seeing this?"
/// panel can show: which foot, which signals counted, how fresh the data is,
/// how much to trust it, and what to do next. Built only from readings the
/// app actually received.
struct RiskExplanation: Equatable {
    struct Signal: Equatable, Identifiable {
        enum Kind: String {
            case footTemperature, ambient, steadiness, temperatureGap, loadGap, limp, burnLimit, personalBaseline, trend
        }
        let kind: Kind
        let title: String
        /// The live value, already formatted, or nil when the channel is missing.
        let value: String?
        /// What it is compared with, in words.
        let rule: String
        /// Whether this signal is currently pushing the level up.
        let contributes: Bool

        var id: String { "\(kind.rawValue)-\(title)" }
    }

    enum Confidence: String {
        case high = "High"
        case medium = "Medium"
        case low = "Low"
    }

    let level: ThermyxRiskLevel
    let foot: Foot?
    let signals: [Signal]
    /// Seconds since the newest reading, per connected foot.
    let dataAge: [Foot: TimeInterval]
    let confidence: Confidence
    let confidenceReasons: [String]
    let nextStep: String

    var contributing: [Signal] { signals.filter(\.contributes) }

    /// Builds the explanation for the pair as it stands.
    ///
    /// - Parameters:
    ///   - asymmetry: What `AsymmetryMonitor` currently reports. When given, the
    ///     left–right rows describe it (windowed, against the wearer's usual)
    ///     and `sustainedTemperatureGap` / `sustainedLoadGap` are ignored.
    ///   - extras: Signals from layers outside the fixed risk engine (personal
    ///     baseline, trends), which may add caution but never lower a level.
    static func build(
        assessment: ThermyxRiskAssessment,
        reading: BilateralReading,
        sustainedTemperatureGap: Bool,
        sustainedLoadGap: Bool,
        rssi: [Foot: Int],
        bothExpected: Bool,
        unit: TemperatureUnit,
        asymmetry: AsymmetryStatus? = nil,
        extras: [Signal] = [],
        now: Date = .now
    ) -> RiskExplanation {
        let hottest = reading.present.max { ($0.footTemperatureC ?? -.infinity) < ($1.footTemperatureC ?? -.infinity) }
        let focusReading = assessment.foot.flatMap { reading[$0] } ?? hottest
        let footC = focusReading?.footTemperatureC
        let zoneMax = reading.present.compactMap { r in [r.zones?.forefootC, r.zones?.archC, r.zones?.heelC].compactMap { $0 }.max() }.max()
        let peakC = [footC, zoneMax].compactMap { $0 }.max()
        let ambientC = reading.present.compactMap(\.ambientTemperatureC).max()
        let steadiness = reading.present.compactMap(\.gaitStability).min()

        var signals: [Signal] = [
            Signal(
                kind: .burnLimit,
                title: "Burn-protection limit",
                value: peakC.map { TemperatureFormat.degrees($0, in: unit) },
                rule: "High risk at \(TemperatureFormat.degrees(ThermyxRiskEngine.burnLimitC, in: unit, decimals: 0)) or more, on its own",
                contributes: (peakC ?? -.infinity) >= ThermyxRiskEngine.burnLimitC
            ),
            Signal(
                kind: .footTemperature,
                title: "Foot temperature",
                value: footC.map { TemperatureFormat.degrees($0, in: unit) },
                rule: "Counts at \(TemperatureFormat.degrees(38, in: unit, decimals: 0)) or more",
                contributes: (footC ?? -.infinity) >= 38
            ),
            Signal(
                kind: .ambient,
                title: "Air temperature",
                value: ambientC.map { TemperatureFormat.degrees($0, in: unit) },
                rule: "Counts at \(TemperatureFormat.degrees(35, in: unit, decimals: 0)) or more",
                contributes: (ambientC ?? -.infinity) >= 35
            ),
            Signal(
                kind: .steadiness,
                title: "Steadiness",
                value: steadiness.map { "\(Int(($0 * 100).rounded()))%" },
                rule: "Counts below 80%",
                contributes: (steadiness ?? .infinity) < 0.8
            )
        ]

        if reading.hasBoth, let asymmetry {
            signals.append(contentsOf: Self.asymmetrySignals(asymmetry, reading: reading, unit: unit))
        } else if reading.hasBoth {
            let gap = reading.temperatureAsymmetryC
            signals.append(Signal(
                kind: .temperatureGap,
                title: "Left–right temperature gap",
                value: gap.map { GapFormat.degrees(unit == .fahrenheit ? $0 * 9 / 5 : $0) },
                rule: "Caution after more than \(unit == .fahrenheit ? "1.8°" : "1°") for 2 minutes",
                contributes: sustainedTemperatureGap && reading.hotterFoot != nil
            ))
            let load = reading.loadAsymmetry
            signals.append(Signal(
                kind: .loadGap,
                title: "Left–right load gap",
                value: load.map { GapFormat.points($0 * 100) },
                rule: "Caution after more than 8 points for 2 minutes",
                contributes: sustainedLoadGap && reading.favouredFoot != nil
            ))
        }
        signals.append(contentsOf: extras)

        var age: [Foot: TimeInterval] = [:]
        for r in reading.present { age[r.foot] = max(0, now.timeIntervalSince(r.timestamp)) }

        let (confidence, reasons) = Self.confidence(
            reading: reading, age: age, rssi: rssi, bothExpected: bothExpected
        )

        let next = ThermyxSuggestion.nextStep(for: assessment, reading: reading) ?? assessment.level.shortGuidance

        return RiskExplanation(
            level: assessment.level,
            foot: assessment.foot,
            signals: signals,
            dataAge: age,
            confidence: confidence,
            confidenceReasons: reasons,
            nextStep: next
        )
    }

    /// The left–right rows when `AsymmetryMonitor` is in use: windowed values
    /// against the wearer's own usual, and a plain statement of the rule.
    static func asymmetrySignals(_ status: AsymmetryStatus, reading: BilateralReading, unit: TemperatureUnit) -> [Signal] {
        let minutes = Int(AsymmetryConfig.enterSeconds / 60)
        let metrics = status.metrics
        func degrees(_ celsius: Double) -> String {
            GapFormat.degrees(unit == .fahrenheit ? celsius * 9 / 5 : celsius)
        }
        let tempBar = unit == .fahrenheit ? (metrics?.tempBar ?? 1) * 9 / 5 : (metrics?.tempBar ?? 1)
        let leanBar = Int(((metrics?.leanBar ?? AsymmetryConfig.leanEnter) * 100).rounded())

        var leanRule = "Caution when you lean \(leanBar) points or more past your usual for \(minutes) of the last 5 minutes, standing or walking. Weight swinging from foot to foot as you walk doesn't count."
        if let usual = metrics?.usualLean, abs(usual) >= 0.01 {
            leanRule += " Your usual is \(GapFormat.points(usual * 100).lowercased())."
        }
        return [
            Signal(
                kind: .temperatureGap,
                title: "Left–right temperature gap",
                value: metrics?.tempGap.map { degrees($0) } ?? reading.temperatureAsymmetryC.map { degrees($0) },
                rule: "Caution when one foot runs \(String(format: "%.1f", tempBar))° or more past your usual gap for \(minutes) of the last 5 minutes",
                contributes: status.finding(.warmerFoot) != nil
            ),
            Signal(
                kind: .loadGap,
                title: "Left–right weight lean",
                value: metrics?.lean.map { GapFormat.points($0 * 100) },
                rule: leanRule,
                contributes: status.finding(.lean) != nil
            ),
            Signal(
                kind: .limp,
                title: "Even stepping",
                value: status.finding(.limp) != nil ? "Uneven" : "Even",
                rule: "Caution when uneven loading plus uneven steadiness or a slower pace hold for \(minutes) of the last 5 minutes while walking",
                contributes: status.finding(.limp) != nil
            )
        ]
    }

    /// How far to trust the current picture: fresh data, all channels
    /// present, a decent radio link, and both insoles when a pair is in use.
    static func confidence(
        reading: BilateralReading,
        age: [Foot: TimeInterval],
        rssi: [Foot: Int],
        bothExpected: Bool
    ) -> (Confidence, [String]) {
        var reasons: [String] = []
        var penalty = 0

        guard reading.hasAny else { return (.low, ["No live data from either insole."]) }

        if let oldest = age.values.max(), oldest > 3 {
            reasons.append("Newest reading is \(Int(oldest)) s old.")
            penalty += oldest > 10 ? 2 : 1
        }
        let missing = reading.present.flatMap { r -> [String] in
            var m: [String] = []
            if r.footTemperatureC == nil { m.append("\(r.foot.label) foot temperature") }
            if r.ambientTemperatureC == nil { m.append("\(r.foot.label) air temperature") }
            if r.gaitStability == nil { m.append("\(r.foot.label) steadiness") }
            return m
        }
        if !missing.isEmpty {
            reasons.append("Not measured: \(missing.joined(separator: ", ")).")
            penalty += missing.count > 1 ? 2 : 1
        }
        let weak = rssi.filter { $0.value < -85 }.map(\.key)
        if !weak.isEmpty {
            reasons.append("Weak Bluetooth signal on the \(weak.map { $0.label.lowercased() }.sorted().joined(separator: " and ")) insole.")
            penalty += 1
        }
        if bothExpected && !reading.hasBoth {
            reasons.append("Only one insole is reporting, so left–right checks are off.")
            penalty += 1
        }
        if reasons.isEmpty { reasons.append("Fresh readings from every channel with a good signal.") }
        let level: Confidence = penalty == 0 ? .high : penalty <= 2 ? .medium : .low
        return (level, reasons)
    }
}
