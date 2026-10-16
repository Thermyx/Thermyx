import Foundation

/// The Thermal Safety Simulator's model: an illustrative minute-by-minute
/// model of a wearer's feet, fed to the app's **real** decision engine.
///
/// The physiology here is deliberately simple and is not a medical model.
/// What is real is everything downstream of the simulated sensor readings:
/// `ThermyxRiskEngine` and `PersonalLayer` decide the level exactly as they
/// do for live insoles, the heat lockout follows `ThermyxViewModel`'s rule,
/// and the insole's Auto/Cool/Heat/Off behaviour and 40 °C burn cutoff
/// follow the firmware. So the simulator shows how Thermyx decides, on
/// conditions the wearer can't safely create for real.
///
/// The insole senses only foot temperature, one arch load and motion, so
/// the simulated readings carry only those. Air temperature changes the
/// feet, and Thermyx reacts through them; it never sees the air directly.
struct ThermalSimulation: Equatable {

    // MARK: Inputs

    enum Activity: String, CaseIterable, Identifiable {
        case resting, standing, walking, running, labor
        var id: String { rawValue }
        var label: String {
            switch self {
            case .resting: return "Rest"
            case .standing: return "Stand"
            case .walking: return "Walk"
            case .running: return "Run"
            case .labor: return "Labor"
            }
        }
        /// Relative metabolic heat, 0...1.
        var metabolic: Double {
            switch self {
            case .resting: return 0
            case .standing: return 0.15
            case .walking: return 0.45
            case .running: return 0.9
            case .labor: return 0.72
            }
        }
        /// Steps per minute.
        var cadence: Double {
            switch self {
            case .resting, .standing: return 0
            case .walking: return 108
            case .running: return 165
            case .labor: return 72
            }
        }
    }

    enum Footwear: String, CaseIterable, Identifiable {
        case runner, workBoot, winterBoot
        var id: String { rawValue }
        var label: String {
            switch self {
            case .runner: return "Mesh runner"
            case .workBoot: return "Work boot"
            case .winterBoot: return "Insulated boot"
            }
        }
        /// How far the foot sits from the air toward the body's warmth.
        var insulation: Double {
            switch self {
            case .runner: return 0.52
            case .workBoot: return 0.62
            case .winterBoot: return 0.78
            }
        }
    }

    enum Fit: String, CaseIterable, Identifiable {
        case good, tight, loose
        var id: String { rawValue }
        var label: String {
            switch self {
            case .good: return "Good"
            case .tight: return "Tight"
            case .loose: return "Loose"
            }
        }
    }

    enum Connection: String, CaseIterable, Identifiable {
        case both, leftOnly, none
        var id: String { rawValue }
        var label: String {
            switch self {
            case .both: return "Both"
            case .leftOnly: return "Left only"
            case .none: return "None"
            }
        }
    }

    enum Fault: String, CaseIterable, Identifiable {
        case none, temperatureDropout, stuckReading, fanBlocked
        var id: String { rawValue }
        var label: String {
            switch self {
            case .none: return "None"
            case .temperatureDropout: return "Sensor drops out"
            case .stuckReading: return "Reading stuck"
            case .fanBlocked: return "Fan blocked"
            }
        }
        var detail: String {
            switch self {
            case .none: return "Everything works."
            case .temperatureDropout: return "The left insole stops reporting temperature."
            case .stuckReading: return "The left insole repeats one temperature."
            case .fanBlocked: return "Cooling can't shed its heat."
            }
        }
    }

    struct Conditions: Equatable {
        var airC: Double = 24
        /// Relative humidity, 0...1.
        var humidity: Double = 0.5
        var sun = false
        var activity: Activity = .walking
        var footwear: Footwear = .runner
        var fit: Fit = .good
        var wet = false
        var packKg: Double = 0
        var acclimatized = false
        /// Favouring the left foot, as after a knock or a blister.
        var favouring = false
        var setting: ThermalSetting = .auto
        var targetC: Double = 31
        var connection: Connection = .both
        var fault: Fault = .none
    }

    /// A ready-made starting point.
    struct Scenario: Identifiable, Equatable {
        let id: String
        let title: String
        let summary: String
        let conditions: Conditions
        var startBattery: Double = 100
        var startHydration: Double = 0.8

