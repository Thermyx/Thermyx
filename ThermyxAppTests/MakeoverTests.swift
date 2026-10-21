import XCTest
@testable import ThermyxApp

/// Learn's articles cite real sources; lessons match live situations.
final class MakeoverTests: XCTestCase {

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
                    recent: ThermyxRiskLevel? = nil, air: Double? = nil, days: Int = 30,
                    asymmetry: AsymmetryStatus = .none) -> String? {
            LearningSuggestion.current(.init(
                reading: pair, assessment: .init(level: level, reasons: []), connected: pair.feet, pairExpected: false,
                trend10: trend, recentPeak: recent, airC: air, daysOfHistory: days, unit: .celsius,
                asymmetry: asymmetry
            ))?.article.id
        }
        XCTAssertEqual(lesson(.init(left: reading(c: 38.5), right: nil), level: .high), "heat-illness")
        XCTAssertEqual(lesson(.init(left: reading(c: 37.8), right: nil)), "overheating")
        XCTAssertEqual(lesson(.init(left: reading(c: 24), right: nil)), "cold-feet")
        XCTAssertEqual(lesson(.init(left: reading(c: nil), right: nil)), "sensor-reliability")
        XCTAssertEqual(lesson(.init(left: reading(c: 31, battery: 10), right: nil)), "sensor-reliability")
        // One heavy moment is not a lean; minutes of it (the monitor's finding) are.
        let heavy = BilateralReading(left: reading(c: 31, load: 0.8), right: reading(foot: .right, c: 31, load: 0.4))
        XCTAssertNil(lesson(heavy))
        let lean = AsymmetryStatus(findings: [.init(kind: .lean, foot: .left, heldSeconds: 240, whileWalking: false, contributions: [])], metrics: nil)
        XCTAssertEqual(lesson(heavy, asymmetry: lean), "fit-pressure")
        XCTAssertEqual(lesson(.init(left: reading(c: 31), right: nil), recent: .caution), "recovery")
        XCTAssertEqual(lesson(.init(left: reading(c: 31), right: nil), air: 33), "hydration")
        XCTAssertEqual(lesson(.init(left: reading(c: 31), right: nil), air: 33, days: 1), "acclimatization")
        XCTAssertNil(lesson(.init(left: reading(c: 31), right: nil)))
    }
}
