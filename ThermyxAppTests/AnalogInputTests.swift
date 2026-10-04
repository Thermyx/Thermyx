import XCTest
@testable import ThermyxApp

/// The single-sensor test board: the TYPE,CHANNEL,VALUE protocol, unit
/// conversions, the main-page rule, the 5-second timeout, and the reconnect
/// rules.
final class AnalogInputTests: XCTestCase {

    private func parse(_ text: String) -> SensorPacket? {
        ThermyxSensorProtocol.parse(Data(text.utf8))
    }

    private func key(_ type: SensorType, _ channel: Int = 0) -> SensorKey {
        SensorKey(type: type, channel: channel)
    }

    // MARK: - Parsing

    func testParsesTypedLines() {
        XCTAssertEqual(parse("NTC,0,2410"), SensorPacket(key: key(.ntc), value: .raw(2410)))
        XCTAssertEqual(parse("FSR,1,812"), SensorPacket(key: key(.fsr, 1), value: .raw(812)))
        XCTAssertEqual(parse("KNOB,0,4095"), SensorPacket(key: key(.knob), value: .raw(4095)))
        XCTAssertEqual(parse("TMP102,0,23.50"), SensorPacket(key: key(.tmp102), value: .celsius(23.5)))
        XCTAssertEqual(parse("TMP102,2,-4"), SensorPacket(key: key(.tmp102, 2), value: .celsius(-4)))
        XCTAssertEqual(parse(" NTC,0,0\r\n"), SensorPacket(key: key(.ntc), value: .raw(0)), "Whitespace and line endings are tolerated")
        XCTAssertEqual(parse("ntc,3,100"), SensorPacket(key: key(.ntc, 3), value: .raw(100)), "TYPE is case-insensitive")
    }

    func testLegacyBareIntegerIsKnobChannelZero() {
        XCTAssertEqual(parse("2048"), SensorPacket(key: key(.knob), value: .raw(2048)))
        XCTAssertEqual(parse("0\n"), SensorPacket(key: key(.knob), value: .raw(0)))
        XCTAssertEqual(parse("12\0"), SensorPacket(key: key(.knob), value: .raw(12)), "A trailing C-string terminator is tolerated")
        XCTAssertNil(parse("4096"))
        XCTAssertNil(parse("-1"))
        XCTAssertNil(parse("20.5"))
    }

    func testUnknownTypesAreKeptAsUnknownSensors() {
        XCTAssertEqual(parse("HUM,2,55"), SensorPacket(key: key(.unknown("HUM"), 2), value: .raw(55)))
        XCTAssertEqual(parse("LUX,0,12.5"), SensorPacket(key: key(.unknown("LUX")), value: .number(12.5)))
    }

    func testDiscardsMalformedAndOutOfRangeLines() {
        for bad in ["", "abc", "NTC", "NTC,0", "NTC,0,1,2", ",0,5", "NTC,,5", "NTC,0,",
                    "NTC,-1,5", "NTC,a,5", "NTC,1.5,5", "NTC,999,5",
                    "NTC,0,4096", "NTC,0,-5", "NTC,0,12.5", "FSR,0,abc", "KNOB,0,1e3",
                    "TMP102,0,abc", "TMP102,0,1e3", "TMP102,0,999", "TMP102,0,nan", "TMP102,0,.5",
                    "N TC,0,5", "NTC,0,٢٠٤٨"] {
            XCTAssertNil(parse(bad), "\"\(bad)\" should be discarded")
        }
        XCTAssertNil(ThermyxSensorProtocol.parse(Data([0xFF, 0xFE])), "Not UTF-8")
    }

    // MARK: - NTC

    func testNTCHalfScaleIsAboutTwentyFiveDegrees() throws {
        XCTAssertEqual(try XCTUnwrap(NTCThermistor.celsius(raw: 2048)), 25.0, accuracy: 0.1)
    }

