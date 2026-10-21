import Foundation

// Population priors: what's typical across Thermyx wearers, so a new wearer's
// personal models don't start from nothing.
//
// Write side. A wearer who opts in sends, at most once a month, a handful of
// rounded numbers about their own calm minutes (never readings, times or
// places). Each number is its own document, with a random ID, no user ID and
// no timestamp, so nothing links a document to a person or to its siblings.
// Documents can't be changed or deleted once written (nothing identifies
// their owner to authorise it); they expire on their own (`expireAt`, a
// Firestore TTL policy) a few days into the next month.
//
// Read side. Firestore aggregation queries return only totals: how many
// documents, their mean, and the sum of their squares (for the spread). A
// cohort with fewer than `PopulationPriors.minimumContributors` contributors
// is skipped in favour of a broader one.

/// One thing a contribution can carry.
enum PopulationMetric: String, CaseIterable {
    case footSitting, footStanding, footWalking
    case steadiness
    case standingLean, walkingLean
    case steadinessGap

    /// Values are rounded to this before they leave the phone.
    var step: Double {
        switch self {
        case .footSitting, .footStanding, .footWalking: return 0.1
        default: return 0.02
        }
    }

    /// The range Firestore's security rules accept. Anything outside is
    /// dropped on the phone first.
    var range: ClosedRange<Double> {
        switch self {
        case .footSitting, .footStanding, .footWalking: return 24...40
        case .steadiness: return 0.5...1
        case .standingLean, .walkingLean: return -0.6...0.6
        case .steadinessGap: return -0.5...0.5
        }
    }

    var activity: CalibrationActivity? {
        switch self {
        case .footSitting: return .sitting
        case .footStanding: return .standing
        case .footWalking: return .walking
        default: return nil
        }
    }

    func round(_ value: Double) -> Double {
        let stepped = (value / step).rounded() * step
        return (stepped * 1000).rounded() / 1000
    }
}

/// How wearers are grouped. Deliberately coarse: what they mostly use
/// Thermyx for, and a wide age band. No sex, no conditions, no location.
struct PopulationCohort: Equatable {
    var usage: String
    var band: String

    /// "outdoor-work|adult"-style key for the most specific grouping.
    var key: String { "\(usage)|\(band)" }

    static let usageSlugs: [(option: String, slug: String)] = [
        ("Outdoor work", "outdoor-work"),
        ("Sports and training", "sports"),
        ("Cold weather", "cold"),
        ("Everyday comfort", "everyday"),
    ]

    /// The first of the wearer's choices, in the app's fixed order, so the
    /// same answers always give the same cohort.
    static func make(usage: [String], age: Int?) -> PopulationCohort {
        let slug = usageSlugs.first { usage.contains($0.option) }?.slug ?? "general"
        let band: String
        switch age {
        case .none: band = "unknown"
        case .some(..<30): band = "under-30"
        case .some(30..<60): band = "30-59"
        default: band = "60-plus"
        }
        return PopulationCohort(usage: slug, band: band)
    }
}

/// What the phone hands over to be summarised. Read-only.
struct PopulationInputs {
    var minutes: [ThermyxHistorySample]
    var baseline: PersonalBaseline
    var usage: [String]
    var age: Int?
}

@MainActor
protocol PopulationSource: AnyObject {
    /// The wearer's cohort, from their own settings.
    var populationCohort: PopulationCohort { get }
    /// Nil in Demo Mode, where there is nothing real to summarise.
    var populationInputs: PopulationInputs? { get }
}

/// What one wearer sends: a cohort and some rounded numbers.
struct PopulationContribution: Equatable {
    var cohort: PopulationCohort
    var values: [PopulationMetric: Double]

    /// Calm minutes needed behind a number before it's worth sending.
    static let minimumMinutes = 20
    /// Seconds of one activity that make a minute "a minute of" it.
    static let minimumActivitySeconds = 30.0

    /// Builds a contribution from the wearer's own calm minutes. Pure.
    ///
    /// Calm means the minute never rose above Normal and the insole wasn't
    /// heating or cooling, the same rule the personal baseline learns by, so
    /// a hot afternoon can't teach the population that hot is normal.
    static func make(from inputs: PopulationInputs) -> PopulationContribution? {
        // Only wearers whose own baseline has calibrated: real wear, not a
        // few seconds of a test.
        guard inputs.baseline.isCalibrated else { return nil }

        let calm = inputs.minutes.filter { sample in
            (sample.peakRiskLevel ?? .normal) == .normal
                && (sample.heatingSeconds ?? 0) == 0 && (sample.coolingSeconds ?? 0) == 0
                && sample.sampleCount >= 10
        }
        func activity(_ s: ThermyxHistorySample) -> CalibrationActivity? {
            let seconds: [(CalibrationActivity, Double)] = [
                (.sitting, s.sittingSeconds ?? 0), (.standing, s.standingSeconds ?? 0), (.walking, s.walkingSeconds ?? 0),
            ]
            guard let top = seconds.max(by: { $0.1 < $1.1 }), top.1 >= minimumActivitySeconds else { return nil }
            return top.0
        }
        func mean(_ xs: [Double]) -> Double? { xs.count >= minimumMinutes ? xs.reduce(0, +) / Double(xs.count) : nil }

        var values: [PopulationMetric: Double] = [:]
        func put(_ metric: PopulationMetric, _ value: Double?) {
            guard let value, value.isFinite else { return }
            let rounded = metric.round(value)
            if metric.range.contains(rounded) { values[metric] = rounded }
        }

        for metric in PopulationMetric.allCases {
            guard let wanted = metric.activity else { continue }
            put(metric, mean(calm.filter { activity($0) == wanted }.compactMap(\.footMeanC)))
        }
        let walking = calm.filter { activity($0) == .walking }
        put(.steadiness, mean(walking.compactMap(\.gaitMean)) ?? inputs.baseline.gaitMean)

        // Left minus right, from minutes where both insoles reported.
        struct Pair { var activity: CalibrationActivity; var load: Double?; var gait: Double? }
        var pairs: [Pair] = []
        let lefts = Dictionary(grouping: calm.filter { $0.foot == .left }, by: \.start)
        let rights = Dictionary(grouping: calm.filter { $0.foot == .right }, by: \.start)
        for (start, l) in lefts {
            guard let left = l.first, let right = rights[start]?.first,
                  let doing = activity(left), doing == activity(right) else { continue }
            pairs.append(Pair(activity: doing,
                              load: zip2(left.balanceMean, right.balanceMean),
                              gait: zip2(left.gaitMean, right.gaitMean)))
        }
        put(.standingLean, mean(pairs.filter { $0.activity == .standing }.compactMap(\.load)))
        put(.walkingLean, mean(pairs.filter { $0.activity == .walking }.compactMap(\.load)))
        put(.steadinessGap, mean(pairs.filter { $0.activity == .walking }.compactMap(\.gait)))

        guard !values.isEmpty else { return nil }
        return PopulationContribution(cohort: .make(usage: inputs.usage, age: inputs.age), values: values)
    }

