import Foundation

/// Links into the app from outside it: `thermyx://sos` from the Safety
/// widget opens Safety and asks to confirm a 911 call. Nothing is sent or
/// dialled without the wearer confirming in the app.
@MainActor
final class ThermyxDeepLink: ObservableObject {
    static let shared = ThermyxDeepLink()

    @Published var sosRequest: Date?
    /// Open AI Insights for this day (from the evening notification).
    @Published var insightsDay: Date?

    /// True when the URL was one of ours.
    @discardableResult
    func handle(_ url: URL) -> Bool {
        guard url.scheme == "thermyx" else { return false }
        if url.host == "sos" { sosRequest = .now }
        return true
    }
}
