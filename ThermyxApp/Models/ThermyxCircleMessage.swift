import Foundation

/// What the trusted circle is told about the wearer: the facts behind each
/// text and the watcher's status card. Built on the wearer's phone, cleaned
/// and stored by the relay, and shown to approved watchers.
///
/// Field values are plain strings on the wire so an older app still decodes
/// a newer relay's card.
struct ThermyxCircleDetail: Codable, Equatable {
    struct Battery: Codable, Equatable {
        var foot: String
        var percent: Int
    }

    /// The name the wearer chose for their circle to see.
    var name: String?
    /// "left", "right" or "both".
    var foot: String?
    /// "forefoot", "arch" or "heel": only from boards that sense zones.
    var zone: String?
    /// `ThermyxRiskCause` raw values, most important first.
    var causes: [String]?
    /// The affected foot's (or zone's) contact temperature.
    var footC: Double?
    /// "rising", "falling" or "steady", over the last minute.
    var trend: String?
    /// "confirmed" or "limited". See `ThermyxCircleTracker`.
    var confidence: String?
    /// Only when an insole is at 10% or less.
    var battery: Battery?
    /// "oneInsole" or "stale": only when the connection is weak.
    var connection: String?
    /// The wearer's local time, formatted on their phone ("4:18 PM CDT").
    var time: String?
    /// When the wearer said "I'm OK".
    var checkedIn: String?
    /// The wearer's unit: "F" or "C".
    var unit: String = "F"
    /// A follow-up: "still", "recovering" or "resolved".
    var update: String?
    /// Minutes since the alert, with "still".
    var minutes: Int?
    /// An SOS: "pressed" (Call 911) or "noResponse" (the Critical countdown).
    var sos: String?
    /// A help request's preset ("water", "walk", "pickup", "unwell").
    var help: String?
    /// The wearer's own words with a help request, plain SMS characters.
    var note: String?
    /// What had been happening before an SOS or help request.
    var episodeLevel: String?
    var episodeMinutes: Int?
    /// When the wearer last tapped I'm OK, on their clock.
    var lastCheckIn: String?

    var riskCauses: [ThermyxRiskCause] { (causes ?? []).compactMap(ThermyxRiskCause.init(rawValue:)) }
    var affectedFoot: Foot? { foot.flatMap(Foot.init(rawValue:)) }
    var footZone: FootZone? { zone.flatMap(FootZone.init(rawValue:)) }
    var isConfirmed: Bool { confidence == "confirmed" }
    var temperatureUnit: TemperatureUnit { unit == "C" ? .celsius : .fahrenheit }
}

// MARK: - Building it

/// Watches the stream for what a single reading can't say: whether the
/// affected foot is rising or falling, and whether the data is solid enough
/// to call confirmed.
///
/// Confirmed means the sensors are behaving, not that the person is in
/// danger: both insoles reporting, the newest reading under 10 seconds old,
/// and a steady stream (at least five readings in the last 30 seconds with no
/// gap over 10). Anything less is "limited", and the circle is told to check
/// on them directly.
struct ThermyxCircleTracker {
    private struct Sample { let time: Date; let left: Double?; let right: Double?; let both: Bool }
    private var samples: [Sample] = []

    static let window: TimeInterval = 120
    static let trendSpan: TimeInterval = 60
    static let trendThresholdC = 0.3

    mutating func record(_ reading: BilateralReading, now: Date = .now) {
        guard reading.hasAny else { return }
        samples.append(Sample(time: now, left: reading.left?.footTemperatureC, right: reading.right?.footTemperatureC, both: reading.hasBoth))
        samples.removeAll { now.timeIntervalSince($0.time) > Self.window }
    }

    /// Change over the last minute: at least 0.3 °C either way counts. Nil
    /// until there's 45 seconds of history.
    func trend(for foot: Foot?, now: Date = .now) -> String? {
        func value(_ s: Sample) -> Double? {
            switch foot {
            case .left: return s.left
            case .right: return s.right
            case nil: return [s.left, s.right].compactMap { $0 }.max()
            }
        }
        let recent = samples.filter { now.timeIntervalSince($0.time) <= 15 }.compactMap(value)
        let earlier = samples.filter {
            let age = now.timeIntervalSince($0.time)
            return age >= Self.trendSpan - 15 && age <= Self.trendSpan + 15
        }.compactMap(value)
        guard !recent.isEmpty, !earlier.isEmpty else { return nil }
        let delta = recent.reduce(0, +) / Double(recent.count) - earlier.reduce(0, +) / Double(earlier.count)
        if delta >= Self.trendThresholdC { return "rising" }
        if delta <= -Self.trendThresholdC { return "falling" }
        return "steady"
    }

