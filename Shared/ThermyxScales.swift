import SwiftUI

// MARK: - Colour scales
//
// Shared by the app (foot maps, charts) and the widgets, so a temperature is
// the same colour on Home, in Insights and on the Lock Screen.

/// The design's two scales: the brand thermal ramp for temperature (28° to
/// 38°), and the clinical "jet" ramp pressure mats use for load.
enum FootScale {
    typealias RGB = (r: Double, g: Double, b: Double)

    /// Temperature, deep blue through ice to ember.
    static let thermal: [(Double, RGB)] = [
        (0, (11, 35, 80)), (0.25, (44, 156, 240)), (0.45, (91, 210, 255)),
        (0.62, (255, 208, 138)), (0.8, (255, 155, 61)), (1, (255, 106, 19)),
    ]

    /// The temperatures the thermal ramp spans.
    static let thermalRangeC: ClosedRange<Double> = 28...38

    /// Clinical load scale (MATLAB's jet).
    static func jet(_ v: Double) -> RGB {
        func c(_ x: Double) -> Double { min(max(x, 0), 1) }
        return (c(1.5 - abs(4 * v - 3)) * 255, c(1.5 - abs(4 * v - 2)) * 255, c(1.5 - abs(4 * v - 1)) * 255)
    }

    static func ramp(_ stops: [(Double, RGB)], _ v: Double) -> RGB {
        let v = min(max(v, 0), 1)
        for i in 1..<stops.count where v <= stops[i].0 {
            let (a, ca) = stops[i - 1], (b, cb) = stops[i]
            let f = (v - a) / (b - a)
            return (ca.r + (cb.r - ca.r) * f, ca.g + (cb.g - ca.g) * f, ca.b + (cb.b - ca.b) * f)
        }
        return stops[stops.count - 1].1
    }

    static func color(_ rgb: RGB) -> Color { Color(.sRGB, red: rgb.r / 255, green: rgb.g / 255, blue: rgb.b / 255) }

    /// Where `celsius` sits on the thermal ramp, 0...1.
    static func thermalPosition(_ celsius: Double) -> Double {
        (celsius - thermalRangeC.lowerBound) / (thermalRangeC.upperBound - thermalRangeC.lowerBound)
    }

    static func thermalColor(_ celsius: Double) -> Color { color(ramp(thermal, thermalPosition(celsius))) }
    static func loadColor(_ level: Double) -> Color { color(jet(level)) }

    /// For legends: the ramps as gradients, low to high.
    static var thermalGradient: [Color] { thermal.map { color($0.1) } }
    static var loadGradient: [Color] { stride(from: 0.0, through: 1.0, by: 0.125).map { color(jet($0)) } }

    /// The sole where nothing is measured.
    static let unsensed = Color(.sRGB, red: 0x14 / 255, green: 0x18 / 255, blue: 0x1E / 255)
}

/// Colours a chart by what it plots, not by which series it is: each stop
/// is a value in the chart's own units (°F on a Fahrenheit chart) and the
/// colour it reads as. The ramps are the foot maps' — thermal for
/// temperature, the clinical "jet" for load — so a line turns ember at the
/// height where the sole would, and the axis and the colour always agree.
struct ChartValueScale: Equatable {
    struct Stop: Equatable {
        let value: Double
        let r: Double, g: Double, b: Double
    }

    /// Low to high.
    let stops: [Stop]

    init(_ stops: [(Double, FootScale.RGB)]) {
        self.stops = stops
            .map { Stop(value: $0.0, r: $0.1.r, g: $0.1.g, b: $0.1.b) }
            .sorted { $0.value < $1.value }
    }

    func color(at value: Double) -> Color {
        guard let first = stops.first, let last = stops.last else { return .white }
        if value <= first.value { return Self.color(first) }
        if value >= last.value { return Self.color(last) }
        for (a, b) in zip(stops, stops.dropFirst()) where value <= b.value {
            let f = (value - a.value) / max(b.value - a.value, .ulpOfOne)
            return Color(.sRGB, red: (a.r + (b.r - a.r) * f) / 255,
                         green: (a.g + (b.g - a.g) * f) / 255,
                         blue: (a.b + (b.b - a.b) * f) / 255)
        }
        return Self.color(last)
    }

    /// A bottom-to-top gradient for a mark whose values run `low...high`.
    /// Swift Charts stretches a mark's gradient over the mark's own bounds,
    /// so sampling the scale across exactly that span puts each colour at
    /// its value on the y axis. `opacity` fades along the same span (0 is
    /// the bottom), for area fills.
    func gradient(from low: Double, to high: Double, opacity: (Double) -> Double = { _ in 1 }) -> LinearGradient {
        LinearGradient(stops: gradientStops(from: low, to: high, opacity: opacity), startPoint: .bottom, endPoint: .top)
    }

    /// Left to right, for keys and legend chips.
    func horizontal(from low: Double, to high: Double) -> LinearGradient {
        LinearGradient(stops: gradientStops(from: low, to: high), startPoint: .leading, endPoint: .trailing)
    }

    private func gradientStops(from low: Double, to high: Double, opacity: (Double) -> Double = { _ in 1 }) -> [Gradient.Stop] {
        guard high > low else {
            let solid = color(at: high).opacity(opacity(1))
            return [.init(color: solid, location: 0), .init(color: solid, location: 1)]
        }
        let samples = 24
        return (0...samples).map { i in
            let t = Double(i) / Double(samples)
            return Gradient.Stop(color: color(at: low + (high - low) * t).opacity(opacity(t)), location: t)
        }
    }

    private static func color(_ s: Stop) -> Color {
        Color(.sRGB, red: s.r / 255, green: s.g / 255, blue: s.b / 255)
    }
}

extension ChartValueScale {
    static let deep: FootScale.RGB = (11, 35, 80)
    static let signal: FootScale.RGB = (44, 156, 240)
    static let ice: FootScale.RGB = (91, 210, 255)
    static let peach: FootScale.RGB = (255, 208, 138)
    static let amber: FootScale.RGB = (255, 155, 61)
    static let ember: FootScale.RGB = (255, 106, 19)

    /// Foot temperature on the maps' thermal ramp, in °C (the unit widgets
    /// plot in; they convert only the labels).
    static let footTemperatureCelsius = ChartValueScale(FootScale.thermal.map { position, rgb in
        (FootScale.thermalRangeC.lowerBound + position * (FootScale.thermalRangeC.upperBound - FootScale.thermalRangeC.lowerBound), rgb)
    })

    /// Steadiness, 0–100 %: low is the warning, high is calm. The usual
    /// range (70s to 90s) is spread from peach to deep blue, so an ordinary
    /// dip shows as a change in colour, not just in height.
    static let steadiness = ChartValueScale([(0, ember), (45, ember), (60, amber), (72, peach), (84, ice), (100, signal)])
}
