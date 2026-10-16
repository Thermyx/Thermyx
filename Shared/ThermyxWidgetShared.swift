import ActivityKit
import Foundation
import SwiftUI

// Shared by the app and the widget extension: what the widgets, the Live
// Activity and the Dynamic Island show, and how they're drawn.

enum ThermyxShared {
    /// The App Group both targets belong to. The app writes the snapshot
    /// here; the Home Screen and Lock Screen widgets read it.
    static let appGroup = "group.com.thermyx.app.a"
    static let snapshotKey = "thermyx.widget.snapshot"
    static let soleViewKey = "thermyx.widget.soleView"
    static let widgetKind = "ThermyxStatus"

    static var defaults: UserDefaults? { UserDefaults(suiteName: appGroup) }
}

/// The wearer's thermal setting.
enum ThermyxWidgetMode: String, Codable, Hashable, CaseIterable, Identifiable {
    case auto, cool, heat, off

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .cool: return "Cool"
        case .heat: return "Heat"
        case .off: return "Off"
        }
    }
}

/// Which measurement the sole shows: the same three tabs as Home.
enum ThermyxSoleView: String, Codable, CaseIterable, Identifiable {
    case temperature, pressure, gait

    var id: String { rawValue }

    var label: String {
        switch self {
        case .temperature: return "Temperature"
        case .pressure: return "Pressure"
        case .gait: return "Gait"
        }
    }

    /// Short enough for a caption under a small sole.
    var shortLabel: String {
        switch self {
        case .temperature: return "Temp"
        case .pressure: return "Pressure"
        case .gait: return "Gait"
        }
    }

    var next: ThermyxSoleView {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    /// What the wearer last picked on the widget, shared through the group.
    static var current: ThermyxSoleView {
        get { ThermyxShared.defaults?.string(forKey: ThermyxShared.soleViewKey).flatMap(ThermyxSoleView.init(rawValue:)) ?? .temperature }
        set { ThermyxShared.defaults?.set(newValue.rawValue, forKey: ThermyxShared.soleViewKey) }
    }
}

/// The live picture at one moment. Temperatures are °C; the views convert.
/// Small enough (one 40-point curve) to fit in a Live Activity update.
struct ThermyxWidgetSnapshot: Codable, Hashable {
    enum Level: String, Codable, Hashable {
        case waiting, normal, caution, high, critical

        var label: String {
            switch self {
            case .waiting: return "Waiting"
            case .normal: return "Normal"
            case .caution: return "Caution"
            case .high: return "High risk"
            case .critical: return "Critical"
            }
        }

        var isConcern: Bool { self == .caution || self == .high || self == .critical }
    }

    var updated: Date
    /// An insole is connected and reporting.
    var live: Bool
    /// Simulated insoles (demo mode).
    var isDemo: Bool
    var fahrenheit: Bool
    var mode: ThermyxWidgetMode
    /// The warmer foot, °C.
    var footC: Double?
    var leftC: Double?
    var rightC: Double?
    /// The arch sensor's level, 0...1 of full scale.
    var leftLoad: Double?
    var rightLoad: Double?
    /// Walking steadiness, 0...1.
    var leftSteady: Double?
    var rightSteady: Double?
    var level: Level
    /// The top reason behind the level, when there is a concern.
    var concern: String?
    /// The warmer foot's temperature, °C, oldest first, over the last
    /// `windowMinutes`.
    var temps: [Float]
    var batteryLeft: Int?
    var batteryRight: Int?

    /// How far back the curve reaches.
    static let windowMinutes = 30

