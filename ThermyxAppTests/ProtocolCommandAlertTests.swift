import XCTest
@testable import ThermyxApp

/// The decoder is the only way a number reaches the screen, so it is tested
/// byte by byte against BLE_PROTOCOL.md. Test cases follow Aaron Qin's
/// protocol, command, and alert-policy tests.
@MainActor
final class ProtocolTests: XCTestCase {

    /// A v1 packet assembled by hand from the spec table.
    private func v1(
        mode: UInt8 = 3,
        battery: UInt8 = 81,
        footCenti: Int16 = 3480,
        ambientCenti: Int16 = 2915,
        gait: UInt16 = 8700,
        balance: UInt16 = 5400,
        flags: UInt8 = 1
    ) -> Data {
        func le(_ value: UInt16) -> [UInt8] { [UInt8(value & 0xFF), UInt8(value >> 8)] }
        return Data([1, mode, battery]
            + le(UInt16(bitPattern: footCenti))
            + le(UInt16(bitPattern: ambientCenti))
            + le(gait) + le(balance) + [flags])
    }

    private func decode(_ data: Data) throws -> ThermyxProtocol.Telemetry {
        try ThermyxProtocol.decode(data).get()
    }

    func testDecodesVersionOneFieldsAsSpecified() throws {
        let t = try decode(v1())
        XCTAssertEqual(t.version, 1)
        XCTAssertEqual(t.mode, .ventilation)
        XCTAssertEqual(t.batteryPercent, 81)
        XCTAssertEqual(t.footTemperatureC!, 34.80, accuracy: 0.001)
        XCTAssertEqual(t.ambientTemperatureC!, 29.15, accuracy: 0.001)
        XCTAssertEqual(t.gaitStability!, 0.87, accuracy: 0.0001)
        XCTAssertEqual(t.pressureBalance!, 0.54, accuracy: 0.0001)
        XCTAssertEqual(t.declaredFoot, .left)
        XCTAssertNil(t.settingEcho, "Old firmware sends no setting echo")
        XCTAssertFalse(t.burnCutoff)
        XCTAssertNil(t.zones)
        XCTAssertNil(t.cadenceStepsPerMinute)
    }

    /// An unplugged sensor reads far outside anything a foot can be. It must
    /// never reach the risk engine as a reading.
    func testRejectsImplausibleTemperatures() throws {
        let unplugged = try decode(v1(footCenti: -20_000, ambientCenti: 9_000))
        XCTAssertNil(unplugged.footTemperatureC)
        XCTAssertNil(unplugged.ambientTemperatureC)
        let edges = try decode(v1(footCenti: -2_000, ambientCenti: 8_000))
        XCTAssertEqual(edges.footTemperatureC, -20)
        XCTAssertEqual(edges.ambientTemperatureC, 80)
    }

    func testRejectsProportionsAboveOneAndBatteryAboveOneHundred() throws {
        let t = try decode(v1(battery: 255, gait: 0xFFFF, balance: 10_001))
        XCTAssertNil(t.batteryPercent)
        XCTAssertNil(t.gaitStability)
        XCTAssertNil(t.pressureBalance)
    }

    func testReadsFootSettingEchoAndCutoffFromTheFlagsByte() throws {
        // Right foot (2), setting Heat (3 << 2), cutoff (bit 4).
        let t = try decode(v1(flags: 0b0001_1110))
        XCTAssertEqual(t.declaredFoot, .right)
        XCTAssertEqual(t.settingEcho, .heat)
        XCTAssertTrue(t.burnCutoff)
        XCTAssertEqual(ThermyxProtocol.flags(foot: .right, echo: .heat, burnCutoff: true), 0b0001_1110)
    }

    func testRejectsUnknownVersionsAndShortPackets() {
        XCTAssertEqual(ThermyxProtocol.decode(Data([9] + Array(repeating: 0, count: 21))), .failure(.unsupportedVersion(9)))
        XCTAssertEqual(ThermyxProtocol.decode(Data()), .failure(.unsupportedVersion(nil)))
        var short = v1()
        short[0] = 3
        XCTAssertEqual(ThermyxProtocol.decode(short), .failure(.tooShort(length: 12, needed: 22)))
    }

    func testRoundTripsAVersionThreePacket() throws {
        let original = ThermyxProtocol.Telemetry(
            version: 3,
            mode: .cooling,
            batteryPercent: 64,
            footTemperatureC: 35.2,
            ambientTemperatureC: 31.07,
            gaitStability: 0.8123,
            pressureBalance: 0.5,
            declaredFoot: .right,
            settingEcho: .cool,
            burnCutoff: false,
            zones: FootZoneTemperatures(forefootC: 36.6, archC: 35.2, heelC: 32.8),
            cadenceStepsPerMinute: 104.3,
            standingFraction: 0.25
        )
        XCTAssertEqual(try decode(ThermyxProtocol.encode(original)), original)
    }

