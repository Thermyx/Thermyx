import Foundation

/// Decides, reading by reading, whether to notify the wearer, send an alert
/// to the relay, send a follow-up, or just post the once-a-minute heartbeat.
/// Pure, so every rule below is unit tested. The edge cases follow Aaron
/// Qin's alert policy.
///
/// - A rise to a new level notifies the wearer and alerts at once.
/// - A higher level always alerts, even mid-reminder or after "I'm OK".
/// - High and Critical follow up while they last: "still High risk after 2
///   minutes", then every five minutes. Caution does not nag.
/// - A level that dips and comes back within two minutes is the same
///   episode: no second alert. Only a level that has stayed lower for two
///   minutes counts as having eased, and then the circle hears it's
///   recovering, or back to Normal.
/// - "I'm OK" quiets the reminders for 30 minutes, never a rise.
/// - Losing the data is not an all-clear.
struct ThermyxAlertPolicy: Equatable {
    /// A follow-up to an alert the circle was sent.
    enum FollowUp: Equatable {
        /// The level hasn't eased; minutes since the alert.
        case still(minutes: Int)
        /// Eased to a lower level that isn't Normal yet.
        case recovering
        /// Back to Normal.
        case resolved
    }

    struct Decision: Equatable {
        var notifyWearer = false
        var alert = false
        var followUp: FollowUp?
        var heartbeat = false
    }

    static let firstFollowUp: TimeInterval = 2 * 60
    static let reminderInterval: TimeInterval = 5 * 60
    static let settleInterval: TimeInterval = 2 * 60
    static let okQuietInterval: TimeInterval = 30 * 60
    static let heartbeatInterval: TimeInterval = 60

    /// The highest level announced in the current episode.
    private(set) var announced: ThermyxRiskLevel = .normal
    /// The highest level the circle was alerted to in this episode, and when.
    private(set) var alerted: ThermyxRiskLevel?
    private var alertedAt: Date?
    private var lowerSince: Date?
    private var lastReminderAt: Date?
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
                if let alerted, level.severity < alerted.severity {
                    decision.followUp = level == .normal ? .resolved : .recovering
                }
                if level == .normal {
                    alerted = nil
                    alertedAt = nil
                    lastReminderAt = nil
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
                decision.followUp = nil
                alerted = level
                alertedAt = now
                lastReminderAt = now
            }
        } else if let alerted, let alertedAt, let lastReminderAt,
                  level.severity >= ThermyxRiskLevel.high.severity,
                  level.severity >= alerted.severity,
                  okUntil.map({ now >= $0 }) ?? true {
            // The first follow-up two minutes after the alert, then every five.
            let gap = lastReminderAt == alertedAt ? Self.firstFollowUp : Self.reminderInterval
            if now.timeIntervalSince(lastReminderAt) >= gap {
                decision.followUp = .still(minutes: max(1, Int((now.timeIntervalSince(alertedAt) / 60).rounded())))
                self.lastReminderAt = now
            }
        }

        if !decision.alert, decision.followUp == nil, lastPostAt.map({ now.timeIntervalSince($0) >= Self.heartbeatInterval }) ?? true {
            decision.heartbeat = true
        }
        if decision.alert || decision.followUp != nil || decision.heartbeat { lastPostAt = now }
        return decision
    }

    /// The wearer checked in: no reminders for a while, but a rise still alerts.
    mutating func imOK(now: Date = .now) {
        okUntil = now.addingTimeInterval(Self.okQuietInterval)
    }

    /// Forces the next status post (e.g. after the wearer changes a setting).
    mutating func postNow() { lastPostAt = nil }
}
