import XCTest
@testable import ThermyxApp

/// Synthetic calibration sessions: a wearer sits, stands and walks indoors and
/// outdoors, with sensor noise and the day-to-day offsets real recordings have.
enum MLCalibrationData {
    struct Style {
        /// Multiplies every noise term.
        var noise = 1.0
        /// Slow walking, fidgety standing and restless sitting: classes that
        /// genuinely overlap.
        var hard = false
        /// Each segment gets its own offsets (shoe, floor, mood), shared by
        /// every window in it.
        var segmentOffset = 0.0
    }

    static func segments(seconds: Int = 30, seed: UInt64 = 1, style: Style = Style(), plan: [(CalibrationActivity, Bool)]? = nil) -> [CalibrationTrainer.Segment] {
        var rng = MLRandom(seed: seed)
        let steps = plan ?? [(.sitting, false), (.standing, false), (.walking, false), (.sitting, true), (.standing, true), (.walking, true)]
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        return steps.map { activity, outdoor in
            let loadOffset = style.segmentOffset * 0.08 * rng.normal()
            let cadenceOffset = style.segmentOffset * 8 * rng.normal()
            let standingOffset = style.segmentOffset * 0.1 * rng.normal()
            // Slow wandering that does not average out across a 10 s window:
            // how still the person is holding, how hard they are pressing.
            var latent = (cadence: 0.0, standing: 0.0, load: 0.0)
            func wander(_ x: inout Double, sd: Double, rng: inout MLRandom) -> Double {
                x = 0.93 * x + (1 - 0.93 * 0.93).squareRoot() * sd * rng.normal()
                return x
            }
            let samples: [CalibrationSample] = (0..<seconds).map { i in
                let n = style.noise
                let time = t.addingTimeInterval(Double(i))
                let load: Double, cadence: Double, standing: Double
                switch (activity, style.hard) {
                case (.sitting, false):
                    load = 0.06 + 0.01 * n * rng.normal(); cadence = 0; standing = 0.04 + 0.02 * n * rng.normal()
                case (.standing, false):
                    load = 0.48 + 0.02 * n * rng.normal() + 0.02 * sin(Double(i) / 3); cadence = 0; standing = 0.92 + 0.03 * n * rng.normal()
                case (.walking, false):
                    load = 0.55 + 0.16 * sin(Double(i) * 1.7) + 0.02 * n * rng.normal()
                    cadence = 104 + 7 * sin(Double(i) / 6.5) + 3 * n * rng.normal(); standing = 0.12 + 0.03 * n * rng.normal()
                case (.sitting, true):
                    // Restless: shifting weight, sometimes half-standing.
                    load = 0.17 + wander(&latent.load, sd: 0.08 * n, rng: &rng) + 0.04 * n * rng.normal()
                    cadence = max(0, 3 + wander(&latent.cadence, sd: 6 * n, rng: &rng))
                    standing = 0.33 + wander(&latent.standing, sd: 0.14 * n, rng: &rng)
                case (.standing, true):
                    // Swaying and shuffling.
                    load = 0.40 + wander(&latent.load, sd: 0.07 * n, rng: &rng) + 0.05 * sin(Double(i) / 2) + 0.03 * n * rng.normal()
                    cadence = max(0, 10 + wander(&latent.cadence, sd: 10 * n, rng: &rng))
                    standing = 0.62 + wander(&latent.standing, sd: 0.14 * n, rng: &rng)
                case (.walking, true):
                    // Slow, hesitant.
                    load = 0.46 + wander(&latent.load, sd: 0.05 * n, rng: &rng) + 0.08 * sin(Double(i) * 1.1) + 0.04 * n * rng.normal()
                    cadence = max(0, 38 + wander(&latent.cadence, sd: 14 * n, rng: &rng))
                    standing = 0.50 + wander(&latent.standing, sd: 0.14 * n, rng: &rng)
                }
                return CalibrationSample(
                    time: time, footC: 31 + 0.1 * rng.normal() + (outdoor ? 1.2 : 0), ambientC: outdoor ? 31 : 23,
                    load: min(1, max(0, load + loadOffset)), gait: 0.9 + 0.01 * rng.normal(),
                    cadence: max(0, cadence + (cadence > 20 ? cadenceOffset : 0)), standing: min(1, max(0, standing + standingOffset))
                )
            }
            t = t.addingTimeInterval(Double(seconds))
            return CalibrationTrainer.Segment(activity: activity, outdoor: outdoor, samples: samples)
        }
    }