    /// One bad zone channel hides the whole heat map, and the "not measured"
    /// markers read as missing, never as zero.
    func testTreatsSentinelsAsAbsent() throws {
        var t = ThermyxProtocol.Telemetry(
            version: 3, mode: .off, batteryPercent: 50, footTemperatureC: 33, ambientTemperatureC: 25,
            gaitStability: 0.9, pressureBalance: 0.5, declaredFoot: .left,
            zones: FootZoneTemperatures(forefootC: 34, archC: 33, heelC: 31)
        )
        var bytes = [UInt8](ThermyxProtocol.encode(t))
        bytes[14] = 0x00; bytes[15] = 0x80   // arch channel: Int16.min
        let decoded = try decode(Data(bytes))
        XCTAssertNil(decoded.zones)
        XCTAssertNil(decoded.cadenceStepsPerMinute)
        XCTAssertNil(decoded.standingFraction)

        t.cadenceStepsPerMinute = 0
        XCTAssertEqual(try decode(ThermyxProtocol.encode(t)).cadenceStepsPerMinute, 0, "Zero is a real zero")
    }

    func testEncodesCommandsAsSpecified() {
        XCTAssertEqual(ThermyxProtocol.command(.cooling), Data([1, 2]))
        XCTAssertEqual(ThermyxProtocol.command(.ventilation), Data([1, 3]))
        XCTAssertEqual(ThermyxProtocol.command(.heating), Data([1, 1]))
        // 31.5 °C → 3150 = 0x0C4E, little-endian.
        XCTAssertEqual(ThermyxProtocol.target(31.5), Data([2, 0x4E, 0x0C]))
    }

    func testReadingCarriesEchoAndCutoff() throws {
        let reading = try decode(v1(flags: 0b0001_1101)).reading(for: .left)
        XCTAssertEqual(reading.settingEcho, .heat)
        XCTAssertTrue(reading.burnCutoff)
    }
}

@MainActor
final class CommandTrackerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    private func reading(_ foot: Foot, mode: ThermalMode, echo: ThermalSetting? = nil, at time: Date, cutoff: Bool = false) -> ThermyxReading {
        var r = ThermyxReading(foot: foot, timestamp: time, footTemperatureC: 33, ambientTemperatureC: 25,
                               pressureBalance: 0.5, gaitStability: 0.9, batteryPercent: 80, thermalMode: mode)
        r.settingEcho = echo
        r.burnCutoff = cutoff
        return r
    }

    func testStaysPendingUntilEveryFootReportsTheSetting() {
        var tracker = ThermalCommandTracker()
        tracker.begin(.cool, feet: [.left, .right], now: t0)
        let t1 = t0.addingTimeInterval(1)
        tracker.update(readings: [.left: reading(.left, mode: .cooling, echo: .cool, at: t1),
                                  .right: reading(.right, mode: .ventilation, echo: .auto, at: t1)],
                       connected: [.left, .right], now: t1)
        XCTAssertTrue(tracker.isPending)
        let t2 = t0.addingTimeInterval(2)
        tracker.update(readings: [.left: reading(.left, mode: .cooling, echo: .cool, at: t2),
                                  .right: reading(.right, mode: .cooling, echo: .cool, at: t2)],
                       connected: [.left, .right], now: t2)
        XCTAssertEqual(tracker.state, .confirmed(.cool))
    }

    func testFailsLoudlyWhenAnInsoleNeverSwitches() {
        var tracker = ThermalCommandTracker()
        tracker.begin(.cool, feet: [.left, .right], now: t0)
        let late = t0.addingTimeInterval(ThermalCommandTracker.timeout + 1)
        tracker.update(readings: [.left: reading(.left, mode: .cooling, echo: .cool, at: late),
                                  .right: reading(.right, mode: .ventilation, echo: .auto, at: late)],
                       connected: [.left, .right], now: late)
        XCTAssertEqual(tracker.failureMessage?.hasPrefix("The right insole"), true)
    }

    func testAWriteErrorFailsTheRequest() {
        var tracker = ThermalCommandTracker()
        tracker.begin(.heat, feet: [.left], now: t0)
        tracker.writeFailed(foot: .left, message: "Not permitted")
        XCTAssertNotNil(tracker.failureMessage)
    }

    func testAFootThatDisconnectsIsNoLongerWaitedOn() {
        var tracker = ThermalCommandTracker()
        tracker.begin(.cool, feet: [.left, .right], now: t0)
        let t1 = t0.addingTimeInterval(1)
        tracker.update(readings: [.left: reading(.left, mode: .cooling, at: t1)], connected: [.left], now: t1)
        XCTAssertEqual(tracker.state, .confirmed(.cool))
    }

    func testConfirmsFromTheActuatorWhenNoEchoIsSent() {
        XCTAssertTrue(ThermalCommandTracker.confirms(.cool, reading(.left, mode: .cooling, at: t0)))
        XCTAssertFalse(ThermalCommandTracker.confirms(.cool, reading(.left, mode: .ventilation, at: t0)))
        XCTAssertTrue(ThermalCommandTracker.confirms(.heat, reading(.left, mode: .ventilation, at: t0, cutoff: true)),
                      "Heat held off by the burn cutoff still took effect")
        XCTAssertFalse(ThermalCommandTracker.confirms(.cool, reading(.left, mode: .cooling, echo: .auto, at: t0)),
                       "The echo wins over the actuator")
    }

    func testOldReadingsDoNotConfirm() {
        var tracker = ThermalCommandTracker()
        tracker.begin(.cool, feet: [.left], now: t0)
        tracker.update(readings: [.left: reading(.left, mode: .cooling, echo: .cool, at: t0.addingTimeInterval(-1))],
                       connected: [.left], now: t0.addingTimeInterval(1))
        XCTAssertTrue(tracker.isPending)
    }
}

