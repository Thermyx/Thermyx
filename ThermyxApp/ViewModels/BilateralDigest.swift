import SwiftUI

/// Which foot (or feet) the insight screens are showing.
enum FootFilter: Hashable, Identifiable, CaseIterable {
    case both
    case one(Foot)

    static var allCases: [FootFilter] { [.both, .one(.left), .one(.right)] }

    var id: String {
        switch self {
        case .both: return "both"
        case .one(let foot): return foot.rawValue
        }
    }

    var label: String {
        switch self {
        case .both: return "Both"
        case .one(let foot): return foot.label
        }
    }

    var shortLabel: String {
        switch self {
        case .both: return "Both"
        case .one(let foot): return foot.shortLabel
        }
    }

    var foot: Foot? {
        if case .one(let foot) = self { return foot }
        return nil
    }

    var feet: [Foot] {
        switch self {
        case .both: return Foot.allCases
        case .one(let foot): return [foot]
        }
    }
}

/// Both feet's history, plus the comparisons between them.
///
/// Left and right are kept strictly separate — a chart that averaged the two
/// would erase the asymmetry that having a pair exists to reveal. Anything
/// that combines them does so explicitly and says so.
struct BilateralDigest {
    let range: InsightsRange
    let style: InsightsPeriodStyle
    let byFoot: [Foot: InsightsDigest]

    init(range: InsightsRange, style: InsightsPeriodStyle, samples: [ThermyxHistorySample]) {
        self.range = range
        self.style = style
        var built: [Foot: InsightsDigest] = [:]
        for foot in Foot.allCases {
            let own = samples.filter { $0.foot == foot }
            guard !own.isEmpty else { continue }
            built[foot] = InsightsDigest(range: range, style: style, samples: own)
        }
        self.byFoot = built
    }

    subscript(foot: Foot) -> InsightsDigest? { byFoot[foot] }

    /// Feet with usable history, in left-then-right order.
    var feet: [Foot] { Foot.allCases.filter { byFoot[$0] != nil } }

    func digests(for filter: FootFilter) -> [(Foot, InsightsDigest)] {
        filter.feet.compactMap { foot in byFoot[foot].map { (foot, $0) } }
    }

    var hasAny: Bool { byFoot.values.contains(where: \.hasSeries) }
    var hasBoth: Bool { feet.count == 2 && byFoot.values.allSatisfy(\.hasSeries) }

    // MARK: - Combined figures
    //
    // Where a single number is genuinely wanted — total heat exposure, worst
    // peak — it comes from the worse foot rather than an average, because the
    // question behind it is "how bad did this get".

    var peakC: Double? { byFoot.values.compactMap(\.peakC).max() }
    var lowC: Double? { byFoot.values.compactMap(\.lowC).min() }

    /// Nil when no foot has usable history — the screens that show these are
    /// gated on `hasAny`, but an optional keeps a zero from ever standing in
    /// for an absence.
    var heatExposureSeconds: TimeInterval? {
        byFoot.values.map(\.heatExposureSeconds).max()
    }

    var comfortSeconds: TimeInterval? {
        byFoot.values.map(\.comfortSeconds).max()
    }

    var heatExposureFraction: Double? {
        byFoot.values.compactMap(\.heatExposureFraction).max()
    }

    // MARK: - Asymmetry over time

    /// Left minus right, bucket by bucket, for any channel. Only buckets where
    /// both feet reported are included — comparing a foot against nothing
    /// would draw a difference that is really just a gap in coverage.
    func asymmetrySeries(_ value: @escaping (ThermyxHistorySample) -> Double?) -> [SeriesPoint] {
        guard let left = byFoot[.left], let right = byFoot[.right] else { return [] }
        let rightByStart = Dictionary(right.samples.map { ($0.start, $0) }, uniquingKeysWith: { a, _ in a })
        return left.samples.compactMap { sample in
            guard let counterpart = rightByStart[sample.start],
                  let l = value(sample), let r = value(counterpart)
            else { return nil }
            return SeriesPoint(date: sample.start, value: l - r)
        }
    }

    var temperatureAsymmetry: [SeriesPoint] { asymmetrySeries(\.footMeanC) }
    var loadAsymmetry: [SeriesPoint] { asymmetrySeries { $0.balanceMean.map { $0 * 100 } } }

    /// Mean absolute temperature gap across the window.
    var meanTemperatureGapC: Double? {
        let points = temperatureAsymmetry
        guard !points.isEmpty else { return nil }
        return points.map { abs($0.value) }.reduce(0, +) / Double(points.count)
    }

    /// Which foot ran hotter over the window, when it is consistent enough to
    /// name. A gap that flips sign is noise, not a finding.
    var consistentlyHotterFoot: Foot? {
        let points = temperatureAsymmetry
        guard points.count >= 5 else { return nil }
        let positive = points.filter { $0.value > 0.4 }.count
        let negative = points.filter { $0.value < -0.4 }.count
        let total = Double(points.count)
        if Double(positive) / total > 0.7 { return .left }
        if Double(negative) / total > 0.7 { return .right }
        return nil
    }

    /// Which foot carried more load, on the same consistency rule.
    var consistentlyLoadedFoot: Foot? {
        let points = loadAsymmetry
        guard points.count >= 5 else { return nil }
        let positive = points.filter { $0.value > 4 }.count
        let negative = points.filter { $0.value < -4 }.count
        let total = Double(points.count)
        if Double(positive) / total > 0.7 { return .left }
        if Double(negative) / total > 0.7 { return .right }
        return nil
    }
}

extension Foot {
    /// Left is drawn solid, right dashed.
    ///
    /// Colour already carries temperature in this app, so it cannot also carry
    /// which foot — the two meanings would fight. Line style is free.
    var isDashedInCharts: Bool { self == .right }

    /// A neutral tint for charts where the value is not a temperature.
    var chartTint: Color { self == .left ? Thermyx.Ink.ice : Thermyx.Ink.signal }
}
