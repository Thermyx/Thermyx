import CoreBluetooth
import SwiftUI
import UserNotifications
import XCTest
@testable import ThermyxApp

/// Charts coloured by value, the AI Insights opt-in, permission states, and
/// the documents that cover AI Insights.
@MainActor
final class StageTwoTests: XCTestCase {

    // MARK: Colour by value

    private func rgb(_ color: Color) -> (Double, Double, Double) {
        let resolved = color.resolve(in: EnvironmentValues())
        return (Double(resolved.red), Double(resolved.green), Double(resolved.blue))
    }

    func testFootTemperatureScaleMatchesTheMapsAtEachEnd() {
        let scale = ChartValueScale.footTemperature(.celsius)
        let cold = rgb(scale.color(at: 28)), hot = rgb(scale.color(at: 38))
        // The thermal ramp runs deep blue to ember, as the foot maps do.
        XCTAssertGreaterThan(cold.2, cold.0, "28 °C reads blue")
        XCTAssertGreaterThan(hot.0, hot.2, "38 °C reads ember")
        let map = rgb(FootScale.thermalColor(33))
        let line = rgb(scale.color(at: 33))
        XCTAssertEqual(map.0, line.0, accuracy: 0.02)
        XCTAssertEqual(map.1, line.1, accuracy: 0.02)
        XCTAssertEqual(map.2, line.2, accuracy: 0.02)
    }

    func testFahrenheitScaleSitsAtTheSameTemperatures() {
        let c = rgb(ChartValueScale.footTemperature(.celsius).color(at: 35))
        let f = rgb(ChartValueScale.footTemperature(.fahrenheit).color(at: 95))
        XCTAssertEqual(c.0, f.0, accuracy: 0.02)
        XCTAssertEqual(c.1, f.1, accuracy: 0.02)
        XCTAssertEqual(c.2, f.2, accuracy: 0.02)
    }

    func testScalesClampOutsideTheirRange() {
        let scale = ChartValueScale.load
        let below = rgb(scale.color(at: -40)), atZero = rgb(scale.color(at: 0))
        XCTAssertEqual(below.0, atZero.0, accuracy: 0.001)
        XCTAssertEqual(below.2, atZero.2, accuracy: 0.001)
    }

    func testGapScalesReadTheSameEitherWay() {
        for scale in [ChartValueScale.temperatureGap(.celsius), .loadGap] {
            let left = rgb(scale.color(at: 2)), right = rgb(scale.color(at: -2))
            XCTAssertEqual(left.0, right.0, accuracy: 0.01)
            XCTAssertEqual(left.1, right.1, accuracy: 0.01)
            XCTAssertEqual(left.2, right.2, accuracy: 0.01)
        }
        // An even split reads cool; a large gap reads warm.
        let even = rgb(ChartValueScale.temperatureGap(.celsius).color(at: 0))
        let large = rgb(ChartValueScale.temperatureGap(.celsius).color(at: 3))
        XCTAssertGreaterThan(even.2, even.0)
        XCTAssertGreaterThan(large.0, large.2)
    }

    func testSteadinessWarnsLowAndCalmsHigh() {
        let low = rgb(ChartValueScale.steadiness.color(at: 30))
        let high = rgb(ChartValueScale.steadiness.color(at: 95))
        XCTAssertGreaterThan(low.0, low.2, "Low steadiness reads ember")
        XCTAssertGreaterThan(high.2, high.0, "High steadiness reads ice")
    }

    func testChangeScaleIsBlueCoolingAndWarmHeating() {
        let scale = ChartValueScale.change(unitSize: 1)
        let cooling = rgb(scale.color(at: -1)), warming = rgb(scale.color(at: 1))
        XCTAssertGreaterThan(cooling.2, cooling.0)
        XCTAssertGreaterThan(warming.0, warming.2)
    }

    // MARK: AI Insights

    func testAIInsightsIsOffUntilTurnedOnAndRemembered() {
        let key = "thermyx.aiInsightsEnabled"
        let saved = UserDefaults.standard.object(forKey: key)
        defer { UserDefaults.standard.set(saved, forKey: key) }

        UserDefaults.standard.removeObject(forKey: key)
        XCTAssertFalse(ThermyxSettingsStore().aiInsightsEnabled, "AI Insights must be opt-in")

        let settings = ThermyxSettingsStore()
        settings.aiInsightsEnabled = true
        XCTAssertTrue(ThermyxSettingsStore().aiInsightsEnabled)
    }

