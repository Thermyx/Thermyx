import SwiftUI

/// A Learn article: a newspaper-style feature with a photograph, a body of
/// typed blocks, and APA 7 references. Bundled in
/// Resources/Content/learning-articles.json.
struct LearningArticle: Codable, Identifiable, Equatable {
    let id: String
    let section: LearningSection
    let title: String
    /// The standfirst under the headline.
    let dek: String
    let image: Photo
    /// Live situations this article is the lesson for (see `LearningSuggestion`).
    let triggers: [String]
    let blocks: [Block]
    /// APA 7, with `*asterisks*` for italics.
    let references: [String]

    struct Photo: Codable, Equatable {
        /// The asset catalog name; its credit is in photo-credits.json.
        let asset: String
        let alt: String
        let caption: String
    }

    struct Block: Codable, Equatable {
        enum Kind: String, Codable {
            /// The opening paragraph, set larger, first sentence bold.
            case lede
            case p
            /// A subhead.
            case h
            /// A pull quote, with its source.
            case quote
            /// A numbered "what to do" box.
            case steps
            /// A bulleted list.
            case list
            /// A large figure with a line of text and its source.
            case fact
            /// A tinted sidebar.
            case note
        }

        let type: Kind
        var text: String?
        var title: String?
        var items: [String]?
        var source: String?
        var figure: String?

        /// What a screen reader or the narrator says for this block.
        var spoken: String {
            switch type {
            case .steps, .list:
                return ([title].compactMap { $0 } + (items ?? [])).joined(separator: ". ")
            case .fact:
                return [figure, text].compactMap { $0 }.joined(separator: " ")
            case .note:
                return [title, text].compactMap { $0 }.joined(separator: ". ")
            case .quote:
                return [text, source.map { "— \($0)" }].compactMap { $0 }.joined(separator: " ")
            default:
                return text ?? ""
            }
        }
    }

    var kicker: String { section.label }
    /// Worked out from the words, at an easy 200 a minute, so the label
    /// matches the article rather than a number typed by hand.
    var readMinutes: Int {
        let words = blocks.reduce(0) { total, block in
            total + ([block.text, block.title, block.figure].compactMap { $0 } + (block.items ?? []))
                .reduce(0) { $0 + $1.split(whereSeparator: \.isWhitespace).count }
        }
        return max(1, Int((Double(words) / 200).rounded(.up)))
    }
    var meta: String { "\(readMinutes) min read" }
}

enum LearningSection: String, Codable, CaseIterable, Identifiable {
    case heat, feet, recovery, cold, data

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heat: return "Heat"
        case .feet: return "Feet"
        case .recovery: return "Recovery"
        case .cold: return "Cold"
        case .data: return "Your data"
        }
    }

    /// The section's colour on the front page and the article's kicker.
    var tint: Color {
        switch self {
        case .heat: return Thermyx.Ink.ember
        case .feet: return Thermyx.Ink.amber
        case .recovery: return Thermyx.Ink.ice
        case .cold: return Thermyx.Ink.signal
        case .data: return Thermyx.Ink.textMuted
        }
    }
}

/// Loads the bundled articles.
enum ThermyxLearningLibrary {
    private struct Payload: Codable { let articles: [LearningArticle] }

    /// Loaded once. A packaging mistake returns an empty library rather than
    /// trapping: Learn then shows its empty state, which is honest, and the
    /// live safety screens keep running.
    static let articles: [LearningArticle] = {
        guard let url = Bundle.main.url(forResource: "learning-articles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }
        return payload.articles
    }()

    static func article(id: String) -> LearningArticle? {
        articles.first { $0.id == id }
    }
}

// MARK: - Photo credits

/// Who took each bundled photograph, and its licence. Shown under every
/// photo and listed in full under Learn → Photo credits.
struct PhotoCredit: Codable, Identifiable, Equatable {
    let asset: String
    let title: String
    let author: String
    let license: String
    let licenseURL: String?
    let source: String
    /// Cropped or resized for the app (relevant to the CC BY licences).
    let modified: Bool