    static func windows(_ segments: [CalibrationTrainer.Segment]) -> [LabelledWindows] {
        segments.enumerated().map { LabelledWindows(activity: $1.activity, segment: $0, windows: ActivityFeatures.windows($1.samples)) }
    }
}

final class MLClassifierTests: XCTestCase {

    private func evaluate(_ segments: [CalibrationTrainer.Segment]) throws -> ClassifierEvaluation {
        try XCTUnwrap(ClassifierEvaluation.evaluate(MLCalibrationData.windows(segments)))
    }

    // MARK: Honest evaluation

    func testHeldOutAccuracyOfTheRealCalibrationLengthIsHighButFlaggedAsSmall() throws {
        let report = try evaluate(MLCalibrationData.segments(seconds: 30))
        print("ML-REPORT real calibration (30 s x 6): \(report.summary); ECE raw \(report.expectedCalibrationErrorRaw) -> \(report.expectedCalibrationError); reliable \(report.isReliable); \(report.warnings)")
        XCTAssertEqual(report.method, .leaveOneSegmentOut, "Each activity was recorded indoors and out, so whole segments are held out")
        XCTAssertEqual(report.folds, 6)
        XCTAssertEqual(report.windows, 18)
        XCTAssertGreaterThanOrEqual(report.accuracy, 0.9)
        XCTAssertFalse(report.isReliable, "Eighteen windows is too few to quote")
        XCTAssertTrue(report.warnings.contains { $0.contains("rough") })
        XCTAssertLessThan(report.accuracyInterval[0], report.accuracy)
        XCTAssertGreaterThan(report.accuracyInterval[1], report.accuracy - 1e-9)
        XCTAssertLessThan(report.accuracyInterval[0], 0.9, "With 18 windows the interval is wide")
        XCTAssertGreaterThanOrEqual(report.temperature, 1)
    }

    func testALongerCalibrationEarnsAReliableReport() throws {
        let report = try evaluate(MLCalibrationData.segments(seconds: 120, seed: 4))
        print("ML-REPORT long calibration (120 s x 6): \(report.summary); reliable \(report.isReliable)")
        XCTAssertTrue(report.isReliable)
        XCTAssertEqual(report.windows, 72)
        XCTAssertGreaterThanOrEqual(report.accuracy, 0.95)
        XCTAssertEqual(report.classCounts, ["sitting": 24, "standing": 24, "walking": 24])
        XCTAssertEqual(report.confusion.values.map { $0.values.reduce(0, +) }.reduce(0, +), 72)
    }

    func testOverlappingActivitiesAreReportedAsHardNotPerfect() throws {
        let segments = MLCalibrationData.segments(seconds: 150, seed: 9, style: .init(noise: 0.8, hard: true))
        let report = try evaluate(segments)
        print("ML-REPORT hard/overlapping (150 s x 6): \(report.summary); recall \(report.recall); ECE raw \(report.expectedCalibrationErrorRaw) -> \(report.expectedCalibrationError); brier \(report.brierCalibrated)")
        XCTAssertLessThan(report.accuracy, 0.99, "Overlapping classes must not score perfectly")
        XCTAssertGreaterThan(report.accuracy, 0.5, "...but they are still better than guessing")
        XCTAssertLessThanOrEqual(report.logLossCalibrated, report.logLossRaw + 1e-9, "Softening never hurts held-out log loss")
        XCTAssertLessThanOrEqual(report.expectedCalibrationError, report.expectedCalibrationErrorRaw + 0.02)
        XCTAssertLessThan(report.expectedCalibrationError, 0.15, "Stated confidence is close to how often it is right")
        XCTAssertGreaterThan(report.temperature, 1, "Naive Bayes is overconfident here, so it is softened")
    }

    func testHeavyOverlapIsSoftenedAndTheCalibrationErrorFalls() throws {
        let report = try evaluate(MLCalibrationData.segments(seconds: 150, seed: 9, style: .init(noise: 1.6, hard: true)))
        print("ML-REPORT heavy overlap (150 s x 6): \(report.summary); ECE raw \(report.expectedCalibrationErrorRaw) -> \(report.expectedCalibrationError)")
        XCTAssertLessThan(report.accuracy, 0.8)
        XCTAssertGreaterThan(report.temperature, 2, "Very overconfident raw, so strongly softened")
        XCTAssertLessThan(report.logLossCalibrated, report.logLossRaw * 0.8)
        XCTAssertLessThan(report.expectedCalibrationError, report.expectedCalibrationErrorRaw * 0.7)
        XCTAssertFalse(report.isReliable && report.accuracy > 0.9)
    }

