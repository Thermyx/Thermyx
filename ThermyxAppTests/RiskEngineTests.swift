import XCTest
@testable import ThermyxApp

@MainActor
final class RiskEngineTests: XCTestCase {

    private func reading(
        _ foot: Foot = .left,
        footC: Double? = 33,
        ambientC: Double? = 25,
        gait: Double? = 0.92,
        balance: Double? = 0.5,
        mode: ThermalMode = .ventilation,
        zones: FootZoneTemperatures? = nil
    ) -> ThermyxReading {
        ThermyxReading(
            foot: foot,
            timestamp: .now,
            footTemperatureC: footC,
            ambientTemperatureC: ambientC,
            pressureBalance: balance,
            gaitStability: gait,
            batteryPercent: 80,
            thermalMode: mode,
            zones: zones
        )
    }

    func testNormalWhenEverythingIsCalm() {
        XCTAssertEqual(ThermyxRiskEngine.assess(reading()).level, .normal)
    }

    func testReasonsCountUpToCritical() {
        XCTAssertEqual(ThermyxRiskEngine.assess(reading(ambientC: 36)).level, .caution)
        XCTAssertEqual(ThermyxRiskEngine.assess(reading(ambientC: 36, gait: 0.7)).level, .high)
        XCTAssertEqual(ThermyxRiskEngine.assess(reading(footC: 38.5, ambientC: 36, gait: 0.7)).level, .critical)
    }

    func testBurnLimitIsHighOnItsOwn() {
        let assessment = ThermyxRiskEngine.assess(reading(footC: 40.2))
        XCTAssertEqual(assessment.level, .high)
        XCTAssertTrue(assessment.level.locksOutHeating)
        XCTAssertTrue(assessment.reasons.first?.contains("burn-protection") ?? false)
    }

    func testBurnLimitChecksEveryZone() {
        let zones = FootZoneTemperatures(forefootC: 40.5, archC: 36, heelC: 34)
        XCTAssertEqual(ThermyxRiskEngine.assess(reading(footC: 36.8, zones: zones)).level, .high)
    }

    func testMissingSensorsDoNotBlankTheAssessment() {
        // No ambient channel, but a dangerously hot foot must still register.
        XCTAssertEqual(ThermyxRiskEngine.assess(reading(footC: 40.5, ambientC: nil)).level, .high)
        XCTAssertEqual(ThermyxRiskEngine.assess(reading(footC: nil, ambientC: nil, gait: nil)).level, .unavailable)
    }

    func testAsymmetryOnlyCountsWhenSustained() {
        let pair = BilateralReading(left: reading(.left, footC: 33), right: reading(.right, footC: 35))
        XCTAssertEqual(ThermyxRiskEngine.assess(pair, sustainedTemperatureGap: false, sustainedLoadGap: false).level, .normal)
        XCTAssertEqual(ThermyxRiskEngine.assess(pair, sustainedTemperatureGap: true, sustainedLoadGap: false).level, .caution)
    }

    func testAsymmetryNeverEscalatesPastCaution() {
        let pair = BilateralReading(left: reading(.left, footC: 30, balance: 0.3), right: reading(.right, footC: 36, balance: 0.7))
        XCTAssertEqual(ThermyxRiskEngine.assess(pair).level, .caution)
    }

    func testPairTakesTheWorseFoot() {
        let pair = BilateralReading(left: reading(.left), right: reading(.right, footC: 40.1))
        let assessment = ThermyxRiskEngine.assess(pair, sustainedTemperatureGap: false, sustainedLoadGap: false)
        XCTAssertEqual(assessment.level, .high)
        XCTAssertEqual(assessment.foot, .right)
    }

    func testSuggestionsFollowTheSignals() {
        let hot = BilateralReading(left: reading(footC: 40.3), right: nil)
        XCTAssertTrue(ThermyxSuggestion.nextStep(for: ThermyxRiskEngine.assess(hot), reading: hot)?.contains("heat limit") ?? false)
        let calm = BilateralReading(left: reading(), right: nil)
        XCTAssertNil(ThermyxSuggestion.nextStep(for: ThermyxRiskEngine.assess(calm), reading: calm))
    }

    // MARK: - Explanation

