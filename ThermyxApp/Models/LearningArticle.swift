import SwiftUI

struct LearningArticle: Codable, Identifiable, Equatable {
    let id: String
    let category: LearningCategory
    let title: String
    let deck: String
    let readMinutes: Int
    let featured: Bool
    let status: Status
    let sections: [Section]
    let sources: String
    /// SF Symbol for the topic card; falls back to the category's.
    var icon: String?
    /// A drawn diagram shown at the top of the article: "peltier",
    /// "modes" or "comfortBand".
    var visual: String?

    var symbol: String { icon ?? category.symbol }

    enum Status: String, Codable {
        /// Copy has been written and cited.
        case published
        /// Structure is real, copy is an outline awaiting writing and sources.
        case placeholder
    }

    struct Section: Codable, Equatable {
        let kind: Kind
        let text: String

        enum Kind: String, Codable {
            case body
            /// The Ember-ruled figure callout.
            case pullStat
            /// The "What to do with this" card.
            case action
        }
    }

    var meta: String { "\(readMinutes) min · \(category.label)" }
    var kicker: String { "\(readMinutes) min read" }
}

enum LearningCategory: String, Codable, CaseIterable, Identifiable {
    case heat
    case cold
    case feet
    case device

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heat: return "Heat"
        case .cold: return "Cold"
        case .feet: return "Feet"
        case .device: return "Your Thermyx"
        }
    }

    var tint: Color {
        switch self {
        case .heat: return Thermyx.Ink.amber
        case .cold: return Thermyx.Ink.ice
        case .feet: return Thermyx.Ink.textSecondary
        case .device: return Thermyx.Ink.signal
        }
    }

    var iconFill: Color {
        switch self {
        case .heat: return Thermyx.Tint.emberFill
        case .cold: return Color(hex: 0x2C9CF0, opacity: 0.14)
        case .feet: return Thermyx.Tint.neutralFill
        case .device: return Thermyx.Tint.signalFill
        }
    }

    var symbol: String {
        switch self {
        case .heat: return "thermometer.sun.fill"
        case .cold: return "snowflake"
        case .feet: return "shoeprints.fill"
        case .device: return "cpu"
        }
    }
}

/// A filter chip on the Learning Center, including the "All" case.
enum LearningFilter: Hashable, Identifiable, CaseIterable {
    case all
    case category(LearningCategory)

    static var allCases: [LearningFilter] { [.all] + LearningCategory.allCases.map(LearningFilter.category) }

    var id: String {
        switch self {
        case .all: return "all"
        case .category(let category): return category.rawValue
        }
    }

    var label: String {
        switch self {
        case .all: return "All"
        case .category(let category): return category.label
        }
    }

    func matches(_ article: LearningArticle) -> Bool {
        switch self {
        case .all: return true
        case .category(let category): return article.category == category
        }
    }
}

/// Loads the bundled Learning Center content.
enum ThermyxLearningLibrary {
    private struct Payload: Codable { let articles: [LearningArticle] }

    /// Loaded once from the bundle.
    ///
    /// A packaging mistake returns an empty library rather than trapping. The
    /// Learning Center then shows its empty state, which is the honest
    /// outcome — crashing the whole app because an article file is missing
    /// would take down the live safety screens with it.
    static let articles: [LearningArticle] = {
        guard let url = Bundle.main.url(forResource: "learning-articles", withExtension: "json"),
              let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else {
            return []
        }
        return payload.articles
    }()

    static var featured: LearningArticle? { articles.first(where: \.featured) }
    static var rest: [LearningArticle] { articles.filter { !$0.featured } }

    static func article(id: String) -> LearningArticle? {
        articles.first { $0.id == id }
    }
}

/// A tip on the Learn tab, worked out on the phone from plain rules over
/// today's data and the profile. No AI model or network is involved.
struct LearnSuggestion: Identifiable, Equatable {
    enum Tone: Equatable { case neutral, warm, cool, caution }
    let id: String
    let symbol: String
    let title: String
    let text: String
    /// A short figure shown on the card, e.g. "3 h warm".
    var figure: String?
    var tone: Tone = .neutral
    /// The article that goes deeper, if any.
    var articleID: String?

    static let maximum = 3

