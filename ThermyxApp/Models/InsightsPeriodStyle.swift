import Foundation

/// How a range's window is anchored.
///
/// **Standard** snaps to the boundaries people actually think in: a day starts
/// at midnight, a week on Sunday, a month on the first. It answers "how has
/// today gone".
///
/// **Rolling** keeps a continuous trailing window — the last 24 hours, 7 days,
/// or 30 days. It answers "how have I been recently", and never shrinks to
/// near-nothing just after a boundary passes.
enum InsightsPeriodStyle: String, CaseIterable, Identifiable, Codable {
    case standard
    case rolling

    var id: String { rawValue }
    var label: String { self == .standard ? "Standard" : "Rolling" }
}

extension InsightsRange {
    /// The window this range covers, given a period style.
    func window(style: InsightsPeriodStyle, now: Date = .now, calendar: Calendar = .current) -> DateInterval {
        switch style {
        case .rolling:
            return DateInterval(start: now.addingTimeInterval(-duration), end: now)

        case .standard:
            let start: Date
            switch self {
            case .day:
                start = calendar.startOfDay(for: now)
            case .week:
                // `Calendar.current` already honours the user's first weekday;
                // forcing Sunday here would be wrong outside the US.
                start = calendar.dateInterval(of: .weekOfYear, for: now)?.start
                    ?? calendar.startOfDay(for: now)
            case .month:
                start = calendar.dateInterval(of: .month, for: now)?.start
                    ?? calendar.startOfDay(for: now)
            }
            return DateInterval(start: start, end: now)
        }
    }

    /// The caption beside a detail-screen title.
    func caption(style: InsightsPeriodStyle) -> String {
        switch (self, style) {
        case (.day, .standard): return "Today"
        case (.week, .standard): return "This week"
        case (.month, .standard): return "This month"
        case (.day, .rolling): return "Last 24 hours"
        case (.week, .rolling): return "Last 7 days"
        case (.month, .rolling): return "Last 30 days"
        }
    }
}
