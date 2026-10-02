import Foundation

/// Decides, reading by reading, whether to notify the wearer, send an alert
/// to the relay, or just post the once-a-minute heartbeat. Pure, so every rule
/// below is unit tested. The edge cases follow Aaron Qin's alert policy.
///
/// - A rise to a new level notifies the wearer and alerts at once.
/// - A higher level always alerts, even mid-reminder or after "I'm OK".
/// - High and Critical remind every five minutes while they last. Caution
///   does not nag.
/// - A level that dips and comes back within two minutes is the same
///   episode: no second alert. Only a level that has stayed lower for two
///   minutes counts as having eased.
/// - "I'm OK" quiets reminders for 30 minutes, never a rise.
/// - Losing the data is not an all-clear.
struct ThermyxAlertPolicy: Equatable {
    struct Decision: Equatable {
        var notifyWearer = false
        var alert = false
        var heartbeat = false
    }

    static let reminderInterval: TimeInterval = 5 * 60
    static let settleInterval: TimeInterval = 2 * 60
    static let okQuietInterval: TimeInterval = 30 * 60
    static let heartbeatInterval: TimeInterval = 60

    /// The highest level announced in the current episode.
    private(set) var announced: ThermyxRiskLevel = .normal
    private var lowerSince: Date?
    private var lastAlertAt: Date?
    private var lastPostAt: Date?
    private var okUntil: Date?

    /// - Parameter alertsEnabled: whether the wearer wants the relay told
    ///   about this level at all.
    mutating func evaluate(_ level: ThermyxRiskLevel, alertsEnabled: Bool, now: Date = .now) -> Decision {
        var decision = Decision()
        guard level != .unavailable else { return decision }

        // Easing off only counts once it has held.
        if level.severity < announced.severity {
            if lowerSince == nil { lowerSince = now }
            if let since = lowerSince, now.timeIntervalSince(since) >= Self.settleInterval {
                announced = level
                lowerSince = nil
                if level == .normal {
                    lastAlertAt = nil
                    okUntil = nil
                }
            }
        } else {
            lowerSince = nil
        }

        if level.severity > announced.severity {
            announced = level
            decision.notifyWearer = true
            if alertsEnabled {
                decision.alert = true
                lastAlertAt = now
            }
        } else if alertsEnabled,
                  level.severity >= ThermyxRiskLevel.high.severity,
                  level.severity >= announced.severity,
                  okUntil.map({ now >= $0 }) ?? true,
                  lastAlertAt.map({ now.timeIntervalSince($0) >= Self.reminderInterval }) ?? true {
            decision.alert = true
            lastAlertAt = now
        }

        if !decision.alert, lastPostAt.map({ now.timeIntervalSince($0) >= Self.heartbeatInterval }) ?? true {
            decision.heartbeat = true
        }
        if decision.alert || decision.heartbeat { lastPostAt = now }
        return decision
    }

    /// The wearer checked in: no reminders for a while, but a rise still alerts.
    mutating func imOK(now: Date = .now) {
        okUntil = now.addingTimeInterval(Self.okQuietInterval)
    }

    /// Forces the next status post (e.g. after the wearer changes a setting).
    mutating func postNow() { lastPostAt = nil }
}
