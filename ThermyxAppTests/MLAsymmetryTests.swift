import XCTest
@testable import ThermyxApp

// MARK: - Synthetic wearers

/// Deterministic randomness: the same seed always gives the same trace.
struct MLRandom {
    private var state: UInt64
    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> Double {
        state = state &+ 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        z ^= z >> 31
        return Double(z >> 11) / Double(1 << 53)
    }

    /// Standard normal, Box–Muller.
    mutating func normal() -> Double {
        let u = max(next(), 1e-12), v = next()
        return (-2 * log(u)).squareRoot() * cos(2 * .pi * v)
    }
}

/// What one second of the wearer looks like. A scenario is a function from
/// time to this.
struct MLMoment {
    var activity: CalibrationActivity = .walking
    /// True left-minus-right load share: positive puts more weight on the left.
    var lean = 0.0
    /// Left minus right steadiness.
    var gaitGap = 0.0
    /// Multiplies the usual cadence.
    var pace = 1.0
    /// Extra °C on the left foot.
    var leftWarmer = 0.0
    var leftMode: ThermalMode = .ventilation
    var rightMode: ThermalMode = .ventilation
}

/// A wearer with a body of their own: sensor gains, usual cadence and the
/// small habits (a usual lean) that the personal baseline exists to learn.
struct MLWearer {
    /// The right arch sensor reads this much higher for the same weight, as
    /// real sensors do; the demo's `archLoad` uses the same idea.
    var rightGain = 1.06
    var usualLean = 0.0
    var cadence = 104.0
    var steadiness = 0.91
    var usualGaitGap = 0.0
    var leftTempC = 32.4
    var rightTempC = 32.8
    var seed: UInt64 = 7
    /// Each insole has one arch pressure sensor. False simulates an insole
    /// whose pressure channel is missing.
    var hasPressure = true
}

enum MLTrace {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // a multiple of 20 s

    /// Plays a scenario into `consume`, one pair reading per sample.
    ///
    /// - Parameters:
    ///   - hz: Packets per second per foot.
    ///   - jitter: Timestamp noise as a share of the sample interval.
    ///   - alternating: Send the feet in separate emissions, each carrying the
    ///     other foot's previous reading (as the view model does).
    static func play(
        _ wearer: MLWearer,
        from start: Double,
        seconds: Double,
        hz: Double = 1,
        jitter: Double = 0.1,
        alternating: Bool = false,
        stride: (Double) -> Double = { $0 },
        _ moment: (Double) -> MLMoment,
        consume: (BilateralReading, Date) -> Void
    ) {
        var rng = MLRandom(seed: wearer.seed &+ UInt64(start * 1000))
        let interval = 1 / hz
        var last = BilateralReading.empty
        var n = 0
        var t = start
        while t < start + seconds {
            let m = moment(t)
            let stamp = t0.addingTimeInterval(t + (rng.next() - 0.5) * jitter * interval)
            let left = reading(.left, wearer, m, t: stride(t), at: stamp, rng: &rng)
            let right = reading(.right, wearer, m, t: stride(t), at: stamp.addingTimeInterval(0.01), rng: &rng)
            if alternating {
                if n % 2 == 0 { last.left = left } else { last.right = right }
                if last.hasBoth { consume(last, stamp) }
            } else {
                consume(BilateralReading(left: left, right: right), stamp)
            }
            n += 1
            t += interval
        }
    }

    static func reading(_ foot: Foot, _ w: MLWearer, _ m: MLMoment, t: Double, at stamp: Date, rng: inout MLRandom) -> ThermyxReading {
        let sign = foot == .left ? 1.0 : -1.0
        let lean = w.usualLean + m.lean
        // Weight carried by this foot: its share of the load, times how hard
        // the person is pressing.
        let share = 1 + sign * lean
        let gain = foot == .right ? w.rightGain : 1
        let load: Double
        let cadence: Double
        let standing: Double
        switch m.activity {
        case .sitting:
            load = 0.06 * share * gain + 0.004 * rng.normal(); cadence = 0; standing = 0.04
        case .standing:
            load = 0.48 * share * gain * (1 + 0.04 * sin(t / 3 + (foot == .left ? 0 : 1))) + 0.006 * rng.normal()
            cadence = 0; standing = 0.92
        case .walking:
            // Each foot's load rises and falls once per stride and the two
            // are half a stride apart, so left minus right swings by tens of
            // points every step while the average stays put.
            let strideHz = w.cadence * m.pace / 120
            let swing = sin(2 * .pi * strideHz * t + (foot == .left ? 0 : .pi))
            load = 0.55 * share * gain * (1 + 0.30 * swing) + 0.01 * rng.normal()
            cadence = w.cadence * m.pace + 2 * rng.normal(); standing = 0.12
        }
        let gait = w.steadiness + sign * (w.usualGaitGap + m.gaitGap) / 2 + 0.006 * rng.normal()
        let temp = (foot == .left ? w.leftTempC + m.leftWarmer : w.rightTempC)
            + (m.activity == .walking ? 0.5 : m.activity == .sitting ? -0.3 : 0) + 0.04 * rng.normal()
        var r = ThermyxReading(
            foot: foot, timestamp: stamp, footTemperatureC: temp, ambientTemperatureC: 24,
            pressureBalance: w.hasPressure ? min(1, max(0, load)) : nil, gaitStability: min(1, max(0, gait)), batteryPercent: 80,
            thermalMode: foot == .left ? m.leftMode : m.rightMode,
            cadenceStepsPerMinute: max(0, cadence), standingFraction: standing
        )
        return r
    }
}

// MARK: - Tests

final class MLAsymmetryTests: XCTestCase {

