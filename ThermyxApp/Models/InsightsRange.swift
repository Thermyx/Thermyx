import Foundation

enum InsightsRange: String, CaseIterable, Identifiable, Codable {
    case day
    case week
    case month

    var id: String { rawValue }

    var label: String {
        switch self {
        case .day: return "Day"
        case .week: return "Week"
        case .month: return "Month"
        }
    }

    /// How far back this range reaches.
    var duration: TimeInterval {
        switch self {
        case .day: return 24 * 3600
        case .week: return 7 * 24 * 3600
        case .month: return 30 * 24 * 3600
        }
    }

    /// Minute buckets are retained for a week; anything longer reads from the
    /// hourly tier.
    var usesHourlyTier: Bool { self == .month }

    /// The caption shown beside a detail-screen title.
    var titleCaption: String {
        switch self {
        case .day: return "Today"
        case .week: return "This week"
        case .month: return "This month"
        }
    }
}
