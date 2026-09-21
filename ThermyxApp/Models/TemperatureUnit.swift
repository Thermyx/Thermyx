import Foundation

enum TemperatureUnit: String, CaseIterable, Identifiable, Codable {
    case celsius
    case fahrenheit

    var id: String { rawValue }

    /// The bare symbol used beside a numeral, e.g. `34.8` + `°C`.
    var symbol: String { self == .celsius ? "°C" : "°F" }

    /// The short segmented-control label.
    var shortLabel: String { self == .celsius ? "°C" : "°F" }

    func convert(_ celsius: Double) -> Double {
        self == .celsius ? celsius : celsius * 9 / 5 + 32
    }

    /// A difference in degrees, which converts by ratio only — no offset.
    func convertDelta(_ celsiusDelta: Double) -> Double {
        self == .celsius ? celsiusDelta : celsiusDelta * 9 / 5
    }
}

/// Every temperature in the app renders through here, so the unit toggle
/// reaches all of them and nothing prints a bare Celsius value by accident.
enum TemperatureFormat {

    /// `34.8°` — the degree mark without the unit letter, for dense readouts
    /// where the unit is already established by a nearby label.
    static func degrees(_ celsius: Double, in unit: TemperatureUnit, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f°", unit.convert(celsius))
    }

    /// `34.8` — the numeral alone, for the hero readout that sets its own
    /// degree mark in a separate, smaller style.
    static func value(_ celsius: Double, in unit: TemperatureUnit, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f", unit.convert(celsius))
    }

    /// `34.8 °C` — the fully-qualified form for accessibility labels.
    static func full(_ celsius: Double, in unit: TemperatureUnit, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f %@", unit.convert(celsius), unit.symbol)
    }

    /// `1.2°` — a signed-magnitude change, for delta chips.
    static func delta(_ celsiusDelta: Double, in unit: TemperatureUnit, decimals: Int = 1) -> String {
        String(format: "%.\(decimals)f°", abs(unit.convertDelta(celsiusDelta)))
    }
}
