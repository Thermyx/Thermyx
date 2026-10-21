import Foundation

// Small, deterministic statistics used by the on-device models. Everything
// here is pure and allocation-light; nothing reads the clock or a random
// number generator, so the same inputs always give the same answer.

/// Robust summaries that a few wild readings cannot drag around. Foot sensors
/// glitch, a step can be missed, and a calm minute can still contain a bump;
/// medians and MADs shrug those off where means and standard deviations don't.
enum RobustStats {
    /// Scales a MAD to estimate a normal distribution's standard deviation.
    static let madToSD = 1.4826

    static func mean(_ xs: [Double]) -> Double? {
        xs.isEmpty ? nil : xs.reduce(0, +) / Double(xs.count)
    }

    /// Sample standard deviation (n − 1), nil with fewer than two values.
    static func sd(_ xs: [Double]) -> Double? {
        guard xs.count >= 2, let m = mean(xs) else { return nil }
        return (xs.map { ($0 - m) * ($0 - m) }.reduce(0, +) / Double(xs.count - 1)).squareRoot()
    }

    static func median(_ xs: [Double]) -> Double? {
        quantile(xs, 0.5)
    }

    /// Linear-interpolated quantile, `q` in 0…1.
    static func quantile(_ xs: [Double], _ q: Double) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let position = min(max(q, 0), 1) * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down)), upper = Int(position.rounded(.up))
        guard lower != upper else { return sorted[lower] }
        let fraction = position - Double(lower)
        return sorted[lower] * (1 - fraction) + sorted[upper] * fraction
    }

    /// Median absolute deviation, unscaled.
    static func mad(_ xs: [Double], median m: Double? = nil) -> Double? {
        guard let centre = m ?? median(xs) else { return nil }
        return median(xs.map { abs($0 - centre) })
    }

    /// A standard-deviation estimate from the MAD. Nil with fewer than three
    /// values, where a spread means nothing.
    static func robustSD(_ xs: [Double]) -> Double? {
        guard xs.count >= 3, let mad = mad(xs) else { return nil }
        return mad * madToSD
    }

    /// Mean of the middle values after trimming `fraction` from each end.
    static func trimmedMean(_ xs: [Double], fraction: Double = 0.1) -> Double? {
        guard !xs.isEmpty else { return nil }
        let sorted = xs.sorted()
        let cut = min(Int(Double(sorted.count) * fraction), (sorted.count - 1) / 2)
        return mean(Array(sorted[cut..<(sorted.count - cut)]))
    }

    /// Drops values more than `k` robust deviations from the median. Needs
    /// eight values to judge anyone an outlier; fewer are returned untouched.
    /// `floor` keeps a perfectly steady series from making everything an
    /// outlier.
    static func rejectingOutliers(_ xs: [Double], k: Double = 3.5, floor: Double) -> (kept: [Double], rejected: Int) {
        guard xs.count >= 8, let m = median(xs) else { return (xs, 0) }
        let spread = max(robustSD(xs) ?? 0, floor)
        let kept = xs.filter { abs($0 - m) <= k * spread }
        // Never throw away most of the data: that means the model is wrong,
        // not that the data is.
        guard kept.count * 2 >= xs.count else { return (xs, 0) }
        return (kept, xs.count - kept.count)
    }

    /// Wilson score interval for a proportion: honest about small samples,
    /// where the plain "p ± 1.96 sqrt(p(1−p)/n)" claims too much.
    static func wilsonInterval(successes: Int, total: Int, z: Double = 1.96) -> ClosedRange<Double>? {
        guard total > 0, successes >= 0, successes <= total else { return nil }
        let n = Double(total), p = Double(successes) / n
        let z2 = z * z
        let denominator = 1 + z2 / n
        let centre = (p + z2 / (2 * n)) / denominator
        let half = z * (p * (1 - p) / n + z2 / (4 * n * n)).squareRoot() / denominator
        return max(0, centre - half)...min(1, centre + half)
    }
}

/// A bounded rolling series of recent values with robust summaries. Codable so
/// a baseline can be kept on the phone between launches.
struct RollingSeries: Codable, Equatable {
    private(set) var values: [Double] = []
    let capacity: Int

    init(capacity: Int = 180) {
        self.capacity = max(1, capacity)
    }

    var count: Int { values.count }
    var median: Double? { RobustStats.median(values) }
    var robustSD: Double? { RobustStats.robustSD(values) }

    mutating func append(_ x: Double) {
        guard x.isFinite else { return }
        values.append(x)
        if values.count > capacity { values.removeFirst(values.count - capacity) }
    }

    mutating func removeAll() { values.removeAll() }
}

/// Bayesian shrinkage: how much a wearer's own data should trust a
/// population prior, and how that trust fades as their data accumulates.
///
/// A wearer's usual value μ is modelled as drawn from the population,
/// μ ~ N(μ₀, τ²). Their measurements scatter around it with within-wearer
/// spread σ. With n independent observations the posterior mean is the
/// precision-weighted blend of the two, so the prior's weight is
/// (1/τ²) / (1/τ² + n/σ²): large for the first few observations, then
/// shrinking roughly as 1/n. A narrow population (small τ) is trusted longer
/// than a wide one, which is the right behaviour: a prior that says "nearly
/// everyone is like this" is worth more than one that says "anything goes".
enum Shrinkage {
    struct Estimate: Equatable {
        /// The blended mean.
        var mean: Double
        /// Share of the answer that came from the prior, 0…1.
        var priorWeight: Double
        /// Posterior standard deviation of the wearer's usual value.
        var sd: Double
    }

    /// Consecutive readings of a body signal are strongly correlated, so n
    /// readings carry far less than n readings' worth of independent
    /// information. Callers divide their count by a factor like this first.
    static func effectiveCount(_ n: Int, correlationFactor: Double) -> Double {
        max(0, Double(n) / max(1, correlationFactor))
    }

    static func blend(
        sampleMean: Double?,
        withinSD: Double,
        effectiveN: Double,
        priorMean: Double,
        priorSD: Double
    ) -> Estimate {
        let tau = max(priorSD, 1e-6)
        let priorPrecision = 1 / (tau * tau)
        guard let sampleMean, effectiveN > 0 else {
            return Estimate(mean: priorMean, priorWeight: 1, sd: tau)
        }
        let sigma = max(withinSD, 1e-6)
        let dataPrecision = effectiveN / (sigma * sigma)
        let total = priorPrecision + dataPrecision
        let mean = (priorPrecision * priorMean + dataPrecision * sampleMean) / total
        return Estimate(mean: mean, priorWeight: priorPrecision / total, sd: (1 / total).squareRoot())
    }

    /// Variance shrinkage (scaled inverse-χ²): the sample variance blended
    /// with a prior variance worth `priorDegrees` observations.
    static func variance(sample: Double?, degrees: Int, prior: Double, priorDegrees: Double) -> Double {
        guard let sample, degrees > 0 else { return prior }
        let d = Double(degrees)
        return (priorDegrees * prior + d * sample) / (priorDegrees + d)
    }

    /// Limits how far the prior may move the answer from the wearer's own
    /// data. However odd a downloaded prior is, it cannot override what the
    /// phone has measured by more than this.
    static func bounded(_ estimate: Estimate, around sampleMean: Double?, maxPull: Double) -> Estimate {
        guard let sampleMean else { return estimate }
        var result = estimate
        result.mean = min(max(estimate.mean, sampleMean - maxPull), sampleMean + maxPull)
        return result
    }
}