        static let all: [Scenario] = [
            Scenario(id: "site", title: "Job site, 35°", summary: "A summer shift on concrete, in boots, in the sun.",
                     conditions: .init(airC: 35, humidity: 0.45, sun: true, activity: .labor, footwear: .workBoot, packKg: 8, setting: .auto, targetC: 31)),
            Scenario(id: "race", title: "Race pace", summary: "A humid 10K at race pace in mesh runners.",
                     conditions: .init(airC: 29, humidity: 0.75, sun: true, activity: .running, footwear: .runner, setting: .auto, targetC: 31)),
            Scenario(id: "patrol", title: "Winter patrol", summary: "Standing watch at −10° in insulated boots.",
                     conditions: .init(airC: -10, humidity: 0.6, activity: .standing, footwear: .winterBoot, packKg: 20, setting: .auto, targetC: 31)),
            Scenario(id: "wet", title: "Wet boots", summary: "Snow got in. Same patrol, soaked boots.",
                     conditions: .init(airC: -4, humidity: 0.9, activity: .walking, footwear: .winterBoot, wet: true, setting: .off, targetC: 31)),
            Scenario(id: "march", title: "Ruck march", summary: "Heavy pack, long walk, one foot sore.",
                     conditions: .init(airC: 31, humidity: 0.5, sun: true, activity: .walking, footwear: .workBoot, fit: .tight, packKg: 30, favouring: true, setting: .cool, targetC: 30),
                     startHydration: 0.6),
            Scenario(id: "desk", title: "Desk day", summary: "Indoors, mostly sitting. A quiet baseline.",
                     conditions: .init(airC: 22, humidity: 0.4, activity: .resting, footwear: .runner, setting: .auto, targetC: 31)),
        ]
    }

    enum Recovery: String, CaseIterable, Identifiable {
        case drink, shade, soak, indoors
        var id: String { rawValue }
        var label: String {
            switch self {
            case .drink: return "Drink water"
            case .shade: return "Rest in shade"
            case .soak: return "Cool foot soak"
            case .indoors: return "Warm up inside"
            }
        }
        var symbol: String {
            switch self {
            case .drink: return "drop"
            case .shade: return "sun.haze"
            case .soak: return "water.waves"
            case .indoors: return "house"
            }
        }
    }

    // MARK: State

    struct Sample: Equatable {
        let minute: Int
        /// The warmer reported foot, or nil with no temperature reported.
        let footC: Double?
        /// The warmer foot's true simulated temperature, reported or not.
        let trueC: Double
        /// The same feet with the insoles' heating and cooling off.
        let passiveC: Double
        let level: ThermyxRiskLevel
        let action: ThermalMode
    }

    struct Event: Identifiable, Equatable {
        enum Kind: Equatable { case level(ThermyxRiskLevel), device, alert, wearer, note }
        let id: Int
        let minute: Int
        let kind: Kind
        let title: String
        let detail: String
    }

    private(set) var conditions: Conditions
    private(set) var minute = 0
    private(set) var footC: [Foot: Double]
    private(set) var passiveC: Double
    /// Whole-body heat strain, 0 (none) to ~1.3.
    private(set) var strain: Double
    /// 0 (dry) to 1 (well hydrated).
    private(set) var hydration: Double
    private(set) var fatigue = 0.0
    private(set) var battery: Double
    /// What the insoles are physically doing this minute.
    private(set) var action: ThermalMode = .off
    /// The setting the app is following, after any heat lockout.
    private(set) var setting: ThermalSetting
    private(set) var assessment: ThermyxRiskAssessment = .unavailable
    private(set) var samples: [Sample] = []
    private(set) var events: [Event] = []

    private var stuckC: Double?
    private var shadeUntil = -1, soakUntil = -1, indoorsUntil = -1
    private var gapSince: Int?, loadGapSince: Int?
    private var lastLevel: ThermyxRiskLevel = .unavailable
    private var nextEventID = 0
    private var burnCutoffLogged = false
    private var batteryLowLogged = false

    init(scenario: Scenario) {
        conditions = scenario.conditions
        setting = scenario.conditions.setting
        battery = scenario.startBattery
        hydration = scenario.startHydration
        strain = 0.15
        // Everyone starts where they walked in from: feet at a comfortable
        // indoor temperature, so the scenario's effect shows as it builds.
        var arrival = scenario.conditions
        arrival.airC = 22; arrival.sun = false; arrival.activity = .standing; arrival.wet = false
        let start = ThermalSimulation.equilibrium(conditions: arrival, strain: 0.15, indoors: true, soaking: false)
        footC = [.left: start, .right: start]
        passiveC = start
        action = insoleAction(warmest: start)
        refresh()
        log(.note, "Simulation started", scenario.summary)
    }

