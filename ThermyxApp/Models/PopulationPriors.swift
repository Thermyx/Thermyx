import Foundation

/// What's typical across Thermyx wearers like this one: the starting point
/// for a new wearer's personal models, before their own data builds up.
///
/// Shared contract between two parts of the app:
/// - **Produced** by the Firebase layer (`Services/Cloud/*`), from opt-in,
///   anonymous, rounded contributions, via Firestore aggregation queries.
///   Never from anyone's raw readings.
/// - **Consumed** by the ML layer (`Models/ML/*`, `PersonalBaseline`): a new
///   wearer's baselines are shrunk toward these and let go of them as their
///   own data accumulates.
///
/// Every value is optional: a cohort with too few contributors has none, and
/// the ML layer then falls back to its fixed defaults. Temperatures are °C at
/// the insole; load lean is left-minus-right share (positive leans left).
struct PopulationPriors: Codable, Equatable {
    struct Stats: Codable, Equatable {
        var mean: Double
        var sd: Double
        /// How many contributors this came from.
        var count: Int
    }

    /// Bump when the meaning of a field changes; consumers ignore other versions.
    static let currentVersion = 1

    var version: Int = PopulationPriors.currentVersion
    /// The cohort these describe, e.g. "outdoor-work|adult". "all" when not split.
    var cohort: String = "all"
    /// When the aggregation was computed.
    var computedAt: Date

    /// Usual foot temperature at the insole while sitting, standing, walking.
    var footByActivity: [CalibrationActivity: Stats] = [:]
    /// Walking steadiness, 0…1.
    var steadiness: Stats?
    /// Usual left-minus-right load share while standing.
    var standingLean: Stats?
    /// Usual left-minus-right load share while walking (step-averaged).
    var walkingLean: Stats?
    /// Usual left-minus-right steadiness while walking.
    var steadinessGap: Stats?

    /// Contributions below this aren't trusted for a cohort.
    static let minimumContributors = 20

    /// Whether a stat is backed by enough contributors to use.
    static func usable(_ stats: Stats?) -> Stats? {
        guard let stats, stats.count >= minimumContributors, stats.sd.isFinite, stats.sd >= 0 else { return nil }
        return stats
    }
}