    func testPrivacyPolicyAndTermsCoverAIInsights() {
        let privacy = LegalDocument.load(.privacy).blocks
        let terms = LegalDocument.load(.terms).blocks
        func text(_ blocks: [LegalDocument.Block]) -> String {
            blocks.map {
                switch $0 {
                case .title(let t), .heading(let t), .subheading(let t), .paragraph(let t), .bullet(let t), .legalese(let t): return t
                case .table(let h, let rows): return (h + rows.flatMap { $0 }).joined(separator: " ")
                case .rule: return ""
                }
            }.joined(separator: " ")
        }
        let p = text(privacy), t = text(terms)
        XCTAssertTrue(privacy.contains(.subheading("2.8 AI Insights (optional, off by default)")))
        XCTAssertTrue(p.contains("Anthropic"))
        XCTAssertTrue(p.contains("Claude API"))
        XCTAssertTrue(terms.contains(.heading("16. AI Insights")))
        XCTAssertTrue(t.contains("not medical advice"))
    }

    // MARK: Permissions

    func testBluetoothStatusSeesTheRadioAsWellAsThePermission() {
        XCTAssertEqual(PermissionPrompt.Status(.notDetermined, state: .unknown), .notAsked)
        XCTAssertEqual(PermissionPrompt.Status(.allowedAlways, state: .poweredOn), .allowed)
        XCTAssertEqual(PermissionPrompt.Status(.allowedAlways, state: .poweredOff), .off)
        XCTAssertEqual(PermissionPrompt.Status(.allowedAlways, state: .unsupported), .off)
        XCTAssertEqual(PermissionPrompt.Status(.denied, state: .unauthorized), .denied)
    }

    func testNotificationStatus() {
        XCTAssertEqual(PermissionPrompt.Status(UNAuthorizationStatus.notDetermined), .notAsked)
        XCTAssertEqual(PermissionPrompt.Status(UNAuthorizationStatus.denied), .denied)
        XCTAssertEqual(PermissionPrompt.Status(UNAuthorizationStatus.provisional), .allowed)
    }

    func testColdRemindersComeSoonerWithPoorCirculation() {
        func pair(_ c: Double) -> BilateralReading {
            BilateralReading(left: ThermyxReading(foot: .left, timestamp: .now, footTemperatureC: c, ambientTemperatureC: 20,
                                                  pressureBalance: 0.5, gaitStability: 0.9, batteryPercent: 80, thermalMode: .off),
                             right: nil)
        }
        let t0 = Date(timeIntervalSince1970: 2_000_000)
        var standard = ThermyxComfortWatch()
        XCTAssertTrue(standard.update(pair(26.5), now: t0).isEmpty)
        XCTAssertTrue(standard.update(pair(26.5), now: t0.addingTimeInterval(90)).isEmpty, "26.5 °C isn't cold for most")

        var circulation = ThermyxComfortWatch()
        circulation.circulationRisk = true
        XCTAssertTrue(circulation.update(pair(26.5), now: t0).isEmpty)
        let notices = circulation.update(pair(26.5), now: t0.addingTimeInterval(31))
        XCTAssertEqual(notices.first?.kind, .cold(26.5, circulation: true))
        XCTAssertTrue(ThermyxComfortWatch.circulationConditions.contains(.poorCirculation))
        XCTAssertFalse(ThermyxComfortWatch.circulationConditions.contains(.heatSensitivity))
    }

    func testDemoWearerAutoWarmsBelowAndCoolsAboveTheTarget() {
        XCTAssertEqual(DemoWearer.autoDecision(contactC: 32.8, targetC: 34.4, previous: .ventilation), .heating,
                       "91 °F with Auto at 94 °F warms, never cools")
        XCTAssertEqual(DemoWearer.autoDecision(contactC: 35.5, targetC: 34.4, previous: .ventilation), .cooling)
        XCTAssertEqual(DemoWearer.autoDecision(contactC: 34.45, targetC: 34.4, previous: .heating), .ventilation)
        XCTAssertEqual(AutoStatus.line(mode: .ventilation, footC: 32.8, targetC: 34.4, target: "94°"), "Below 94° · warming soon")
        XCTAssertEqual(AutoStatus.line(mode: .heating, footC: 32.8, targetC: 34.4, target: "94°"), "Warming to 94°")
        XCTAssertEqual(AutoStatus.line(mode: .ventilation, footC: 34.2, targetC: 34.4, target: "94°"), "Holding 94°")
    }