    // MARK: Controls

    mutating func update(_ change: (inout Conditions) -> Void) {
        let before = conditions
        change(&conditions)
        if conditions.setting != before.setting {
            setting = conditions.setting
            log(.wearer, "Mode set to \(conditions.setting.label)", "Chosen in the simulator.")
        }
        if conditions.fault != before.fault, conditions.fault != .none {
            log(.device, conditions.fault.label, conditions.fault.detail)
            if conditions.fault == .stuckReading { stuckC = footC[.left] }
        }
        if conditions.fault != .stuckReading { stuckC = nil }
        if conditions.connection != before.connection {
            log(.device, "Insoles: \(conditions.connection.label.lowercased())", conditions.connection == .none
                ? "No readings arrive, so Thermyx can't assess anything."
                : conditions.connection == .leftOnly ? "Thermyx assesses one foot and loses the left–right comparison." : "Both feet report again.")
        }
        refresh()
    }

    mutating func setBattery(_ percent: Double) {
        battery = min(max(percent, 0), 100)
        batteryLowLogged = battery <= Double(ThermyxBattery.low)
        refresh()
    }

    mutating func perform(_ recovery: Recovery) {
        switch recovery {
        case .drink:
            hydration = min(1, hydration + 0.35)
            log(.wearer, "Drank water", "Hydration recovers; heat strain eases over the next minutes.")
        case .shade:
            shadeUntil = minute + 10
            log(.wearer, "Resting in shade", "Ten minutes off your feet and out of the sun.")
        case .soak:
            soakUntil = minute + 6
            log(.wearer, "Cool foot soak", "Six minutes in cool water: the fastest way to cool a hot foot.")
        case .indoors:
            indoorsUntil = minute + 12
            log(.wearer, "Warming up inside", "Twelve minutes in a heated room.")
        }
    }

    // MARK: Time

    /// Advances one simulated minute.
    mutating func step() {
        minute += 1
        let resting = minute <= shadeUntil
        let soaking = minute <= soakUntil
        let indoors = minute <= indoorsUntil
        var c = conditions
        if resting { c.activity = .resting; c.sun = false }
        if indoors { c.airC = 21; c.sun = false; c.humidity = 0.4 }
        let m = c.activity.metabolic
        let heat = Self.heatLoad(c)

        // Heat strain drifts toward what the work and weather demand.
        let target = min(1.3, max(0, 0.15 + 0.55 * m * (0.6 + 0.4 * heat) + 0.5 * heat
                                   - 0.3 * (hydration - 0.5) - (c.acclimatized ? 0.12 : 0)))
        strain += (target - strain) / (resting || soaking ? 14 : 25)
        hydration = max(0, hydration - (0.0015 + 0.006 * m * (0.5 + heat)))
        fatigue = min(1, max(0, fatigue + (m > 0.2 ? 0.0015 * m : -0.004)))

        let eq = Self.equilibrium(conditions: c, strain: strain, indoors: indoors, soaking: soaking)
        passiveC += (eq - passiveC) / 8

        // What the insoles do this minute, as the firmware would.
        let warmest = footC.values.max() ?? eq
        action = insoleAction(warmest: warmest)
        let rate = actionRate(airC: c.airC)
        for foot in Foot.allCases {
            let bias = c.favouring && foot == .left ? 0.9 : 0
            var t = footC[foot] ?? eq
            t += (eq + bias - t) / 8 + rate
            footC[foot] = t
        }

        // Battery: sensing, plus the thermal module when it runs.
        let draw = 0.02 + (action == .cooling ? 0.3 : action == .heating ? 0.35 : action == .ventilation ? 0.15 : 0)
        battery = max(0, battery - draw)
        if battery <= Double(ThermyxBattery.low), !batteryLowLogged {
            batteryLowLogged = true
            log(.device, "Battery low · \(Int(battery))%", "Thermyx warns you on the phone at \(ThermyxBattery.low)% and again at \(ThermyxBattery.critical)%.")
        }
        if battery == 0 { conditions.connection = .none }

        refresh()
        samples.append(Sample(minute: minute, footC: reportedPeak, trueC: footC.values.max() ?? passiveC,
                              passiveC: passiveC, level: assessment.level, action: action))
        if samples.count > 240 { samples.removeFirst(samples.count - 240) }
    }