    static func load() -> ThermyxWidgetSnapshot? {
        guard let data = ThermyxShared.defaults?.data(forKey: ThermyxShared.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        ThermyxShared.defaults?.set(data, forKey: ThermyxShared.snapshotKey)
    }

    /// Readings older than this aren't shown as live.
    static let staleAfter: TimeInterval = 15 * 60

    func isLive(at date: Date) -> Bool { live && date.timeIntervalSince(updated) < Self.staleAfter }

    /// Heating is locked out at High risk and above, as in the app.
    var heatLocked: Bool { level == .high || level == .critical }

    // MARK: Battery

    /// Warnings at 10% and again at 5%, as in the app.
    static let batteryLow = 10
    static let batteryCritical = 5

    /// The insole most in need of charging, once one is at 10% or below.
    var lowBattery: (side: String, percent: Int)? {
        let feet = [("Left", batteryLeft), ("Right", batteryRight)].compactMap { side, p in p.map { (side, $0) } }
        guard let worst = feet.min(by: { $0.1 < $1.1 }), worst.1 <= Self.batteryLow else { return nil }
        return worst
    }

    var batteryIsCritical: Bool { (lowBattery?.percent ?? 100) <= Self.batteryCritical }

    // MARK: Concern, in fewer words
    //
    // The risk engine's sentences are written for the app. A widget has a
    // line or two, so the same reasons are shortened here by what they say.

    /// About 25 characters: for the medium widget and the island.
    var shortConcern: String? {
        guard let concern else { return nil }
        let table: [(String, String)] = [
            ("Foot contact has reached", "Heating off at the limit"),
            ("Foot-contact temperature is elevated", "Foot temperature elevated"),
            ("Foot-contact temperature is low", "Foot temperature low"),
            ("Movement stability is below", "Steadiness below baseline"),
            ("Ambient temperature is elevated", "Air temperature elevated"),
            ("Foot temperature is rising", "Foot warming quickly"),
        ]
        if let hit = table.first(where: { concern.hasPrefix($0.0) }) { return hit.1 }
        if concern.contains("warmer than the other") { return "One foot running warmer" }
        if concern.hasPrefix("Load is") { return "Load unevenly shared" }
        return concern
    }

    /// About 14 characters: for the Lock Screen's one line.
    var tinyConcern: String? {
        switch shortConcern {
        case "Heating off at the limit": return "Heat limit"
        case "Foot temperature elevated": return "Foot too warm"
        case "Foot temperature low": return "Foot cold"
        case "Steadiness below baseline": return "Unsteady steps"
        case "Air temperature elevated": return "Hot air"
        case "Foot warming quickly": return "Warming fast"
        case "One foot running warmer": return "Feet differ"
        case "Load unevenly shared": return "Uneven load"
        default: return concern == nil ? nil : level.label
        }
    }

    // MARK: Formatting

    func convert(_ c: Double) -> Double { fahrenheit ? c * 9 / 5 + 32 : c }

    func temperature(_ c: Double?, decimals: Int = 1) -> String {
        guard let c else { return "—" }
        return String(format: "%.\(decimals)f°", convert(c))
    }

    var unitSymbol: String { fahrenheit ? "F" : "C" }

    var footText: String { temperature(footC) }

    /// Speech for the whole picture, for VoiceOver.
    var spoken: String {
        var parts = ["\(mode.label) mode"]
        if let footC { parts.append("warmer foot \(temperature(footC)) \(unitSymbol == "F" ? "Fahrenheit" : "Celsius")") }
        parts.append(level.label)
        if let batteryLeft { parts.append("left insole battery \(batteryLeft) percent") }
        if let batteryRight { parts.append("right insole battery \(batteryRight) percent") }
        return parts.joined(separator: ", ")
    }
}

/// The Live Activity: the Lock Screen banner and the Dynamic Island.
struct ThermyxActivityAttributes: ActivityAttributes {
    typealias ContentState = ThermyxWidgetSnapshot
    var startedAt: Date
}

// MARK: - Look

/// The website's colours, for the widget extension (which doesn't have the
/// app's design system).
enum ThermyxWidgetInk {
    static let ice = Color(red: 0x5B / 255, green: 0xD2 / 255, blue: 0xFF / 255)
    static let signal = Color(red: 0x2C / 255, green: 0x9C / 255, blue: 0xF0 / 255)
    static let ember = Color(red: 0xFF / 255, green: 0x6A / 255, blue: 0x13 / 255)
    static let amber = Color(red: 0xFF / 255, green: 0xB0 / 255, blue: 0x20 / 255)
    static let red = Color(red: 0xFF / 255, green: 0x45 / 255, blue: 0x3A / 255)
    static let calm = Color(red: 0x5C / 255, green: 0xD6 / 255, blue: 0x8A / 255)
    static let bg = Color.black
    static let text = Color(red: 0xF2 / 255, green: 0xF4 / 255, blue: 0xF7 / 255)
    static let muted = Color(red: 0xA1 / 255, green: 0xA8 / 255, blue: 0xB3 / 255)
    static let faint = Color(red: 0x7C / 255, green: 0x84 / 255, blue: 0x8F / 255)
    /// Wells behind controls, and the hairline between sections.
    static let well = Color(red: 0x11 / 255, green: 0x12 / 255, blue: 0x15 / 255)
    static let hairline = Color(red: 0x1C / 255, green: 0x1E / 255, blue: 0x22 / 255)
    static let onPrimary = Color(red: 0x0A / 255, green: 0x0A / 255, blue: 0x0B / 255)

    static func color(_ level: ThermyxWidgetSnapshot.Level) -> Color {
        switch level {
        case .waiting: return faint
        case .normal: return ice
        case .caution: return amber
        case .high: return ember
        case .critical: return red
        }
    }

    /// Ice normally, amber at 10%, red at 5%.
    static func battery(_ percent: Int?) -> Color {
        guard let percent else { return faint }
        if percent <= ThermyxWidgetSnapshot.batteryCritical { return red }
        if percent <= ThermyxWidgetSnapshot.batteryLow { return amber }
        return ice
    }
}

/// The mode as a coloured dot: blue for Cool, orange for Heat, half and half
/// for Auto, an empty ring for Off.
struct ThermyxModeDot: View {
    let mode: ThermyxWidgetMode
    var size: CGFloat = 12

    var body: some View {
        Group {
            switch mode {
            case .cool:
                Circle().fill(ThermyxWidgetInk.ice)
            case .heat:
                Circle().fill(ThermyxWidgetInk.ember)
            case .auto:
                Circle()
                    .fill(LinearGradient(stops: [.init(color: ThermyxWidgetInk.ice, location: 0.5),
                                                 .init(color: ThermyxWidgetInk.ember, location: 0.5)],
                                         startPoint: .leading, endPoint: .trailing))
            case .off:
                Circle().strokeBorder(ThermyxWidgetInk.faint, lineWidth: max(1.5, size / 6))
            }
        }
        .frame(width: size, height: size)
        .accessibilityLabel("Mode: \(mode.label)")
    }
}