    func testLeaveOneWindowOutIsOptimisticWhereHeldOutSegmentsAreNot() throws {
        // Each segment has its own offsets, as real recordings do. Windows of
        // one segment are near-copies, so holding out one of them while its
        // siblings are in training says little about a new stretch of wear.
        let segments = MLCalibrationData.segments(seconds: 90, seed: 21, style: .init(noise: 0.7, hard: true, segmentOffset: 1.0))
        var training: [CalibrationActivity: [ActivityFeatures]] = [:]
        for s in segments { training[s.activity, default: []] += ActivityFeatures.windows(s.samples) }
        let looAccuracy = try XCTUnwrap(ActivityClassifier.leaveOneOutAccuracy(training))
        let heldOut = try evaluate(segments)
        print("ML-REPORT optimism: leave-one-window-out \(looAccuracy) vs leave-one-segment-out \(heldOut.accuracy)")
        XCTAssertGreaterThan(looAccuracy, heldOut.accuracy, "The old check flatters the model")
    }

    func testBlockedKFoldWhenEachActivityWasRecordedOnce() throws {
        let plan: [(CalibrationActivity, Bool)] = [(.sitting, false), (.standing, false), (.walking, false)]
        let report = try evaluate(MLCalibrationData.segments(seconds: 60, seed: 3, plan: plan))
        XCTAssertEqual(report.method, .blockedKFold)
        XCTAssertEqual(report.windows, 18)
        XCTAssertTrue(report.warnings.contains { $0.contains("same stretch") }, "Says plainly that this is a weaker test")
        XCTAssertGreaterThanOrEqual(report.accuracy, 0.9)
    }

    func testClassImbalanceIsVisibleAndDoesNotInflateTheHeadline() throws {
        // Lots of sitting, a little of everything else.
        let plan: [(CalibrationActivity, Bool)] = [(.sitting, false), (.sitting, true), (.sitting, false), (.sitting, true),
                                                   (.standing, false), (.standing, true), (.walking, false), (.walking, true)]
        var segments = MLCalibrationData.segments(seconds: 20, seed: 8, style: .init(noise: 2.0, hard: true), plan: plan)
        // Give sitting much more data.
        segments[0].samples += MLCalibrationData.segments(seconds: 180, seed: 15, style: .init(noise: 2.0, hard: true), plan: [(.sitting, false)])[0].samples
        let report = try evaluate(segments)
        XCTAssertTrue(report.warnings.contains { $0.contains("unbalanced") })
        XCTAssertGreaterThan(report.classCounts["sitting"] ?? 0, 3 * (report.classCounts["standing"] ?? 1))
        // Balanced accuracy is the mean of the recalls, whatever the mix.
        XCTAssertEqual(report.balancedAccuracy, report.recall.values.reduce(0, +) / Double(report.recall.count), accuracy: 1e-12)
    }

    func testNothingToHoldOutMeansNoReport() {
        XCTAssertNil(ClassifierEvaluation.evaluate([]))
        let one = MLCalibrationData.windows(MLCalibrationData.segments(plan: [(.sitting, false), (.sitting, true)]))
        XCTAssertNil(ClassifierEvaluation.evaluate(one), "A single activity has nothing to tell apart")
    }

    // MARK: Calibrated probabilities

    func testTemperatureScalingKeepsTheAnswerAndSoftensTheConfidence() throws {
        let segments = MLCalibrationData.segments(seconds: 150, seed: 9, style: .init(noise: 0.8, hard: true))
        var training: [CalibrationActivity: [ActivityFeatures]] = [:]
        for s in segments { training[s.activity, default: []] += ActivityFeatures.windows(s.samples) }
        let raw = ActivityClassifier(training: training)
        var soft = raw
        soft.calibrate(temperature: 4)
        for window in ActivityFeatures.windows(segments[0].samples) {
            XCTAssertEqual(raw.predict(window)?.activity, soft.predict(window)?.activity)
            XCTAssertLessThanOrEqual(soft.predict(window)!.confidence, raw.predict(window)!.confidence + 1e-12)
        }
        var ignored = raw
        ignored.calibrate(temperature: 0.2)
        XCTAssertEqual(ignored.temperature, nil, "It only ever softens")
        let p = try XCTUnwrap(soft.probabilities(ActivityFeatures.windows(segments[2].samples)[0]))
        XCTAssertEqual(p.values.reduce(0, +), 1, accuracy: 1e-9)
    }

