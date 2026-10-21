import SwiftUI

// The Demo studio's timeline: events placed, to the second, on the timeline
// of the video being recorded, which the simulated pair plays out. Admin
// only. The pair's physics runs `DemoPlayer.pace` times faster than the
// timeline, so a 40-second "heat builds" really heats the feet.
//
// An event either lasts (heat building, a limp, an insole dropping out) or
// happens once (a battery falling, an SOS, a check-in). Between events the
// wearer has an ordinary day: the usual walk/stand/sit round and mild air.

enum DemoEventKind: String, Codable, CaseIterable, Identifiable {
    case heat, coolingFailure, cold, limp, lean, dropout, quiet
    case battery9, battery4, sos, help, checkIn

    var id: String { rawValue }

    var label: String {
        switch self {
        case .heat: return "Heat builds"
        case .coolingFailure: return "Cooling fails"
        case .cold: return "Cold exposure"
        case .limp: return "Limp"
        case .lean: return "Heavy lean"
        case .dropout: return "Insole drops out"
        case .quiet: return "Phone goes quiet"
        case .battery9: return "Battery 9%"
        case .battery4: return "Battery 4%"
        case .sos: return "SOS pressed"
        case .help: return "Asks for help"
        case .checkIn: return "Checks in OK"
        }
    }

    /// What it does, for the palette.
    var detail: String {
        switch self {
        case .heat: return "Air climbs toward 40 °C while they work."
        case .coolingFailure: return "The insole can't cool, in hot air, as they tire: heads for Critical."
        case .cold: return "Air drops near freezing while they stand."
        case .limp: return "One foot unsteady and carrying less, steps slow."
        case .lean: return "Standing with most of the weight on one foot."
        case .dropout: return "One insole stops reporting, then comes back."
        case .quiet: return "The phone stops posting, so the circle hears it went quiet."
        case .battery9: return "One insole falls to 9%."
        case .battery4: return "One insole falls to 4%."
        case .sos: return "They press Call 911: the circle is told."
        case .help: return "They ask for help without calling 911."
        case .checkIn: return "They tap I'm OK."
        }
    }

    var symbol: String {
        switch self {
        case .heat: return "sun.max.fill"
        case .coolingFailure: return "exclamationmark.triangle.fill"
        case .cold: return "snowflake"
        case .limp: return "figure.walk.motion"
        case .lean: return "figure.stand"
        case .dropout: return "antenna.radiowaves.left.and.right.slash"
        case .quiet: return "iphone.slash"
        case .battery9: return "battery.25percent"
        case .battery4: return "battery.0percent"
        case .sos: return "sos"
        case .help: return "hand.raised.fill"
        case .checkIn: return "hand.thumbsup.fill"
        }
    }

    var tint: Color {
        switch self {
        case .heat, .coolingFailure, .sos: return Thermyx.Ink.ember
        case .cold, .checkIn: return Thermyx.Ink.ice
        case .limp, .lean, .help, .battery9, .battery4: return Thermyx.Ink.amber
        case .dropout, .quiet: return Thermyx.Ink.textSecondary
        }
    }

    /// Seconds it lasts when placed; nil for one-off events.
    var defaultLength: Double? {
        switch self {
        case .heat: return 40
        case .coolingFailure: return 30
        case .cold: return 30
        case .limp: return 25
        case .lean: return 20
        case .dropout: return 8
        case .quiet: return 15
        case .battery9, .battery4, .sos, .help, .checkIn: return nil
        }
    }

    /// Whether the event is about one foot.
    var hasFoot: Bool { [.limp, .lean, .dropout, .battery9, .battery4].contains(self) }
}

struct DemoEvent: Codable, Identifiable, Equatable {
    var id = UUID()
    var kind: DemoEventKind
    /// Seconds into the timeline.
    var start: Double
    /// Seconds it lasts; 0 for one-off events.
    var length: Double
    var foot: Foot = .right

    init(_ kind: DemoEventKind, at start: Double, length: Double? = nil, foot: Foot = .right) {
        self.kind = kind
        self.start = start
        self.length = length ?? kind.defaultLength ?? 0
        self.foot = foot
    }

