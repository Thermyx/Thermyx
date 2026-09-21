import Foundation

/// Everything the Insights screens draw, derived in one place from retained
/// history.
///
/// Each field is optional and stays nil when the underlying history cannot
/// support it. Views check for nil and show an empty state — no card ever
/// renders half-populated or against a fabricated baseline.
struct InsightsDigest {
    let range: InsightsRange
    var style: InsightsPeriodStyle = .standard
    let samples: [ThermyxHistorySample]

    // MARK: - Availability

    /// Three buckets is the floor for anything shaped like a trend.
    var hasSeries: Bool { samples.count >= 3 }

    /// Zone data exists only if the insole reported it. A v1 insole has none,
    /// and the zone heat map is hidden entirely rather than drawn empty.
    var hasZones: Bool { samples.contains { $0.zones != nil } }

    var hasAmbient: Bool { samples.contains { $0.ambientMeanC != nil } }
    var hasGait: Bool { samples.contains { $0.gaitMean != nil } }
    var hasBalance: Bool { samples.contains { $0.balanceMean != nil } }

    // MARK: - Temperature

    var footValues: [Double] { samples.compactMap(\.footMeanC) }

    var peakC: Double? { samples.compactMap(\.footMaxC).max() }
    var lowC: Double? { samples.compactMap(\.footMinC).min() }
    var averageC: Double? {
        let values = footValues
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    /// The hottest bucket, marked on the full-day chart.
    var peakSample: ThermyxHistorySample? {
        samples.max { ($0.footMaxC ?? -.infinity) < ($1.footMaxC ?? -.infinity) }
    }

    /// Seconds in each temperature band, from bucket durations.
    var timeInZone: [ThermyxTemperatureScale.Band: TimeInterval] {
        var result: [ThermyxTemperatureScale.Band: TimeInterval] = [:]
        let bucketLength = range.usesHourlyTier ? TimeInterval(3600) : TimeInterval(60)
        for sample in samples {
            guard let foot = sample.footMeanC else { continue }
            result[ThermyxTemperatureScale.band(for: foot), default: 0] += bucketLength
        }
        return result
    }

    /// Proportion of the window spent above the comfort band — the donut.
    var heatExposureFraction: Double? {
        let zones = timeInZone
        let total = zones.values.reduce(0, +)
        guard total > 0 else { return nil }
        let hot = (zones[.warm] ?? 0) + (zones[.hot] ?? 0)
        return hot / total
    }

    var heatExposureSeconds: TimeInterval {
        let zones = timeInZone
        return (zones[.warm] ?? 0) + (zones[.hot] ?? 0)
    }

    var comfortSeconds: TimeInterval {
        let zones = timeInZone
        return (zones[.cool] ?? 0) + (zones[.comfort] ?? 0)
    }

    /// Mean gap between foot and ambient temperature, shown on the
    /// foot-vs-ambient card.
    var footAmbientDelta: Double? {
        let pairs = samples.compactMap { sample -> Double? in
            guard let foot = sample.footMeanC, let ambient = sample.ambientMeanC else { return nil }
            return foot - ambient
        }
        guard !pairs.isEmpty else { return nil }
        return pairs.reduce(0, +) / Double(pairs.count)
    }

    // MARK: - Movement

    var gaitValues: [Double] { samples.compactMap(\.gaitMean) }

    /// The user's own rolling baseline: the mean of the earlier half of the
    /// window. Nil when there is not enough history for that to mean anything.
    var gaitBaseline: Double? {
        let values = gaitValues
        guard values.count >= 6 else { return nil }
        let head = values.prefix(values.count / 2)
        return head.reduce(0, +) / Double(head.count)
    }

    var gaitLatest: Double? { samples.last(where: { $0.gaitMean != nil })?.gaitMean }

    /// Percentage-point change against the baseline.
    var gaitDelta: Double? {
        guard let baseline = gaitBaseline, let latest = gaitLatest, baseline > 0 else { return nil }
        return (latest - baseline) * 100
    }

    var balanceLatest: Double? { samples.last(where: { $0.balanceMean != nil })?.balanceMean }

    // MARK: - Cadence and standing
    //
    // Both arrive from the controller's IMU on protocol v3. On older firmware
    // they are absent and the tiles that use them show their empty state.

    var hasCadence: Bool { samples.contains { $0.cadenceMean != nil } }
    var hasStanding: Bool { samples.contains { $0.standingMean != nil } }

    var cadenceValues: [Double] { samples.compactMap(\.cadenceMean) }

    var cadenceAverage: Double? {
        let values = cadenceValues
        guard !values.isEmpty else { return nil }
        return values.reduce(0, +) / Double(values.count)
    }

    var cadenceLatest: Double? { samples.last(where: { $0.cadenceMean != nil })?.cadenceMean }

    /// Standing time, integrated from each bucket's standing proportion.
    var standingSeconds: TimeInterval? {
        guard hasStanding else { return nil }
        let bucketLength = range.usesHourlyTier ? TimeInterval(3600) : TimeInterval(60)
        return samples.compactMap(\.standingMean).reduce(0) { $0 + $1 * bucketLength }
    }

    /// How long this window actually has data for.
    var trackedSeconds: TimeInterval {
        let bucketLength = range.usesHourlyTier ? TimeInterval(3600) : TimeInterval(60)
        return Double(samples.count) * bucketLength
    }

    // MARK: - Series for the shared chart

    func points(_ value: (ThermyxHistorySample) -> Double?) -> [SeriesPoint] {
        samples.compactMap { sample in
            guard let v = value(sample) else { return nil }
            return SeriesPoint(date: sample.start, value: v)
        }
    }

    /// Forefoot / arch / heel share of load. Derived from the single balance
    /// channel the current hardware reports, so only forefoot and heel are
    /// measured; the arch share is the remainder, and the UI says so.
    var pressureSplit: (forefoot: Double, arch: Double, heel: Double)? {
        guard let balance = balanceLatest else { return nil }
        let forefoot = min(max(balance, 0), 1)
        let heel = 1 - forefoot
        return (forefoot: forefoot * 0.82, arch: 0.18, heel: heel * 0.82)
    }

    // MARK: - Zones

    /// A row per zone, each holding one value per bucket, for the heat map.
    func zoneSeries(columns: Int = 7) -> [FootZone: [Double]]? {
        guard hasZones else { return nil }
        let withZones = samples.filter { $0.zones != nil }
        guard withZones.count >= columns else { return nil }

        var result: [FootZone: [Double]] = [:]
        let chunk = Double(withZones.count) / Double(columns)
        for zone in FootZone.allCases {
            var row: [Double] = []
            for column in 0..<columns {
                let start = Int(Double(column) * chunk)
                let end = max(start + 1, Int(Double(column + 1) * chunk))
                let slice = withZones[start..<min(end, withZones.count)]
                let values = slice.compactMap { $0.zones?[zone] }
                guard !values.isEmpty else { continue }
                row.append(values.reduce(0, +) / Double(values.count))
            }
            guard row.count == columns else { return nil }
            result[zone] = row
        }
        return result
    }

    /// Time-of-day labels matching the heat-map columns. Each label marks the
    /// midpoint of its column, so the ticks step evenly across the window.
    func columnLabels(count: Int = 7) -> [String] {
        guard let first = samples.first?.start, let last = samples.last?.start, count > 1 else { return [] }
        let span = last.timeIntervalSince(first)
        let formatter = DateFormatter()
        formatter.dateFormat = range == .day ? "HH:mm" : "E"
        return (0..<count).map { index in
            if index == count - 1 { return "Now" }
            let midpoint = span * (Double(index) + 0.5) / Double(count)
            return formatter.string(from: first.addingTimeInterval(midpoint))
        }
    }

    /// The `06:00 / 10:00 / 14:00 / 18:00` style axis under the big charts.
    func axisLabels(count: Int = 4) -> [String] {
        guard let first = samples.first?.start, let last = samples.last?.start, count > 1 else { return [] }
        let span = last.timeIntervalSince(first)
        let formatter = DateFormatter()
        switch range {
        case .day: formatter.dateFormat = "HH:mm"
        case .week: formatter.dateFormat = "EEE"
        case .month: formatter.dateFormat = "d MMM"
        }
        return (0..<count).map { index in
            formatter.string(from: first.addingTimeInterval(span * Double(index) / Double(count - 1)))
        }
    }
}