    static func make(
        today: ThermyxDailySummary?,
        calibrated: Bool,
        profile: UserProfile,
        current: BilateralReading,
        usualSteadiness: Double?
    ) -> [LearnSuggestion] {
        var out: [LearnSuggestion] = []
        let conditions = profile.conditionSet

        if !calibrated {
            out.append(.init(id: "calibrate", symbol: "figure.walk.motion", title: "Calibrate Thermyx",
                             text: "About 3 minutes of sitting, standing and walking teaches Thermyx your normal and sets Auto for you. Start it from Home.",
                             articleID: "modes"))
        }
        if let lowest = current.present.compactMap(\.batteryPercent).min(), lowest <= 20 {
            out.append(.init(id: "battery", symbol: "battery.25percent", title: "Charge your insoles soon",
                             text: "Heating and cooling use the most power. Auto saves battery by resting when your foot is already comfortable.",
                             figure: "\(lowest)%", tone: .caution, articleID: "how-peltier-works"))
        }
        if let today, today.hotHours >= 2 || (today.peakFootC ?? 0) >= ThermyxTemperatureScale.warm {
            out.append(.init(id: "warm-day", symbol: "sun.max.fill", title: "Your feet ran warm today",
                             text: "Plan shade and water breaks for days like this, and switch to Cool or Auto before your feet get hot, not after.",
                             figure: today.hotHours > 0 ? "\(today.hotHours) h warm" : nil, tone: .warm, articleID: "hydration"))
        }
        if conditions.contains(.heatSensitivity), !out.contains(where: { $0.id == "warm-day" }) {
            out.append(.init(id: "heat-sensitive", symbol: "thermometer.sun.fill", title: "Get ahead of the heat",
                             text: "You said heat affects you. Turn on Auto before you head out on warm days so cooling starts early.",
                             tone: .warm, articleID: "hydration"))
        }
        if conditions.contains(.poorCirculation) || (today?.lowFootC ?? 99) <= ThermyxRiskEngine.coldFootC {
            out.append(.init(id: "cold", symbol: "snowflake", title: "Keep your feet warm gently",
                             text: "Warm cold feet gradually with Auto or Heat rather than direct heat, and move your toes and ankles every so often.",
                             figure: (today?.lowFootC).map { String(format: "low %.0f °C", $0) }, tone: .cool, articleID: "cold-feet"))
        }
        if conditions.contains(.neuropathy) || conditions.contains(.diabetes) {
            out.append(.init(id: "check-feet", symbol: "eye.fill", title: "Look at your feet after wearing",
                             text: "With reduced feeling you may not notice heat or rubbing. Check your feet for redness or blisters after each session, and keep Heat use short.",
                             tone: .caution, articleID: "what-thermyx-is-not"))
        }
        if let now = current.present.compactMap(\.gaitStability).min(), let usual = usualSteadiness, usual - now >= 0.08 {
            out.append(.init(id: "steadiness", symbol: "figure.walk", title: "Your steps are less steady than usual",
                             text: "That can be tiredness. Slow down, take a break, and check both insoles sit flat.",
                             figure: "\(Int((now * 100).rounded()))% now", tone: .caution, articleID: "fatigue-gait"))
        }
        if let cooling = today?.coolingSeconds, cooling >= 30 * 60 {
            out.append(.init(id: "cooling", symbol: "fan.fill", title: "Cooling worked hard today",
                             text: "Keep the fan vent clear, and use Auto so the insole rests when your foot is already in range.",
                             figure: "\(Int(cooling / 60)) min", tone: .cool, articleID: "how-peltier-works"))
        }
        if profile.focus == .performance {
            out.append(.init(id: "performance", symbol: "figure.run", title: "Watch your steadiness and cadence",
                             text: "A steady walk that slips late in a session is an early fatigue sign. Compare days in Insights.",
                             articleID: "fatigue-gait"))
        }
        if out.isEmpty {
            out.append(.init(id: "start", symbol: "slider.horizontal.3", title: "Get to know the modes",
                             text: "Auto is the one to use most of the time. Cool and Heat are for quick changes, and Off saves battery.",
                             articleID: "modes"))
        }
        return Array(out.prefix(maximum))
    }
}