    func testShoeSizesConvertThroughFootLength() {
        XCTAssertEqual(SoleSize.make(9.5, in: .usWomen).usMens, 8, "Women's runs 1.5 above men's")
        XCTAssertEqual(SoleSize.make(10.5, in: .uk).usMens, 11.5, "UK runs 1 below US men's")
        XCTAssertEqual(SoleSize.make(11.5, in: .usMen).lengthMM, 295.5, "Templates are used where measured")
        XCTAssertEqual(SoleSize.make(usMens: 9).size(in: .eu), 42)
        XCTAssertTrue(SoleSize.make(11, in: .usMen).isSupported)
        XCTAssertFalse(SoleSize.make(9.5, in: .usWomen).isSupported)
        XCTAssertEqual(ShoeSizeSystem.usWomen.format(9.5), "US women's 9.5")
    }

    func testDemoHistoryCreditsTimeAndActivity() {
        let demo = ThermyxDemoHistory.make(feet: Foot.allCases, targetC: 31, zones: false, days: 8)
        let today = demo.minutes.filter { Calendar.current.isDateInToday($0.start) && $0.foot == .left }
        XCTAssertFalse(today.isEmpty)
        let worn = today.compactMap(\.trackedSeconds).reduce(0, +)
        XCTAssertGreaterThan(worn, 7 * 3600, "Today's shift is credited as worn time")
        XCTAssertGreaterThan(today.compactMap(\.steps).reduce(0, +), 1000)
        XCTAssertGreaterThan(today.compactMap(\.sittingSeconds).reduce(0, +), 0)
        XCTAssertGreaterThan(today.compactMap(\.walkingSeconds).reduce(0, +), 0)
        XCTAssertNotNil(demo.last[.left], "The live insoles have somewhere to carry on from")
        XCTAssertTrue(demo.events.allSatisfy { $0.endedAt != nil }, "No event is left open for the live store")
    }

    func testDemoHistoryNeverReplacesTheRealHistory() {
        let store = ThermyxHistoryStore()
        let real = ThermyxReading(foot: .left, timestamp: .now, footTemperatureC: 31, ambientTemperatureC: 22,
                                  pressureBalance: 0.4, gaitStability: 0.9, batteryPercent: 80, thermalMode: .ventilation)
        store.record(real, assessment: ThermyxRiskEngine.assess(real))
        let realMinutes = store.minuteSamples
        XCTAssertFalse(realMinutes.isEmpty)

        let demo = ThermyxDemoHistory.make(feet: [.left], targetC: 31, zones: false, days: 2)
        store.enterDemo(minutes: demo.minutes, hours: demo.hours, events: demo.events)
        XCTAssertTrue(store.isInDemo)
        XCTAssertGreaterThan(store.minuteSamples.count, realMinutes.count)

        store.exitDemo()
        XCTAssertFalse(store.isInDemo)
        XCTAssertEqual(store.minuteSamples, realMinutes, "The real history comes back exactly")
    }

    func testTimelapseSkipsTimeNotWorn() {
        func sample(_ minutesAgo: Double, c: Double) -> ThermyxHistorySample {
            var s = ThermyxHistorySample(foot: .left, start: Date(timeIntervalSince1970: 1_800_000_000 - minutesAgo * 60))
            s.accumulate(ThermyxReading(foot: .left, timestamp: s.start, footTemperatureC: c, ambientTemperatureC: 22,
                                        pressureBalance: 0.5, gaitStability: 0.9, batteryPercent: 80, thermalMode: .off),
                         risk: .normal)
            return s
        }
        // Two stretches of wear, three hours apart.
        let samples = (0..<20).map { sample(Double(300 + $0), c: 30) } + (0..<20).map { sample(Double($0), c: 34) }
        let digest = BilateralDigest(range: .day, style: .standard, samples: samples)
        let frames = digest.timelapse(for: .both)
        XCTAssertEqual(frames.count, 6, "Two 20-minute stretches, 10 minutes a frame, nothing in the gap")
        XCTAssertEqual(frames.first?.temperatureC[.left] ?? 0, 30, accuracy: 0.01)
        XCTAssertEqual(frames.last?.temperatureC[.left] ?? 0, 34, accuracy: 0.01)
        XCTAssertNotNil(frames.last?.steadiness[.left])
    }

