import Foundation

// Honest evaluation and calibration of the activity classifier.
//
// What the old check got wrong: it was leave-one-window-out. Neighbouring
// 10 s windows of the same minute are nearly copies of each other, so holding
// out one and training on its twins says almost nothing about how the model
// will do on a *new* stretch of walking. The evaluation here holds out whole
// contiguous pieces instead:
//
//  - **Leave-one-segment-out** when every activity was recorded in at least
//    two separate segments (indoor and outdoor, say): each segment in turn is
//    the test set and the model has never seen it. This is the real question:
//    does what was learned indoors recognise walking outside?
//  - **Blocked k-fold** otherwise: each segment is cut into contiguous blocks
//    and one block per segment is held out, with a gap either side when there
//    is room, so test windows are never next to training windows.
//
// Raw naive Bayes probabilities are overconfident (the features are not
// independent, so the evidence is counted several times). Held-out scores are
// used to fit a single temperature that softens them, and the report shows
// log loss, Brier score and expected calibration error before and after.
// That one parameter is fit on the same held-out scores it is judged on, so
// the "after" figures are very slightly optimistic; the accuracy figures are
// untouched by it.
//
// With a calibration this short (30 s per step, three windows) the sample is
// small. The report says so: it carries the number of held-out windows, a
// Wilson 95% interval on accuracy, and `isReliable`.

/// One recorded stretch of a single activity, already cut into windows.
struct LabelledWindows: Equatable {
    var activity: CalibrationActivity
    /// Distinguishes separate recordings of the same activity.
    var segment: Int
    var windows: [ActivityFeatures]
}

struct ClassifierEvaluation: Codable, Equatable {
    enum Method: String, Codable, Equatable {
        case leaveOneSegmentOut, blockedKFold
    }

    var method: Method
    var folds: Int
    /// Held-out windows scored.
    var windows: Int
    /// Windows per activity in the held-out set.
    var classCounts: [String: Int]

    var accuracy: Double
    /// Wilson 95% interval on accuracy, [low, high].
    var accuracyInterval: [Double]
    /// Mean of the per-activity recalls: not flattered by a common class.
    var balancedAccuracy: Double
    var macroF1: Double
    var recall: [String: Double]
    /// confusion[truth][guess] = count.
    var confusion: [String: [String: Int]]

    /// Temperature that softens the raw probabilities (1 = already honest).
    var temperature: Double
    var logLossRaw: Double
    var logLossCalibrated: Double
    var brierCalibrated: Double
    /// Expected calibration error: how far stated confidence is from how
    /// often the model is right, averaged over confidence bins. Raw is the
    /// model as trained; the other is after the temperature.
    var expectedCalibrationErrorRaw: Double
    var expectedCalibrationError: Double

    /// Enough held-out data to quote the numbers: at least 30 windows and 5
    /// of every activity.
    var isReliable: Bool
    var warnings: [String]

    /// One plain line for a debug screen or log.
    var summary: String {
        let lo = Int((accuracyInterval[0] * 100).rounded()), hi = Int((accuracyInterval[1] * 100).rounded())
        return "\(method == .leaveOneSegmentOut ? "Leave-one-segment-out" : "Blocked \(folds)-fold"): "
            + "\(Int((accuracy * 100).rounded()))% of \(windows) held-out windows (95% range \(lo)–\(hi)%), "
            + "balanced \(Int((balancedAccuracy * 100).rounded()))%, "
            + String(format: "log loss %.2f→%.2f at T=%.1f", logLossRaw, logLossCalibrated, temperature)
    }

    // MARK: Running it

    private struct Held {
        var truth: CalibrationActivity
        var scores: [CalibrationActivity: Double]
    }