    private func pair(_ left: ThermyxReading?, _ right: ThermyxReading?) -> BilateralReading {
        var p = BilateralReading.empty
        p.left = left
        p.right = right
        return p
    }

    func testExplanationNamesTheSignalsThatCount() {
        let p = pair(reading(.left, footC: 38.5, ambientC: 36), nil)
        let a = ThermyxRiskEngine.assess(p, sustainedTemperatureGap: false, sustainedLoadGap: false)
        let e = RiskExplanation.build(assessment: a, reading: p, sustainedTemperatureGap: false, sustainedLoadGap: false,
                                      rssi: [.left: -60], bothExpected: false, unit: .celsius)
        XCTAssertEqual(e.level, .high)
        XCTAssertEqual(Set(e.contributing.map(\.kind)), [.footTemperature, .ambient])
        XCTAssertEqual(e.confidence, .high)
    }

    func testBurnLimitShowsAsItsOwnSignal() {
        let p = pair(reading(.left, footC: 40.5), nil)
        let a = ThermyxRiskEngine.assess(p)
        let e = RiskExplanation.build(assessment: a, reading: p, sustainedTemperatureGap: false, sustainedLoadGap: false,
                                      rssi: [:], bothExpected: false, unit: .celsius)
        XCTAssertTrue(e.contributing.contains { $0.kind == .burnLimit })
    }

    func testGapSignalsOnlyCountWhenSustained() {
        let p = pair(reading(.left, footC: 36), reading(.right, footC: 33))
        let a = ThermyxRiskEngine.assess(p, sustainedTemperatureGap: false, sustainedLoadGap: false)
        let brief = RiskExplanation.build(assessment: a, reading: p, sustainedTemperatureGap: false, sustainedLoadGap: false,
                                          rssi: [:], bothExpected: true, unit: .celsius)
        XCTAssertFalse(brief.contributing.contains { $0.kind == .temperatureGap })
        let held = RiskExplanation.build(assessment: a, reading: p, sustainedTemperatureGap: true, sustainedLoadGap: false,
                                         rssi: [:], bothExpected: true, unit: .celsius)
        XCTAssertTrue(held.contributing.contains { $0.kind == .temperatureGap })
    }

    func testConfidenceDropsForStaleMissingAndWeakData() {
        let old = ThermyxReading(foot: .left, timestamp: Date.now.addingTimeInterval(-12), footTemperatureC: 33,
                             ambientTemperatureC: nil, pressureBalance: 0.5, gaitStability: nil,
                             batteryPercent: 50, thermalMode: .off)
        let p = pair(old, nil)
        let (level, reasons) = RiskExplanation.confidence(reading: p, age: [.left: 12], rssi: [.left: -90], bothExpected: true)
        XCTAssertEqual(level, .low)
        XCTAssertGreaterThanOrEqual(reasons.count, 4)
    }

    func testNoDataIsLowConfidence() {
        let (level, _) = RiskExplanation.confidence(reading: .empty, age: [:], rssi: [:], bothExpected: false)
        XCTAssertEqual(level, .low)
    }

    func testDeviceHealthStates() {
        XCTAssertEqual(DeviceHealthStrip.state(connected: false, age: 1), .off)
        XCTAssertEqual(DeviceHealthStrip.state(connected: true, age: nil), .off)
        XCTAssertEqual(DeviceHealthStrip.state(connected: true, age: 1), .live)
        XCTAssertEqual(DeviceHealthStrip.state(connected: true, age: 5), .stale)
        XCTAssertEqual(DeviceHealthStrip.signalWord(-60), "good")
        XCTAssertEqual(DeviceHealthStrip.signalWord(-90), "weak")
    }

    // MARK: - Personal layer

    private func calibrated(footC: Double = 33, gait: Double = 0.92) -> PersonalBaseline {
        var b = PersonalBaseline()
        for _ in 0..<PersonalBaseline.calibrationMinutes { b.learn(footC: footC, gait: gait) }
        return b
    }

    func testBaselineNeedsCalibrationBeforeWarning() {
        var b = PersonalBaseline()
        for _ in 0..<(PersonalBaseline.calibrationMinutes - 1) { b.learn(footC: 31, gait: 0.95) }
        XCTAssertFalse(b.isCalibrated)
        let p = pair(reading(.left, footC: 35.5), nil)
        let r = PersonalLayer.apply(ThermyxRiskEngine.assess(p), reading: p, baseline: b, trend: .init(), unit: .celsius)
        XCTAssertEqual(r.assessment.level, .normal)
    }