    // MARK: Readings

    /// What the insoles would report right now. Only what the hardware
    /// senses: foot temperature, one arch load, gait from the IMU.
    var reading: BilateralReading {
        guard battery > 0 else { return .empty }
        var pair = BilateralReading.empty
        let feet: [Foot] = conditions.connection == .both ? [.left, .right] : conditions.connection == .leftOnly ? [.left] : []
        for foot in feet {
            var temp = footC[foot].map { ($0 * 10).rounded() / 10 }
            if foot == .left, conditions.fault == .temperatureDropout { temp = nil }
            if foot == .left, conditions.fault == .stuckReading, let stuckC { temp = (stuckC * 10).rounded() / 10 }
            var r = ThermyxReading(foot: foot, timestamp: .now, footTemperatureC: temp, ambientTemperatureC: nil,
                                   pressureBalance: archLoad(foot), gaitStability: steadiness(foot),
                                   batteryPercent: Int(battery.rounded()), thermalMode: action,
                                   cadenceStepsPerMinute: effectiveActivity.cadence,
                                   standingFraction: effectiveActivity == .standing ? 1 : 0)
            r.loadIsArchLevel = true
            r.settingEcho = setting
            r.burnCutoff = conditions.setting == .heat && (footC.values.max() ?? 0) >= ThermyxRiskEngine.burnLimitC
            r.footDetected = true
            pair[foot] = r
        }
        return pair
    }

    var reportedPeak: Double? { reading.present.compactMap(\.footTemperatureC).max() }

    var effectiveActivity: Activity { minute <= shadeUntil ? .resting : conditions.activity }

    func archLoad(_ foot: Foot) -> Double {
        let m = effectiveActivity.metabolic
        var load = 0.38 + 0.32 * min(1, conditions.packKg / 30) + 0.12 * m
        if conditions.fit == .loose { load -= 0.07 }
        if conditions.fit == .tight { load += 0.04 }
        if conditions.favouring { load += foot == .left ? -0.14 : 0.14 }
        return min(1, max(0, load))
    }

    func steadiness(_ foot: Foot) -> Double {
        var g = 0.96
        if conditions.fit == .tight { g -= 0.02 }
        if conditions.fit == .loose { g -= 0.05 }
        g -= 0.3 * max(0, strain - 0.55)
        g -= 0.2 * max(0, 0.45 - hydration)
        g -= 0.12 * fatigue
        if conditions.favouring, foot == .left { g -= 0.06 }
        return min(0.99, max(0.4, g))
    }

    /// Minutes the warmer foot spent outside the engine's temperature band
    /// (at or above 38°, or at or below 25°), with Thermyx's heating and
    /// cooling and, from the passive twin, without. Judged by the same
    /// temperature rules on both, so the difference is the insoles' work.
    var minutesOutsideBand: (with: Int, without: Int) {
        let with = samples.filter { Self.temperatureLevel($0.trueC) != .normal }.count
        let without = samples.filter { Self.temperatureLevel($0.passiveC) != .normal }.count
        return (with, without)
    }

    /// The engine's temperature-only rules: the cold and hot thresholds and
    /// the burn limit.
    static func temperatureLevel(_ c: Double) -> ThermyxRiskLevel {
        if c >= ThermyxRiskEngine.burnLimitC { return .high }
        if c >= 38 || c <= ThermyxRiskEngine.coldFootC { return .caution }
        return .normal
    }

    // MARK: Model

    /// Environmental heat, 0 (mild) up.
    static func heatLoad(_ c: Conditions) -> Double {
        max(0, (c.airC - 24) / 14) + (c.sun ? 0.25 : 0) + (c.airC > 26 ? c.humidity * 0.25 : 0)
    }

    /// Where an inactive insole's foot temperature settles: between the air
    /// and the body's warmth, by how insulated the shoe is.
    static func equilibrium(conditions c: Conditions, strain: Double, indoors: Bool, soaking: Bool) -> Double {
        let air = indoors ? 21 : c.airC
        let core = 37 + 1.1 * strain
        var ratio = c.footwear.insulation - (c.wet ? 0.18 : 0) + (c.fit == .tight ? 0.03 : 0)
        // Cold narrows the foot's blood vessels: less warmth reaches it.
        if air < 15 { ratio -= 0.1 * (15 - air) / 30 }
        var eq = air + (core - air) * ratio + 2.2 * c.activity.metabolic + (c.sun && !indoors ? 0.5 : 0)
        if soaking { eq = min(eq, 24) }
        return eq
    }