    /// Cross-validates and calibrates. Nil when there is too little data to
    /// hold anything out. The returned temperature is for
    /// `ActivityClassifier.calibrate(temperature:)`.
    static func evaluate(_ segments: [LabelledWindows]) -> ClassifierEvaluation? {
        let usable = segments.filter { !$0.windows.isEmpty }
        guard Set(usable.map(\.activity)).count >= 2 else { return nil }

        let perActivity = Dictionary(grouping: usable, by: \.activity)
        let separate = perActivity.values.allSatisfy { $0.count >= 2 }

        var held: [Held] = []
        var folds = 0
        let method: Method
        if separate {
            method = .leaveOneSegmentOut
            for test in usable {
                var training: [CalibrationActivity: [ActivityFeatures]] = [:]
                for other in usable where other.segment != test.segment || other.activity != test.activity {
                    training[other.activity, default: []] += other.windows
                }
                folds += 1
                score(test.windows, truth: test.activity, training: training, into: &held)
            }
        } else {
            method = .blockedKFold
            let shortest = usable.map { $0.windows.count }.min() ?? 0
            guard shortest >= 2 else { return nil }
            let k = min(5, max(2, shortest))
            for fold in 0..<k {
                var training: [CalibrationActivity: [ActivityFeatures]] = [:]
                var tests: [(CalibrationActivity, [ActivityFeatures])] = []
                for segment in usable {
                    let m = segment.windows.count
                    let purge = m >= 3 * k ? 1 : 0
                    let foldOf: (Int) -> Int = { min(k - 1, $0 * k / m) }
                    let testIndices = segment.windows.indices.filter { foldOf($0) == fold }
                    tests.append((segment.activity, testIndices.map { segment.windows[$0] }))
                    for j in segment.windows.indices where foldOf(j) != fold {
                        if testIndices.contains(where: { abs($0 - j) <= purge }) { continue }
                        training[segment.activity, default: []].append(segment.windows[j])
                    }
                }
                folds += 1
                for (activity, windows) in tests where !windows.isEmpty {
                    score(windows, truth: activity, training: training, into: &held)
                }
            }
        }
        guard held.count >= 2 else { return nil }
        return summarise(held, method: method, folds: folds)
    }

    private static func score(
        _ windows: [ActivityFeatures],
        truth: CalibrationActivity,
        training: [CalibrationActivity: [ActivityFeatures]],
        into held: inout [Held]
    ) {
        let model = ActivityClassifier(training: training)
        for window in windows {
            guard let scores = model.logScores(window) else { continue }
            held.append(Held(truth: truth, scores: scores))
        }
    }

    // MARK: Metrics

    private static func probabilities(_ scores: [CalibrationActivity: Double], temperature: Double) -> [CalibrationActivity: Double] {
        let scaled = scores.mapValues { $0 / temperature }
        let top = scaled.values.max() ?? 0
        let exps = scaled.mapValues { exp($0 - top) }
        let total = exps.values.reduce(0, +)
        return exps.mapValues { $0 / total }
    }

    private static func logLoss(_ held: [Held], temperature: Double) -> Double {
        let total = held.reduce(0.0) { sum, h in
            let p = probabilities(h.scores, temperature: temperature)[h.truth] ?? 0
            return sum - log(max(p, 1e-6))
        }
        return total / Double(held.count)
    }

    /// The temperature (≥ 1: we only ever soften) that minimises held-out log
    /// loss, by golden-section search on log T. Log loss is unimodal in T for
    /// this model, so this finds the optimum.
    static func fitTemperature(_ scores: [(truth: CalibrationActivity, scores: [CalibrationActivity: Double])]) -> Double {
        let held = scores.map { Held(truth: $0.truth, scores: $0.scores) }
        return fitTemperature(held)
    }

    private static func fitTemperature(_ held: [Held]) -> Double {
        var lo = 0.0, hi = log(50.0)
        let phi = (5.0.squareRoot() - 1) / 2
        var a = hi - phi * (hi - lo), b = lo + phi * (hi - lo)
        var fa = logLoss(held, temperature: exp(a)), fb = logLoss(held, temperature: exp(b))
        for _ in 0..<60 {
            if fa < fb {
                hi = b; b = a; fb = fa
                a = hi - phi * (hi - lo); fa = logLoss(held, temperature: exp(a))
            } else {
                lo = a; a = b; fa = fb
                b = lo + phi * (hi - lo); fb = logLoss(held, temperature: exp(b))
            }
        }
        let best = exp((lo + hi) / 2)
        // When held-out windows are separated perfectly the loss is flat in T
        // and the search lands anywhere. Prefer the least softening that does
        // as well (within 0.005 nats): the data can't justify more.
        let floor = logLoss(held, temperature: best) + 0.005
        var t = 1.0
        while t < best, logLoss(held, temperature: t) > floor { t *= 1.05 }
        return min(t, best)
    }