    // MARK: Widgets

    func testOldWidgetSnapshotsStillDecode() throws {
        // What an earlier build saved, with the calculus fields it had.
        let json = #"{"updated":790000000,"live":true,"isDemo":false,"fahrenheit":false,"mode":"auto","level":"normal","temps":[31.5,32],"rates":[0.1],"ratePerMinute":0.2,"changeC":1.1,"battery":50,"footC":32}"#
        let snapshot = try JSONDecoder().decode(ThermyxWidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertEqual(snapshot.footC, 32)
        XCTAssertNil(snapshot.leftC, "Per-foot values arrive with the next update")
        XCTAssertEqual(snapshot.temps.count, 2)
    }

    func testWidgetConcernsAreShortenedByWhatTheySay() {
        var s = ThermyxWidgetSnapshot(updated: .now, live: true, isDemo: false, fahrenheit: false, mode: .auto,
                                      level: .caution, concern: "Foot-contact temperature is elevated.", temps: [])
        XCTAssertEqual(s.shortConcern, "Foot temperature elevated")
        XCTAssertEqual(s.tinyConcern, "Foot too warm")
        s.concern = "Movement stability is below baseline."
        XCTAssertEqual(s.tinyConcern, "Unsteady steps")
        s.concern = "Something the engine learns to say later."
        XCTAssertEqual(s.shortConcern, "Something the engine learns to say later.", "Unknown reasons pass through whole")
        s.concern = nil
        XCTAssertNil(s.shortConcern)
    }

    func testWidgetBatteryWarnsAtTenAndFive() {
        var s = ThermyxWidgetSnapshot(updated: .now, live: true, isDemo: false, fahrenheit: false, mode: .auto,
                                      level: .normal, concern: nil, temps: [], batteryLeft: 40, batteryRight: 55)
        XCTAssertNil(s.lowBattery)
        s.batteryLeft = 10
        XCTAssertEqual(s.lowBattery?.side, "Left")
        XCTAssertFalse(s.batteryIsCritical)
        s.batteryRight = 5
        XCTAssertEqual(s.lowBattery?.side, "Right", "The lower of the two")
        XCTAssertTrue(s.batteryIsCritical)
    }

    func testHeatIsLockedOnTheWidgetAtHighRiskAndAbove() {
        func snap(_ level: ThermyxWidgetSnapshot.Level) -> ThermyxWidgetSnapshot {
            ThermyxWidgetSnapshot(updated: .now, live: true, isDemo: false, fahrenheit: false, mode: .cool, level: level, concern: nil, temps: [])
        }
        XCTAssertFalse(snap(.caution).heatLocked)
        XCTAssertTrue(snap(.high).heatLocked)
        XCTAssertTrue(snap(.critical).heatLocked)
    }

    func testAModeRequestFromAButtonIsKeptThenExpires() {
        ThermyxModeInbox.clear()
        ThermyxModeInbox.onRequest = nil
        ThermyxModeInbox.submit(.cool)
        XCTAssertEqual(ThermyxModeInbox.pending(), .cool)
        XCTAssertNil(ThermyxModeInbox.pending(now: .now.addingTimeInterval(ThermyxModeInbox.expiry + 5)),
                     "A request nobody picked up goes stale")
        XCTAssertEqual(ThermyxModeInbox.take(), .cool)
        XCTAssertNil(ThermyxModeInbox.pending(), "Taken once")
    }

    func testSoleViewStepsThroughAllThree() {
        XCTAssertEqual(ThermyxSoleView.temperature.next, .pressure)
        XCTAssertEqual(ThermyxSoleView.pressure.next, .gait)
        XCTAssertEqual(ThermyxSoleView.gait.next, .temperature)
    }

    func testBluetoothMessagesSayWhatToDo() {
        XCTAssertTrue(ThermyxBLEService.unavailableMessage(.poweredOff).contains("Turn it on"))
        XCTAssertTrue(ThermyxBLEService.unavailableMessage(.unauthorized).contains("Settings"))
        XCTAssertTrue(ThermyxBLEService.unavailableMessage(.unsupported).contains("Bluetooth LE"))
    }
}