    func testNTCRisesAsItWarmsAndAvoidsDivideByZero() throws {
        XCTAssertGreaterThan(try XCTUnwrap(NTCThermistor.celsius(raw: 3000)), try XCTUnwrap(NTCThermistor.celsius(raw: 2048)))
        XCTAssertNil(NTCThermistor.celsius(raw: 0), "Open circuit")
        XCTAssertNil(NTCThermistor.celsius(raw: 4095), "Shorted thermistor")
    }

    func testNTCIsSmoothedOverFiveSamplesAndOffset() throws {
        var table = SensorTable()
        let start = Date(timeIntervalSince1970: 1_000)
        for (i, raw) in [1000, 2048, 2048, 2048, 2048, 2048].enumerated() {
            table.ingest(SensorPacket(key: key(.ntc), value: .raw(raw)), at: start.addingTimeInterval(Double(i)), calibration: .init())
        }
        let channel = try XCTUnwrap(table.channels[key(.ntc)])
        XCTAssertEqual(channel.ntcWindow.count, 5, "Only the last five samples count")
        XCTAssertEqual(try XCTUnwrap(SensorReadout.ntcCelsius(channel, calibration: .init())), 25.0, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(SensorReadout.ntcCelsius(channel, calibration: .init(ntcOffsetC: 1.5))), 26.5, accuracy: 0.1)

        let shown = SensorReadout.display(channel, calibration: .init())
        XCTAssertEqual(shown.primary, "25.0 °C")
        XCTAssertEqual(shown.secondary, "77.0 °F")
    }

    func testNTCOutsideDisplayRangeShowsDashes() {
        var table = SensorTable()
        table.ingest(SensorPacket(key: key(.ntc), value: .raw(50)), at: .now, calibration: .init())
        let channel = table.channels[key(.ntc)]!
        XCTAssertEqual(SensorReadout.display(channel, calibration: .init()).primary, "--", "About -49 °C is outside -20…100 °C")

        var rails = SensorTable()
        rails.ingest(SensorPacket(key: key(.ntc), value: .raw(4095)), at: .now, calibration: .init())
        XCTAssertEqual(SensorReadout.display(rails.channels[key(.ntc)]!, calibration: .init()).primary, "--")
    }

    // MARK: - Other sensor types

    func testTMP102ShowsCelsiusAndFahrenheit() {
        var table = SensorTable()
        table.ingest(SensorPacket(key: key(.tmp102), value: .celsius(23.5)), at: .now, calibration: .init())
        let shown = SensorReadout.display(table.channels[key(.tmp102)]!, calibration: .init())
        XCTAssertEqual(shown.primary, "23.5 °C")
        XCTAssertEqual(shown.secondary, "74.3 °F")
        XCTAssertEqual(shown.chartUnit, "°C")
    }

    func testFSRShowsNewtonsAndApproximateKilopascals() {
        var table = SensorTable()
        table.ingest(SensorPacket(key: key(.fsr), value: .raw(2048)), at: .now, calibration: .init())
        let shown = SensorReadout.display(table.channels[key(.fsr)]!, calibration: .init())
        XCTAssertEqual(shown.primary, "1.25 N")
        XCTAssertEqual(shown.secondary, "9.9 kPa approx.")
        XCTAssertEqual(shown.chartUnit, "N")
    }

    func testKnobShowsRawAndVoltsOnly() {
        var table = SensorTable()
        table.ingest(SensorPacket(key: key(.knob), value: .raw(2048)), at: .now, calibration: .init())
        let shown = SensorReadout.display(table.channels[key(.knob)]!, calibration: .init())
        XCTAssertEqual(shown.title, "Test input")
        XCTAssertEqual(shown.primary, "2048")
        XCTAssertEqual(shown.secondary, "1.65 V")
    }

