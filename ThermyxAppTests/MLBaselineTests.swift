import XCTest
@testable import ThermyxApp

@MainActor
final class MLBaselineTests: XCTestCase {

    private func reading(footC: Double = 33, gait: Double = 0.92, mode: ThermalMode = .ventilation, at time: Date = MLTrace.t0) -> BilateralReading {
        BilateralReading(
            left: ThermyxReading(foot: .left, timestamp: time, footTemperatureC: footC, ambientTemperatureC: 24, pressureBalance: 0.5,
                                 gaitStability: gait, batteryPercent: 80, thermalMode: mode),
            right: nil
        )
    }

    private func calibrated(footC: Double = 33, gait: Double = 0.92, minutes: Int = PersonalBaseline.calibrationMinutes, noise: Double = 0.15) -> PersonalBaseline {
        var b = PersonalBaseline()
        var rng = MLRandom(seed: 17)
        for _ in 0..<minutes { b.learn(footC: footC + noise * rng.normal(), gait: gait + 0.01 * rng.normal()) }
        return b
    }

    private func priors(foot: PopulationPriors.Stats? = nil, steadiness: PopulationPriors.Stats? = nil,
                        activities: [CalibrationActivity: PopulationPriors.Stats] = [:]) -> PopulationPriors {
        var p = PopulationPriors(computedAt: MLTrace.t0)
        p.footByActivity = activities
        if let foot { p.footByActivity[.sitting] = foot }
        p.steadiness = steadiness
        return p
    }

    // MARK: Robust learning

    func testAWildCalmMinuteIsNotLearnedOnceTheUsualIsKnown() {
        var b = calibrated(minutes: 40)
        let mean = b.footMeanC, learned = b.minutesLearned
        b.learn(footC: 35.9, gait: nil)   // sensor glitch in an otherwise calm minute
        XCTAssertEqual(b.minutesLearned, learned)
        XCTAssertEqual(b.footMeanC, mean)
        XCTAssertEqual(b.rejectedMinutes, 1)
        b.learn(footC: 33.1, gait: 0.92)
        XCTAssertEqual(b.minutesLearned, learned + 1)
        XCTAssertEqual(b.rejectedStreak, 0)
    }

    func testOneBadChannelDoesNotCostTheOtherOne() {
        var b = calibrated(minutes: 40)
        let learned = b.minutesLearned
        b.learn(footC: 33, gait: 0.80)   // steadiness far from usual, temperature ordinary
        XCTAssertEqual(b.minutesLearned, learned + 1)
        XCTAssertEqual(b.gaitSamples?.count, 40, "The odd steadiness was not learned")
    }

    func testTwentyOddMinutesInARowBecomeTheNewUsual() {
        var b = calibrated(minutes: 40)
        for _ in 0..<(PersonalBaseline.regimeChangeMinutes - 1) { b.learn(footC: 35.4, gait: nil) }
        XCTAssertEqual(b.minutesLearned, 40, "Still treated as odd")
        b.learn(footC: 35.4, gait: nil)
        XCTAssertEqual(b.minutesLearned, 41, "Twenty in a row is a new usual, not a glitch")
        XCTAssertEqual(b.footSamples?.median ?? 0, 35.4, accuracy: 0.01)
        XCTAssertLessThanOrEqual(b.footMeanC ?? 99, PersonalBaseline.footClampC.upperBound)
    }