@MainActor
final class AlertPolicyTests: XCTestCase {
    private var now = Date(timeIntervalSince1970: 2_000_000)
    private var policy = ThermyxAlertPolicy()

    private func step(_ level: ThermyxRiskLevel, after seconds: TimeInterval = 1, alerts: Bool = true) -> ThermyxAlertPolicy.Decision {
        now = now.addingTimeInterval(seconds)
        return policy.evaluate(level, alertsEnabled: alerts, now: now)
    }

    func testARiseAlertsOnceNotOnEveryPacket() {
        XCTAssertFalse(step(.normal).alert)
        let rise = step(.high)
        XCTAssertTrue(rise.alert)
        XCTAssertTrue(rise.notifyWearer)
        for _ in 0..<30 { XCTAssertFalse(step(.high).alert) }
    }

    func testHoldingHighRemindsEveryFiveMinutes() {
        _ = step(.high)
        XCTAssertFalse(step(.high, after: ThermyxAlertPolicy.reminderInterval - 10).alert)
        XCTAssertTrue(step(.high, after: 20).alert)
    }

    func testCautionDoesNotNag() {
        XCTAssertTrue(step(.caution).alert)
        XCTAssertFalse(step(.caution, after: ThermyxAlertPolicy.reminderInterval * 3).alert)
    }

    func testAFlapInsideTwoMinutesStaysQuiet() {
        _ = step(.high)
        _ = step(.normal, after: 30)
        let back = step(.high, after: 30)
        XCTAssertFalse(back.alert)
        XCTAssertFalse(back.notifyWearer)
    }

    func testReturningToNormalLetsTheSameLevelAlertAgain() {
        _ = step(.high)
        _ = step(.normal, after: 10)
        _ = step(.normal, after: ThermyxAlertPolicy.settleInterval)
        XCTAssertTrue(step(.high, after: 10).alert)
    }

    func testAHigherLevelAlwaysAlerts() {
        _ = step(.high)
        policy.imOK(now: now)
        XCTAssertTrue(step(.critical, after: 5).alert)
    }

    func testNoDataIsNotAnAllClear() {
        _ = step(.high)
        for _ in 0..<200 { _ = step(.unavailable, after: 5) }
        XCTAssertFalse(step(.high).notifyWearer, "Losing data must not reset the episode")
    }

    func testImOKQuietsRemindersButNotARise() {
        _ = step(.high)
        policy.imOK(now: now)
        XCTAssertFalse(step(.high, after: ThermyxAlertPolicy.reminderInterval + 1).alert)
        XCTAssertTrue(step(.critical, after: 1).alert)
    }

    func testImOKWearsOff() {
        _ = step(.high)
        policy.imOK(now: now)
        XCTAssertTrue(step(.high, after: ThermyxAlertPolicy.okQuietInterval + 1).alert)
    }

    func testAlertsOffStillNotifyTheWearerAndPostStatus() {
        let d = step(.high, alerts: false)
        XCTAssertTrue(d.notifyWearer)
        XCTAssertFalse(d.alert)
        XCTAssertTrue(d.heartbeat)
    }

    func testHeartbeatOncePerMinute() {
        XCTAssertTrue(step(.normal).heartbeat)
        XCTAssertFalse(step(.normal, after: 30).heartbeat)
        XCTAssertTrue(step(.normal, after: 31).heartbeat)
    }
}