    func testUnknownSensorShowsRawValue() {
        var table = SensorTable()
        table.ingest(SensorPacket(key: key(.unknown("HUM")), value: .raw(55)), at: .now, calibration: .init())
        let shown = SensorReadout.display(table.channels[key(.unknown("HUM"))]!, calibration: .init())
        XCTAssertEqual(shown.title, "Unknown sensor (HUM)")
        XCTAssertEqual(shown.primary, "55")
    }

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
        XCTAssertEqual(FSR402.forceNewtons(raw: 4095, scale: 1), 20)
        XCTAssertEqual(FSR402.forceNewtons(raw: 4000, scale: 1), 20, "Clamped at 20 N")
        XCTAssertEqual(FSR402.conductanceMicrosiemens(raw: 0), 0)
        XCTAssertEqual(FSR402.conductanceMicrosiemens(raw: 4095), .infinity)
        XCTAssertEqual(FSR402.forceNewtons(raw: 4095, scale: 1.5), 30, "Scale multiplies after the clamp")
    }

    func testOverrideRelabelsRawReadingsOnly() {
        let knob = SensorPacket(key: key(.knob), value: .raw(2048))
        XCTAssertEqual(SensorTypeOverride.auto.apply(to: knob), knob)
        XCTAssertEqual(SensorTypeOverride.ntc.apply(to: knob).key, key(.ntc))
        let tmp = SensorPacket(key: key(.tmp102), value: .celsius(22))
        XCTAssertEqual(SensorTypeOverride.fsr.apply(to: tmp), tmp, "A TMP102's °C is never relabelled")
    }

    // MARK: - Main page rule

    func testMainPagePrefersTemperature() {
        XCTAssertEqual(SensorTable.mainSensor(among: [key(.fsr), key(.knob), key(.ntc, 1)]), key(.ntc, 1),
                       "Temperature wins even when other sensors are connected")
        XCTAssertEqual(SensorTable.mainSensor(among: [key(.ntc, 0), key(.tmp102, 3)]), key(.tmp102, 3), "TMP102 before NTC")
        XCTAssertEqual(SensorTable.mainSensor(among: [key(.ntc, 2), key(.ntc, 1)]), key(.ntc, 1), "Then the lowest channel")
        XCTAssertEqual(SensorTable.mainSensor(among: [key(.tmp102, 1), key(.tmp102, 0)]), key(.tmp102, 0))
    }

    func testMainPageWithoutTemperature() {
        XCTAssertEqual(SensorTable.mainSensor(among: [key(.knob), key(.fsr, 2), key(.unknown("X"))]), key(.fsr, 2), "FSR first")
        XCTAssertEqual(SensorTable.mainSensor(among: [key(.unknown("X")), key(.knob)]), key(.knob), "Then KNOB")
        XCTAssertEqual(SensorTable.mainSensor(among: [key(.unknown("X"))]), key(.unknown("X")), "Then unknown")
        XCTAssertNil(SensorTable.mainSensor(among: []), "Nothing connected")
    }

    // MARK: - 5-second timeout

    func testSensorsTimeOutAfterFiveSeconds() {
        var table = SensorTable()
        let t0 = Date(timeIntervalSince1970: 10_000)
        table.ingest(SensorPacket(key: key(.ntc), value: .raw(2048)), at: t0, calibration: .init())
        table.ingest(SensorPacket(key: key(.fsr), value: .raw(500)), at: t0, calibration: .init())
        XCTAssertEqual(table.connected.count, 2, "Several sensors at once")

        XCTAssertFalse(table.expire(now: t0.addingTimeInterval(5)), "Still connected at exactly 5 s")
        table.ingest(SensorPacket(key: key(.fsr), value: .raw(510)), at: t0.addingTimeInterval(4), calibration: .init())
        XCTAssertTrue(table.expire(now: t0.addingTimeInterval(5.1)))
        XCTAssertEqual(table.connected.map(\.key), [key(.fsr)], "Only the quiet sensor is removed")

        table.expire(now: t0.addingTimeInterval(9.1))
        XCTAssertTrue(table.connected.isEmpty)
    }

    func testTraceKeepsTwoMinutes() {
        var table = SensorTable()
        let t0 = Date(timeIntervalSince1970: 20_000)
        for second in stride(from: 0, through: 180, by: 10) {
            table.ingest(SensorPacket(key: key(.knob), value: .raw(second)), at: t0.addingTimeInterval(Double(second)), calibration: .init())
        }
        let trace = table.channels[key(.knob)]!.trace
        XCTAssertEqual(trace.first?.time, t0.addingTimeInterval(60))
        XCTAssertEqual(trace.count, 13)
    }

    func testMinuteBucketsAverage() {
        var minute = SensorMinute(key: "NTC#0", start: .now)
        minute.add(24)
        minute.add(26)
        XCTAssertEqual(minute.count, 2)
        XCTAssertEqual(minute.mean, 25, accuracy: 0.0001)
    }

    // MARK: - Reconnect rules

    func testNeverConnectsToABoardThatWasNeverChosen() {
        XCTAssertNil(BoardReconnectPolicy.boardToReconnectOnLaunch(BoardMemory()))
        XCTAssertFalse(BoardReconnectPolicy.shouldReconnectAfterDrop(BoardMemory(), peripheral: UUID()))
    }

    func testReconnectsAfterADropUntilTheUserDisconnects() {
        let board = UUID()
        var memory = BoardReconnectPolicy.afterManualConnect(id: board, name: "Thermyx 1")
        XCTAssertEqual(memory.name, "Thermyx 1")
        XCTAssertTrue(BoardReconnectPolicy.shouldReconnectAfterDrop(memory, peripheral: board), "Rule 2: unexpected drop")
        XCTAssertFalse(BoardReconnectPolicy.shouldReconnectAfterDrop(memory, peripheral: UUID()), "Only the remembered board")
        XCTAssertEqual(BoardReconnectPolicy.boardToReconnectOnLaunch(memory), board, "Rule 4: relaunch")

        memory = BoardReconnectPolicy.afterUserDisconnect(memory)
        XCTAssertFalse(BoardReconnectPolicy.shouldReconnectAfterDrop(memory, peripheral: board), "Rule 3: Disconnect stops it")
        XCTAssertNil(BoardReconnectPolicy.boardToReconnectOnLaunch(memory), "Rule 4: not after a manual disconnect")

        memory = BoardReconnectPolicy.afterManualConnect(id: board, name: "Thermyx 1")
        XCTAssertTrue(BoardReconnectPolicy.shouldReconnectAfterDrop(memory, peripheral: board), "A manual connect turns it back on")
    }

    func testBoardMemorySurvivesRelaunch() throws {
        let defaults = try XCTUnwrap(UserDefaults(suiteName: "thermyx.tests.board"))
        defaults.removePersistentDomain(forName: "thermyx.tests.board")
        let board = UUID()
        BoardReconnectPolicy.afterUserDisconnect(BoardReconnectPolicy.afterManualConnect(id: board, name: "Thermyx")).save(defaults)
        let loaded = BoardMemory.load(defaults)
        XCTAssertEqual(loaded.peripheralID, board)
        XCTAssertTrue(loaded.userDisconnected)
        XCTAssertNil(BoardReconnectPolicy.boardToReconnectOnLaunch(loaded))
        defaults.removePersistentDomain(forName: "thermyx.tests.board")
    }

    func testStatusLabels() {
        XCTAssertEqual(BoardLinkState.notConnected.label, "Not connected")
        XCTAssertEqual(BoardLinkState.scanning.label, "Scanning…")
        XCTAssertEqual(BoardLinkState.connecting("Thermyx").label, "Connecting…")
        XCTAssertEqual(BoardLinkState.connected("Thermyx 1").label, "Connected · Thermyx 1")
        XCTAssertEqual(BoardLinkState.reconnecting("Thermyx").label, "Reconnecting…")
    }
}
