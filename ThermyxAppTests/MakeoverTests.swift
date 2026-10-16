import XCTest
@testable import ThermyxApp

/// The Simulator's model drives the real decision engine; Learn's articles
/// cite real sources; lessons match live situations.
final class MakeoverTests: XCTestCase {

    // MARK: Simulator

    private func scenario(_ id: String) -> ThermalSimulation.Scenario {
        ThermalSimulation.Scenario.all.first { $0.id == id }!
    }

    private func run(_ sim: inout ThermalSimulation, minutes: Int) {
        for _ in 0..<minutes { sim.step() }
    }

    func testThermyxKeepsAHotFootInTheSafeBandLongerThanAPassiveInsole() {
        var sim = ThermalSimulation(scenario: scenario("site"))
        run(&sim, minutes: 120)
        let m = sim.minutesOutsideBand
        XCTAssertGreaterThan(m.without, 0, "The job site should push a passive insole past 38°")
        XCTAssertLessThan(m.with, m.without, "Auto's cooling should shorten the time outside the band")
    }

    func testHeatIsPulledToCoolAtHighRisk() {
        var sim = ThermalSimulation(scenario: scenario("site"))
        sim.update { $0.setting = .heat }
        var sawHigh = false
        for _ in 0..<180 {
            sim.step()
            if sim.assessment.level.locksOutHeating { sawHigh = true; break }
        }
        XCTAssertTrue(sawHigh, "Heat on a hot site should reach High")
        XCTAssertEqual(sim.setting, .cool, "The app's lockout pulls Heat to Cool at High")
        XCTAssertTrue(sim.events.contains { $0.title.hasPrefix("Heat locked out") })
    }

    func testHeatingNeverTakesTheFootPastTheBurnLimit() {
        var sim = ThermalSimulation(scenario: scenario("desk"))
        sim.update { $0.setting = .heat }
        run(&sim, minutes: 200)
        let hottest = sim.samples.map(\.trueC).max() ?? 0
        XCTAssertLessThan(hottest, ThermyxRiskEngine.burnLimitC + 0.5, "The firmware stops heating at 40°")
    }

    func testColdWetBootsWithTheInsolesOffRaiseCaution() {
        var sim = ThermalSimulation(scenario: scenario("wet"))
        var level = ThermyxRiskLevel.normal
        for _ in 0..<120 {
            sim.step()
            if sim.assessment.level == .caution { level = .caution; break }
        }
        XCTAssertEqual(level, .caution)
        XCTAssertTrue(sim.assessment.reasons.contains { $0.contains("low") })
    }

    func testNoInsolesMeansNothingToAssess() {
        var sim = ThermalSimulation(scenario: scenario("desk"))
        sim.update { $0.connection = .none }
        sim.step()
        XCTAssertFalse(sim.reading.hasAny)
        XCTAssertEqual(sim.assessment.level, .unavailable)
    }

    func testASensorDropoutReportsNothingRatherThanAnEstimate() {
        var sim = ThermalSimulation(scenario: scenario("desk"))
        sim.update { $0.fault = .temperatureDropout }
        sim.step()
        XCTAssertNil(sim.reading.left?.footTemperatureC)
        XCTAssertNotNil(sim.reading.right?.footTemperatureC)
    }

    func testSimulatedReadingsCarryOnlyWhatTheHardwareSenses() {
        var sim = ThermalSimulation(scenario: scenario("site"))
        sim.step()
        for r in sim.reading.present {
            XCTAssertNil(r.ambientTemperatureC, "The insole has no air sensor")
            XCTAssertNil(r.zones, "One temperature sensor per insole")
            XCTAssertTrue(r.loadIsArchLevel, "One arch pressure sensor")
        }
    }

    // MARK: Learn

