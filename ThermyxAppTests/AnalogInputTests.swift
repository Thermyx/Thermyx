import XCTest
@testable import ThermyxApp

/// The XIAO test-board path: parsing the text value, the percent and volts,
/// and the rule that a test input never becomes a temperature.
@MainActor
final class AnalogInputTests: XCTestCase {

    override func tearDown() {
        AnalogTemperatureCalibration.current = nil
        super.tearDown()
    }

    private func parse(_ text: String) -> Int? {
        ThermyxSensorProtocol.parse(Data(text.utf8))
    }

    func testParsesTheFirmwareTextFormat() {
        XCTAssertEqual(parse("2048"), 2048)
        XCTAssertEqual(parse("0"), 0)
        XCTAssertEqual(parse("4095"), 4095)
        XCTAssertEqual(parse(" 1234\r\n"), 1234, "Whitespace and line endings are tolerated")
        XCTAssertEqual(parse("12\0"), 12, "A trailing C-string terminator is tolerated")
    }

    func testRejectsAnythingOutsideTheContract() {
        XCTAssertNil(parse("4096"))
        XCTAssertNil(parse("-1"))
        XCTAssertNil(parse(""))
        XCTAssertNil(parse("abc"))
        XCTAssertNil(parse("20.5"))
        XCTAssertNil(parse("1e3"))
        XCTAssertNil(parse("٢٠٤٨"), "Only ASCII digits")
        XCTAssertNil(ThermyxSensorProtocol.parse(Data([0xFF, 0xFE])), "Not UTF-8")
    }

    func testPercentAndVoltsSpanTheFullScale() {
        XCTAssertEqual(AnalogInput(raw: 0, kind: .testInput).percent, 0)
        XCTAssertEqual(AnalogInput(raw: 4095, kind: .testInput).percent, 100)
        XCTAssertEqual(AnalogInput(raw: 2048, kind: .testInput).percent, 50.01, accuracy: 0.01)
        XCTAssertEqual(AnalogInput(raw: 4095, kind: .testInput).volts, 3.3, accuracy: 0.0001)
    }

    func testATestInputIsNeverATemperature() {
        AnalogTemperatureCalibration.current = .ntcDivider()
        XCTAssertNil(AnalogInput(raw: 2048, kind: .testInput).temperatureC)
        XCTAssertNil(AnalogInput(raw: 2048, kind: .fsrLoad).temperatureC)
    }

    func testTemperatureNeedsACalibration() {
        XCTAssertNil(AnalogInput(raw: 2048, kind: .temperature).temperatureC)
        XCTAssertFalse(AnalogSourceKind.temperature.isAvailable)
        XCTAssertTrue(AnalogSourceKind.testInput.isAvailable)
        XCTAssertTrue(AnalogSourceKind.fsrLoad.isAvailable)
    }

    func testCalibrationsConvertAsDocumented() throws {
        // 10 kΩ NTC against 10 kΩ: half scale is the nominal 25 °C.
        AnalogTemperatureCalibration.current = .ntcDivider()
        XCTAssertEqual(try XCTUnwrap(AnalogInput(raw: 2048, kind: .temperature).temperatureC), 25, accuracy: 0.1)
        XCTAssertNil(AnalogInput(raw: 0, kind: .temperature).temperatureC, "Shorted sensor reads as missing")

        // TMP36: 750 mV is 25 °C.
        AnalogTemperatureCalibration.current = .linear(offsetMillivolts: 500, millivoltsPerC: 10)
        let raw = Int((750.0 / 3300.0 * 4095).rounded())
        XCTAssertEqual(try XCTUnwrap(AnalogInput(raw: raw, kind: .temperature).temperatureC), 25, accuracy: 0.2)
    }