    var end: Double { start + length }
    var isInstant: Bool { kind.defaultLength == nil }

    func covers(_ second: Double) -> Bool { !isInstant && second >= start && second < end }
}

/// What the timeline says is happening at one moment.
struct DemoConditions: Equatable {
    /// Replaces the usual walk/stand/sit round.
    var activity: CalibrationActivity?
    /// Replaces the usual air.
    var ambientC: Double?
    var coolingFault = false
    /// Heat strain: steadiness drifts down.
    var strained = false
    var limp: Foot?
    var lean: Foot?
    var dropped: Set<Foot> = []
    /// The phone holds back its posts to the relay.
    var quiet = false
}

struct DemoScript: Codable, Equatable {
    var events: [DemoEvent] = []
    /// Seconds the timeline runs.
    var length: Double = 120

    static let lengths: [Double] = [60, 90, 120, 180, 300]

    /// The usual air for the timeline's day.
    static let baseAmbientC = 27.0

    func conditions(at second: Double) -> DemoConditions {
        var c = DemoConditions()
        for event in events.sorted(by: { $0.start < $1.start }) where event.covers(second) {
            let progress = event.length > 0 ? min(1, max(0, (second - event.start) / event.length)) : 1
            switch event.kind {
            case .heat:
                // Climbs over the first half, holds after.
                c.ambientC = Self.baseAmbientC + (40 - Self.baseAmbientC) * min(1, progress * 2)
                c.activity = .walking
            case .coolingFailure:
                c.coolingFault = true
                c.ambientC = max(c.ambientC ?? 0, 36 + 2 * min(1, progress * 2))
                c.strained = progress > 0.3
                c.activity = .walking
            case .cold:
                c.ambientC = Self.baseAmbientC - (Self.baseAmbientC - 1) * min(1, progress * 2)
                c.activity = .standing
            case .limp:
                c.limp = event.foot
                c.activity = .walking
            case .lean:
                c.lean = event.foot
                c.activity = .standing
            case .dropout:
                c.dropped.insert(event.foot)
            case .quiet:
                c.quiet = true
            default:
                break
            }
        }
        return c
    }

    /// One-off events whose moment falls in (from, to].
    func instants(after from: Double, through to: Double) -> [DemoEvent] {
        events.filter { $0.isInstant && $0.start > from && $0.start <= to }.sorted { $0.start < $1.start }
    }

    // MARK: Presets

    struct Preset: Identifiable {
        let name: String
        let script: DemoScript
        var id: String { name }
    }

    static let presets: [Preset] = [
        Preset(name: "Hot shift", script: DemoScript(events: [
            DemoEvent(.heat, at: 5, length: 50),
            DemoEvent(.coolingFailure, at: 45, length: 35),
            DemoEvent(.checkIn, at: 95),
        ], length: 120)),
        Preset(name: "Limp", script: DemoScript(events: [
            DemoEvent(.limp, at: 8, length: 30, foot: .left),
            DemoEvent(.lean, at: 50, length: 25, foot: .right),
        ], length: 90)),
        Preset(name: "Battery dies", script: DemoScript(events: [
            DemoEvent(.battery9, at: 6, foot: .left),
            DemoEvent(.battery4, at: 20, foot: .left),
            DemoEvent(.dropout, at: 34, length: 12, foot: .left),
        ], length: 60)),
        Preset(name: "SOS", script: DemoScript(events: [
            DemoEvent(.heat, at: 4, length: 45),
            DemoEvent(.sos, at: 40),
            DemoEvent(.help, at: 55),
            DemoEvent(.checkIn, at: 75),
        ], length: 90)),
    ]
}

/// A small seeded generator, so the simulated pair can be replayed exactly:
/// scrubbing back to a moment gives the same feet as playing through to it.
struct DemoRandom: Equatable {
    private(set) var state: UInt64

    init(seed: UInt64) { state = seed }

    /// SplitMix64.
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }

    mutating func double(in range: ClosedRange<Double>) -> Double {
        let unit = Double(next() >> 11) / Double(1 << 53)
        return range.lowerBound + (range.upperBound - range.lowerBound) * unit
    }
}
