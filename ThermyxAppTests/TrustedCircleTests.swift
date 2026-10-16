import XCTest
@testable import ThermyxApp

/// The trusted circle's messages and status card.
final class TrustedCircleTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func reading(_ foot: Foot, _ c: Double?, at time: Date, battery: Int = 70, zones: FootZoneTemperatures? = nil) -> ThermyxReading {
        ThermyxReading(foot: foot, timestamp: time, footTemperatureC: c, ambientTemperatureC: 30, pressureBalance: 0.5,
                       gaitStability: 0.9, batteryPercent: battery, thermalMode: .cooling, zones: zones)
    }

    // MARK: Parity with the relay

    /// The preview on Safety must say exactly what the relay texts. Both
    /// sides are checked against the same file.
    func testMessagesMatchTheRelaysFixtures() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("ThermyxBackend/test/message-fixtures.json")
        let data = try Data(contentsOf: url)
        let fixtures = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [[String: Any]])
        XCTAssertGreaterThanOrEqual(fixtures.count, 10)
        for f in fixtures {
            let name = f["name"] as? String ?? "?"
            let expected = try XCTUnwrap(f["expected"] as? String)
            let detail = try (f["detail"]).map { try JSONDecoder().decode(ThermyxCircleDetail.self, from: JSONSerialization.data(withJSONObject: $0)) }
            if let silence = f["silence"] as? [String: Any] {
                let loc = silence["location"] as? [String: Double]
                let text = ThermyxCircleMessage.silence(
                    name: silence["name"] as? String, level: silence["level"] as? String ?? "",
                    location: loc.map { .init(latitude: $0["latitude"]!, longitude: $0["longitude"]!) },
                    minutes: silence["minutes"] as? Int ?? 0)
                XCTAssertEqual(text, expected, name)
                continue
            }
            let event = try XCTUnwrap(f["event"] as? [String: Any])
            let level = event["level"] as? String ?? ""
            if f["reconnected"] as? Bool == true {
                XCTAssertEqual(ThermyxCircleMessage.reconnected(level: level, detail: detail), expected, name)
                continue
            }
            let loc = event["location"] as? [String: Double]
            let text = ThermyxCircleMessage.text(
                level: level, kind: event["kind"] as? String ?? "alert", detail: detail,
                locationConsent: event["locationConsent"] as? Bool ?? false,
                location: loc.map { .init(latitude: $0["latitude"]!, longitude: $0["longitude"]!) })
            XCTAssertEqual(text, expected, name)
        }
    }

    // MARK: Building the card

    func testTheCardNamesTheFootTheEngineBlamed() {
        let pair = BilateralReading(left: reading(.left, 34.0, at: t0), right: reading(.right, 38.6, at: t0))
        let assessment = ThermyxRiskEngine.assess(pair, sustainedTemperatureGap: false, sustainedLoadGap: false)
        let d = ThermyxCircleDetail.make(assessment: assessment, reading: pair, tracker: .init(), name: "  Miheer ",
                                         unit: .fahrenheit, now: t0, timeZone: TimeZone(identifier: "America/Chicago")!)
        XCTAssertEqual(d.name, "Miheer")
        XCTAssertEqual(d.foot, "right")
        XCTAssertNil(d.zone, "Today's insoles have one temperature per foot: no zone is invented")
        XCTAssertEqual(d.footC, 38.6)
        XCTAssertEqual(d.causes, ["hot"])
        XCTAssertEqual(d.unit, "F")
        XCTAssertTrue(d.time?.contains("CDT") == true || d.time?.contains("CST") == true, d.time ?? "")
    }

    func testAZoneComesOnlyFromABoardThatSensesIt() {
        let zones = FootZoneTemperatures(forefootC: 39.2, archC: 37.0, heelC: 36.4)
        let pair = BilateralReading(left: reading(.left, 34, at: t0), right: reading(.right, 38.3, at: t0, zones: zones))
        let d = ThermyxCircleDetail.make(assessment: ThermyxRiskEngine.assess(pair), reading: pair, tracker: .init(),
                                         name: "", unit: .celsius, now: t0)
        XCTAssertEqual(d.foot, "right")
        XCTAssertEqual(d.zone, "forefoot")
        XCTAssertEqual(d.footC, 39.2, "The zone's own temperature")
        XCTAssertNil(d.name)
    }

    func testBothFeetHot() {
        let pair = BilateralReading(left: reading(.left, 38.4, at: t0), right: reading(.right, 38.9, at: t0))
        let d = ThermyxCircleDetail.make(assessment: ThermyxRiskEngine.assess(pair), reading: pair, tracker: .init(),
                                         name: "A", unit: .fahrenheit, now: t0)
        XCTAssertEqual(d.foot, "both")
        XCTAssertEqual(d.footC, 38.9)
        XCTAssertTrue(ThermyxCircleMessage.condition(d)?.hasPrefix("Both feet are hot") == true)
    }

    func testBatteryAndConnectionOnlyWhenTheyMatter() {
        let fine = BilateralReading(left: reading(.left, 33, at: t0), right: reading(.right, 33, at: t0))
        let a = ThermyxCircleDetail.make(assessment: ThermyxRiskEngine.assess(fine), reading: fine, tracker: .init(), name: "", unit: .celsius, now: t0)
        XCTAssertNil(a.battery)
        XCTAssertNil(a.connection)

        let low = BilateralReading(left: reading(.left, 33, at: t0, battery: 8), right: nil)
        let b = ThermyxCircleDetail.make(assessment: ThermyxRiskEngine.assess(low), reading: low, tracker: .init(), name: "", unit: .celsius, now: t0)
        XCTAssertEqual(b.battery, .init(foot: "left", percent: 8))
        XCTAssertEqual(b.connection, "oneInsole")

        let c = ThermyxCircleDetail.make(assessment: ThermyxRiskEngine.assess(fine), reading: fine, tracker: .init(), name: "", unit: .celsius,
                                         now: t0.addingTimeInterval(90))
        XCTAssertEqual(c.connection, "stale")
    }

    func testTrendAndConfidenceFromTheStream() {
        var tracker = ThermyxCircleTracker()
        for i in 0...60 {
            let time = t0.addingTimeInterval(Double(i))
            tracker.record(BilateralReading(left: reading(.left, 33, at: time), right: reading(.right, 37 + Double(i) * 0.02, at: time)), now: time)
        }
        let now = t0.addingTimeInterval(60)
        XCTAssertEqual(tracker.trend(for: .right, now: now), "rising")
        XCTAssertEqual(tracker.trend(for: .left, now: now), "steady")
        XCTAssertEqual(tracker.confidence(now: now), "confirmed")
        XCTAssertEqual(tracker.confidence(now: now.addingTimeInterval(15)), "limited", "Old data isn't confirmed")

        var oneFoot = ThermyxCircleTracker()
        for i in 0...30 {
            let time = t0.addingTimeInterval(Double(i))
            oneFoot.record(BilateralReading(left: reading(.left, 33, at: time), right: nil), now: time)
        }
        XCTAssertEqual(oneFoot.confidence(now: t0.addingTimeInterval(30)), "limited", "One insole isn't confirmed")
        XCTAssertNil(ThermyxCircleTracker().trend(for: .left, now: t0), "No trend without history")
    }

    func testEveryRaisedLevelSaysWhy() {
        let hot = ThermyxRiskEngine.assess(reading(.left, 40.5, at: t0))
        XCTAssertEqual(hot.causes.first, .heatLimit)
        let cold = ThermyxRiskEngine.assess(reading(.left, 22, at: t0))
        XCTAssertEqual(cold.causes, [.cold])
        XCTAssertEqual(hot.causes.count, hot.reasons.count, "One cause per reason")
    }

    func testTheWatchersHeadlineLeavesTheNumberToTheCard() {
        var d = ThermyxCircleDetail()
        d.foot = "right"; d.zone = "forefoot"; d.causes = ["hot"]; d.footC = 38.4; d.trend = "rising"
        XCTAssertEqual(ThermyxCircleMessage.headline(d), "Right forefoot temperature is elevated and still rising.")
        d.causes = nil
        XCTAssertNil(ThermyxCircleMessage.headline(d))
    }

    func testOldWatchStatesStillDecode() throws {
        let json = #"{"level":"High risk","kind":"alert","updatedAt":"2026-10-15T21:18:00.000Z"}"#
        let state = try JSONDecoder().decode(ThermyxAlertAPIClient.WatchState.self, from: Data(json.utf8))
        XCTAssertNil(state.detail)
        XCTAssertNil(state.timeline)
    }
}
