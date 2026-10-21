import XCTest
@testable import ThermyxApp

final class MLStatisticsTests: XCTestCase {

    func testMedianMadAndRobustSpread() throws {
        let xs = [1.0, 2, 3, 4, 100]
        XCTAssertEqual(try XCTUnwrap(RobustStats.median(xs)), 3)
        XCTAssertEqual(try XCTUnwrap(RobustStats.mad(xs)), 1)
        XCTAssertEqual(try XCTUnwrap(RobustStats.robustSD(xs)), 1.4826, accuracy: 1e-9)
        XCTAssertGreaterThan(try XCTUnwrap(RobustStats.sd(xs)), 40, "The ordinary spread is wrecked by one wild value")
        XCTAssertNil(RobustStats.median([]))
        XCTAssertNil(RobustStats.robustSD([1, 2]), "Two values have no spread worth quoting")
        XCTAssertEqual(try XCTUnwrap(RobustStats.quantile([0, 10], 0.25)), 2.5, accuracy: 1e-12)
        XCTAssertEqual(try XCTUnwrap(RobustStats.trimmedMean([1, 2, 3, 4, 100], fraction: 0.2)), 3, accuracy: 1e-12)
    }

    func testOutlierRejectionNeedsEnoughDataAndNeverEatsMostOfIt() {
        let few = [1.0, 1, 1, 50]
        XCTAssertEqual(RobustStats.rejectingOutliers(few, floor: 0.1).kept, few, "Four values can't judge an outlier")
        let many = [10.0, 10.1, 9.9, 10.2, 9.8, 10.0, 10.1, 9.9, 60]
        let result = RobustStats.rejectingOutliers(many, floor: 0.1)
        XCTAssertEqual(result.rejected, 1)
        XCTAssertFalse(result.kept.contains(60))
        // Two clusters: dropping one would be dropping half the data.
        let split = Array(repeating: 0.0, count: 6) + Array(repeating: 100.0, count: 6) + [50]
        XCTAssertEqual(RobustStats.rejectingOutliers(split, floor: 0.1).rejected, 0)
        // A perfectly steady series doesn't make everything an outlier.
        XCTAssertEqual(RobustStats.rejectingOutliers(Array(repeating: 5.0, count: 10), floor: 0.5).rejected, 0)
    }

    func testWilsonIntervalMatchesKnownValuesAndIsHonestAboutSmallSamples() throws {
        let nine = try XCTUnwrap(RobustStats.wilsonInterval(successes: 9, total: 10))
        XCTAssertEqual(nine.lowerBound, 0.5958, accuracy: 0.001)
        XCTAssertEqual(nine.upperBound, 0.9821, accuracy: 0.001)
        let all = try XCTUnwrap(RobustStats.wilsonInterval(successes: 18, total: 18))
        XCTAssertEqual(all.upperBound, 1, accuracy: 1e-9)
        XCTAssertLessThan(all.lowerBound, 0.85, "18 for 18 does not prove 100%")
        XCTAssertNil(RobustStats.wilsonInterval(successes: 1, total: 0))
    }

    func testRollingSeriesIsBoundedAndIgnoresNonFiniteValues() {
        var s = RollingSeries(capacity: 5)
        for i in 0..<10 { s.append(Double(i)) }
        s.append(.nan); s.append(.infinity)
        XCTAssertEqual(s.values, [5, 6, 7, 8, 9])
        XCTAssertEqual(s.median, 7)
    }

    // MARK: Shrinkage

    func testPriorWeightIsAllOfItWithNoDataAndFallsRoughlyAsOneOverN() {
        let none = Shrinkage.blend(sampleMean: nil, withinSD: 1, effectiveN: 0, priorMean: 5, priorSD: 2)
        XCTAssertEqual(none.mean, 5)
        XCTAssertEqual(none.priorWeight, 1)
        var previous = 1.0
        for n in [1.0, 2, 4, 8, 16, 32, 64] {
            let e = Shrinkage.blend(sampleMean: 10, withinSD: 1, effectiveN: n, priorMean: 0, priorSD: 2)
            XCTAssertLessThan(e.priorWeight, previous)
            // Exact formula: (1/τ²) / (1/τ² + n/σ²).
            XCTAssertEqual(e.priorWeight, 0.25 / (0.25 + n), accuracy: 1e-12)
            XCTAssertEqual(e.mean, 10 * (1 - e.priorWeight), accuracy: 1e-12)
            previous = e.priorWeight
        }
    }

    func testANarrowPopulationIsTrustedLongerThanAWideOne() {
        let narrow = Shrinkage.blend(sampleMean: 10, withinSD: 1, effectiveN: 5, priorMean: 0, priorSD: 0.5)
        let wide = Shrinkage.blend(sampleMean: 10, withinSD: 1, effectiveN: 5, priorMean: 0, priorSD: 5)
        XCTAssertGreaterThan(narrow.priorWeight, wide.priorWeight * 10)
    }

    func testBoundedLimitsHowFarAPriorCanPullAndVarianceShrinkageBlends() {
        let wild = Shrinkage.blend(sampleMean: 33, withinSD: 0.5, effectiveN: 1, priorMean: 20, priorSD: 0.01)
        XCTAssertEqual(Shrinkage.bounded(wild, around: 33, maxPull: 1).mean, 32, accuracy: 1e-12)
        XCTAssertEqual(Shrinkage.bounded(wild, around: nil, maxPull: 1).mean, wild.mean, "Nothing to bound against")
        XCTAssertEqual(Shrinkage.variance(sample: nil, degrees: 0, prior: 4, priorDegrees: 10), 4)
        XCTAssertEqual(Shrinkage.variance(sample: 1, degrees: 10, prior: 4, priorDegrees: 10), 2.5, accuracy: 1e-12)
        XCTAssertEqual(Shrinkage.effectiveCount(30, correlationFactor: 6), 5)
        XCTAssertEqual(Shrinkage.effectiveCount(30, correlationFactor: 0.2), 30, "Never more than one look per reading")
    }
}
