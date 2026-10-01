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
}