    func testBaselineAddsCautionWhenWellAboveUsual() {
        let p = pair(reading(.left, footC: 35.5), nil)
        let fixed = ThermyxRiskEngine.assess(p)
        XCTAssertEqual(fixed.level, .normal)
        let r = PersonalLayer.apply(fixed, reading: p, baseline: calibrated(footC: 33), trend: .init(), unit: .celsius)
        XCTAssertEqual(r.assessment.level, .caution)
        XCTAssertTrue(r.signals.contains { $0.kind == .personalBaseline && $0.contributes })
    }

    func testPersonalLayerNeverLowersOrEscalatesPastFixedRules() {
        // A wearer whose "usual" is hot still gets the fixed High.
        let hot = pair(reading(.left, footC: 38.5, ambientC: 36), nil)
        let fixed = ThermyxRiskEngine.assess(hot)
        XCTAssertEqual(fixed.level, .high)
        let r = PersonalLayer.apply(fixed, reading: hot, baseline: calibrated(footC: 39), trend: TemperatureTrend(delta5: -2), unit: .celsius)
        XCTAssertEqual(r.assessment.level, .high)
        // Personal signals alone stop at Caution.
        let calm = pair(reading(.left, footC: 36.5, gait: 0.81), nil)
        let rise = PersonalLayer.apply(ThermyxRiskEngine.assess(calm), reading: calm, baseline: calibrated(footC: 32, gait: 0.97),
                                       trend: TemperatureTrend(delta5: 2), unit: .celsius)
        XCTAssertEqual(rise.assessment.level, .caution)
    }

    func testBaselineCannotLearnADangerousNormal() {
        let b = calibrated(footC: 39.5, gait: 0.5)
        XCTAssertLessThanOrEqual(b.footMeanC ?? 0, PersonalBaseline.footClampC.upperBound)
        XCTAssertGreaterThanOrEqual(b.gaitMean ?? 0, PersonalBaseline.gaitClamp.lowerBound)
    }

    func testFastRiseAddsCautionAndRecoveryIsOnlyANote() {
        let p = pair(reading(.left, footC: 34), nil)
        let fixed = ThermyxRiskEngine.assess(p)
        XCTAssertEqual(PersonalLayer.apply(fixed, reading: p, baseline: nil, trend: TemperatureTrend(delta5: 1.2), unit: .celsius).assessment.level, .caution)
        XCTAssertEqual(PersonalLayer.apply(fixed, reading: p, baseline: nil, trend: TemperatureTrend(delta5: 0.4, delta10: 1.6), unit: .celsius).assessment.level, .caution)
        let cooling = PersonalLayer.apply(fixed, reading: p, baseline: nil, trend: TemperatureTrend(delta5: -0.8), unit: .celsius)
        XCTAssertEqual(cooling.assessment.level, .normal)
        XCTAssertEqual(cooling.signals.first?.title, "Cooling down")
    }

    func testBaselineExpiresAfterNinetyDays() {
        var b = PersonalBaseline()
        b.learn(footC: 33, gait: 0.9, now: Date(timeIntervalSince1970: 0))
        XCTAssertTrue(b.isExpired(now: Date(timeIntervalSince1970: 91 * 24 * 3600)))
        XCTAssertFalse(b.isExpired(now: Date(timeIntervalSince1970: 89 * 24 * 3600)))
    }

    func testBaselineStoreLearnsOnlyCalmMinutes() {
        let defaults = UserDefaults(suiteName: "thermyx.tests.\(UUID().uuidString)")!
        let store = PersonalBaselineStore(defaults: defaults)
        let start = Date(timeIntervalSince1970: 1_000_000)
        let calm = pair(reading(.left, footC: 33), nil)
        for s in stride(from: 0, through: 120, by: 10) {
            store.observe(calm, fixedLevel: .normal, now: start.addingTimeInterval(TimeInterval(s)))
        }
        XCTAssertEqual(store.baseline.minutesLearned, 2)
        for s in stride(from: 130, through: 190, by: 10) {
            store.observe(calm, fixedLevel: .caution, now: start.addingTimeInterval(TimeInterval(s)))
        }
        XCTAssertEqual(store.baseline.minutesLearned, 2)
        store.deleteAll()
        XCTAssertEqual(store.baseline.minutesLearned, 0)
    }