    func testEveryArticleIsCitedAndHasACreditedPhoto() {
        let articles = ThermyxLearningLibrary.articles
        XCTAssertEqual(articles.count, 8)
        for id in ["overheating", "fit-pressure", "recovery", "sensor-reliability"] {
            XCTAssertNotNil(ThermyxLearningLibrary.article(id: id), "The brief's lesson \(id)")
        }
        for article in articles {
            XCTAssertGreaterThanOrEqual(article.references.count, 2, article.id)
            XCTAssertNotNil(PhotoCredit.for(article.image.asset), "\(article.id) photo needs a credit")
            XCTAssertEqual(article.references, article.references.sorted { $0.lowercased() < $1.lowercased() },
                           "APA lists references alphabetically")
            for reference in article.references {
                XCTAssertNotNil(reference.range(of: #"\((\d{4}|n\.d\.)\)\."#, options: .regularExpression), reference)
                XCTAssertTrue(reference.contains("https://"), "Every reference links its source: \(reference)")
            }
        }
    }

    func testInTextCitationsAllAppearInTheReferences() {
        for article in ThermyxLearningLibrary.articles {
            let text = article.blocks.map { [$0.text, $0.source].compactMap { $0 }.joined(separator: " ") + ($0.items ?? []).joined(separator: " ") }
                .joined(separator: " ")
            let regex = try! NSRegularExpression(pattern: #"\(([^()]*?(\d{4}|n\.d\.))\)"#)
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let group = String(text[Range(match.range(at: 1), in: text)!])
                for cite in group.split(separator: ";") {
                    let parts = cite.trimmingCharacters(in: .whitespaces)
                    guard let yearRange = parts.range(of: #"(\d{4}|n\.d\.)$"#, options: .regularExpression) else { continue }
                    let year = String(parts[yearRange])
                    let author = parts.components(separatedBy: CharacterSet(charactersIn: ",&")).first!
                        .replacingOccurrences(of: " et al.", with: "").trimmingCharacters(in: .whitespaces)
                    XCTAssertTrue(article.references.contains { $0.hasPrefix(author) && $0.contains("(\(year))") },
                                  "\(article.id): (\(parts)) has no reference")
                }
            }
        }
    }

    func testTheLessonMatchesWhatsHappening() {
        func reading(foot: Foot = .left, c: Double?, battery: Int = 80, load: Double? = 0.5) -> ThermyxReading {
            var r = ThermyxReading(foot: foot, timestamp: .now, footTemperatureC: c, ambientTemperatureC: nil, pressureBalance: load,
                                   gaitStability: 0.95, batteryPercent: battery, thermalMode: .off)
            r.loadIsArchLevel = true
            return r
        }
        func lesson(_ pair: BilateralReading, level: ThermyxRiskLevel = .normal, trend: Double? = nil,
                    recent: ThermyxRiskLevel? = nil, air: Double? = nil, days: Int = 30) -> String? {
            LearningSuggestion.current(.init(
                reading: pair, assessment: .init(level: level, reasons: []), connected: pair.feet, pairExpected: false,
                trend10: trend, recentPeak: recent, airC: air, daysOfHistory: days, unit: .celsius
            ))?.article.id
        }
        XCTAssertEqual(lesson(.init(left: reading(c: 38.5), right: nil), level: .high), "heat-illness")
        XCTAssertEqual(lesson(.init(left: reading(c: 37.8), right: nil)), "overheating")
        XCTAssertEqual(lesson(.init(left: reading(c: 24), right: nil)), "cold-feet")
        XCTAssertEqual(lesson(.init(left: reading(c: nil), right: nil)), "sensor-reliability")
        XCTAssertEqual(lesson(.init(left: reading(c: 31, battery: 10), right: nil)), "sensor-reliability")
        XCTAssertEqual(lesson(.init(left: reading(c: 31, load: 0.8), right: reading(foot: .right, c: 31, load: 0.4))), "fit-pressure")
        XCTAssertEqual(lesson(.init(left: reading(c: 31), right: nil), recent: .caution), "recovery")
        XCTAssertEqual(lesson(.init(left: reading(c: 31), right: nil), air: 33), "hydration")
        XCTAssertEqual(lesson(.init(left: reading(c: 31), right: nil), air: 33, days: 1), "acclimatization")
        XCTAssertNil(lesson(.init(left: reading(c: 31), right: nil)))
    }
}