    private static func zip2(_ l: Double?, _ r: Double?) -> Double? {
        guard let l, let r else { return nil }
        return l - r
    }

    // MARK: Periods

    /// The calendar month in UTC, "2026-10". At most one contribution goes
    /// out per period per phone.
    static func period(for date: Date) -> String {
        let c = utc.dateComponents([.year, .month], from: date)
        return String(format: "%04d-%02d", c.year ?? 0, c.month ?? 0)
    }

    /// Three days into the next month: long enough that a phone that
    /// contributes on the 1st isn't counted twice, short enough that the
    /// numbers are gone within about five weeks.
    static func expiry(for date: Date) -> Date {
        let start = utc.dateInterval(of: .month, for: date)?.end ?? date
        return start.addingTimeInterval(3 * 24 * 3600)
    }

    private static let utc: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        return calendar
    }()

    // MARK: Documents

    static let collection = "priorSamples"
    static let schema = 1

    /// One document per number: random ID, no user ID, no timestamp.
    func documents(now: Date, makeID: () -> String = { UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased() }) -> [CloudWrite] {
        let expireAt = Self.expiry(for: now)
        return PopulationMetric.allCases.compactMap { metric in
            guard let value = values[metric] else { return nil }
            return CloudWrite(path: "\(Self.collection)/\(makeID())", data: [
                "v": Self.schema,
                "metric": metric.rawValue,
                "cohort": cohort.key,
                "usage": cohort.usage,
                "band": cohort.band,
                "value": value,
                "sq": value * value,
                "expireAt": expireAt,
            ])
        }
    }
}

// MARK: - Reading the totals

/// Turns aggregation totals into `PopulationPriors`.
struct PopulationPriorsReader {
    let store: CloudDocumentStore

    /// Cohorts to try, most specific first, ending with everyone.
    static func levels(for cohort: PopulationCohort) -> [(key: String, filter: [String: String])] {
        [
            (cohort.key, ["cohort": cohort.key]),
            (cohort.usage, ["usage": cohort.usage]),
            ("all", [:]),
        ]
    }

    /// For each number, the most specific cohort with enough contributors.
    /// `cohort` on the result names the most specific one that supplied any.
    func fetch(cohort: PopulationCohort, now: Date = .now) async throws -> PopulationPriors? {
        let levels = Self.levels(for: cohort)
        var priors = PopulationPriors(computedAt: now)
        var best = levels.count
        for metric in PopulationMetric.allCases {
            for (index, level) in levels.enumerated() {
                var filter = level.filter
                filter["metric"] = metric.rawValue
                let totals = try await store.aggregate(CloudAggregateRequest(collection: PopulationContribution.collection, equals: filter, averageOf: "value"))
                guard totals.count >= PopulationPriors.minimumContributors, let mean = totals.average else { continue }
                let squares = try await store.aggregate(CloudAggregateRequest(collection: PopulationContribution.collection, equals: filter, sumOf: "sq"))
                guard let sumSquares = squares.sum, let stats = Self.stats(count: totals.count, mean: mean, sumSquares: sumSquares, metric: metric) else { continue }
                if let activity = metric.activity {
                    priors.footByActivity[activity] = stats
                } else {
                    switch metric {
                    case .steadiness: priors.steadiness = stats
                    case .standingLean: priors.standingLean = stats
                    case .walkingLean: priors.walkingLean = stats
                    case .steadinessGap: priors.steadinessGap = stats
                    default: break
                    }
                }
                best = min(best, index)
                break
            }
        }
        guard best < levels.count else { return nil }
        priors.cohort = levels[best].key
        return priors
    }

    /// Mean and sample standard deviation from a count, a mean and a sum of
    /// squares. Nil when the totals can't be right (a mean outside the
    /// metric's range, which a poisoned cohort could produce).
    static func stats(count: Int, mean: Double, sumSquares: Double, metric: PopulationMetric) -> PopulationPriors.Stats? {
        guard count >= 2, mean.isFinite, sumSquares.isFinite, metric.range.contains(mean) else { return nil }
        let n = Double(count)
        let variance = max(0, (sumSquares - n * mean * mean) / (n - 1))
        return PopulationPriors.Stats(mean: mean, sd: variance.squareRoot(), count: count)
    }
}