    // MARK: - Calibration model

    /// One minute of samples for an activity, with a little deterministic noise.
    private func minute(_ activity: CalibrationActivity, footC: Double, start: Date = Date(timeIntervalSince1970: 0)) -> [CalibrationSample] {
        (0..<60).map { i in
            let wobble = Double((i * 37) % 11 - 5) / 50   // −0.1…+0.1
            switch activity {
            case .sitting:
                return CalibrationSample(time: start.addingTimeInterval(Double(i)), footC: footC + wobble, ambientC: 24,
                                         load: 0.30 + wobble / 4, gait: nil, cadence: 0, standing: 0.05)
            case .standing:
                return CalibrationSample(time: start.addingTimeInterval(Double(i)), footC: footC + wobble, ambientC: 24,
                                         load: 0.55 + wobble / 4, gait: nil, cadence: 0, standing: 0.95)
            case .walking:
                return CalibrationSample(time: start.addingTimeInterval(Double(i)), footC: footC + wobble, ambientC: 24,
                                         load: 0.5 + (i % 2 == 0 ? 0.15 : -0.15), gait: 0.9 + wobble / 10, cadence: 105 + wobble * 20, standing: 0.1)
            }
        }
    }

    private var indoorSegments: [CalibrationTrainer.Segment] {
        [
            .init(activity: .sitting, outdoor: false, samples: minute(.sitting, footC: 30)),
            .init(activity: .standing, outdoor: false, samples: minute(.standing, footC: 31)),
            .init(activity: .walking, outdoor: false, samples: minute(.walking, footC: 32.5)),
        ]
    }