    var id: String { asset }

    /// "Photo: Matti Blume · CC BY-SA 4.0"
    var line: String { "Photo: \(author) · \(license)" }

    private struct Payload: Codable { let photos: [PhotoCredit] }

    static let all: [PhotoCredit] = {
        guard let url = Bundle.main.url(forResource: "photo-credits", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return [] }
        return payload.photos
    }()

    static func `for`(_ asset: String) -> PhotoCredit? { all.first { $0.asset == asset } }
}

// MARK: - Just-in-time

/// The lesson that fits what's happening now, and why. Plain rules over the
/// same live readings the risk engine sees, so each suggestion can be traced
/// to the signal behind it.
struct LearningSuggestion: Equatable {
    let article: LearningArticle
    /// "Your left foot is at 37.9° and rising."
    let reason: String

    struct Context {
        var reading: BilateralReading
        var assessment: ThermyxRiskAssessment
        var connected: [Foot]
        var pairExpected: Bool
        /// Change in the warmer foot over the last 10 minutes, °C.
        var trend10: Double?
        /// The worst level in the last two hours of history.
        var recentPeak: ThermyxRiskLevel?
        /// Local air temperature, when known.
        var airC: Double?
        /// Days of history on this phone.
        var daysOfHistory: Int
        var unit: TemperatureUnit
        /// A lean or limp held for minutes, from `AsymmetryMonitor`.
        var asymmetry: AsymmetryStatus = .none
    }

    static func current(_ c: Context) -> LearningSuggestion? {
        func make(_ id: String, _ reason: String) -> LearningSuggestion? {
            ThermyxLearningLibrary.article(id: id).map { LearningSuggestion(article: $0, reason: reason) }
        }
        let peak = c.reading.peakFootTemperatureC
        let level = c.assessment.level
        let degrees = { (v: Double) in TemperatureFormat.degrees(v, in: c.unit) }

        if level.severity >= ThermyxRiskLevel.high.severity {
            return make("heat-illness", "Your level is \(level.rawValue). Know the signs that need help now.")
        }
        if !c.connected.isEmpty {
            if c.reading.present.contains(where: { $0.footTemperatureC == nil }) {
                return make("sensor-reliability", "An insole is connected but not reporting temperature.")
            }
            if let low = c.reading.present.first(where: { ($0.batteryPercent ?? 100) <= ThermyxComfortWatch.batteryLow }) {
                return make("sensor-reliability", "Your \(low.foot.label.lowercased()) insole's battery is low.")
            }
            if c.pairExpected, c.connected.count == 1 {
                return make("sensor-reliability", "Only one insole is reporting.")
            }
        }
        if let peak, peak <= ThermyxRiskEngine.coldFootC {
            return make("cold-feet", "Your foot is at \(degrees(peak)).")
        }
        if let peak, peak >= 37.5 || (c.trend10 ?? 0) >= 1.5 {
            let rising = (c.trend10 ?? 0) >= 1 ? " and rising" : ""
            return make("overheating", "Your warmer foot is at \(degrees(peak))\(rising).")
        }
        if let limp = c.asymmetry.findings.first(where: { $0.kind == .limp }) {
            return make("fit-pressure", "You've been favouring your \(limp.foot.label.lowercased()) foot as you walk.")
        }
        if let lean = c.asymmetry.findings.first(where: { $0.kind == .lean }) {
            return make("fit-pressure", "You've been leaning on your \(lean.foot.label.lowercased()) foot for a while.")
        }
        if let recent = c.recentPeak, recent.severity >= ThermyxRiskLevel.caution.severity, level == .normal {
            return make("recovery", "You reached \(recent.rawValue) in the last two hours.")
        }
        if let air = c.airC, air >= 30 {
            if c.daysOfHistory <= 3 {
                return make("acclimatization", "It's \(degrees(air)) outside, and you're new to Thermyx.")
            }
            return make("hydration", "It's \(degrees(air)) outside.")
        }
        return nil
    }
}