    func testBaselinesSavedBeforeTheNewFieldsStillLoad() throws {
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(calibrated())) as? [String: Any])
        for key in ["footSamples", "gaitSamples", "rejectedStreak", "rejectedMinutes", "drift"] { json[key] = nil }
        let old = try JSONDecoder().decode(PersonalBaseline.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertTrue(old.isCalibrated)
        XCTAssertNotNil(old.footMeanC)
        var b = old
        b.learn(footC: 33, gait: 0.92)
        XCTAssertEqual(b.minutesLearned, old.minutesLearned + 1)
    }

    func testMedianBasedSpreadIgnoresAFewUnusualMinutes() {
        var b = calibrated(minutes: 60, noise: 0.2)
        // A couple of mild bumps that are inside the outlier fence.
        b.learn(footC: 34.0, gait: nil); b.learn(footC: 34.1, gait: nil)
        XCTAssertLessThan(b.footSpread, 0.35)
        XCTAssertEqual(b.footMargin, 2.0, "The floor still rules ordinary wearers")
    }

    // MARK: Blending with the population

    func testWithoutAUsablePriorTheWearersOwnNumbersAreUsedAsTheyAre() {
        let b = calibrated()
        XCTAssertEqual(b.posterior(priors: nil), PersonalBaseline.Posterior(footMean: b.footMeanC, footPriorWeight: 0, gaitMean: b.gaitMean, gaitPriorWeight: 0))
        let thin = priors(foot: .init(mean: 29, sd: 0.2, count: PopulationPriors.minimumContributors - 1),
                          steadiness: .init(mean: 0.7, sd: .nan, count: 1_000))
        XCTAssertEqual(b.posterior(priors: thin), b.posterior(priors: nil))
        XCTAssertNil(PersonalBaseline.footPrior(thin))
    }

    func testThePriorMattersEarlyAndFadesAsMinutesAccumulate() {
        let p = priors(foot: .init(mean: 32, sd: 0.8, count: 300), steadiness: .init(mean: 0.88, sd: 0.04, count: 300))
        var weights: [Double] = []
        for minutes in [10, 30, 90, 240] {
            let post = calibrated(footC: 33.5, gait: 0.95, minutes: minutes, noise: 0.5).posterior(priors: p)
            weights.append(post.footPriorWeight)
            XCTAssertGreaterThan(post.footMean ?? 0, 32, "Between the prior and the wearer")
            XCTAssertLessThan(post.footMean ?? 99, 33.6)
        }
        print("ML-REPORT prior weight on foot baseline after 10/30/90/240 calm minutes: \(weights.map { String(format: "%.3f", $0) })")
        XCTAssertEqual(weights, weights.sorted(by: >))
        XCTAssertGreaterThan(weights[0], 0.1)
        XCTAssertLessThan(weights[3], 0.03)
    }

    func testNoPriorCanMoveTheUsualMoreThanADegreeFromTheWearersOwn() {
        let wild = priors(foot: .init(mean: 20, sd: 0.01, count: 100_000), steadiness: .init(mean: 0.1, sd: 0.001, count: 100_000))
        let b = calibrated(footC: 33, gait: 0.92, minutes: PersonalBaseline.calibrationMinutes)
        let post = b.posterior(priors: wild)
        XCTAssertEqual(post.footMean ?? 0, (b.footMeanC ?? 0) - PersonalBaseline.maxPriorPullC, accuracy: 1e-9)
        XCTAssertEqual(post.gaitMean ?? 0, max((b.gaitMean ?? 0) - PersonalBaseline.maxPriorPullGait, PersonalBaseline.gaitClamp.lowerBound), accuracy: 1e-9)
        let clamped = priors(foot: .init(mean: 45, sd: 0.01, count: 100_000))
        XCTAssertLessThanOrEqual(calibrated(footC: 35.9).posterior(priors: clamped).footMean ?? 99, PersonalBaseline.footClampC.upperBound)
    }

    func testThePopulationPriorIsTheContributorWeightedMixtureOfActivities() throws {
        let p = priors(activities: [.sitting: .init(mean: 30, sd: 1, count: 100), .walking: .init(mean: 33, sd: 1, count: 300),
                                    .standing: .init(mean: 20, sd: 1, count: 5)])
        let mix = try XCTUnwrap(PersonalBaseline.footPrior(p))
        XCTAssertEqual(mix.mean, 32.25, accuracy: 1e-9, "The thin standing stat is left out")
        XCTAssertEqual(mix.count, 400)
        XCTAssertGreaterThan(mix.sd, 1, "Includes the spread between activities")
        XCTAssertEqual(mix.sd, (0.25 * (1 + 5.0625) + 0.75 * (1 + 0.5625)).squareRoot(), accuracy: 1e-9)
    }

    func testBlendingChangesTheWarningCentreButNeverTheFixedLevel() {
        let b = calibrated(footC: 33, minutes: PersonalBaseline.calibrationMinutes)
        let warmPopulation = priors(foot: .init(mean: 34, sd: 0.2, count: 500))
        let p = BilateralReading(left: ThermyxReading(foot: .left, timestamp: MLTrace.t0, footTemperatureC: 35.2, ambientTemperatureC: 24,
                                                      pressureBalance: 0.5, gaitStability: 0.92, batteryPercent: 80, thermalMode: .ventilation), right: nil)
        let fixed = ThermyxRiskEngine.assess(p)
        let own = PersonalLayer.apply(fixed, reading: p, baseline: b, trend: .init(), unit: .celsius)
        let blended = PersonalLayer.apply(fixed, reading: p, baseline: b, trend: .init(), unit: .celsius, priors: warmPopulation)
        XCTAssertEqual(own.assessment.level, .caution, "2.2 °C over their own usual")
        XCTAssertEqual(blended.assessment.level, .normal, "A warm population raises the centre by a bounded amount")
        XCTAssertTrue(blended.signals.first?.rule.contains("typical wearers") ?? false, "And says so")
        // The fixed rules are untouched.
        let hot = BilateralReading(left: ThermyxReading(foot: .left, timestamp: MLTrace.t0, footTemperatureC: 40.5, ambientTemperatureC: 24,
                                                        pressureBalance: 0.5, gaitStability: 0.92, batteryPercent: 80, thermalMode: .ventilation), right: nil)
        XCTAssertEqual(PersonalLayer.apply(ThermyxRiskEngine.assess(hot), reading: hot, baseline: b, trend: .init(), unit: .celsius, priors: warmPopulation).assessment.level, .high)
    }

    // MARK: Calibration model blending

    private func model() throws -> PersonalThermalModel {
        try XCTUnwrap(CalibrationTrainer.train(segments: MLCalibrationData.segments(seconds: 60, seed: 2), comfort: 0))
    }

    func testCalibrationMeansAreBlendedWithThePopulationAndTheRawOnesKept() throws {
        let raw = try model()
        let sittingRaw = try XCTUnwrap(raw.footByActivity[.sitting]).mean
        let p = priors(activities: [.sitting: .init(mean: sittingRaw - 3, sd: 0.8, count: 400)])
        let blended = raw.shrunk(toward: p)
        let sitting = try XCTUnwrap(blended.footByActivity[.sitting])
        XCTAssertLessThan(sitting.mean, sittingRaw)
        XCTAssertGreaterThanOrEqual(sitting.mean, sittingRaw - PersonalThermalModel.maxPriorPullC - 1e-9)
        XCTAssertEqual(blended.rawFootByActivity?[.sitting]?.mean, sittingRaw)
        XCTAssertEqual(blended.footByActivity[.standing], raw.footByActivity[.standing], "No prior for standing, no change")
        XCTAssertEqual(blended.comfortTargetC, raw.comfortTargetC, "The comfort target is the wearer's own")
        XCTAssertEqual(blended.shrunk(toward: p), blended, "Blending again from the raw values changes nothing")
        XCTAssertEqual(blended.shrunk(toward: nil).footByActivity, raw.footByActivity, "Taking the prior away restores the wearer's own")
        XCTAssertGreaterThan(blended.footPriorWeight?[.sitting] ?? 0, 0)
    }

    func testStoreReblendsTheModelWhenPriorsArriveLater() throws {
        let defaults = UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!
        let store = PersonalBaselineStore(defaults: defaults)
        let raw = try model()
        store.adopt(raw, indoorSamples: [])
        XCTAssertEqual(store.model?.footByActivity, raw.footByActivity)
        let sittingRaw = try XCTUnwrap(raw.footByActivity[.sitting]).mean
        store.priors = priors(activities: [.sitting: .init(mean: sittingRaw - 2, sd: 0.8, count: 400)])
        XCTAssertLessThan(try XCTUnwrap(store.model?.footByActivity[.sitting]).mean, sittingRaw)
        let reloaded = PersonalBaselineStore(defaults: defaults)
        XCTAssertEqual(reloaded.model?.footByActivity, store.model?.footByActivity, "Saved")
        store.priors = nil
        XCTAssertEqual(store.model?.footByActivity, raw.footByActivity)
    }

    func testLiveActivityGuessIsTheSameWithOneInsoleOrTwoEmittingSeparately() throws {
        // Each foot's packets arrive in their own emission, so a pair reading
        // arrives twice a second. The live window is still ten seconds.
        for activity in CalibrationActivity.allCases {
            let store = PersonalBaselineStore(defaults: UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!)
            store.adopt(try model(), indoorSamples: [])
            MLTrace.play(MLWearer(), from: 0, seconds: 40, hz: 1, alternating: true, { _ in MLMoment(activity: activity) }) { pair, stamp in
                store.observe(pair, fixedLevel: .normal, now: stamp)
            }
            let top = store.activity?.max { $0.value < $1.value }
            XCTAssertEqual(top?.key, activity, "\(activity)")
            XCTAssertGreaterThan(top?.value ?? 0, 0.8)
        }
    }

    // MARK: Drift

    func testASmallShiftThatPersistsIsCaughtWhileNoiseNeverIs() {
        // Noise only: 2 000 minutes (a day and a half) over several seeds.
        for seed in 1...6 {
            var rng = MLRandom(seed: UInt64(seed))
            var drift = DriftState()
            var alarmed = false
            for _ in 0..<2_000 {
                drift.update(footC: 33 + 0.5 * rng.normal(), footExpected: (33, 0.5), gait: 0.92 + 0.02 * rng.normal(), gaitUsual: (0.92, 0.02))
                alarmed = alarmed || drift.report().isAnomalous
            }
            XCTAssertFalse(alarmed, "seed \(seed)")
        }
        // A 1.2 °C shift, 1.6 spreads: well under the fixed 2 °C margin.
        var delays: [Int] = []
        for seed in 1...20 {
            var rng = MLRandom(seed: UInt64(seed) + 100)
            var drift = DriftState()
            for _ in 0..<60 { drift.update(footC: 33 + 0.5 * rng.normal(), footExpected: (33, 0.5), gait: nil, gaitUsual: nil) }
            var minutes = 0
            while !drift.report().isAnomalous, minutes < 120 {
                drift.update(footC: 34.2 + 0.5 * rng.normal(), footExpected: (33, 0.5), gait: nil, gaitUsual: nil)
                minutes += 1
            }
            delays.append(minutes)
        }
        print("ML-REPORT drift: +1.2 C shift (2.4 spreads at 0.5 C) detected after min/median/max minutes: \(delays.min()!)/\(delays.sorted()[10])/\(delays.max()!)")
        XCTAssertLessThanOrEqual(delays.max() ?? 999, 10)
    }

    func testOneGlitchyMinuteCannotAlarmOnItsOwn() {
        var drift = DriftState()
        drift.update(footC: 39, footExpected: (33, 0.5), gait: 0.2, gaitUsual: (0.92, 0.02))
        XCTAssertFalse(drift.report().isAnomalous)
        XCTAssertLessThan(drift.report().score, 1)
        XCTAssertEqual(drift.foot.tally, DriftState.zCap - DriftState.allowance, accuracy: 1e-9, "One minute adds at most 3.25")
        for _ in 0..<5 { drift.update(footC: 33, footExpected: (33, 0.5), gait: 0.92, gaitUsual: (0.92, 0.02)) }
        XCTAssertEqual(drift.foot.tally, 0, accuracy: 1e-9, "Back to normal drains it")
        XCTAssertEqual(drift.foot.run, 0)
    }

    func testDriftNamesEachFeatureAndHowLongItHasBeenRunning() {
        var drift = DriftState()
        for _ in 0..<8 { drift.update(footC: 35, footExpected: (33, 0.6), gait: 0.82, gaitUsual: (0.92, 0.03)) }
        let report = drift.report()
        XCTAssertTrue(report.isAnomalous)
        XCTAssertEqual(Set(report.contributing.map(\.name)), [.footTemperature, .steadiness])
        let foot = report.feature(.footTemperature)!
        XCTAssertEqual(foot.run, 8)
        XCTAssertEqual(foot.meanDeparture, 2.0, accuracy: 1e-9)
        XCTAssertEqual(report.feature(.steadiness)!.meanDeparture, 0.10, accuracy: 1e-9)
    }

    func testDriftAddsCautionOnlyAndSaysWhatMoved() {
        var b = calibrated()
        var drift = DriftState()
        for _ in 0..<7 { drift.update(footC: 34.7, footExpected: (33, 0.6), gait: nil, gaitUsual: nil) }
        b.drift = drift
        let p = BilateralReading(left: ThermyxReading(foot: .left, timestamp: MLTrace.t0, footTemperatureC: 34.7, ambientTemperatureC: 24,
                                                      pressureBalance: 0.5, gaitStability: 0.92, batteryPercent: 80, thermalMode: .ventilation), right: nil)
        let fixed = ThermyxRiskEngine.assess(p)
        XCTAssertEqual(fixed.level, .normal)
        let r = PersonalLayer.apply(fixed, reading: p, baseline: b, trend: .init(), unit: .celsius)
        XCTAssertEqual(r.assessment.level, .caution, "1.7 °C is under the 2 °C single-minute margin, but it has persisted")
        XCTAssertTrue(r.assessment.reasons.contains { $0.contains("stayed above your usual for 7 minutes") })
        let signal = r.signals.first { $0.title.contains("staying") }
        XCTAssertEqual(signal?.contributes, true)
        XCTAssertTrue(signal?.value?.contains("7 min") ?? false)
        // Never lowers, never past Caution on its own.
        let high = BilateralReading(left: ThermyxReading(foot: .left, timestamp: MLTrace.t0, footTemperatureC: 40.5, ambientTemperatureC: 24,
                                                         pressureBalance: 0.5, gaitStability: 0.92, batteryPercent: 80, thermalMode: .ventilation), right: nil)
        XCTAssertEqual(PersonalLayer.apply(ThermyxRiskEngine.assess(high), reading: high, baseline: b, trend: .init(), unit: .celsius).assessment.level, .high)
        // A Fahrenheit wearer sees Fahrenheit.
        let f = PersonalLayer.apply(fixed, reading: p, baseline: b, trend: .init(), unit: .fahrenheit)
        XCTAssertTrue(f.signals.first { $0.title.contains("staying") }?.value?.contains("3.") ?? false)
    }

    func testStoreTracksDriftThroughNonCalmMinutesButNotHeatingOnes() {
        let defaults = UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!
        let store = PersonalBaselineStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 2_000_000)
        var t = 0.0
        func feed(minutes: Int, footC: Double, level: ThermyxRiskLevel = .normal, mode: ThermalMode = .ventilation) {
            for _ in 0..<(minutes * 6) {
                store.observe(reading(footC: footC, mode: mode), fixedLevel: level, now: start.addingTimeInterval(t))
                t += 10
            }
        }
        feed(minutes: 40, footC: 33)
        XCTAssertTrue(store.baseline.isCalibrated)
        let before = store.baseline.drift?.foot.tally ?? 0
        feed(minutes: 12, footC: 36, level: .normal, mode: .heating)
        XCTAssertEqual(store.baseline.drift?.foot.tally ?? 0, before, accuracy: 0.01, "Heating moves the foot by design: not evidence")
        feed(minutes: 8, footC: 35, level: .caution)
        XCTAssertTrue(store.baseline.drift?.report().isAnomalous ?? false, "A slow rise that stops minutes being calm still builds the tally")
        let learned = store.baseline.minutesLearned
        feed(minutes: 5, footC: 35, level: .caution)
        XCTAssertEqual(store.baseline.minutesLearned, learned, "And never teaches the usual")
    }

    // MARK: Store: left/right norms

    func testAsymmetryNormsArePersistedClearedAndNeverLearnedFromDemo() {
        let defaults = UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!
        let store = PersonalBaselineStore(defaults: defaults)
        MLTrace.play(MLWearer(), from: 0, seconds: 40 * 60, { _ in MLMoment() }) { pair, _ in
            store.observeAsymmetry(pair, learn: true)
        }
        let learned = store.asymmetryEstimates
        XCTAssertGreaterThan(learned.walkingLean.count, 30)
        XCTAssertTrue(store.asymmetryStatus(now: MLTrace.t0.addingTimeInterval(40 * 60)).isEmpty)
        let reloaded = PersonalBaselineStore(defaults: defaults)
        XCTAssertGreaterThan(reloaded.asymmetryEstimates.walkingLean.count, 20, "Saved on the way")

        let demo = PersonalBaselineStore(defaults: UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!)
        MLTrace.play(MLWearer(), from: 0, seconds: 20 * 60, { _ in MLMoment() }) { pair, _ in demo.observeAsymmetry(pair, learn: false) }
        XCTAssertEqual(demo.asymmetryEstimates.walkingLean.count, 0)

        store.deleteAll()
        XCTAssertEqual(store.asymmetryEstimates.walkingLean.count, 0)
        XCTAssertNil(defaults.data(forKey: "thermyx.asymmetryBaseline"))
    }

    func testAnElevatedMomentNeverTeachesTheNorms() {
        let store = PersonalBaselineStore(defaults: UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!)
        var wearer = MLWearer()
        wearer.leftTempC = 38.5   // a hot foot: Caution from the fixed rules
        MLTrace.play(wearer, from: 0, seconds: 10 * 60, { _ in MLMoment() }) { pair, _ in store.observeAsymmetry(pair, learn: true) }
        XCTAssertEqual(store.asymmetryEstimates.walkingLean.count, 0)
        store.priors = nil
    }

    func testPriorsFlowIntoTheLeftRightNorms() {
        let store = PersonalBaselineStore(defaults: UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!)
        var p = PopulationPriors(computedAt: MLTrace.t0)
        p.standingLean = .init(mean: 0.04, sd: 0.02, count: 200)
        store.priors = p
        XCTAssertEqual(store.asymmetryEstimates.standingLean.mean, 0.04, accuracy: 1e-9)
        store.priors = nil
        XCTAssertEqual(store.asymmetryEstimates.standingLean.mean, 0, accuracy: 1e-9)
    }
}
