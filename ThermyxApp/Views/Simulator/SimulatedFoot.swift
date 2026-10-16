import SwiftUI

/// Whole-sole pressure and temperature for the Simulator's maps, ported from
/// the v2 design's model: fourteen load sites under toes, forefoot, midfoot
/// and heel, weighted through the stance phase, and a temperature shape
/// warmest under the ball and heel. Simulator only: live insoles don't
/// measure any of this.
enum SimulatedFoot {
    enum Region { case toes, forefoot, midfoot, heel }

    /// (medial-ness, toe-to-heel, spread, weight, region)
    private static let sites: [(m: Double, v: Double, s: Double, w: Double, r: Region)] = [
        (0.66, 0.075, 0.06, 0.95, .toes), (0.47, 0.1, 0.04, 0.5, .toes), (0.35, 0.145, 0.035, 0.42, .toes),
        (0.24, 0.2, 0.035, 0.36, .toes), (0.15, 0.27, 0.03, 0.3, .toes),
        (0.68, 0.27, 0.075, 0.85, .forefoot), (0.52, 0.28, 0.07, 0.8, .forefoot), (0.37, 0.32, 0.07, 0.68, .forefoot),
        (0.2, 0.39, 0.07, 0.6, .forefoot),
        (0.22, 0.53, 0.07, 0.38, .midfoot), (0.28, 0.66, 0.07, 0.36, .midfoot), (0.36, 0.76, 0.07, 0.4, .midfoot),
        (0.6, 0.87, 0.09, 0.95, .heel), (0.48, 0.9, 0.07, 0.35, .heel),
    ]

    /// The centre of pressure from heel strike to toe-off, as (m, v).
    static let centreOfPressure: [CGPoint] = [
        CGPoint(x: 0.6, y: 0.93), CGPoint(x: 0.56, y: 0.8), CGPoint(x: 0.5, y: 0.62), CGPoint(x: 0.5, y: 0.45),
        CGPoint(x: 0.56, y: 0.3), CGPoint(x: 0.63, y: 0.16), CGPoint(x: 0.66, y: 0.06),
    ]

    /// How loaded each region is at a point in stance (0 heel strike to 1
    /// toe-off), or standing when `phase` is nil.
    static func weights(phase: Double?) -> [Region: Double] {
        guard let ph = phase else { return [.toes: 0.9, .forefoot: 1, .midfoot: 0.85, .heel: 1] }
        func bump(_ c: Double, _ w: Double) -> Double { exp(-pow((ph - c) / w, 2)) }
        return [.heel: bump(0.14, 0.2), .midfoot: bump(0.42, 0.22), .forefoot: bump(0.66, 0.2), .toes: bump(0.88, 0.12)]
    }

    struct Loading: Equatable {
        /// Overall load, about 0.4 (barely standing) to 1.2 (heavy pack).
        var intensity = 1.0
        var fit: ThermalSimulation.Fit = .good
    }

    static func pressure(m: Double, v: Double, weights: [Region: Double], loading: Loading) -> Double {
        var q = 1.0
        for site in sites {
            var w = site.w * (weights[site.r] ?? 0)
            var s = site.s
            switch loading.fit {
            case .tight where site.r == .forefoot || site.r == .toes: w *= 1.15; s *= 0.88
            case .loose where site.r == .heel: w *= 1.1
            case .loose where site.r == .forefoot: w *= 0.9
            default: break
            }
            let dx = (m - site.m) * 0.419, dy = v - site.v
            q *= 1 - min(0.98, w * loading.intensity) * exp(-(dx * dx + dy * dy) / (2 * s * s))
        }
        return (1 - q) * (1 + 0.1 * sin(m * 29 + v * 41) * sin(m * 17 - v * 23))
    }

    /// The design's temperature shape, 0...1: warm under the ball and heel,
    /// cooler at the arch and toes.
    static func temperatureShape(m: Double, v: Double, foot: Foot) -> Double {
        func g(_ a: Double, _ b: Double, _ s: Double) -> Double {
            exp(-(pow((m - a) * 0.419, 2) + pow(v - b, 2)) / (2 * s * s))
        }
        let shape = 0.4 + 0.4 * g(0.5, 0.32, 0.16) + 0.2 * g(0.6, 0.86, 0.1) - 0.22 * g(0.85, 0.6, 0.08)
            - 0.12 * g(0.45, 0.04, 0.05) + 0.04 * sin(m * 19 + v * 27)
        return min(1, max(0, shape))
    }

    static func pressureField(phase: Double?, loading: Loading) -> FootField {
        let w = weights(phase: phase)
        return FootField(value: { m, v in pressure(m: m, v: v, weights: w, loading: loading) }, scale: .load, bands: 16)
    }

    /// The temperature shape spread ±1.6 °C around the foot's simulated mean.
    static func temperatureField(meanC: Double, foot: Foot) -> FootField {
        FootField(value: { m, v in
            FootScale.thermalPosition(meanC + (temperatureShape(m: m, v: v, foot: foot) - 0.55) * 3.2)
        }, scale: .thermal, bands: 12)
    }

    /// Where in stance a foot is at `time`, for `cadence` steps a minute: nil
    /// when standing still, above 1 while the foot is in the air.
    static func phase(time: TimeInterval, cadence: Double, foot: Foot) -> Double? {
        guard cadence > 0 else { return nil }
        let period = 120 / cadence
        let cycle = (time / period + (foot == .right ? 0.5 : 0)).truncatingRemainder(dividingBy: 1)
        return cycle / 0.62
    }
}
