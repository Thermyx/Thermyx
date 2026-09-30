import XCTest
@testable import ThermyxApp

@MainActor
final class FormattingAndModelTests: XCTestCase {

    func testGapFormatNamesTheFoot() {
        XCTAssertEqual(GapFormat.degrees(2.14), "Left +2.1°")
        XCTAssertEqual(GapFormat.degrees(-2.14), "Right +2.1°")
        XCTAssertEqual(GapFormat.degrees(0.01), "Even")
        XCTAssertEqual(GapFormat.points(-8), "Right +8 pts")
    }

    func testDurationsUseOneFormat() {
        XCTAssertEqual(DurationFormat.long(92 * 60), "1h 32m")
        XCTAssertEqual(DurationFormat.long(18 * 60), "18m")
    }

    func testDeviceIDsAreUniqueAndReadable() {
        let ids = Set((0..<200).map { _ in ThermyxSettingsStore.makeDeviceID() })
        XCTAssertGreaterThan(ids.count, 195)
        for id in ids {
            XCTAssertTrue(id.hasPrefix("thermyx-"))
            XCTAssertEqual(id.count, "thermyx-".count + 6)
            XCTAssertFalse(id.contains("0") || id.contains("o") || id.contains("1") || id.contains("l"))
        }
    }

    func testOlderAlertEventsStillDecode() throws {
        // An event from a build that predates kind / per-foot readings.
        let json = #"{"deviceID":"thermyx-right-01","level":"Caution","reasons":["Hot."],"recipients":[],"timestamp":780000000,"readings":{"footTemperatureC":36.1}}"#
        let event = try JSONDecoder().decode(ThermyxAlertEvent.self, from: Data(json.utf8))
        XCTAssertNil(event.kind)
        XCTAssertNil(event.bilateral)
        XCTAssertEqual(event.readings.footTemperatureC, 36.1)
    }

    func testEventRoundTripsBothFeetAndLocation() throws {
        var event = ThermyxAlertEvent(
            deviceID: "thermyx-abc234",
            level: "High risk",
            reasons: [],
            recipients: [],
            timestamp: .now,
            readings: .init(footTemperatureC: 39, ambientTemperatureC: 30, gaitStability: 0.9, pressureBalance: 0.5, batteryPercent: 70)
        )
        event.kind = .alert
        event.left = event.readings
        event.location = .init(latitude: 29.76, longitude: -95.37, accuracyM: 50)
        let decoded = try JSONDecoder().decode(ThermyxAlertEvent.self, from: JSONEncoder().encode(event))
        XCTAssertEqual(decoded.kind, .alert)
        XCTAssertEqual(decoded.bilateral?.left?.footTemperatureC, 39)
        XCTAssertNil(decoded.bilateral?.right)
        XCTAssertEqual(decoded.location, event.location)
    }

    func testSensorSitesMatchTheHardware() {
        XCTAssertEqual(SoleGeometry.SensorSite.allCases.count, 3)
        XCTAssertEqual(Set(SoleGeometry.SensorSite.allCases.map(\.zone)), Set(FootZone.allCases))
    }

    func testTargetRangeStaysUnderTheBurnLimit() {
        XCTAssertLessThan(ThermyxSettingsStore.targetRange.upperBound, ThermyxRiskEngine.burnLimitC)
    }
}