    func confidence(now: Date = .now) -> String {
        let last30 = samples.filter { now.timeIntervalSince($0.time) <= 30 }
        guard let latest = last30.last, latest.both, now.timeIntervalSince(latest.time) <= 10, last30.count >= 5 else { return "limited" }
        let gaps = zip(last30, last30.dropFirst()).map { $1.time.timeIntervalSince($0.time) }
        return (gaps.max() ?? 0) <= 10 ? "confirmed" : "limited"
    }
}

extension ThermyxCircleDetail {
    /// The wearer's clock, as the circle should read it: "4:18 PM CDT".
    static func localTime(_ date: Date, timeZone: TimeZone = .current, locale: Locale = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = locale
        formatter.timeZone = timeZone
        formatter.setLocalizedDateFormatFromTemplate("jmmz")
        // iOS puts a narrow no-break space before "PM"; use a plain one so
        // the text stays in the SMS alphabet.
        return formatter.string(from: date)
            .replacingOccurrences(of: "\u{202F}", with: " ")
            .replacingOccurrences(of: "\u{00A0}", with: " ")
    }

    /// The detail for the wearer's current state.
    static func make(
        assessment: ThermyxRiskAssessment,
        reading: BilateralReading,
        tracker: ThermyxCircleTracker,
        name: String,
        unit: TemperatureUnit,
        now: Date = .now,
        timeZone: TimeZone = .current
    ) -> ThermyxCircleDetail {
        var d = ThermyxCircleDetail()
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        d.name = trimmed.isEmpty ? nil : String(trimmed.prefix(40))
        d.unit = unit == .celsius ? "C" : "F"
        d.time = localTime(now, timeZone: timeZone)
        d.causes = assessment.causes.isEmpty ? nil : assessment.causes.prefix(3).map(\.rawValue)

        // Which foot: both, when both are over the line for a heat cause;
        // else the foot the engine blamed; else the warmer one.
        let causes = assessment.causes
        let heat = causes.first == .hot || causes.first == .heatLimit
        let hotFeet = reading.present.filter { ($0.footTemperatureC ?? 0) >= 38 }
        let foot: Foot? = assessment.foot ?? reading.hotterFoot ?? reading.present.first?.foot
        if heat, hotFeet.count == 2 {
            d.foot = "both"
            d.footC = hotFeet.compactMap(\.footTemperatureC).max()
        } else if let foot, let r = reading[foot] {
            d.foot = foot.rawValue
            d.footC = r.footTemperatureC
            // A zone only from a board that senses it: the hottest for heat,
            // the coldest for cold.
            if let zones = r.zones, heat || causes.first == .cold {
                let pick = FootZone.allCases.map { ($0, zones[$0]) }
                let chosen = causes.first == .cold ? pick.min { $0.1 < $1.1 } : pick.max { $0.1 < $1.1 }
                if let chosen { d.zone = chosen.0.rawValue; d.footC = chosen.1 }
            }
        }
        d.footC = d.footC.map { ($0 * 10).rounded() / 10 }
        d.trend = tracker.trend(for: d.foot == "both" ? nil : d.affectedFoot, now: now)
        d.confidence = tracker.confidence(now: now)

        if let low = reading.present.compactMap({ r in r.batteryPercent.map { (r.foot, $0) } }).min(by: { $0.1 < $1.1 }),
           low.1 <= ThermyxBattery.low {
            d.battery = Battery(foot: low.0.rawValue, percent: low.1)
        }
        if let newest = reading.present.map(\.timestamp).max(), now.timeIntervalSince(newest) > 60 {
            d.connection = "stale"
        } else if reading.hasAny, !reading.hasBoth {
            d.connection = "oneInsole"
        }
        return d
    }
}

// MARK: - The text

/// The texts a trusted contact receives. Mirrors ThermyxBackend/message.js,
/// which composes the real ones; this one draws the preview on the Safety
/// screen. Both are checked against ThermyxBackend/test/message-fixtures.json.
enum ThermyxCircleMessage {
    struct Location: Equatable {
        var latitude: Double
        var longitude: Double
    }