    /// Plays a scenario through a monitor, sampling its status every ten
    /// seconds of data time.
    private struct Run {
        var monitor = AsymmetryMonitor()
        var timeline: [(t: Double, status: AsymmetryStatus)] = []

        mutating func play(
            _ wearer: MLWearer, from start: Double, seconds: Double,
            hz: Double = 1, jitter: Double = 0.1, alternating: Bool = false, learn: Bool = true,
            _ moment: (Double) -> MLMoment
        ) {
            var nextCheck = start
            MLTrace.play(wearer, from: start, seconds: seconds, hz: hz, jitter: jitter, alternating: alternating, moment) { pair, stamp in
                monitor.observe(pair, learn: learn, calm: true)
                let t = stamp.timeIntervalSince(MLTrace.t0)
                if t >= nextCheck {
                    nextCheck = t + 10
                    timeline.append((t, monitor.status(now: stamp)))
                }
            }
        }

        func firstActive(_ kind: AsymmetryStatus.Kind, after t: Double = 0) -> Double? {
            timeline.first { $0.t >= t && $0.status.finding(kind) != nil }?.t
        }

        func anyActive(before t: Double = .infinity, after start: Double = 0) -> Bool {
            timeline.contains { $0.t >= start && $0.t < t && !$0.status.isEmpty }
        }

        /// How many times the kind switched on or off.
        func transitions(_ kind: AsymmetryStatus.Kind) -> Int {
            var count = 0
            var previous = false
            for entry in timeline {
                let now = entry.status.finding(kind) != nil
                if now != previous { count += 1 }
                previous = now
            }
            return count
        }
    }

    private let minute = 60.0

    // MARK: Plain walking must never alert

    func testPlainWalkingNeverAlertsAtAnyCadenceOrSamplingRate() {
        for (cadence, hz) in [(96.0, 1.0), (104, 1), (112, 1), (120, 1), (104, 2), (104, 0.5), (84, 1), (130, 5)] {
            var run = Run()
            var wearer = MLWearer()
            wearer.cadence = cadence
            run.play(wearer, from: 0, seconds: 90 * minute, hz: hz) { _ in MLMoment() }
            XCTAssertFalse(run.anyActive(), "Walking at \(cadence) steps/min sampled at \(hz) Hz must never alert")
        }
    }

    func testAStrideLockedToThePacketRateIsNotReadAsALean() {
        // 120 steps/min is 1 Hz per foot: sampled once a second, every packet
        // lands on the same phase of the stride and the "average" is whatever
        // phase that was. Such bins must not count as load evidence.
        XCTAssertLessThan(AsymmetryBinBuilder.beatsPerBin(strideHz: 1.0, packetHz: 1), AsymmetryConfig.minimumBeatsPerBin)
        XCTAssertLessThan(AsymmetryBinBuilder.beatsPerBin(strideHz: 1.0, packetHz: 0.5), AsymmetryConfig.minimumBeatsPerBin)
        XCTAssertGreaterThanOrEqual(AsymmetryBinBuilder.beatsPerBin(strideHz: 0.87, packetHz: 1), AsymmetryConfig.minimumBeatsPerBin)
        XCTAssertGreaterThan(AsymmetryBinBuilder.beatsPerBin(strideHz: 0.87, packetHz: 20), 10)
        for jitter in [0.0, 0.1, 0.3] {
            var run = Run()
            var wearer = MLWearer()
            wearer.cadence = 119.8
            run.play(wearer, from: 0, seconds: 60 * minute, jitter: jitter) { _ in MLMoment() }
            XCTAssertFalse(run.anyActive(), "jitter \(jitter)")
        }
    }

