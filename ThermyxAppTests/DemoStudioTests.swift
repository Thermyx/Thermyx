import XCTest
@testable import ThermyxApp

/// The Demo studio's timeline and its alerts.
final class DemoStudioTests: XCTestCase {
    func testConditionsFollowTheEventsUnderThePlayhead() {
        let script = DemoScript(events: [
            DemoEvent(.heat, at: 5, length: 10),
            DemoEvent(.limp, at: 8, length: 4, foot: .left),
            DemoEvent(.quiet, at: 20, length: 3),
        ], length: 30)
        XCTAssertNil(script.conditions(at: 1).ambientC, "The usual day before anything happens")
        let mid = script.conditions(at: 9)
        XCTAssertEqual(mid.limp, .left)
        XCTAssertEqual(mid.activity, .walking)
        XCTAssertGreaterThan(mid.ambientC ?? 0, DemoScript.baseAmbientC)
        XCTAssertEqual(script.conditions(at: 14).ambientC ?? 0, 40, accuracy: 0.01, "Heat climbs over the first half, then holds")
        XCTAssertNil(script.conditions(at: 12.5).limp, "Over when it ends")
        XCTAssertTrue(script.conditions(at: 21).quiet)
        XCTAssertFalse(script.conditions(at: 23.5).quiet)
    }

    func testOneOffEventsFireOnceAsThePlayheadPasses() {
        let script = DemoScript(events: [DemoEvent(.sos, at: 10), DemoEvent(.checkIn, at: 12)], length: 20)
        XCTAssertEqual(script.instants(after: 9.9, through: 10).map(\.kind), [.sos])
        XCTAssertTrue(script.instants(after: 10, through: 11).isEmpty, "Not again")
        XCTAssertEqual(script.instants(after: 0, through: 20).map(\.kind), [.sos, .checkIn])
    }

    func testTheSeededGeneratorReplaysExactly() {
        var a = DemoRandom(seed: 42), b = DemoRandom(seed: 42)
        let first = (0..<100).map { _ in a.double(in: -1...1) }
        let second = (0..<100).map { _ in b.double(in: -1...1) }
        XCTAssertEqual(first, second)
        XCTAssertTrue(first.allSatisfy { (-1...1).contains($0) })
    }

    @MainActor
    func testScrubbingLandsWhereThePlaythroughWould() {
        let ble = ThermyxBLEService()
        ble.startDemoMode()
        guard let sim = ble.simulator else { return XCTFail("No simulated pair") }
        sim.connect(feet: Foot.allCases)
        let player = DemoPlayer()
        player.script = DemoScript(events: [DemoEvent(.heat, at: 0, length: 10), DemoEvent(.battery9, at: 3, foot: .left)], length: 10)
        player.attach(sim)
        player.load()
        var fired: [DemoEventKind] = []
        player.onInstant = { fired.append($0.kind) }

        // Play through to 5:00 by stepping, then scrub back and forth to 5:00.
        sim.fastForward(seconds: 5 * DemoPlayer.pace)
        let played = sim.snapshot()
        XCTAssertEqual(player.playhead, 5, accuracy: 0.001)
        XCTAssertEqual(fired, [.battery9], "Passing it while playing fires it")
        player.seek(to: 2)
        player.seek(to: 5)
        XCTAssertEqual(player.playhead, 5, accuracy: 0.001)
        XCTAssertEqual(fired, [.battery9], "Scrubbing past it doesn't fire it again")
        XCTAssertEqual(String(describing: sim.snapshot()), String(describing: played), "Same feet, same moment")
        ble.stopDemoMode()
    }

    func testAPresetNeverRunsPastItsEnd() {
        for preset in DemoScript.presets {
            XCTAssertTrue(preset.script.events.allSatisfy { $0.end <= preset.script.length }, preset.name)
        }
    }

    func testHelpNotesStayInTheSMSAlphabet() {
        XCTAssertEqual(ThermyxCircleMessage.plainNote("By gate “B” 🔥 please"), "By gate \"B\" please")
        XCTAssertNil(ThermyxCircleMessage.plainNote("🔥"))
        XCTAssertEqual(ThermyxCircleMessage.plainNote(String(repeating: "a", count: 200))?.count, 80)
    }

    func testHighAndCriticalBreakThroughFocus() {
        XCTAssertEqual(ThermyxAlertCoordinator.interruption(for: .critical), .timeSensitive)
        XCTAssertEqual(ThermyxAlertCoordinator.interruption(for: .high), .timeSensitive)
        XCTAssertEqual(ThermyxAlertCoordinator.interruption(for: .caution), .active)
    }

    func testOldSnapshotsDecodeWithoutTheNewWidgetFields() throws {
        let json = #"{"updated":790000000,"live":true,"isDemo":false,"fahrenheit":false,"mode":"auto","level":"normal","temps":[]}"#
        let s = try JSONDecoder().decode(ThermyxWidgetSnapshot.self, from: Data(json.utf8))
        XCTAssertNil(s.readiness)
        XCTAssertNil(s.lastCheckIn)
    }
}
