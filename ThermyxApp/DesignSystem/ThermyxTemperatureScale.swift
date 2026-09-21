import SwiftUI

/// Maps a contact temperature onto the palette: Signal Blue cold, Ice cool,
/// Amber warm, Ember hot. Used by the insole blooms, the zone heat map, and
/// the time-in-zone split so one temperature always reads as one colour.
enum ThermyxTemperatureScale {
    /// Band edges in °C.
    static let cool: Double = 30
    static let comfortable: Double = 34
    static let warm: Double = 37

    enum Band: String, CaseIterable, Identifiable {
        case cool, comfort, warm, hot
        var id: String { rawValue }

        var label: String {
            switch self {
            case .cool: return "Cool"
            case .comfort: return "Comfort"
            case .warm: return "Warm"
            case .hot: return "Hot"
            }
        }

        var color: Color {
            switch self {
            case .cool: return Thermyx.Ink.signal
            case .comfort: return Thermyx.Ink.ice
            case .warm: return Thermyx.Ink.amber
            case .hot: return Thermyx.Ink.ember
            }
        }
    }

    static func band(for celsius: Double) -> Band {
        switch celsius {
        case ..<cool: return .cool
        case cool..<comfortable: return .comfort
        case comfortable..<warm: return .warm
        default: return .hot
        }
    }

    static func tint(for celsius: Double) -> Color {
        band(for: celsius).color
    }

    /// The comfort band drawn behind temperature charts.
    static let comfortRange: ClosedRange<Double> = cool...comfortable
}