    func testTrainerStoresTheHonestNumbersAndUsesThemForAccuracy() throws {
        let segments = MLCalibrationData.segments(seconds: 30)
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: segments, comfort: 0))
        let report = try XCTUnwrap(model.classifierReport)
        XCTAssertEqual(model.classifierAccuracy, report.accuracy)
        XCTAssertEqual(model.classifier.temperature, report.temperature > 1 ? report.temperature : nil)
        let restored = try JSONDecoder().decode(PersonalThermalModel.self, from: JSONEncoder().encode(model))
        XCTAssertEqual(restored, model)
    }

    func testModelsSavedBeforeTheseFieldsExistedStillLoad() throws {
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: MLCalibrationData.segments(), comfort: 0))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(model)) as? [String: Any])
        for key in ["classifierReport", "footCounts", "rawFootByActivity", "footPriorWeight"] { json[key] = nil }
        var classifier = try XCTUnwrap(json["classifier"] as? [String: Any])
        classifier["temperature"] = nil
        classifier["windowCounts"] = nil
        json["classifier"] = classifier
        let old = try JSONDecoder().decode(PersonalThermalModel.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(old.classifierReport)
        XCTAssertNil(old.classifier.temperature)
        XCTAssertTrue(old.classifier.isUsable)
        XCTAssertNotNil(old.classifier.predict(ActivityFeatures.windows(MLCalibrationData.segments()[2].samples)[0]))
    }

    // MARK: Robust fitting

    func testAStumbleInTheStandingMinuteDoesNotWidenWhatStandingLooksLike() throws {
        let clean = MLCalibrationData.segments(seconds: 120, seed: 5, plan: [(.sitting, false), (.standing, false), (.walking, false)])
        var dirty = clean
        // Ten seconds of walking-like steps inside the standing recording.
        for i in 30..<40 { dirty[1].samples[i].cadence = 100; dirty[1].samples[i].load = 0.7 }
        func fit(_ segs: [CalibrationTrainer.Segment]) -> ActivityClassifier {
            var training: [CalibrationActivity: [ActivityFeatures]] = [:]
            for s in segs { training[s.activity, default: []] += ActivityFeatures.windows(s.samples) }
            return ActivityClassifier(training: training)
        }
        let a = fit(clean).distributions[.standing]![0]!, b = fit(dirty).distributions[.standing]![0]!
        print("ML-REPORT outlier rejection: standing cadence variance clean \(a.variance) vs with stumble \(b.variance)")
        XCTAssertEqual(b.variance, a.variance, accuracy: a.variance * 0.5 + 1, "One odd window barely moves it")
    }

    func testSmallClassesGetTheirVarianceShrunkTowardThePool() {
        // Two windows of a still posture claim a variance near zero; the
        // pooled variance keeps that from becoming near-certainty.
        let still = ActivityFeatures(cadence: 0, standing: 0.9, load: 0.5, loadSpread: 0.01, gait: nil)
        let moving = (0..<12).map { i in ActivityFeatures(cadence: 70 + Double(i * 5), standing: 0.1, load: 0.5, loadSpread: 0.1, gait: nil) }
        let model = ActivityClassifier(training: [.standing: [still, still], .walking: moving])
        let v = model.distributions[.standing]![0]!.variance
        XCTAssertGreaterThan(v, ActivityClassifier.varianceFloor[0], "Pooled with the walking variance")
    }

    func testExplanationNamesTheFeaturesThatDecidedIt() throws {
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: MLCalibrationData.segments(), comfort: 0))
        let walking = ActivityFeatures.windows(MLCalibrationData.segments()[2].samples)[0]
        let why = try XCTUnwrap(model.classifier.contributions(walking))
        XCTAssertEqual(why.activity, .walking)
        XCTAssertEqual(why.items.first?.feature, "Step rate", "Cadence is what separates walking from the rest")
        XCTAssertGreaterThan(why.items.first?.logOdds ?? 0, 5)
        XCTAssertEqual(Set(why.items.map(\.feature)).isSubset(of: Set(ActivityFeatures.names)), true)
    }

    func testMissingFeaturesAreSkippedNotInvented() throws {
        let model = try XCTUnwrap(CalibrationTrainer.train(segments: MLCalibrationData.segments(), comfort: 0))
        let onlyCadence = ActivityFeatures(cadence: 105, standing: nil, load: nil, loadSpread: nil, gait: nil)
        XCTAssertEqual(model.classifier.predict(onlyCadence)?.activity, .walking)
        let nothing = ActivityFeatures(cadence: nil, standing: nil, load: nil, loadSpread: nil, gait: nil)
        XCTAssertNil(model.classifier.predict(nothing))
    }
}