    func testClassifierLearnsTheWearersActivities() throws {
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: indoorSegments, comfort: 0))
        XCTAssertTrue(model.classifier.isUsable)
        for activity in CalibrationActivity.allCases {
            let window = Array(minute(activity, footC: 31).prefix(ActivityFeatures.windowSeconds))
            let guess = try XCTUnwrap(model.classifier.predict(ActivityFeatures(window: window)))
            XCTAssertEqual(guess.activity, activity)
            XCTAssertGreaterThan(guess.confidence, 0.9)
        }
        XCTAssertEqual(try XCTUnwrap(model.classifierAccuracy), 1, accuracy: 0.001, "Leave-one-out on clean data")
    }

    func testClassifierStaysOffWithoutMovementSensors() throws {
        // Temperature only, as on a board with no pressure or motion sensor.
        let tempOnly = indoorSegments.map { seg in
            CalibrationTrainer.Segment(activity: seg.activity, outdoor: false, samples: seg.samples.map {
                CalibrationSample(time: $0.time, footC: $0.footC, ambientC: nil, load: nil, gait: nil, cadence: nil, standing: nil)
            })
        }
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: tempOnly, comfort: nil))
        XCTAssertFalse(model.classifier.isUsable, "No made-up activity guesses")
        XCTAssertNil(model.classifierAccuracy)
        XCTAssertEqual(try XCTUnwrap(model.footByActivity[.walking]).mean, 32.5, accuracy: 0.05, "Thermal profile still learned")
    }

    func testComfortTargetFollowsRestingTempAndAnswer() throws {
        XCTAssertEqual(try XCTUnwrap(CalibrationTrainer.train(segments: indoorSegments, comfort: 0)?.comfortTargetC), 30, accuracy: 0.05)
        XCTAssertEqual(try XCTUnwrap(CalibrationTrainer.train(segments: indoorSegments, comfort: 1)?.comfortTargetC), 28.5, accuracy: 0.05,
                       "Too warm lowers the target")
        XCTAssertEqual(PersonalThermalModel.comfortTarget(restingC: 37.9, comfort: -1), 38, "Never above the firmware's 38 °C")
        XCTAssertEqual(PersonalThermalModel.comfortTarget(restingC: 25, comfort: 1), 26, "Never below 26 °C")
    }

    func testOutdoorMinutesDontChangeTheUsualTemperature() throws {
        var segments = indoorSegments
        segments.append(.init(activity: .walking, outdoor: true, samples: minute(.walking, footC: 35.5)))
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: segments, comfort: 0))
        XCTAssertTrue(model.outdoorDone)
        XCTAssertEqual(try XCTUnwrap(model.footByActivity[.walking]).mean, 32.5, accuracy: 0.05)
    }

    func testCalibrationModelOnlyAddsCaution() throws {
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: indoorSegments, comfort: 0))
        let sitting: [CalibrationActivity: Double] = [.sitting: 1]
        func assess(_ footC: Double, base: ThermyxRiskLevel) -> ThermyxRiskLevel {
            let r = ThermyxReading(foot: .left, timestamp: .now, footTemperatureC: footC, ambientTemperatureC: nil,
                                   pressureBalance: nil, gaitStability: nil, batteryPercent: nil, thermalMode: .ventilation)
            return PersonalLayer.apply(ThermyxRiskAssessment(level: base, reasons: []), reading: BilateralReading(left: r, right: nil),
                                       baseline: nil, trend: TemperatureTrend(), unit: .celsius, model: model, activity: sitting).assessment.level
        }
        XCTAssertEqual(assess(30.5, base: .normal), .normal, "Within the usual for sitting")
        XCTAssertEqual(assess(33.0, base: .normal), .caution, "3 °C over the usual while sitting")
        XCTAssertEqual(assess(29.0, base: .high), .high, "Never lowers a level")
    }

    func testFootDetectedFlagRoundTrips() throws {
        for state in [true, false] {
            var t = ThermyxProtocol.Telemetry(version: 3, mode: .ventilation, batteryPercent: nil, footTemperatureC: 30,
                                              ambientTemperatureC: nil, gaitStability: nil, pressureBalance: nil,
                                              declaredFoot: .left, settingEcho: .auto)
            t.footDetected = state
            XCTAssertEqual(try ThermyxProtocol.decode(ThermyxProtocol.encode(t)).get().footDetected, state)
        }
        let legacy = ThermyxProtocol.Telemetry(version: 3, mode: .ventilation, batteryPercent: nil, footTemperatureC: 30,
                                               ambientTemperatureC: nil, gaitStability: nil, pressureBalance: nil,
                                               declaredFoot: .left, settingEcho: .auto)
        XCTAssertNil(try ThermyxProtocol.decode(ThermyxProtocol.encode(legacy)).get().footDetected, "Unknown, not 'no foot'")
    }

    // MARK: Fake insole (TEMPORARY)

    func testFakeInsoleScriptIsRepeatable() {
        for activity in CalibrationActivity.allCases {
            XCTAssertEqual(FakeInsoleScript.samples(activity: activity, outdoor: false, seconds: 30, start: .distantPast),
                           FakeInsoleScript.samples(activity: activity, outdoor: false, seconds: 30, start: .distantPast))
        }
        XCTAssertGreaterThan(FakeInsoleScript.steadyFootC(activity: .walking, outdoor: false, foot: .left),
                             FakeInsoleScript.steadyFootC(activity: .sitting, outdoor: false, foot: .left))
    }

    func testFakeInsoleRecordingTrainsAUsableModel() throws {
        let segments = CalibrationPlan.steps.map {
            CalibrationTrainer.Segment(activity: $0.activity, outdoor: $0.outdoor,
                                       samples: FakeInsoleScript.samples(activity: $0.activity, outdoor: $0.outdoor,
                                                                         seconds: CalibrationPlan.secondsPerStep))
        }
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: segments, comfort: 0))
        XCTAssertTrue(model.classifier.isUsable)
        XCTAssertGreaterThanOrEqual(try XCTUnwrap(model.classifierAccuracy), 0.95)
        XCTAssertTrue(model.outdoorDone)
        XCTAssertEqual(try XCTUnwrap(model.footByActivity[.sitting]?.mean), 30.5, accuracy: 0.2, "Indoor only, right foot")
        XCTAssertFalse(model.isTestData, "The trainer doesn't mark it; the session does")
    }

    func testTestDataFlagSurvivesSaving() throws {
        var model = try XCTUnwrap(CalibrationTrainer.train(segments: indoorSegments, comfort: 0))
        model.fromTestData = true
        let decoded = try JSONDecoder().decode(PersonalThermalModel.self, from: JSONEncoder().encode(model))
        XCTAssertTrue(decoded.isTestData)
    }

    func testFakeFirmwareFollowsCommandsAndBurnCutoff() {
        let decide = ThermyxInsoleSimulator.scriptedDecision
        XCTAssertEqual(decide(.cooling, 30, 31, .ventilation), .cooling)
        XCTAssertEqual(decide(.heating, 40.2, 31, .heating), .ventilation, "Burn cutoff at 40 °C")
        XCTAssertEqual(decide(.heating, 39, 31, .ventilation), .ventilation, "Stays off until below 38.5 °C")
        XCTAssertEqual(decide(.heating, 38, 31, .ventilation), .heating)
        XCTAssertEqual(decide(.ventilation, 31.5, 31, .ventilation), .ventilation, "Auto leaves a near-target foot alone")
        XCTAssertEqual(decide(.ventilation, 33, 31, .ventilation), .cooling)
    }

    // MARK: Off, cold, battery, heating time, daily summaries

    func testOffIsConfirmedByTheInsoleReportingOff() {
        XCTAssertTrue(ThermalCommandTracker.confirms(.off, reading(mode: .off)))
        XCTAssertFalse(ThermalCommandTracker.confirms(.off, reading(mode: .cooling)))
        var echoedAuto = reading(mode: .off)
        echoedAuto.settingEcho = .auto
        XCTAssertTrue(ThermalCommandTracker.confirms(.off, echoedAuto), "Current firmware echoes Auto for Off")
        XCTAssertEqual(ThermalSetting.off.command, .off)
        XCTAssertEqual(ThermyxProtocol.command(.off), Data([1, 0]))
    }

    func testColdFootIsCautionButNeverLocksOutHeat() {
        let cold = ThermyxRiskEngine.assess(reading(footC: 23))
        XCTAssertEqual(cold.level, .caution)
        XCTAssertTrue(cold.reasons.contains { $0.contains("low") })
        let coldAndUnsteady = ThermyxRiskEngine.assess(reading(footC: 23, gait: 0.7))
        XCTAssertEqual(coldAndUnsteady.level, .caution, "Cold doesn't add to the count toward High")
        XCTAssertFalse(coldAndUnsteady.level.locksOutHeating)
    }

    func testColdNoticeAfterAMinuteThenQuiet() {
        var watch = ThermyxComfortWatch()
        let t0 = Date(timeIntervalSince1970: 1_000_000)
        let pair = BilateralReading(left: reading(footC: 24), right: nil)
        XCTAssertTrue(watch.update(pair, now: t0).isEmpty)
        XCTAssertTrue(watch.update(pair, now: t0.addingTimeInterval(30)).isEmpty)
        let notices = watch.update(pair, now: t0.addingTimeInterval(61))
        XCTAssertEqual(notices.count, 1)
        XCTAssertEqual(notices.first?.foot, .left)
        XCTAssertTrue(watch.update(pair, now: t0.addingTimeInterval(120)).isEmpty, "No repeat inside 20 minutes")
    }

    func testBatteryNoticesOnceAtTwentyAndTen() {
        var watch = ThermyxComfortWatch()
        func at(_ percent: Int) -> BilateralReading {
            var r = reading(footC: 32)
            r = ThermyxReading(foot: .left, timestamp: .now, footTemperatureC: 32, ambientTemperatureC: 25, pressureBalance: 0.5,
                               gaitStability: 0.9, batteryPercent: percent, thermalMode: .ventilation, zones: nil)
            return BilateralReading(left: r, right: nil)
        }
        XCTAssertTrue(watch.update(at(30), now: .now).isEmpty)
        XCTAssertEqual(watch.update(at(20), now: .now).count, 1)
        XCTAssertTrue(watch.update(at(18), now: .now).isEmpty)
        XCTAssertEqual(watch.update(at(10), now: .now).first?.kind, .battery(10, critical: true))
        XCTAssertTrue(watch.update(at(9), now: .now).isEmpty)
        XCTAssertTrue(watch.update(at(80), now: .now).isEmpty)
        XCTAssertEqual(watch.update(at(19), now: .now).count, 1, "Warns again after charging")
    }

    func testHistoryCreditsHeatingAndCoolingTime() {
        var sample = ThermyxHistorySample(foot: .left, start: .now)
        sample.accumulate(reading(mode: .heating), risk: .normal, elapsed: 2)
        sample.accumulate(reading(mode: .cooling), risk: .normal, elapsed: 3)
        sample.accumulate(reading(mode: .ventilation), risk: .normal, elapsed: 1)
        XCTAssertEqual(sample.trackedSeconds, 6)
        XCTAssertEqual(sample.heatingSeconds, 2)
        XCTAssertEqual(sample.coolingSeconds, 3)
    }

    func testDailySummaryGroupsByDayAndTakesTheWarmerFoot() {
        let calendar = Calendar(identifier: .gregorian)
        let day = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 10))!
        var left = ThermyxHistorySample(foot: .left, start: day)
        left.footMeanC = 31; left.footMaxC = 33; left.footMinC = 30
        left.trackedSeconds = 1800; left.heatingSeconds = 300; left.coolingSeconds = 0
        var right = ThermyxHistorySample(foot: .right, start: day)
        right.footMeanC = 36; right.footMaxC = 37; right.footMinC = 35
        right.trackedSeconds = 1200; right.heatingSeconds = 0; right.coolingSeconds = 600
        var other = ThermyxHistorySample(foot: .left, start: day.addingTimeInterval(-86_400))
        other.footMeanC = 30
        let days = ThermyxDailySummary.days(hourSamples: [left, right, other], events: [], calendar: calendar)
        XCTAssertEqual(days.count, 2)
        let today = days[0]
        XCTAssertEqual(today.wornSeconds, 1800)
        XCTAssertEqual(today.heatingSeconds, 300)
        XCTAssertEqual(today.coolingSeconds, 600)
        XCTAssertEqual(today.averageFootC, 36, "The warmer foot for the hour")
        XCTAssertEqual(today.peakFootC, 37)
        XCTAssertEqual(today.lowFootC, 30)
        XCTAssertEqual(today.feet, [.left, .right])
        XCTAssertNil(days[1].heatingSeconds, "Old buckets didn't record it")
    }

    // MARK: Tabs, profile, summaries, battery

    func testLearningLibraryIncludesTheNewTopics() {
        let ids = ThermyxLearningLibrary.articles.map(\.id)
        for id in ["how-peltier-works", "modes", "reading-insights"] { XCTAssertTrue(ids.contains(id), id) }
        XCTAssertTrue(ThermyxLearningLibrary.articles.allSatisfy { $0.icon != nil })
    }

    func testHealthConditionsAreAMultiSelectThatSurvivesSaving() throws {
        var profile = UserProfile()
        XCTAssertTrue(profile.conditionSet.isEmpty)
        profile.conditionSet = [.neuropathy, .diabetes]
        XCTAssertEqual(profile.conditions, [.diabetes, .neuropathy], "Kept in a stable order")
        let decoded = try JSONDecoder().decode(UserProfile.self, from: JSONEncoder().encode(profile))
        XCTAssertEqual(decoded.conditionSet, [.diabetes, .neuropathy])
        // A profile saved by the previous build (on/off switches) still loads.
        let old = Data(#"{"age":30,"diabetes":true}"#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(UserProfile.self, from: old).age, 30)
    }

    func testActivityFromCadenceAndStanding() {
        func r(_ cadence: Double?, _ standing: Double?) -> ThermyxReading {
            ThermyxReading(foot: .left, timestamp: .now, footTemperatureC: 31, ambientTemperatureC: nil, pressureBalance: nil,
                           gaitStability: nil, batteryPercent: nil, thermalMode: .ventilation, zones: nil,
                           cadenceStepsPerMinute: cadence, standingFraction: standing)
        }
        XCTAssertEqual(ThermyxHistorySample.activity(of: r(100, 0.1)), .walking)
        XCTAssertEqual(ThermyxHistorySample.activity(of: r(0, 0.9)), .standing)
        XCTAssertEqual(ThermyxHistorySample.activity(of: r(0, 0.1)), .sitting)
        XCTAssertNil(ThermyxHistorySample.activity(of: r(nil, nil)))
        var sample = ThermyxHistorySample(foot: .left, start: .now)
        sample.accumulate(r(120, 0.1), risk: nil, elapsed: 30)
        XCTAssertEqual(sample.steps, 60)
        XCTAssertEqual(sample.walkingSeconds, 30)
    }

    func testWeeklyReportCountsTheStreak() {
        let calendar = Calendar(identifier: .gregorian)
        let now = calendar.date(from: DateComponents(year: 2026, month: 10, day: 9, hour: 8))!
        func day(_ offset: Int, worn: TimeInterval) -> ThermyxDailySummary {
            let d = calendar.date(byAdding: .day, value: -offset, to: calendar.startOfDay(for: now))!
            return ThermyxDailySummary(day: d, wornSeconds: worn, heatingSeconds: 60, coolingSeconds: 120, averageFootC: 31,
                                       peakFootC: 33, lowFootC: 30, averageAmbientC: nil, hotHours: 0, cadenceAverage: nil,
                                       standingSeconds: nil, gaitAverage: nil, peakRisk: nil, events: 0, feet: [.left])
        }
        // Not worn yet today; worn the three days before, then a gap.
        let days = [day(1, worn: 3600), day(2, worn: 3600), day(3, worn: 1800), day(5, worn: 3600), day(9, worn: 7200)]
        let report = ThermyxWeeklyReport.make(days: days, now: now, calendar: calendar)
        XCTAssertEqual(report.streak, 3)
        XCTAssertEqual(report.daysWorn, 4)
        XCTAssertEqual(report.coolingSeconds, 480)
        XCTAssertEqual(try XCTUnwrap(report.wornChange), (12_600.0 - 7200) / 7200, accuracy: 0.001)
    }

    func testSessionEndsAfterFifteenStillMinutes() {
        var stillness = SessionStillness()
        let t0 = Date(timeIntervalSince1970: 0)
        func r(_ t: TimeInterval, _ cadence: Double) -> ThermyxReading {
            ThermyxReading(foot: .left, timestamp: t0.addingTimeInterval(t), footTemperatureC: 31, ambientTemperatureC: nil,
                           pressureBalance: nil, gaitStability: nil, batteryPercent: nil, thermalMode: .ventilation, zones: nil,
                           cadenceStepsPerMinute: cadence, standingFraction: 0.1)
        }
        XCTAssertFalse(stillness.update(r(0, 100)))
        XCTAssertFalse(stillness.update(r(25 * 60, 100)))
        XCTAssertFalse(stillness.update(r(26 * 60, 0)))
        XCTAssertFalse(stillness.update(r(40 * 60, 0)))
        XCTAssertTrue(stillness.update(r(41 * 60 + 1, 0)))
        XCTAssertFalse(stillness.update(r(50 * 60, 0)), "Once per session")
        XCTAssertFalse(stillness.endSession(), "Already summarized")
    }

    func testBatteryEstimateNeedsAReadableDrop() {
        var estimator = BatteryEstimator()
        let t0 = Date(timeIntervalSince1970: 0)
        func r(_ t: TimeInterval, _ percent: Int) -> ThermyxReading {
            ThermyxReading(foot: .left, timestamp: t0.addingTimeInterval(t), footTemperatureC: 31, ambientTemperatureC: nil,
                           pressureBalance: nil, gaitStability: nil, batteryPercent: percent, thermalMode: .ventilation, zones: nil)
        }
        estimator.add(r(0, 80))
        estimator.add(r(10 * 60, 79))
        XCTAssertNil(estimator.hoursLeft(.left), "Too soon")
        estimator.add(r(30 * 60, 75))
        XCTAssertEqual(try XCTUnwrap(estimator.hoursLeft(.left)), 7.5, accuracy: 0.01, "5 points in 30 min, 75 left")
    }

    func testTrustedCircleIsCappedAtThree() {
        let store = ThermyxSettingsStore()
        let saved = store.contacts
        defer { store.contacts = saved }
        store.contacts = []
        for i in 1...4 { store.addContact(name: "Person \(i)", phone: "+1202555010\(i)") }
        XCTAssertEqual(store.contacts.count, 3)
        XCTAssertFalse(store.canAddContact)
    }
}
