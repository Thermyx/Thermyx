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