    func testWalkingNeverAlertsWithoutLearningEither() {
        // Demo Mode: detection runs from the fixed defaults and learns nothing.
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 60 * minute, learn: false) { _ in MLMoment() }
        XCTAssertFalse(run.anyActive())
        XCTAssertEqual(run.monitor.baseline.binsLearned, 0, "Nothing learned from simulated wear")
    }

    func testEachFootArrivingInItsOwnEmissionIsNotDoubleCounted() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 40 * minute, alternating: true) { _ in MLMoment() }
        XCTAssertFalse(run.anyActive())
        // One bin is 20 s of both feet however the packets were grouped.
        XCTAssertLessThanOrEqual(run.monitor.baseline.walkingLean.count, 40 * 3)
    }

    func testDemoStyleDayWithSensorOffsetStaysQuiet() {
        // The simulator's 45-minute walk/stand/sit round, right sensor reading
        // higher, for three hours.
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 180 * minute) { t in
            MLMoment(activity: DemoWearer.activity(minute: Int(t / 60)))
        }
        XCTAssertFalse(run.anyActive())
    }

    func testIrregularWalkingWithPausesAndTurnsStaysQuiet() {
        var run = Run()
        var rng = MLRandom(seed: 99)
        var plan: [(until: Double, moment: MLMoment)] = []
        var t = 0.0
        while t < 120 * minute {
            let activity: CalibrationActivity = [.walking, .walking, .standing, .sitting][Int(rng.next() * 4) % 4]
            t += 20 + rng.next() * 200
            plan.append((t, MLMoment(activity: activity, pace: 0.7 + 0.5 * rng.next())))
        }
        run.play(MLWearer(), from: 0, seconds: 120 * minute) { now in
            plan.first { now < $0.until }?.moment ?? MLMoment()
        }
        XCTAssertFalse(run.anyActive(), "Stop-start walking, pace changes and sitting are not asymmetry")
    }

    // MARK: The Demo studio's scenarios

    /// The studio's "limp" and "lean" conditions, as `ThermyxInsoleSimulator`
    /// publishes them, run with no learning (Demo Mode learns nothing).
    private func demoPair(second t: Double, activity: CalibrationActivity, limp: Foot? = nil, lean: Foot? = nil,
                          gait: inout [Foot: Double]) -> BilateralReading {
        var pair = BilateralReading.empty
        for foot in Foot.allCases {
            var load = DemoWearer.archLoad(activity, seconds: t, foot: foot)
            var cadence = DemoWearer.cadence(activity, minute: t / 60)
            var target = 0.92
            if let limp {
                load *= limp == foot ? 0.62 : 1.22
                cadence *= 0.78
                target = limp == foot ? 0.62 : 0.84
            }
            if let lean { load = lean == foot ? 0.86 + 0.02 * sin(t / 5) : 0.17 + 0.02 * sin(t / 7) }
            if activity == .walking { gait[foot, default: 0.92] += (target - gait[foot, default: 0.92]) * 0.08 }
            var r = ThermyxReading(foot: foot, timestamp: MLTrace.t0.addingTimeInterval(t + (foot == .left ? 0 : 0.01)),
                                   footTemperatureC: 32.4, ambientTemperatureC: 24, pressureBalance: min(1, max(0, load)),
                                   gaitStability: gait[foot, default: 0.92], batteryPercent: 80, thermalMode: .ventilation,
                                   cadenceStepsPerMinute: cadence, standingFraction: DemoWearer.standingFraction(activity))
            pair[foot] = r
        }
        return pair
    }

    func testTheStudiosLimpIsCaughtAsALimpAndItsNormalWalkingIsQuiet() {
        var monitor = AsymmetryMonitor()
        var gait: [Foot: Double] = [:]
        var firstLimp: Double?
        let onset = 20 * minute
        for second in 0..<Int(30 * minute) {
            let t = Double(second)
            monitor.observe(demoPair(second: t, activity: .walking, limp: t >= onset ? .left : nil, gait: &gait), learn: false)
            let status = monitor.status(now: MLTrace.t0.addingTimeInterval(t))
            if t < onset { XCTAssertTrue(status.isEmpty, "Normal demo walking at \(t) s") }
            else if firstLimp == nil, status.finding(.limp) != nil { firstLimp = t - onset }
        }
        XCTAssertNotNil(firstLimp)
        XCTAssertLessThanOrEqual(firstLimp ?? .infinity, 4 * minute)
        let status = monitor.status(now: MLTrace.t0.addingTimeInterval(30 * minute))
        XCTAssertEqual(status.finding(.limp)?.foot, .right, "The sore left foot is spared; the right carries the weight")
        let a = ThermyxRiskEngine.assess(demoPair(second: 1800, activity: .walking, limp: .left, gait: &gait), asymmetry: status)
        XCTAssertEqual(a.causes, [.unsteady, .limp], "The sore foot's 62% steadiness trips the fixed rule too")
    }

    func testTheStudiosLeanIsCaught() {
        var monitor = AsymmetryMonitor()
        var gait: [Foot: Double] = [:]
        var first: Double?
        for second in 0..<Int(20 * minute) {
            let t = Double(second)
            monitor.observe(demoPair(second: t, activity: .standing, lean: t >= 5 * minute ? .right : nil, gait: &gait), learn: false)
            if first == nil, monitor.status(now: MLTrace.t0.addingTimeInterval(t)).finding(.lean) != nil { first = t - 5 * minute }
        }
        XCTAssertNotNil(first)
        XCTAssertLessThanOrEqual(first ?? .infinity, 4 * minute)
        XCTAssertEqual(monitor.status(now: MLTrace.t0.addingTimeInterval(20 * minute)).finding(.lean)?.foot, .right)
    }

    // MARK: Plain-English readouts

    private let jargon = ["z-score", "mad", "ewma", "posterior", "dt/dt", "integral", "derivative", "cusum", "median", "shrink", "bayes", "prior"]

    func testReadoutsSayWhichFootAndHowMuchAndWhetherItIsFlagged() throws {
        var run = Run()
        let onset = 20 * minute
        run.play(MLWearer(), from: 0, seconds: 40 * minute) { t in
            t < onset ? MLMoment() : MLMoment(lean: 0.14, gaitGap: 0.10, pace: 0.82)
        }
        // Before: balanced as usual, nothing flagged.
        let calm = try XCTUnwrap(run.timeline.last { $0.t < onset - 60 }?.status)
        let pressure0 = try XCTUnwrap(calm.pressure), gait0 = try XCTUnwrap(calm.gait)
        XCTAssertNil(pressure0.carryingMore)
        XCTAssertFalse(pressure0.isFlagged)
        XCTAssertEqual(pressure0.sentence, "Your weight is balanced the way it usually is.")
        XCTAssertNil(gait0.lessSteady)
        XCTAssertFalse(gait0.isFlagged)
        XCTAssertEqual(gait0.sentence, "Your steps are as even between your feet as usual.")
        // After: the left foot carries 14 points more than usual, the right is less steady.
        let status = try XCTUnwrap(run.timeline.last?.status)
        let pressure = try XCTUnwrap(status.pressure), gait = try XCTUnwrap(status.gait)
        XCTAssertEqual(pressure.carryingMore, .left)
        XCTAssertEqual(pressure.pointsBeyondUsual, 14, accuracy: 3)
        XCTAssertGreaterThan(pressure.currentPoints, pressure.usualPoints)
        XCTAssertTrue(pressure.isFlagged)
        XCTAssertEqual(gait.lessSteady, .right)
        XCTAssertEqual(gait.pointsBeyondUsual, 10, accuracy: 3)
        XCTAssertTrue(gait.isFlagged)
        for sentence in [pressure0.sentence, gait0.sentence, pressure.sentence, gait.sentence] {
            for word in jargon { XCTAssertFalse(sentence.lowercased().contains(word), sentence) }
        }
    }

    func testAMildDifferenceIsDescribedButNotFlagged() throws {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 30 * minute) { t in
            t < 20 * minute ? MLMoment(activity: .standing) : MLMoment(activity: .standing, lean: 0.06)
        }
        XCTAssertFalse(run.anyActive())
        let pressure = try XCTUnwrap(run.timeline.last?.status.pressure)
        XCTAssertFalse(pressure.isFlagged)
        XCTAssertEqual(pressure.carryingMore, .left)
        XCTAssertTrue(pressure.sentence.hasPrefix("A little more weight on your left foot than usual"))
        XCTAssertNil(run.timeline.last?.status.gait, "Standing only: no walking steadiness to compare")
    }

    func testReadoutsWaitForAMinuteOfData() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 40) { _ in MLMoment() }
        XCTAssertNil(run.monitor.status(now: MLTrace.t0.addingTimeInterval(40)).pressure)
        XCTAssertNil(AsymmetryStatus.none.gait)
    }

    // MARK: Many wearers

    /// Different bodies, cadences, sensor gains and sampling: no false alarms
    /// in an hour of plain walking, and every real limp and lean caught at the
    /// three-minute mark.
    func testAcrossManyWearersTheRatesHold() {
        var falseAlarms = 0
        var limpDelays: [Double] = [], leanDelays: [Double] = []
        for seed in 1...16 {
            var rng = MLRandom(seed: UInt64(seed) * 77)
            var w = MLWearer()
            w.seed = UInt64(seed)
            w.cadence = 80 + 50 * rng.next()
            w.rightGain = 0.92 + 0.16 * rng.next()
            w.steadiness = 0.85 + 0.1 * rng.next()
            w.usualLean = 0.12 * (rng.next() - 0.5)
            let jitter = [0.0, 0.1, 0.3][seed % 3]
            let hz = [1.0, 1.0, 2.0, 0.5][seed % 4]

            var plain = Run()
            plain.play(w, from: 0, seconds: 40 * minute, hz: hz, jitter: jitter) { _ in MLMoment() }
            if plain.anyActive() { falseAlarms += 1 }

            var limp = Run()
            limp.play(w, from: 0, seconds: 30 * minute, hz: hz, jitter: jitter) { t in
                t < 20 * minute ? MLMoment() : MLMoment(lean: 0.14, gaitGap: 0.10, pace: 0.82)
            }
            if let at = limp.firstActive(.limp, after: 20 * minute) { limpDelays.append(at - 20 * minute) }

            var lean = Run()
            lean.play(w, from: 0, seconds: 30 * minute, hz: hz, jitter: jitter) { t in
                MLMoment(activity: .standing, lean: t < 20 * minute ? 0 : -0.15)
            }
            if let at = lean.firstActive(.lean, after: 20 * minute) { leanDelays.append(at - 20 * minute) }
        }
        print("ML-REPORT 16 wearers: false alarms \(falseAlarms)/16 hours walking; limp caught \(limpDelays.count)/16 after \(limpDelays.min() ?? -1)-\(limpDelays.max() ?? -1) s; lean caught \(leanDelays.count)/16 after \(leanDelays.min() ?? -1)-\(leanDelays.max() ?? -1) s")
        XCTAssertEqual(falseAlarms, 0)
        XCTAssertEqual(limpDelays.count, 16)
        XCTAssertEqual(leanDelays.count, 16)
        XCTAssertLessThanOrEqual(limpDelays.max() ?? .infinity, 4 * minute)
        XCTAssertLessThanOrEqual(leanDelays.max() ?? .infinity, 4 * minute)
    }

    // MARK: Heavy lean

    func testHeavyLeanWhileStandingAlertsWithinFourMinutesAndClears() {
        var run = Run()
        let wearer = MLWearer()
        let onset = 20 * minute, leanEnds = 35 * minute
        run.play(wearer, from: 0, seconds: 45 * minute) { t in
            MLMoment(activity: .standing, lean: t >= onset && t < leanEnds ? 0.20 : 0)
        }
        XCTAssertFalse(run.anyActive(before: onset))
        let alerted = try? XCTUnwrap(run.firstActive(.lean, after: onset))
        XCTAssertNotNil(alerted)
        XCTAssertLessThanOrEqual((alerted ?? .infinity) - onset, 4 * minute, "Alerts within four minutes")
        XCTAssertGreaterThanOrEqual((alerted ?? 0) - onset, 170, "But not before three minutes of evidence")
        let finding = run.timeline.first { $0.status.finding(.lean) != nil }?.status.finding(.lean)
        XCTAssertEqual(finding?.foot, .left)
        XCTAssertEqual(finding?.whileWalking, false)
        XCTAssertGreaterThan(finding?.contributions.first?.observed ?? 0, 0.1)
        // Gone within four minutes of standing evenly again, and stays gone.
        let cleared = run.timeline.first { $0.t > leanEnds && $0.status.isEmpty }?.t
        XCTAssertLessThanOrEqual((cleared ?? .infinity) - leanEnds, 4 * minute)
        XCTAssertEqual(run.transitions(.lean), 2, "On once, off once")
    }

    func testHeavyLeanWhileWalkingAlertsToo() {
        var run = Run()
        let onset = 20 * minute
        run.play(MLWearer(), from: 0, seconds: 40 * minute) { t in
            MLMoment(activity: .walking, lean: t >= onset ? -0.18 : 0)
        }
        XCTAssertFalse(run.anyActive(before: onset))
        XCTAssertNotNil(run.firstActive(.lean, after: onset))
        XCTAssertLessThanOrEqual((run.firstActive(.lean, after: onset) ?? .infinity) - onset, 4 * minute)
        XCTAssertEqual(run.timeline.last?.status.finding(.lean)?.foot, .right)
    }

    func testLeanBelowTheBarNeverAlerts() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 120 * minute) { t in
            MLMoment(activity: t.truncatingRemainder(dividingBy: 600) < 300 ? .standing : .walking, lean: 0.07)
        }
        XCTAssertFalse(run.anyActive(after: 0), "7 points is well inside ordinary standing sway")
    }

    func testBriefStumblesAndAShortLimpDoNotAlert() {
        var run = Run()
        let wearer = MLWearer()
        // Warm up with 20 minutes of ordinary walking, then three 25 s
        // stumbles inside five minutes, then a 90 s limp, then ordinary
        // walking.
        let stumbles: [ClosedRange<Double>] = [1230...1255, 1320...1345, 1410...1435]
        let limp: ClosedRange<Double> = 1800...1890
        run.play(wearer, from: 0, seconds: 40 * minute) { t in
            if stumbles.contains(where: { $0.contains(t) }) { return MLMoment(lean: 0.3, gaitGap: 0.2, pace: 0.5) }
            if limp.contains(t) { return MLMoment(lean: 0.16, gaitGap: 0.12, pace: 0.8) }
            return MLMoment()
        }
        XCTAssertFalse(run.anyActive(), "Brief events never reach three minutes of evidence")
    }

    // MARK: Limping

    func testSustainedLimpAlertsWithinFourMinutesAsALimpNotJustALean() {
        var run = Run()
        let onset = 25 * minute
        run.play(MLWearer(), from: 0, seconds: 45 * minute) { t in
            t < onset ? MLMoment() : MLMoment(lean: 0.14, gaitGap: 0.10, pace: 0.82)
        }
        XCTAssertFalse(run.anyActive(before: onset))
        let limpAt = run.firstActive(.limp, after: onset)
        XCTAssertNotNil(limpAt)
        XCTAssertLessThanOrEqual((limpAt ?? .infinity) - onset, 4 * minute)
        let finding = run.timeline.compactMap { $0.status.finding(.limp) }.last
        XCTAssertEqual(finding?.foot, .left)
        XCTAssertEqual(finding.map { Set($0.contributions.map(\.feature)) }, [.loadShare, .steadinessGap, .pace])
        XCTAssertGreaterThan(finding?.heldSeconds ?? 0, 3 * minute)
    }

    func testLimpNeedsCorroborationWhereLoadAloneIsALean() {
        // Uneven load while walking but steadiness and pace are the wearer's
        // own: heavy leaning, not a limp.
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 45 * minute) { t in
            t < 25 * minute ? MLMoment() : MLMoment(lean: 0.16)
        }
        XCTAssertNil(run.firstActive(.limp))
        XCTAssertNotNil(run.firstActive(.lean))
    }

    func testSlowWalkingAloneIsNotALimp() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 50 * minute) { t in
            t < 25 * minute ? MLMoment() : MLMoment(pace: 0.7)
        }
        XCTAssertFalse(run.anyActive(), "A slower pace alone is just a slower pace")
    }

    func testWithoutAPressureChannelThereIsNoLeanButALimpStillShowsFromSteadinessAndPace() {
        var run = Run()
        var wearer = MLWearer()
        wearer.hasPressure = false
        run.play(wearer, from: 0, seconds: 45 * minute) { t in
            t < 25 * minute ? MLMoment() : MLMoment(lean: 0.3, gaitGap: 0.12, pace: 0.8)
        }
        let limp = run.timeline.compactMap { $0.status.finding(.limp) }.last
        XCTAssertNotNil(limp)
        XCTAssertEqual(limp.map { Set($0.contributions.map(\.feature)) }, [.steadinessGap, .pace])
        XCTAssertNil(run.firstActive(.lean))
        XCTAssertNil(run.timeline.last?.status.pressure, "No pressure readings, no pressure readout")
        XCTAssertNotNil(run.timeline.last?.status.gait)
        XCTAssertEqual(run.monitor.baseline.standingLean.count + run.monitor.baseline.walkingLean.count, 0)
    }

    // MARK: Personal baseline

    func testAWearerWhoAlwaysLeansALittleIsComparedWithThemselves() {
        var wearer = MLWearer()
        wearer.usualLean = 0.075
        var run = Run()
        // Half an hour of their ordinary self, then a lean that is 15 points
        // from even but only 7.5 from their usual, then a real departure.
        run.play(wearer, from: 0, seconds: 30 * minute) { _ in MLMoment(activity: .standing) }
        let learned = run.monitor.estimates().standingLean
        XCTAssertEqual(learned.mean, 0.075 - 0.03, accuracy: 0.02, "Their usual (the right sensor reads high, which offsets it)")
        XCTAssertLessThan(learned.priorWeight, 0.2)
        run.play(wearer, from: 30 * minute, seconds: 30 * minute) { _ in MLMoment(activity: .standing, lean: 0.075) }
        XCTAssertFalse(run.anyActive(), "Their usual lean, and even a bit more, is not heavy")
        run.play(wearer, from: 60 * minute, seconds: 30 * minute) { _ in MLMoment(activity: .standing, lean: 0.20) }
        XCTAssertNotNil(run.firstActive(.lean, after: 60 * minute), "A real departure from their usual still alerts")
        // The same lean from an average wearer would have crossed the default bar.
        var average = Run()
        average.play(MLWearer(), from: 0, seconds: 60 * minute) { _ in MLMoment(activity: .standing, lean: 0.15) }
        XCTAssertNotNil(average.firstActive(.lean))
    }

    func testTheBaselineCannotLearnAHeavyLeanAsNormal() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 20 * minute) { _ in MLMoment(activity: .standing) }
        let before = run.monitor.estimates().standingLean.mean
        run.play(MLWearer(), from: 20 * minute, seconds: 4 * 60 * minute) { _ in MLMoment(activity: .standing, lean: 0.22) }
        XCTAssertEqual(run.monitor.estimates().standingLean.mean, before, accuracy: 0.03,
                       "Hours of heavy leaning are not learned as 'usual'")
        XCTAssertNotNil(run.timeline.last?.status.finding(.lean), "Still alerting hours later")
    }

    func testElevatedMinutesNeverTeachTheBaseline() {
        var monitor = AsymmetryMonitor()
        MLTrace.play(MLWearer(), from: 0, seconds: 20 * minute, { _ in MLMoment(activity: .standing) }) { pair, _ in
            monitor.observe(pair, learn: true, calm: false)
        }
        XCTAssertEqual(monitor.baseline.binsLearned, 0)
    }

    func testLearnedBaselineIsClampedInsideTheAlertBars() {
        var run = Run()
        var wearer = MLWearer()
        wearer.usualLean = 0.09
        run.play(wearer, from: 0, seconds: 120 * minute) { _ in MLMoment(activity: .standing) }
        let mean = run.monitor.estimates().standingLean.mean
        XCTAssertTrue(AsymmetryConfig.leanClamp.contains(mean))
    }

    // MARK: Hysteresis

    func testALeanHoveringAtTheBarDoesNotFlap() {
        var run = Run()
        var rng = MLRandom(seed: 5)
        run.play(MLWearer(), from: 0, seconds: 20 * minute) { _ in MLMoment(activity: .standing) }
        // True lean wanders around the entry bar: 0.095 ± 0.03.
        run.play(MLWearer(), from: 20 * minute, seconds: 90 * minute) { _ in
            MLMoment(activity: .standing, lean: 0.095 + 0.03 * rng.normal())
        }
        XCTAssertLessThanOrEqual(run.transitions(.lean), 4, "At most a couple of on/off cycles in 90 minutes")
    }

    func testOnceOnItHoldsAtLeastTwoMinutes() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 20 * minute) { _ in MLMoment(activity: .standing) }
        run.play(MLWearer(), from: 20 * minute, seconds: 8 * minute) { _ in MLMoment(activity: .standing, lean: 0.25) }
        run.play(MLWearer(), from: 28 * minute, seconds: 15 * minute) { _ in MLMoment(activity: .standing) }
        let on = run.timeline.first { $0.status.finding(.lean) != nil }!.t
        let off = run.timeline.first { $0.t > on && $0.status.finding(.lean) == nil }!.t
        XCTAssertGreaterThanOrEqual(off - on, AsymmetryConfig.minimumHoldSeconds)
    }

    // MARK: Temperature gap

    func testAWarmerFootMustHoldForMinutesAndMatchTheWearersUsualGap() {
        var run = Run()
        let onset = 25 * minute
        run.play(MLWearer(), from: 0, seconds: 50 * minute) { t in
            MLMoment(activity: .standing, leftWarmer: t >= onset ? 1.9 : 0)
        }
        XCTAssertFalse(run.anyActive(before: onset), "A usual 0.4 °C gap is not a finding")
        let at = run.firstActive(.warmerFoot, after: onset)
        XCTAssertNotNil(at)
        XCTAssertLessThanOrEqual((at ?? .infinity) - onset, 4 * minute)
        XCTAssertEqual(run.timeline.last?.status.finding(.warmerFoot)?.foot, .left)
    }

    func testAGapCausedByOneInsoleHeatingIsNotEvidence() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 30 * minute) { _ in
            MLMoment(activity: .standing, leftWarmer: 3, leftMode: .heating)
        }
        XCTAssertFalse(run.anyActive(), "The insole is doing that")
    }

    func testBriefTemperatureBlipsDoNotAlert() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 40 * minute) { t in
            MLMoment(activity: .standing, leftWarmer: (1500...1600).contains(t) ? 3 : 0)
        }
        XCTAssertFalse(run.anyActive())
    }

    // MARK: Robustness

    func testNoFindingsFromOneInsole() {
        var monitor = AsymmetryMonitor()
        MLTrace.play(MLWearer(), from: 0, seconds: 30 * minute, { _ in MLMoment(activity: .standing, lean: 0.3) }) { pair, _ in
            monitor.observe(BilateralReading(left: pair.left, right: nil))
        }
        XCTAssertTrue(monitor.status(now: MLTrace.t0.addingTimeInterval(30 * minute)).isEmpty)
    }

    func testStaleEvidenceReportsNothing() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 30 * minute) { t in MLMoment(activity: .standing, lean: t > 10 * minute ? 0.3 : 0) }
        let last = MLTrace.t0.addingTimeInterval(30 * minute)
        XCTAssertNotNil(run.monitor.status(now: last).finding(.lean))
        XCTAssertTrue(run.monitor.status(now: last.addingTimeInterval(200)).isEmpty, "No data for over 90 s")
    }

    func testReplayedAndOutOfOrderPacketsAreIgnored() {
        var monitor = AsymmetryMonitor()
        var all: [BilateralReading] = []
        MLTrace.play(MLWearer(), from: 0, seconds: 10 * minute, { _ in MLMoment(activity: .standing) }) { pair, _ in all.append(pair) }
        for pair in all { monitor.observe(pair); monitor.observe(pair) }   // everything twice
        for pair in all.prefix(30) { monitor.observe(pair) }              // and an old stretch again
        var once = AsymmetryMonitor()
        for pair in all { once.observe(pair) }
        XCTAssertEqual(monitor.baseline, once.baseline)
    }

    func testResetEvidenceKeepsWhatWasLearned() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 30 * minute) { _ in MLMoment(activity: .standing) }
        let learned = run.monitor.baseline
        run.monitor.resetEvidence()
        XCTAssertEqual(run.monitor.baseline, learned)
        XCTAssertTrue(run.monitor.status(now: MLTrace.t0.addingTimeInterval(30 * minute)).isEmpty)
    }

    func testBaselineSurvivesSavingAndLoading() throws {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 30 * minute) { _ in MLMoment() }
        let data = try JSONEncoder().encode(run.monitor.baseline)
        let restored = AsymmetryMonitor(baseline: try JSONDecoder().decode(AsymmetryBaseline.self, from: data))
        XCTAssertEqual(restored.estimates(), run.monitor.estimates())
    }

    // MARK: Priors

    private func priors(standingLean: PopulationPriors.Stats? = nil, walkingLean: PopulationPriors.Stats? = nil,
                        gap: PopulationPriors.Stats? = nil) -> PopulationPriors {
        var p = PopulationPriors(computedAt: MLTrace.t0)
        p.standingLean = standingLean
        p.walkingLean = walkingLean
        p.steadinessGap = gap
        return p
    }

    func testUnusablePriorsMeanFixedDefaults() {
        let thin = priors(standingLean: .init(mean: 0.08, sd: 0.01, count: PopulationPriors.minimumContributors - 1),
                          walkingLean: .init(mean: 0.08, sd: .nan, count: 500))
        var a = AsymmetryMonitor(), b = AsymmetryMonitor(priors: thin)
        MLTrace.play(MLWearer(), from: 0, seconds: 10 * minute, { _ in MLMoment(activity: .standing) }) { pair, _ in
            a.observe(pair); b.observe(pair)
        }
        XCTAssertEqual(a.estimates(), b.estimates(), "Too few contributors or a broken spread: ignored")
        XCTAssertEqual(AsymmetryMonitor(priors: nil).estimates(), AsymmetryMonitor().estimates())
    }

    func testThePriorStartsAHandfulOfBinsInAndFadesAsDataAccumulates() {
        let p = priors(standingLean: .init(mean: 0.05, sd: 0.02, count: 400))
        var monitor = AsymmetryMonitor(priors: p)
        // No data: the prior is the answer.
        XCTAssertEqual(monitor.estimates().standingLean.mean, 0.05, accuracy: 1e-9)
        XCTAssertEqual(monitor.estimates().standingLean.priorWeight, 1, accuracy: 1e-9)

        var weights: [Double] = []
        var wearer = MLWearer()
        wearer.rightGain = 1   // true lean 0
        var t = 0.0
        for chunk in [5.0, 10, 20, 60, 180] {
            MLTrace.play(wearer, from: t, seconds: chunk * minute, { _ in MLMoment(activity: .standing) }) { pair, _ in
                monitor.observe(pair, learn: true, calm: true)
            }
            t += chunk * minute
            weights.append(monitor.estimates().standingLean.priorWeight)
        }
        XCTAssertEqual(weights, weights.sorted(by: >), "The prior's weight only falls as data accumulates")
        XCTAssertLessThan(weights.last!, 0.05)
        XCTAssertGreaterThan(weights.first!, weights.last! * 3)
        // And the estimate has moved from the prior to the wearer's own (about 0).
        XCTAssertEqual(monitor.estimates().standingLean.mean, 0, accuracy: 0.015)
    }

    func testAnOddPriorCannotMoveTheBaselineFarFromTheWearersOwnMeasurement() {
        let wild = priors(standingLean: .init(mean: 0.12, sd: 0.001, count: 10_000))
        var monitor = AsymmetryMonitor(priors: wild)
        var wearer = MLWearer()
        wearer.rightGain = 1
        MLTrace.play(wearer, from: 0, seconds: 8 * minute, { _ in MLMoment(activity: .standing) }) { pair, _ in
            monitor.observe(pair, learn: true, calm: true)
        }
        let est = monitor.estimates().standingLean
        XCTAssertLessThanOrEqual(abs(est.mean - 0), AsymmetryConfig.maxPullLean + 0.005)
        XCTAssertTrue(AsymmetryConfig.leanClamp.contains(est.mean))
    }

    func testThresholdsWidenForANoisyWearerButStayBounded() {
        var steady = Run(), noisy = Run()
        var rng = MLRandom(seed: 11)
        steady.play(MLWearer(), from: 0, seconds: 40 * minute) { _ in MLMoment(activity: .standing) }
        noisy.play(MLWearer(), from: 0, seconds: 40 * minute) { _ in MLMoment(activity: .standing, lean: 0.04 * rng.normal()) }
        let a = steady.monitor.estimates().thresholds.lean, b = noisy.monitor.estimates().thresholds.lean
        XCTAssertEqual(a, AsymmetryConfig.leanEnter, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(b, a)
        XCTAssertLessThanOrEqual(b, AsymmetryConfig.leanEnterMax)
    }

    // MARK: Risk engine integration

    private func pair(lean: Double = 0) -> BilateralReading {
        var rng = MLRandom(seed: 1)
        return BilateralReading(
            left: MLTrace.reading(.left, MLWearer(), MLMoment(activity: .standing, lean: lean), t: 0, at: MLTrace.t0, rng: &rng),
            right: MLTrace.reading(.right, MLWearer(), MLMoment(activity: .standing, lean: lean), t: 0, at: MLTrace.t0, rng: &rng)
        )
    }

    private func finding(_ kind: AsymmetryStatus.Kind, foot: Foot = .left, held: TimeInterval = 240, walking: Bool = false) -> AsymmetryStatus.Finding {
        .init(kind: kind, foot: foot, heldSeconds: held, whileWalking: walking, contributions: [.init(feature: .loadShare, observed: 0.14, threshold: 0.1, usual: nil)])
    }

    func testAsymmetryRaisesCautionOnlyAndNeverLowersALevel() {
        let calm = pair()
        for kind in [AsymmetryStatus.Kind.lean, .limp, .warmerFoot] {
            let status = AsymmetryStatus(findings: [finding(kind)], metrics: nil)
            let a = ThermyxRiskEngine.assess(calm, asymmetry: status)
            XCTAssertEqual(a.level, .caution, "\(kind)")
            XCTAssertEqual(a.causes, [kind.cause])
            XCTAssertEqual(a.asymmetryFoot, .left)
            XCTAssertEqual(a.foot, .left, "Nothing else is wrong, so the favoured foot is the one named")
        }
        // On top of a High already set by the fixed rules: stays High, same foot.
        var hotRight = pair()
        hotRight.right = ThermyxReading(foot: .right, timestamp: MLTrace.t0, footTemperatureC: 40.4, ambientTemperatureC: 24,
                                        pressureBalance: 0.5, gaitStability: 0.9, batteryPercent: 80, thermalMode: .ventilation)
        let high = ThermyxRiskEngine.assess(hotRight, asymmetry: AsymmetryStatus(findings: [finding(.limp)], metrics: nil))
        XCTAssertEqual(high.level, .high)
        XCTAssertEqual(high.foot, .right)
        XCTAssertEqual(high.asymmetryFoot, .left)
        XCTAssertEqual(ThermyxRiskEngine.assess(calm, asymmetry: .none).level, .normal)
    }

    func testEverythingAtOnceStillStopsAtCaution() {
        let status = AsymmetryStatus(findings: [finding(.lean), finding(.limp), finding(.warmerFoot, foot: .right)], metrics: nil)
        let a = ThermyxRiskEngine.assess(pair(), asymmetry: status)
        XCTAssertEqual(a.level, .caution)
        XCTAssertEqual(a.causes, [.limp, .warmerFoot], "A limp replaces the lean it explains")
    }

    func testReasonsArePlainAndNotDiagnostic() {
        let sentences = [
            AsymmetryWording.reason(finding(.lean, held: 250)),
            AsymmetryWording.reason(finding(.lean, held: 250, walking: true)),
            AsymmetryWording.reason(finding(.limp, held: 250)),
            AsymmetryWording.reason(finding(.warmerFoot, held: 250))
        ]
        XCTAssertEqual(sentences[0], "You've been leaning on your left foot for about 4 minutes.")
        XCTAssertEqual(sentences[1], "You've been favouring your left foot while walking for about 4 minutes.")
        for s in sentences {
            for banned in ["injur", "diagnos", "disease", "fracture", "pathology", "neuropath", "diabet"] {
                XCTAssertFalse(s.lowercased().contains(banned), s)
            }
        }
    }

    func testTheOldPerPacketRuleIsGoneByDefault() {
        // A walking pair frozen at a step's peak is what used to trip the alert.
        var rng = MLRandom(seed: 2)
        var wearer = MLWearer()
        wearer.rightGain = 1
        let peak = BilateralReading(
            left: MLTrace.reading(.left, wearer, MLMoment(), t: 0.29, at: MLTrace.t0, rng: &rng),
            right: MLTrace.reading(.right, wearer, MLMoment(), t: 0.29, at: MLTrace.t0, rng: &rng)
        )
        XCTAssertGreaterThan(abs(peak.loadAsymmetry ?? 0), 0.1, "The instantaneous gap really is that big")
        XCTAssertNil(peak.favouredFoot, "...and is not a favoured foot while walking")
        XCTAssertEqual(ThermyxRiskEngine.assess(peak).level, .normal)
        XCTAssertEqual(ThermyxRiskEngine.assess(peak, sustainedTemperatureGap: false, sustainedLoadGap: true).level, .normal)
    }

    func testExplanationDescribesTheMonitorsWindowedView() {
        var run = Run()
        run.play(MLWearer(), from: 0, seconds: 30 * minute) { t in MLMoment(activity: .standing, lean: t > 12 * minute ? 0.2 : 0) }
        let now = MLTrace.t0.addingTimeInterval(30 * minute)
        let status = run.monitor.status(now: now)
        let p = pair(lean: 0.2)
        let assessment = ThermyxRiskEngine.assess(p, asymmetry: status)
        let e = RiskExplanation.build(assessment: assessment, reading: p, sustainedTemperatureGap: false, sustainedLoadGap: false,
                                      rssi: [:], bothExpected: true, unit: .celsius, asymmetry: status, now: now)
        let load = e.signals.first { $0.kind == .loadGap }
        XCTAssertEqual(load?.contributes, true)
        XCTAssertTrue(load?.value?.hasPrefix("Left +") ?? false, load?.value ?? "nil")
        XCTAssertTrue(e.signals.contains { $0.kind == .limp && !$0.contributes })
        XCTAssertTrue(e.signals.contains { $0.kind == .temperatureGap && !$0.contributes })
        XCTAssertTrue(ThermyxSuggestion.nextStep(for: assessment, reading: p)?.contains("favouring your left foot") ?? false)
    }
}