    /// Expected calibration error over equal-width confidence bins (5 when
    /// there are few windows, else 10).
    private static func expectedCalibrationError(_ held: [Held], temperature: Double) -> Double {
        let confidences: [(confidence: Double, right: Bool)] = held.map { h in
            let p = probabilities(h.scores, temperature: temperature)
            let guess = h.scores.max { $0.value < $1.value }!.key
            return (p[guess] ?? 0, guess == h.truth)
        }
        let bins = held.count < 60 ? 5 : 10
        var ece = 0.0
        for b in 0..<bins {
            let lower = Double(b) / Double(bins), upper = Double(b + 1) / Double(bins)
            let inBin = confidences.filter { $0.confidence >= lower && ($0.confidence < upper || (b == bins - 1 && $0.confidence <= upper)) }
            guard !inBin.isEmpty else { continue }
            let accuracy = Double(inBin.filter(\.right).count) / Double(inBin.count)
            let confidence = inBin.map(\.confidence).reduce(0, +) / Double(inBin.count)
            ece += Double(inBin.count) / Double(held.count) * abs(accuracy - confidence)
        }
        return ece
    }

    private static func summarise(_ held: [Held], method: Method, folds: Int) -> ClassifierEvaluation {
        let temperature = fitTemperature(held)
        let activities = CalibrationActivity.allCases.filter { a in held.contains { $0.truth == a } }

        var confusion: [String: [String: Int]] = [:]
        var correct = 0
        var brier = 0.0
        for h in held {
            let p = probabilities(h.scores, temperature: temperature)
            let guess = h.scores.max { $0.value < $1.value }!.key
            confusion[h.truth.rawValue, default: [:]][guess.rawValue, default: 0] += 1
            if guess == h.truth { correct += 1 }
            for a in CalibrationActivity.allCases {
                let y = a == h.truth ? 1.0 : 0.0
                brier += ((p[a] ?? 0) - y) * ((p[a] ?? 0) - y)
            }
        }
        let n = Double(held.count)

        var recall: [String: Double] = [:]
        var f1s: [Double] = []
        var counts: [String: Int] = [:]
        for a in activities {
            let support = confusion[a.rawValue]?.values.reduce(0, +) ?? 0
            counts[a.rawValue] = support
            let tp = confusion[a.rawValue]?[a.rawValue] ?? 0
            let predicted = confusion.values.reduce(0) { $0 + ($1[a.rawValue] ?? 0) }
            let r = support > 0 ? Double(tp) / Double(support) : 0
            let precision = predicted > 0 ? Double(tp) / Double(predicted) : 0
            recall[a.rawValue] = r
            f1s.append(precision + r > 0 ? 2 * precision * r / (precision + r) : 0)
        }

        let ece = expectedCalibrationError(held, temperature: temperature)
        let eceRaw = expectedCalibrationError(held, temperature: 1)

        var warnings: [String] = []
        if held.count < 30 { warnings.append("Only \(held.count) held-out windows, so these numbers are rough.") }
        for (activity, count) in counts where count < 5 {
            warnings.append("Few \(activity) windows (\(count)); its accuracy is uncertain.")
        }
        if let most = counts.values.max(), let least = counts.values.min(), least > 0, most >= 3 * least {
            warnings.append("The activities are unbalanced (\(most) vs \(least) windows); read balanced accuracy.")
        }
        if method == .blockedKFold {
            warnings.append("Each activity was recorded once, so held-out windows come from the same stretch as training windows.")
        }
        let interval = RobustStats.wilsonInterval(successes: correct, total: held.count) ?? 0...1

        return ClassifierEvaluation(
            method: method, folds: folds, windows: held.count, classCounts: counts,
            accuracy: Double(correct) / n,
            accuracyInterval: [interval.lowerBound, interval.upperBound],
            balancedAccuracy: recall.values.reduce(0, +) / Double(max(1, recall.count)),
            macroF1: f1s.reduce(0, +) / Double(max(1, f1s.count)),
            recall: recall, confusion: confusion,
            temperature: temperature,
            logLossRaw: logLoss(held, temperature: 1),
            logLossCalibrated: logLoss(held, temperature: temperature),
            brierCalibrated: brier / n,
            expectedCalibrationErrorRaw: eceRaw,
            expectedCalibrationError: ece,
            isReliable: held.count >= 30 && activities.allSatisfy { (counts[$0.rawValue] ?? 0) >= 5 },
            warnings: warnings
        )
    }
}