    /// The firmware's behaviour for the setting the app is following.
    private func insoleAction(warmest: Double) -> ThermalMode {
        guard battery > 0, conditions.connection != .none else { return .off }
        switch setting {
        case .off: return .off
        case .cool: return .cooling
        case .heat: return warmest >= ThermyxRiskEngine.burnLimitC ? .off : .heating
        case .auto:
            if warmest > conditions.targetC + 0.4 { return .cooling }
            if warmest < conditions.targetC - 0.4 { return .heating }
            return .off
        }
    }

    /// °C per minute the module moves the foot. Cooling weakens in hot air
    /// (the heat sink sheds less), and reverses with the fan blocked.
    private func actionRate(airC: Double) -> Double {
        switch action {
        case .cooling, .ventilation:
            if conditions.fault == .fanBlocked { return 0.04 }
            return -0.22 * min(1, max(0.25, (46 - airC) / 22))
        case .heating: return 0.3
        case .off: return 0
        }
    }

    // MARK: Decisions

    /// Runs the real engine on the simulated readings, and applies the app's
    /// responses to what it decides.
    private mutating func refresh() {
        let pair = reading
        // Gaps count only once they've held, as on the real insoles.
        if pair.hotterFoot != nil { gapSince = gapSince ?? minute } else { gapSince = nil }
        if pair.favouredFoot != nil { loadGapSince = loadGapSince ?? minute } else { loadGapSince = nil }
        let now = minute
        let sustained = { (since: Int?) in since.map { now - $0 >= 2 } ?? false }
        let fixed = ThermyxRiskEngine.assess(pair, sustainedTemperatureGap: sustained(gapSince), sustainedLoadGap: sustained(loadGapSince))
        let layered = PersonalLayer.apply(fixed, reading: pair, baseline: nil, trend: trend, unit: .celsius)
        assessment = layered.assessment

        // ThermyxViewModel's safety override: at High and above, Heat (or an
        // insole heating on its own in Auto) is pulled to Cool.
        if assessment.level.locksOutHeating, setting == .heat || action == .heating {
            setting = .cool
            log(.device, "Heat locked out · switched to Cool", "At \(assessment.level.rawValue), Thermyx won't heat a heat-strained foot.")
        }
        if conditions.setting == .heat, (footC.values.max() ?? 0) >= ThermyxRiskEngine.burnLimitC, !burnCutoffLogged {
            burnCutoffLogged = true
            log(.device, "Burn cutoff at 40°", "The firmware stops heating on its own, whatever the app asks.")
        }

        let level = assessment.level
        if level != lastLevel {
            if level != .unavailable || lastLevel != .unavailable {
                log(.level(level), level == .unavailable ? "No readings" : "Level: \(level.rawValue)",
                    assessment.reasons.first ?? (level == .unavailable ? "Nothing to assess without readings." : "Every signal is within range."))
            }
            switch level {
            case .caution where lastLevel.severity < ThermyxRiskLevel.caution.severity:
                log(.alert, "Phone notification", "At Caution you're told on your phone. (Simulated: nothing is sent.)")
            case .high where lastLevel.severity < ThermyxRiskLevel.high.severity:
                log(.alert, "Trusted circle alerted", "At High risk your circle hears from Thermyx. (Simulated: nothing is sent.)")
            case .critical:
                log(.alert, "Full-screen alert", "Critical opens the emergency screen with SOS. (Simulated.)")
            default: break
            }
            lastLevel = level
        }
    }

    /// The warmer foot's change over 5 and 10 simulated minutes.
    private var trend: TemperatureTrend {
        guard let now = reportedPeak else { return TemperatureTrend() }
        func delta(_ back: Int) -> Double? {
            samples.last(where: { $0.minute == minute - back })?.footC.map { now - $0 }
        }
        return TemperatureTrend(delta5: delta(5), delta10: delta(10))
    }

    private mutating func log(_ kind: Event.Kind, _ title: String, _ detail: String) {
        events.append(Event(id: nextEventID, minute: minute, kind: kind, title: title, detail: detail))
        nextEventID += 1
        if events.count > 60 { events.removeFirst(events.count - 60) }
    }
}
