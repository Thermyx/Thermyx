import Foundation

/// Follows a Cool / Auto / Heat request until every connected insole shows
/// it took effect, and says so plainly when one does not. A tap that the
/// insole ignored must never look like it worked.
///
/// An insole confirms by echoing the setting (flags bits 2–3). Older firmware
/// that sends no echo confirms from what its actuator reports instead: Cool
/// once it is cooling, Heat once it is heating or its burn cutoff is holding
/// heat off, Auto on its next packet. Approach from Aaron Qin's branch.
struct ThermalCommandTracker: Equatable {
    enum State: Equatable {
        case idle
        case pending(ThermalSetting, waitingOn: Set<Foot>, since: Date)
        case confirmed(ThermalSetting)
        case failed(ThermalSetting, message: String)
    }

    /// How long an insole has to show the change before it counts as ignored.
    static let timeout: TimeInterval = 6

    private(set) var state: State = .idle

    var isPending: Bool {
        if case .pending = state { return true }
        return false
    }

    var failureMessage: String? {
        if case .failed(_, let message) = state { return message }
        return nil
    }

    mutating func begin(_ setting: ThermalSetting, feet: Set<Foot>, now: Date = .now) {
        state = feet.isEmpty ? .idle : .pending(setting, waitingOn: feet, since: now)
    }

    /// Feeds the latest readings in. Feet that disconnected are no longer
    /// waited on; feet that show the setting are done.
    mutating func update(readings: [Foot: ThermyxReading], connected: Set<Foot>, now: Date = .now) {
        guard case .pending(let setting, let waiting, let since) = state else { return }
        var remaining = waiting.intersection(connected)
        for foot in remaining {
            guard let reading = readings[foot], reading.timestamp >= since else { continue }
            if Self.confirms(setting, reading) { remaining.remove(foot) }
        }
        if remaining.isEmpty {
            state = .confirmed(setting)
        } else if now.timeIntervalSince(since) >= Self.timeout {
            let names = remaining.sorted { $0.rawValue < $1.rawValue }.map(\.label)
            let what = names.count == 2 ? "Neither insole switched" : "The \(names[0].lowercased()) insole didn't switch"
            state = .failed(setting, message: "\(what) to \(setting.label). Check it's on and in range, then try again.")
        } else {
            state = .pending(setting, waitingOn: remaining, since: since)
        }
    }

    /// A Bluetooth write error ends the request at once.
    mutating func writeFailed(foot: Foot, message: String) {
        guard case .pending(let setting, let waiting, _) = state, waiting.contains(foot) else { return }
        state = .failed(setting, message: "The \(foot.label.lowercased()) insole didn't accept \(setting.label): \(message)")
    }

    mutating func reset() { state = .idle }

    static func confirms(_ setting: ThermalSetting, _ reading: ThermyxReading) -> Bool {
        // Off has no echo code (current firmware echoes Auto for it), so the
        // insole reporting itself off is the confirmation.
        if setting == .off { return reading.thermalMode == .off }
        if let echo = reading.settingEcho { return echo == setting }
        switch setting {
        case .cool: return reading.thermalMode == .cooling
        case .heat: return reading.thermalMode == .heating || reading.burnCutoff
        case .auto: return true
        case .off: return reading.thermalMode == .off
        }
    }
}
