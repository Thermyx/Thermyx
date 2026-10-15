import XCTest
@testable import ThermyxApp

/// The three-minute calibration's calculus and model, the required About
/// you answers, and who counts as an admin.
final class CalibrationRedesignTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 0)

    /// A straight-line foot temperature, one reading a second.
    private func ramp(seconds: Int, from c0: Double, perMinute: Double, activity: CalibrationActivity = .sitting) -> [CalibrationSample] {
        (0..<seconds).map { i in
            CalibrationSample(time: t0.addingTimeInterval(Double(i)), footC: c0 + perMinute * Double(i) / 60, ambientC: 24,
                              load: activity == .standing ? 0.55 : 0.3, gait: activity == .walking ? 0.9 : nil,
                              cadence: activity == .walking ? 104 : 0, standing: activity == .standing ? 0.95 : 0.05)
        }
    }

    // MARK: Calculus

    func testSlopeOfALineIsItsGradient() throws {
        let slope = try XCTUnwrap(ThermalCalculus.slope(times: [0, 1, 2, 3], values: [1, 3, 5, 7]))
        XCTAssertEqual(slope, 2, accuracy: 1e-9)
        XCTAssertNil(ThermalCalculus.slope(times: [0, 1], values: [1, 2]), "Needs three points")
        XCTAssertNil(ThermalCalculus.slope(times: [4, 4, 4], values: [1, 2, 3]), "No spread in time")
    }

    func testRateIsInDegreesPerMinute() throws {
        let rate = try XCTUnwrap(ThermalCalculus.rate(ramp(seconds: 30, from: 30, perMinute: 0.6)))
        XCTAssertEqual(rate, 0.6, accuracy: 1e-6)
        XCTAssertNil(ThermalCalculus.rate(ramp(seconds: 2, from: 30, perMinute: 0.6)))
    }

    func testAccumulatedChangeIntegratesTheRate() throws {
        // 0.6 °C/min for the 27 seconds that have a fitted rate: 0.27 °C.
        let change = try XCTUnwrap(ThermalCalculus.accumulatedChange(ramp(seconds: 30, from: 30, perMinute: 0.6)))
        XCTAssertEqual(change, 0.27, accuracy: 0.01)
        let falling = try XCTUnwrap(ThermalCalculus.accumulatedChange(ramp(seconds: 30, from: 32, perMinute: -1.2)))
        XCTAssertLessThan(falling, 0)
    }

    func testOneNoisyReadingDoesntAccumulate() throws {
        var samples = ramp(seconds: 30, from: 30, perMinute: 0)
        samples[15].footC = 31
        let change = try XCTUnwrap(ThermalCalculus.accumulatedChange(samples))
        XCTAssertEqual(change, 0, accuracy: 0.05, "A spike goes up and comes back down")
    }

    func testMissingSecondsAreSkipped() throws {
        var samples = ramp(seconds: 30, from: 30, perMinute: 0.6)
        for i in 10..<14 { samples[i].footC = nil }
        XCTAssertEqual(try XCTUnwrap(ThermalCalculus.rate(samples)), 0.6, accuracy: 1e-6)
    }

    func testPhaseSummaryRecordsWhereAndHowTheFootMoved() throws {
        let summary = CalibrationPhaseSummary(activity: .walking, outdoor: true, samples: ramp(seconds: 30, from: 31, perMinute: 1.2, activity: .walking))
        XCTAssertEqual(try XCTUnwrap(summary.footMeanC), 31.29, accuracy: 0.01)
        XCTAssertEqual(try XCTUnwrap(summary.ratePerMinute), 1.2, accuracy: 1e-6)
        XCTAssertGreaterThan(try XCTUnwrap(summary.accumulatedC), 0.5)
        XCTAssertEqual(summary.cadenceMean, 104)
        XCTAssertEqual(summary.seconds, 30)
    }

    // MARK: Stability

    func testStabilityLevelsAreRelativeToTheWearersWalk() {
        let profile = StabilityProfile(mean: 0.92, sd: 0.01)
        XCTAssertEqual(profile.sd, StabilityProfile.minimumSD, "Spread is floored")
        XCTAssertEqual(profile.level(0.93), .steady)
        XCTAssertEqual(profile.level(0.89), .steady)
        XCTAssertEqual(profile.level(0.86), .variable)
        XCTAssertEqual(profile.level(0.83), .unsteady)
        XCTAssertEqual(StabilityProfile(mean: 0.84, sd: 0.02).level(0.79), .unsteady, "The fixed 80% rule always counts")
    }

    func testStabilityNeedsTenWalkingSeconds() {
        XCTAssertNil(StabilityProfile(walkingGait: Array(repeating: 0.9, count: 9)))
        XCTAssertNotNil(StabilityProfile(walkingGait: Array(repeating: 0.9, count: 10)))
    }

    // MARK: Model

    func testThreeMinutePlan() {
        XCTAssertEqual(CalibrationPlan.steps.count, 6)
        XCTAssertEqual(CalibrationPlan.secondsPerStep, 30)
        XCTAssertEqual(CalibrationPlan.totalSeconds, 180)
        XCTAssertEqual(CalibrationPlan.indoorCount, 3)
        XCTAssertEqual(CalibrationPlan.steps.map(\.activity), [.sitting, .standing, .walking, .sitting, .standing, .walking])
    }

    func testTrainerLearnsOutdoorLoadWalkingAndEachPhase() throws {
        let segments: [CalibrationTrainer.Segment] = [
            .init(activity: .sitting, outdoor: false, samples: ramp(seconds: 30, from: 30, perMinute: 0)),
            .init(activity: .standing, outdoor: false, samples: ramp(seconds: 30, from: 31, perMinute: 0, activity: .standing)),
            .init(activity: .walking, outdoor: false, samples: ramp(seconds: 30, from: 32, perMinute: 0.4, activity: .walking)),
            .init(activity: .walking, outdoor: true, samples: ramp(seconds: 30, from: 34, perMinute: 1.0, activity: .walking)),
        ]
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: segments, comfort: 0))
        XCTAssertEqual(try XCTUnwrap(model.outdoorFootByActivity?[.walking]?.mean), 34.24, accuracy: 0.01)
        XCTAssertNil(model.outdoorFootByActivity?[.sitting], "Not done outside")
        XCTAssertEqual(try XCTUnwrap(model.loadByActivity?[.standing]?.mean), 0.55, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.walkingStability?.mean), 0.9, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(model.walkingCadence?.mean), 104, accuracy: 1e-9)
        XCTAssertEqual(model.phases?.count, 4)
        XCTAssertEqual(try XCTUnwrap(model.phase(.walking, outdoor: true)?.ratePerMinute), 1.0, accuracy: 1e-6)
        XCTAssertEqual(try XCTUnwrap(model.footByActivity[.walking]).mean, 32.1, accuracy: 0.05, "Indoor usual stays indoor")
    }

    func testModelsSavedBeforeTheNewFieldsStillLoad() throws {
        let segments = [CalibrationTrainer.Segment(activity: .sitting, outdoor: false, samples: ramp(seconds: 30, from: 30, perMinute: 0))]
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: segments, comfort: 0))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        for key in ["outdoorFootByActivity", "loadByActivity", "walkingStability", "walkingCadence", "phases"] { json[key] = nil }
        let old = try JSONDecoder().decode(PersonalThermalModel.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.phases)
        XCTAssertEqual(old.footByActivity, model.footByActivity)
    }

    // MARK: About you

    func testProfileNeedsEveryAnswer() {
        var profile = UserProfile()
        XCTAssertFalse(profile.isComplete)
        profile.age = 34
        profile.sex = .female
        profile.heightCm = 170
        profile.weightKg = 62
        profile.focus = .health
        XCTAssertFalse(profile.isComplete, "Health conditions unanswered")
        profile.conditionSet = []
        XCTAssertTrue(profile.isComplete, "\"None\" is an answer")
        XCTAssertFalse(UserProfile.ageRange.contains(12), "Accounts are for 13 and over")
    }

    func testSexIsMaleOrFemaleAndOlderAnswersLoadAsUnanswered() throws {
        XCTAssertEqual(UserProfile.Sex.allCases, [.male, .female])
        let old = try JSONDecoder().decode(UserProfile.self, from: Data(#"{"age":30,"sex":"other","focus":"health"}"#.utf8))
        XCTAssertNil(old.sex)
        XCTAssertEqual(old.age, 30, "The rest of the profile survives")
        XCTAssertEqual(old.focus, .health)
    }

    // MARK: Admins

    func testAdminsAreTheThreeAccounts() {
        XCTAssertTrue(ThermyxAdmins.isAdmin(email: "aaronhanqin@gmail.com"))
        XCTAssertTrue(ThermyxAdmins.isAdmin(email: " MiheerParasnis@gmail.com "), "Case and spaces don't matter")
        XCTAssertTrue(ThermyxAdmins.isAdmin(email: "reyanshmah@gmail.com"))
        XCTAssertFalse(ThermyxAdmins.isAdmin(email: "someone@gmail.com"))
        XCTAssertFalse(ThermyxAdmins.isAdmin(email: nil))
        XCTAssertTrue(ThermyxAccount(uid: "u", email: "reyanshmah@gmail.com", displayName: nil).isAdmin)
    }
}

extension CalibrationRedesignTests {
    func testShownMathMatchesTheModel() throws {
        var samples: [CalibrationSample] = []
        for i in 0..<30 {
            samples.append(CalibrationSample(time: Date(timeIntervalSince1970: Double(i)), footC: 30 + 0.01 * Double(i) + (i % 3 == 0 ? 0.02 : 0),
                                             ambientC: nil, load: nil, gait: nil, cadence: nil, standing: nil))
        }
        let steps = ThermalCalculus.steps(samples)
        XCTAssertEqual(steps.count, 30)
        XCTAssertNil(steps[1].ratePerMinute, "Two readings make no slope")
        XCTAssertEqual(try XCTUnwrap(steps.last?.ratePerMinute), try XCTUnwrap(ThermalCalculus.rate(samples)), accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(steps.last?.accumulated), try XCTUnwrap(ThermalCalculus.accumulatedChange(samples)), accuracy: 1e-9)
        let last = try XCTUnwrap(steps.last)
        XCTAssertEqual(last.covariance / last.spread * 60, try XCTUnwrap(last.ratePerMinute), accuracy: 1e-9, "The shown fraction is the slope")
        XCTAssertEqual(steps.compactMap(\.area).reduce(0, +), try XCTUnwrap(last.accumulated), accuracy: 1e-9, "The trapezoids add up to ∫")
    }
}

extension CalibrationRedesignTests {
    func testArchOnlyLoadFlagRoundTrips() throws {
        var t = ThermyxProtocol.Telemetry(version: 3, mode: .ventilation, batteryPercent: nil, footTemperatureC: 31,
                                          ambientTemperatureC: nil, gaitStability: nil, pressureBalance: 0.42,
                                          declaredFoot: .left, settingEcho: .auto)
        t.loadIsArchLevel = true
        t.footDetected = true
        let decoded = try ThermyxProtocol.decode(ThermyxProtocol.encode(t)).get()
        XCTAssertTrue(decoded.loadIsArchLevel)
        XCTAssertEqual(decoded.footDetected, true, "Bit 7 leaves the foot bits alone")
        XCTAssertEqual(decoded.reading(for: .left).loadLabel, "Arch load")
        t.loadIsArchLevel = false
        XCTAssertEqual(try ThermyxProtocol.decode(ThermyxProtocol.encode(t)).get().reading(for: .left).loadLabel, "Forefoot load")
    }
}
