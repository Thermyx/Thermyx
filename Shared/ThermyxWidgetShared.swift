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
    static let widgetKind = "ThermyxStatus"
}

/// The wearer's thermal setting.
enum ThermyxWidgetMode: String, Codable, Hashable {
    case auto, cool, heat, off

    var label: String {
        switch self {
        case .auto: return "Auto"
        case .cool: return "Cool"
        case .heat: return "Heat"
        case .off: return "Off"
        }
    }
}

/// The live picture at one moment. Temperatures are °C; the views convert.
/// Kept small (the curves are 30 points each) so it fits in a Live
/// Activity update.
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
    /// Simulated insoles (admin Demo Mode).
    var isDemo: Bool
    var fahrenheit: Bool
    var mode: ThermyxWidgetMode
    /// The warmer foot, °C.
    var footC: Double?
    /// dT/dt over the last 10 s, °C per minute.
    var ratePerMinute: Double?
    /// ∫ dT/dt dt over the last 10 minutes, °C.
    var changeC: Double?
    var level: Level
    /// The top reason behind the level, when there is a concern.
    var concern: String?
    /// Foot temperature, °C, oldest first, over the last 10 minutes.
    var temps: [Float]
    /// dT/dt, °C per minute, at the same moments.
    var rates: [Float]
    var battery: Int?

    static func load() -> ThermyxWidgetSnapshot? {
        guard let data = UserDefaults(suiteName: ThermyxShared.appGroup)?.data(forKey: ThermyxShared.snapshotKey) else { return nil }
        return try? JSONDecoder().decode(Self.self, from: data)
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults(suiteName: ThermyxShared.appGroup)?.set(data, forKey: ThermyxShared.snapshotKey)
    }

    /// Readings older than this aren't shown as live.
    static let staleAfter: TimeInterval = 15 * 60

    func isLive(at date: Date) -> Bool { live && date.timeIntervalSince(updated) < Self.staleAfter }

    // MARK: Formatting

    func temperature(_ c: Double?) -> String {
        guard let c else { return "—" }
        return String(format: "%.1f°", fahrenheit ? c * 9 / 5 + 32 : c)
    }

    var footText: String { temperature(footC) }

    /// "+0.12°/min".
    var rateText: String {
        guard let r = ratePerMinute else { return "—" }
        return String(format: "%+.2f°/min", fahrenheit ? r * 9 / 5 : r)
    }

    /// "+1.4° in 10 min".
    var changeText: String {
        guard let c = changeC else { return "—" }
        return String(format: "%+.1f°", fahrenheit ? c * 9 / 5 : c)
    }

    var rateSymbol: String {
        guard let r = ratePerMinute else { return "minus" }
        if r > 0.05 { return "arrow.up.right" }
        if r < -0.05 { return "arrow.down.right" }
        return "arrow.right"
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
    static let bg = Color(red: 0x07 / 255, green: 0x09 / 255, blue: 0x0C / 255)
    static let text = Color.white
    static let muted = Color.white.opacity(0.62)
    static let faint = Color.white.opacity(0.38)

    static func color(_ level: ThermyxWidgetSnapshot.Level) -> Color {
        switch level {
        case .waiting: return faint
        case .normal: return calm
        case .caution: return amber
        case .high: return ember
        case .critical: return red
        }
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
