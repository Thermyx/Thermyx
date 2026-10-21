import XCTest
@testable import ThermyxApp

/// The recovery test, the safety plan and the readiness profile.
final class RecoveryLoopTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    /// A hold: `start` to `end` over `seconds`, one reading a second.
    private func hold(start: Double, end: Double, seconds: Int = 180, still: Bool? = true,
                      level: (Int) -> ThermyxRiskLevel = { _ in .high }) -> [RecoverySample] {
        (0...seconds).map { i in
            RecoverySample(t: Double(i), footC: start + (end - start) * Double(i) / Double(seconds), still: still, loadGap: nil, level: level(i))
        }
    }

    // MARK: The test

    func testACoolingFootRecovers() {
        let r = RecoveryEvaluator.evaluate(hold(start: 38.6, end: 37.4, level: { $0 > 150 ? .normal : .caution }), startLevel: .high)
        XCTAssertEqual(r.outcome, .recovered)
        XCTAssertEqual(r.dropC ?? 0, 1.2, accuracy: 0.15)
        XCTAssertNotNil(r.minutesToImprove, "The half-degree mark is found")
    }

    func testAFootThatCoolsALittleIsImproving() {
        let r = RecoveryEvaluator.evaluate(hold(start: 38.6, end: 38.1), startLevel: .high)
        XCTAssertEqual(r.outcome, .improving)
    }

    func testAFootThatDoesntCoolIsSaidSo() {
        let flat = RecoveryEvaluator.evaluate(hold(start: 38.6, end: 38.5), startLevel: .high)
        XCTAssertEqual(flat.outcome, .notImproving)
        let warming = RecoveryEvaluator.evaluate(hold(start: 38.6, end: 39.4), startLevel: .high)
        XCTAssertEqual(warming.outcome, .notImproving)
        XCTAssertNil(warming.minutesToImprove)
    }

    func testMovingDuringTheHoldMakesItInconclusive() {
        var samples = hold(start: 38.6, end: 37.0)
        for i in samples.indices where i % 2 == 0 { samples[i].still = false }
        XCTAssertEqual(RecoveryEvaluator.evaluate(samples, startLevel: .high).outcome, .inconclusive,
                       "A cooling foot while walking isn't a recovery test")
    }

    func testTooLittleDataIsInconclusiveNotAGuess() {
        XCTAssertEqual(RecoveryEvaluator.evaluate(hold(start: 38, end: 36, seconds: 20), startLevel: .high).outcome, .inconclusive)
        XCTAssertEqual(RecoveryEvaluator.evaluate([], startLevel: .high).outcome, .inconclusive)
    }

    func testUnknownStillnessDoesntBlockTheVerdict() {
        // Insoles that don't report cadence can't say; the test goes on what it can measure.
        XCTAssertEqual(RecoveryEvaluator.evaluate(hold(start: 38.6, end: 37.4, still: nil), startLevel: .high).outcome, .recovered)
    }

    func testWeightEvening() {
        var samples = hold(start: 38.6, end: 37.5)
        for i in samples.indices { samples[i].loadGap = i < 20 ? 0.25 : 0.05 }
        XCTAssertEqual(RecoveryEvaluator.evaluate(samples, startLevel: .high).loadEvened, true)
    }

    func testTheSessionCollectsTheHoldAndRecordsWhatWasTicked() {
        var s = RecoverySession(startedAt: t0, startLevel: .high)
        XCTAssertFalse(s.canStartHold)
        s.done = [.pause, .hydrate]
        s.switchedToCool = true
        XCTAssertTrue(s.canStartHold)
        s.startHold(now: t0)
        for i in 0...60 {
            let reading = BilateralReading(
                left: ThermyxReading(foot: .left, timestamp: t0, footTemperatureC: 38.5 - Double(i) * 0.02, ambientTemperatureC: 30,
                                     pressureBalance: 0.5, gaitStability: 0.9, batteryPercent: 70, thermalMode: .cooling, cadenceStepsPerMinute: 0, standingFraction: 0),
                right: nil)
            s.add(reading, level: .high, now: t0.addingTimeInterval(Double(i)))
        }
        XCTAssertEqual(s.samples.count, 61)
        XCTAssertEqual(s.samples.last?.still, true)
        XCTAssertEqual(s.remaining(now: t0.addingTimeInterval(60)), s.holdSeconds - 60, accuracy: 0.01)
        XCTAssertEqual(s.actions, [.rested, .stoppedActivity, .hydrated, .cooledDown])
        XCTAssertFalse(s.isGettingWorse)
    }

    func testAWarmingFootIsFlaggedBeforeTheTimerEnds() {
        var s = RecoverySession(startedAt: t0, startLevel: .high)
        s.startHold(now: t0)
        s.samples = hold(start: 38.4, end: 39.2, seconds: 60)
        XCTAssertTrue(s.isGettingWorse)
    }

    // MARK: The safety plan

    private func record(_ actions: [RecoveryAction], rate: Double, day: Int = 0) -> RecoveryRecord {
        RecoveryRecord(id: UUID(), startedAt: t0.addingTimeInterval(Double(day) * 86_400), startLevel: "High risk", startFootC: 38.6,
                       endFootC: 38.6 - rate * 3, seconds: 180, outcome: .improving, stillFraction: 1, loadEvened: nil,
                       actions: actions, guided: true)
    }

    func testThePlanWaitsForEnoughRecoveries() {
        let plan = SafetyPlan.build([record([.rested], rate: 0.3), record([], rate: 0.1)])
        XCTAssertTrue(plan.findings.isEmpty)
        XCTAssertEqual(plan.measured, 2)
        XCTAssertFalse(plan.isReady)
    }

    func testRestWasFollowedByFasterCooling() {
        let plan = SafetyPlan.build(ThermyxRecoveryStore.demoRecords(now: t0))
        let rest = plan.findings.first { $0.action == .rested }
        XCTAssertNotNil(rest)
        XCTAssertTrue(rest?.text.hasPrefix("After short rest breaks, your foot cooled") == true, rest?.text ?? "")
        XCTAssertTrue(rest?.text.contains("when carrying on") == true)
        XCTAssertTrue(rest?.text.hasSuffix("(5 recoveries with it, 4 without).") == true, rest?.text ?? "")
        XCTAssertLessThanOrEqual(plan.findings.count, 3)
        XCTAssertTrue(plan.helped.contains(.rested))
        // Drinking water didn't separate the two groups in the demo: not claimed.
        XCTAssertFalse(plan.findings.contains { $0.action == .hydrated })
    }

    func testNoPatternIsSaidWhenThereIsntOne() {
        let records = (0..<8).map { record($0 % 2 == 0 ? [.hydrated] : [], rate: 0.2, day: $0) }
        let plan = SafetyPlan.build(records)
        XCTAssertTrue(plan.isReady)
        XCTAssertTrue(plan.findings.isEmpty)
    }

    func testOneRecoveryIsNeverAPattern() {
        // Rested appears once; it can't be compared.
        var records = (0..<6).map { record([], rate: 0.1, day: $0) }
        records.append(record([.rested], rate: 0.5, day: 7))
        XCTAssertFalse(SafetyPlan.build(records).findings.contains { $0.action == .rested })
    }

    func testSpeedIsPlainWords() {
        XCTAssertEqual(SafetyPlan.speed(2.4), "about twice as fast as")
        XCTAssertEqual(SafetyPlan.speed(1.4), "about 40% faster than")
    }

    func testLoggedEventsJoinTheComparisonOnceTheyHaveAnEnd() {
        let withEnd = RecoveryRecord(id: UUID(), startedAt: t0, startLevel: "High risk", startFootC: 38.8, endFootC: 37.0, seconds: 600,
                                     outcome: .recovered, stillFraction: nil, loadEvened: nil, actions: [.rested], guided: false)
        XCTAssertEqual(withEnd.coolingRate ?? 0, 0.18, accuracy: 0.01)
        var noEnd = withEnd
        noEnd.endFootC = nil
        XCTAssertNil(noEnd.coolingRate)
        var tooShort = withEnd
        tooShort.seconds = 10
        XCTAssertNil(tooShort.coolingRate, "Ten seconds says nothing about cooling")
    }

    @MainActor
    func testDemoRecoveriesNeverTouchTheRealOnes() {
        let store = ThermyxRecoveryStore()
        let before = store.records.count
        store.enterDemo(ThermyxRecoveryStore.demoRecords(now: t0))
        XCTAssertEqual(store.records.count, 9)
        store.add(record([.rested], rate: 0.3))
        store.exitDemo()
        XCTAssertEqual(store.records.count, before, "Nothing from the demo was kept")
    }

    // MARK: Readiness

    /// A month of calm hours at a usual temperature for each activity.
    private func hours(sitting: Double, walking: Double, count: Int = 40, leftLead: Double = 0) -> [ThermyxHistorySample] {
        var out: [ThermyxHistorySample] = []
        for i in 0..<count {
            let start = t0.addingTimeInterval(-Double(i + 1) * 3600 * 5)
            for foot in Foot.allCases {
                var s = ThermyxHistorySample(foot: foot, start: start)
                let walkingHour = i % 2 == 0
                s.footMeanC = (walkingHour ? walking : sitting) + Double(i % 5) * 0.1
                s.walkingSeconds = walkingHour ? 3000 : 0
                s.sittingSeconds = walkingHour ? 0 : 3000
                s.balanceMean = 0.5 + (foot == .left ? leftLead / 2 : -leftLead / 2)
                s.peakRisk = ThermyxRiskLevel.normal.rawValue
                s.sampleCount = 60
                out.append(s)
            }
        }
        return out
    }

    private func reading(_ c: Double, cadence: Double = 0, left: Double = 0.5, right: Double = 0.5) -> BilateralReading {
        func r(_ foot: Foot, _ load: Double) -> ThermyxReading {
            ThermyxReading(foot: foot, timestamp: t0, footTemperatureC: c, ambientTemperatureC: 24, pressureBalance: load, gaitStability: 0.92,
                           batteryPercent: 80, thermalMode: .ventilation, cadenceStepsPerMinute: cadence, standingFraction: 0)
        }
        return BilateralReading(left: r(.left, left), right: r(.right, right))
    }

    func testTypicalWhenTheFootIsInsideItsUsualRange() {
        let p = ReadinessProfile.build(reading: reading(31.8), activity: [.sitting: 0.9], model: nil,
                                       hours: hours(sitting: 31.5, walking: 34), recoveries: [], comfortTargetC: 31, now: t0)
        XCTAssertEqual(p.status, .typical)
        XCTAssertEqual(p.activity, .sitting)
        XCTAssertEqual(p.ranges.count, 2, "Standing has no history and no calibration: no range is invented")
        XCTAssertTrue(p.ranges.allSatisfy(\.fromHistory))
        XCTAssertEqual(p.comfortTargetC, 31)
    }

    func testWarmerAndCoolerThanUsual() {
        let h = hours(sitting: 31.5, walking: 34)
        let warm = ReadinessProfile.build(reading: reading(34.5), activity: [.sitting: 0.9], model: nil, hours: h, recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(warm.status, .warmer)
        XCTAssertEqual(warm.notes.first, "Your warmer foot is above its usual range while you're sitting.")
        let cool = ReadinessProfile.build(reading: reading(28.5), activity: [.sitting: 0.9], model: nil, hours: h, recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(cool.status, .cooler)
    }

    func testTheSameTemperatureCanBeNormalWalkingAndHighSitting() {
        let h = hours(sitting: 31.5, walking: 34.5)
        let sitting = ReadinessProfile.build(reading: reading(34.4), activity: [.sitting: 1], model: nil, hours: h, recoveries: [], comfortTargetC: nil, now: t0)
        let walking = ReadinessProfile.build(reading: reading(34.4, cadence: 100), activity: [.walking: 1], model: nil, hours: h, recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(sitting.status, .warmer)
        XCTAssertEqual(walking.status, .typical, "Compared with your own walking, not with a generic number")
    }

    func testStillLearningWithoutHistoryOrCalibration() {
        let p = ReadinessProfile.build(reading: reading(33), activity: nil, model: nil, hours: [], recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(p.status, .learning)
        XCTAssertTrue(p.ranges.isEmpty)
        let few = ReadinessProfile.build(reading: reading(33), activity: [.sitting: 1], model: nil, hours: Array(hours(sitting: 31, walking: 34, count: 3)), recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(few.status, .learning, "A few hours isn't your normal")
    }

    func testOnlyCalmHoursDefineNormal() {
        var h = hours(sitting: 31.5, walking: 34)
        // A very hot, alarmed stretch must not become "usual".
        for i in h.indices where h[i].sittingSeconds == 3000 && i % 4 == 0 { h[i].footMeanC = 39; h[i].peakRisk = ThermyxRiskLevel.high.rawValue }
        let p = ReadinessProfile.build(reading: reading(31.8), activity: [.sitting: 1], model: nil, hours: h, recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertLessThan(p.ranges.first { $0.activity == .sitting }?.highC ?? 99, 33)
    }

    func testUsualWeightOnEachFootAndLeaningMoreThanUsual() {
        let h = hours(sitting: 31.5, walking: 34, leftLead: 0.02)
        let even = ReadinessProfile.build(reading: reading(31.8, left: 0.51, right: 0.49), activity: [.sitting: 1], model: nil, hours: h, recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(even.usualLean ?? 9, 0.02, accuracy: 0.01)
        XCTAssertTrue(even.notes.isEmpty)
        let leaning = ReadinessProfile.build(reading: reading(31.8, left: 0.7, right: 0.4), activity: [.sitting: 1], model: nil, hours: h, recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(leaning.notes, ["You're putting more weight on your left foot than usual."])
    }

    func testRecoveriesGettingQuicker() {
        func rec(_ rate: Double, _ day: Int) -> RecoveryRecord { record([], rate: rate, day: day) }
        let faster = [0.1, 0.1, 0.12, 0.11, 0.2, 0.22, 0.24].enumerated().map { rec($1, $0) }
        XCTAssertEqual(ReadinessProfile.recoveryTrend(faster), .faster)
        let slower = [0.3, 0.3, 0.28, 0.3, 0.15, 0.14, 0.12].enumerated().map { rec($1, $0) }
        XCTAssertEqual(ReadinessProfile.recoveryTrend(slower), .slower)
        XCTAssertEqual(ReadinessProfile.recoveryTrend(Array(faster.prefix(3))), .notEnough)
    }

    func testReadinessNeverTouchesTheRiskLevel() {
        // It's a description. The risk engine doesn't take it as an input.
        let hot = ThermyxRiskEngine.assess(reading(39))
        let p = ReadinessProfile.build(reading: reading(39), activity: [.sitting: 1], model: nil, hours: hours(sitting: 39, walking: 39), recoveries: [], comfortTargetC: nil, now: t0)
        XCTAssertEqual(p.status, .typical, "Hot can be 'usual' for someone")
        XCTAssertGreaterThanOrEqual(hot.level.severity, ThermyxRiskLevel.caution.severity, "…and is still flagged by the fixed rules")
    }
}
