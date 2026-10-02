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
}