    private static func cap(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// The relay's cleaning, for the parts the text depends on.
    static func cleaned(_ raw: ThermyxCircleDetail?) -> ThermyxCircleDetail {
        var d = raw ?? ThermyxCircleDetail()
        if let name = d.name {
            let one = name.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
            let collapsed = one.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            d.name = collapsed.isEmpty ? nil : String(collapsed.prefix(40))
        }
        if !["left", "right", "both"].contains(d.foot ?? "") { d.foot = nil }
        if d.foot == "both" || !["forefoot", "arch", "heel"].contains(d.zone ?? "") { d.zone = nil }
        if let causes = d.causes {
            var seen: [String] = []
            for c in causes where ThermyxRiskCause(rawValue: c) != nil && !seen.contains(c) { seen.append(c) }
            d.causes = seen.isEmpty ? nil : Array(seen.prefix(3))
        }
        d.footC = d.footC.flatMap { $0 > 0 && $0 < 60 ? ($0 * 10).rounded() / 10 : nil }
        if d.unit != "C" { d.unit = "F" }
        if let help = d.help, helpPhrases[help] == nil { d.help = nil }
        d.note = d.note.flatMap(plainNote)
        if let level = d.episodeLevel, ThermyxRiskLevel(rawValue: level) == nil || level == ThermyxRiskLevel.normal.rawValue { d.episodeLevel = nil }
        if let m = d.episodeMinutes, !(1..<1440).contains(m) { d.episodeMinutes = nil }
        return d
    }

    /// "Ask for help" presets, and how a text says them.
    static let helpPhrases: [String: String] = [
        "water": "they need water",
        "walk": "they can't walk well",
        "pickup": "they want someone to come and get them",
        "unwell": "they're feeling unwell",
    ]

    /// A short note in plain SMS characters only, so one emoji can't turn the
    /// whole text into Unicode.
    static func plainNote(_ raw: String) -> String? {
        let quotes = raw.replacingOccurrences(of: "\u{2018}", with: "'").replacingOccurrences(of: "\u{2019}", with: "'")
            .replacingOccurrences(of: "\u{201C}", with: "\"").replacingOccurrences(of: "\u{201D}", with: "\"")
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 .,!?'\"():;/-")
        let kept = String(quotes.map { allowed.contains($0) ? $0 : " " })
        let collapsed = kept.split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
        let note = String(collapsed.prefix(80))
        return note.isEmpty ? nil : note
    }

    /// What had been happening, and the last check-in.
    static func context(_ d: ThermyxCircleDetail) -> String? {
        var parts: [String] = []
        if let level = d.episodeLevel {
            parts.append("Before this: \(level)\(d.episodeMinutes.map { " for \($0) minute\($0 == 1 ? "" : "s")" } ?? "").")
        }
        if let checkIn = d.lastCheckIn { parts.append("Last check-in: \(checkIn).") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    static func temperature(_ c: Double, unit: String) -> String {
        let v = unit == "C" ? c : c * 9 / 5 + 32
        return String(format: "%.1f%@", v, unit)
    }

    private static func place(_ d: ThermyxCircleDetail) -> String {
        if d.foot == "both" { return "Both feet" }
        if let foot = d.foot, let zone = d.zone { return "\(cap(foot)) \(zone)" }
        if let foot = d.foot { return "\(cap(foot)) foot" }
        return "Their foot"
    }

    /// What the insoles saw, as one sentence.
    static func condition(_ d: ThermyxCircleDetail) -> String? {
        let causes = d.causes ?? []
        let t = d.footC.map { temperature($0, unit: d.unit) }
        let plural = d.foot == "both"
        let oneFoot = d.foot.flatMap { $0 == "both" ? nil : $0 }
        var sentence: String?
        switch causes.first {
        case "heatLimit":
            sentence = "\(place(d)) reached the insole's heat limit\(t.map { " (\($0))" } ?? ""). Heating has switched off."
        case "hot":
            let trend = d.trend == "rising" ? " and still rising" : d.trend == "falling" ? " but falling" : ""
            sentence = plural
                ? "Both feet are hot\(trend)\(t.map { ": \($0) at the warmer insole" } ?? "")."
                : "\(place(d)) temperature is elevated\(trend)\(t.map { ": \($0) at the insole" } ?? "")."
        case "cold":
            let trend = d.trend == "falling" ? " and still cooling" : d.trend == "rising" ? " but warming" : ""
            sentence = "\(place(d)) \(plural ? "are" : "is") cold\(trend)\(t.map { ": \($0) at the insole" } ?? "")."
        case "unsteady": sentence = "Their steps are much less steady than usual."
        case "hotAir": sentence = "The air around them is very hot."
        case "warmerFoot": sentence = "\(oneFoot.map { "\(cap($0)) foot" } ?? "One foot") is running much warmer than the other."
        case "unevenLoad": sentence = "They're putting much more weight on \(oneFoot.map { "their \($0) foot" } ?? "one foot")."
        case "limp": sentence = "Their steps have been uneven for a while\(oneFoot.map { ", with more weight on their \($0) foot" } ?? "")."
        default:
            let trend = d.trend == "rising" ? " and is rising" : d.trend == "falling" ? " and is falling" : ""
            sentence = t.map { "\(place(d)) reads \($0) at the insole\(trend)." }
        }
        let alsoPhrases: [String: String] = [
            "heatLimit": "the insole hit its heat limit", "hot": "foot temperature is high", "cold": "a foot is cold",
            "unsteady": "their steps are less steady", "hotAir": "the air is very hot",
            "warmerFoot": "one foot is much warmer", "unevenLoad": "their weight is uneven", "limp": "their steps are uneven",
        ]
        let also = causes.dropFirst().compactMap { alsoPhrases[$0] }
        if let s = sentence, !also.isEmpty { sentence = s + " Also: \(also.joined(separator: " and "))." }
        return sentence
    }

    /// The condition without its number, for the watcher's card, which
    /// shows the temperature on its own: "Right forefoot temperature is
    /// elevated and still rising."
    static func headline(_ raw: ThermyxCircleDetail?) -> String? {
        var d = cleaned(raw)
        guard !(d.causes ?? []).isEmpty else { return nil }
        d.footC = nil
        return condition(d)
    }

    static func confidence(_ d: ThermyxCircleDetail) -> String? {
        guard let confidence = d.confidence else { return d.time.map { "Reading at \($0)." } }
        if confidence == "confirmed" { return d.time.map { "Data confirmed at \($0)." } ?? "Data confirmed." }
        return "Limited data\(d.time.map { " at \($0)" } ?? ""): check on them directly."
    }

    static func equipment(_ d: ThermyxCircleDetail) -> String? {
        var parts: [String] = []
        if let b = d.battery { parts.append("\(cap(b.foot)) insole battery is at \(b.percent)%.") }
        if d.connection == "oneInsole" { parts.append("Only one insole is connected.") }
        if d.connection == "stale" { parts.append("Their readings are more than a minute old.") }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }

    private static func locationLine(consent: Bool, location: Location?, severe: Bool) -> String? {
        guard severe else { return nil }
        guard consent else { return "Location not shared." }
        guard let location else { return "Location unavailable." }
        return "Location: \(mapsLink(location))"
    }

    static func mapsLink(_ l: Location) -> String {
        "https://maps.google.com/?q=\(String(format: "%.5f", l.latitude)),\(String(format: "%.5f", l.longitude))"
    }

    /// What the contact should do, by level.
    static func action(level: String, kind: String, hasLocation: Bool) -> String? {
        if kind == "sos" { return "Call them now. If you can't reach them, call 911\(hasLocation ? " and give their location" : "")." }
        switch level {
        case ThermyxRiskLevel.critical.rawValue: return "Call them now. If they don't answer or seem unresponsive, call 911."
        case ThermyxRiskLevel.high.rawValue: return "Call them now."
        case ThermyxRiskLevel.caution.rawValue: return "Check in with them within 5 minutes."
        default: return nil
        }
    }

    /// What Thermyx told the wearer.
    static func wearerWasAsked(level: String) -> String? {
        switch level {
        case ThermyxRiskLevel.critical.rawValue: return "Thermyx told them to stop and get help."
        case ThermyxRiskLevel.high.rawValue: return "Thermyx told them to stop, drink water and cool down."
        default: return nil
        }
    }

    static let followUp = "Thermyx will text again when they check in or readings recover."

    /// The whole text.
    static func text(level: String, kind: String, detail raw: ThermyxCircleDetail?, locationConsent: Bool, location: Location?) -> String {
        let d = cleaned(raw)
        let name = d.name ?? "your contact"
        let severe = kind == "sos" || kind == "help" || level == ThermyxRiskLevel.high.rawValue || level == ThermyxRiskLevel.critical.rawValue
        var lines: [String] = []
        switch kind {
        case "sos": lines.append("Thermyx SOS - \(name)")
        case "help": lines.append("Thermyx Help Request - \(name)")
        case "test": lines.append("Thermyx TEST - \(name)")
        case "alert": lines.append("Thermyx \(level == ThermyxRiskLevel.high.rawValue ? "High-Risk" : level) Alert - \(name)")
        default: lines.append("Thermyx update - \(name)")
        }
        func push(_ line: String?) { if let line { lines.append(line) } }
        let elevated = level == ThermyxRiskLevel.high.rawValue || level == ThermyxRiskLevel.critical.rawValue

        if kind == "test" {
            push("This is a test of Thermyx alerts. \(d.name ?? "They") set you up as a trusted contact. No action needed.")
            return lines.joined(separator: "\n")
        }
        if kind == "help" {
            let who = d.name ?? "They"
            let at = d.time.map { " at \($0)" } ?? ""
            push(d.help.flatMap { helpPhrases[$0] }.map { "\(who) asked for help\(at): \($0)." } ?? "\(who) asked for help\(at).")
            if let note = d.note { push("They wrote: \"\(note)\"") }
            push(context(d))
            push(condition(d))
            push(equipment(d))
            let loc = locationLine(consent: locationConsent, location: location, severe: true)
            push(loc)
            push("Call them now, and go to them if you can.\((loc?.hasPrefix("Location:") ?? false) ? "" : " If you can't reach them, call 911.")")
            push(followUp)
            return lines.joined(separator: "\n")
        }

        if kind == "ok" {
            push("\(d.name ?? "They") checked in\(d.checkedIn.map { " at \($0)" } ?? "") and \(d.name != nil ? "says they're" : "say they're") OK.")
            if elevated { push("Readings are still \(level), so stay in touch.") }
            return lines.joined(separator: "\n")
        }
        if kind == "update" {
            if d.update == "resolved" {
                push("Readings are back to Normal\(d.time.map { " as of \($0)" } ?? "").")
                return lines.joined(separator: "\n")
            }
            if d.update == "recovering" {
                push("Readings are recovering: now \(level)\(d.time.map { " as of \($0)" } ?? "").")
                push(condition(d))
                return lines.joined(separator: "\n")
            }
            push("Still \(level)\(d.minutes.map { " after \($0) minute\($0 == 1 ? "" : "s")" } ?? "").")
            push(condition(d))
            push(confidence(d))
            push(equipment(d))
            let loc = locationLine(consent: locationConsent, location: location, severe: severe)
            push(loc)
            push(action(level: level, kind: kind, hasLocation: loc?.hasPrefix("Location:") ?? false))
            return lines.joined(separator: "\n")
        }
        if kind == "sos" {
            push(d.sos == "noResponse"
                 ? "\(d.name ?? "They") didn't respond to a Critical alert for 60 seconds\(d.time.map { " (\($0))" } ?? "")."
                 : "\(d.name ?? "They") pressed Call 911\(d.time.map { " at \($0)" } ?? "").")
            push(context(d))
            push(condition(d))
        } else {
            push(condition(d))
            push(confidence(d))
        }
        push(equipment(d))
        let loc = locationLine(consent: locationConsent, location: location, severe: severe)
        push(loc)
        if kind != "sos" { push(wearerWasAsked(level: level)) }
        push(action(level: level, kind: kind, hasLocation: loc?.hasPrefix("Location:") ?? false))
        push(followUp)
        return lines.joined(separator: "\n")
    }

    /// The relay's own text when an active event goes quiet.
    static func silence(name: String?, level: String, location: Location?, minutes: Int) -> String {
        var lines = ["Thermyx - no update from \(name ?? "your contact")"]
        lines.append("Their phone hasn't sent anything for \(minutes) minutes during a \(level) alert. Their phone, signal or insoles may be off.")
        if let location { lines.append("Last location: \(mapsLink(location))") }
        lines.append("Check on them directly. If you can't reach them, call 911.")
        return lines.joined(separator: "\n")
    }

    /// The relay's text when updates resume after a silence.
    static func reconnected(level: String, detail raw: ThermyxCircleDetail?) -> String {
        let d = cleaned(raw)
        var lines = ["Thermyx update - \(d.name ?? "your contact")", "Their phone is back in touch. Now \(level)."]
        if level != ThermyxRiskLevel.normal.rawValue, let c = condition(d) { lines.append(c) }
        return lines.joined(separator: "\n")
    }
}