    func testMinuteBucketsKeepMeanMinAndMax() {
        var sample = AnalogSample(start: .now, kind: .testInput)
        for raw in [1000, 2000, 3000] { sample.add(raw) }
        XCTAssertEqual(sample.count, 3)
        XCTAssertEqual(sample.rawMean, 2000)
        XCTAssertEqual(sample.rawMin, 1000)
        XCTAssertEqual(sample.rawMax, 3000)
        XCTAssertEqual(sample.percentMean, 2000.0 / 4095 * 100, accuracy: 0.001)
    }

    func testAnalogOnlyReadingsAreNotBodyData() {
        var reading = ThermyxReading(foot: .left, timestamp: .now, footTemperatureC: nil, ambientTemperatureC: nil,
                                     pressureBalance: nil, gaitStability: nil, batteryPercent: nil, thermalMode: .off)
        reading.analogInput = AnalogInput(raw: 3000, kind: .testInput)
        XCTAssertFalse(reading.hasSensorData)
        XCTAssertEqual(ThermyxRiskEngine.assess(reading).level, .unavailable, "A knob never raises a risk level")
    }

    func testStatusLabels() {
        XCTAssertEqual(SensorLinkStatus.searching.label, "Searching…")
        XCTAssertEqual(SensorLinkStatus.connected("Thermyx").label, "Connected · Thermyx")
        XCTAssertEqual(SensorLinkStatus.disconnected(reconnecting: true).label, "Disconnected · reconnecting…")
    }

    // MARK: - FSR402 force

    func testFSRBelowFifteenCountsIsNoTouch() {
        XCTAssertEqual(FSR402.forceNewtons(raw: 0, scale: 1), 0)
        XCTAssertEqual(FSR402.forceNewtons(raw: 14, scale: 1), 0)
        XCTAssertGreaterThan(FSR402.forceNewtons(raw: 15, scale: 1), 0)
    }

    func testFSRFollowsTheDocumentedFormula() {
        // raw 2048: V = 1.6504, R = 9,995 Ω, G = 100.05 µS, F = 1.2506 N.
        let force = FSR402.forceNewtons(raw: 2048, scale: 1)
        XCTAssertEqual(force, 1.2506, accuracy: 0.0005)
        XCTAssertEqual(FSR402.pressureKPa(forceN: force), 9.8706, accuracy: 0.005)
        XCTAssertEqual(FSR402.forceNewtons(raw: 1000, scale: 1), 0.4039, accuracy: 0.0005)
        XCTAssertEqual(FSR402.forceNewtons(raw: 3000, scale: 1), 3.4247, accuracy: 0.0005)
    }

    func testFSRFullScaleClampsInsteadOfDividingByZero() {
        let force = FSR402.forceNewtons(raw: 4095, scale: 1)
        XCTAssertTrue(force.isFinite)
        XCTAssertEqual(force, 20)
        XCTAssertEqual(FSR402.forceNewtons(raw: 4000, scale: 1), 20, "Clamped at 20 N")
        XCTAssertEqual(FSR402.conductanceMicrosiemens(raw: 0), 0)
        XCTAssertEqual(FSR402.conductanceMicrosiemens(raw: 4095), .infinity)
    }

    func testFSRScaleMultipliesAfterTheClamp() {
        XCTAssertEqual(FSR402.forceNewtons(raw: 2048, scale: 2), 2.5012, accuracy: 0.001)
        XCTAssertEqual(FSR402.forceNewtons(raw: 4095, scale: 1.5), 30)
        XCTAssertEqual(FSR402.forceNewtons(raw: 10, scale: 3), 0)
    }

    func testOnlyFSRSourcesHaveAForce() {
        XCTAssertNil(AnalogInput(raw: 2048, kind: .testInput).forceN)
        XCTAssertNotNil(AnalogInput(raw: 2048, kind: .fsrLoad).forceN)
    }

    func testMinuteBucketsAverageForce() {
        var sample = AnalogSample(start: .now, kind: .fsrLoad)
        sample.add(2048, forceN: 1.0)
        sample.add(3000, forceN: 3.0)
        XCTAssertEqual(try XCTUnwrap(sample.forceMeanN), 2.0, accuracy: 0.0001)
    }
}
