import XCTest
@testable import ThermyxApp

/// The population pipeline: what a wearer sends, how it is rounded and kept
/// anonymous, and how the totals become `PopulationPriors`.
@MainActor
final class CloudPriorsTests: XCTestCase {

    // MARK: Building a contribution

    private let day = Date(timeIntervalSince1970: 1_800_000_000)

    private func calibrated(gait: Double? = 0.93) -> PersonalBaseline {
        var baseline = PersonalBaseline()
        baseline.minutesLearned = 30
        baseline.footMeanC = 33
        baseline.gaitMean = gait
        return baseline
    }

    /// `count` calm minutes of one activity, both insoles, at the given values.
    private func minutes(_ activity: CalibrationActivity, count: Int, foot: Double, gait: Double = 0.9,
                         left: Double = 0.55, right: Double = 0.47, startAt offset: Int = 0) -> [ThermyxHistorySample] {
        (0..<count).flatMap { i -> [ThermyxHistorySample] in
            let start = day.addingTimeInterval(Double((offset + i) * 60))
            return [Foot.left, Foot.right].map { side in
                var s = ThermyxHistorySample(foot: side, start: start)
                s.sampleCount = 55
                s.footMeanC = foot
                s.gaitMean = side == .left ? gait + 0.02 : gait - 0.02
                s.balanceMean = side == .left ? left : right
                s.peakRisk = ThermyxRiskLevel.normal.rawValue
                switch activity {
                case .sitting: s.sittingSeconds = 55
                case .standing: s.standingSeconds = 55
                case .walking: s.walkingSeconds = 55
                }
                return s
            }
        }
    }

    private func inputs(_ samples: [ThermyxHistorySample], baseline: PersonalBaseline? = nil,
                        usage: [String] = ["Outdoor work"], age: Int? = 41) -> PopulationInputs {
        PopulationInputs(minutes: samples, baseline: baseline ?? calibrated(), usage: usage, age: age)
    }

    func testValuesAreRoundedBeforeTheyLeaveThePhone() throws {
        let samples = minutes(.sitting, count: 25, foot: 33.14)
            + minutes(.walking, count: 25, foot: 34.76, gait: 0.8137, left: 0.5513, right: 0.4707, startAt: 100)
            + minutes(.standing, count: 25, foot: 33.99, left: 0.5513, right: 0.4707, startAt: 200)
        let c = try XCTUnwrap(PopulationContribution.make(from: inputs(samples)))
        XCTAssertEqual(c.values[.footSitting], 33.1)
        XCTAssertEqual(c.values[.footWalking], 34.8)
        XCTAssertEqual(c.values[.footStanding], 34.0)
        XCTAssertEqual(try XCTUnwrap(c.values[.steadiness]), 0.82, accuracy: 1e-9)
        // Left minus right: 0.5513 - 0.4707 = 0.0806 -> 0.08
        XCTAssertEqual(try XCTUnwrap(c.values[.standingLean]), 0.08, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(c.values[.walkingLean]), 0.08, accuracy: 1e-9)
        // Left gait is +0.02, right -0.02.
        XCTAssertEqual(try XCTUnwrap(c.values[.steadinessGap]), 0.04, accuracy: 1e-9)
        for (metric, value) in c.values {
            let steps = value / metric.step
            XCTAssertEqual(steps, steps.rounded(), accuracy: 1e-6, "\(metric) is not on its rounding grid")
        }
    }

    func testOnlyCalmMinutesCount() throws {
        var hot = minutes(.sitting, count: 30, foot: 37.5, startAt: 0)
        for i in hot.indices { hot[i].peakRisk = ThermyxRiskLevel.high.rawValue }
        var heating = minutes(.sitting, count: 30, foot: 36.5, startAt: 100)
        for i in heating.indices { heating[i].heatingSeconds = 20 }
        let calm = minutes(.sitting, count: 25, foot: 32.0, startAt: 200)
        let c = try XCTUnwrap(PopulationContribution.make(from: inputs(hot + heating + calm)))
        XCTAssertEqual(c.values[.footSitting], 32.0, "a hot afternoon or a heated minute must not shift the average")
    }

    func testTooFewMinutesLeavesAMetricOutAndNothingAtAllSendsNothing() throws {
        let some = minutes(.sitting, count: 25, foot: 33) + minutes(.walking, count: 5, foot: 34, startAt: 100)
        let c = try XCTUnwrap(PopulationContribution.make(from: inputs(some)))
        XCTAssertNotNil(c.values[.footSitting])
        XCTAssertNil(c.values[.footWalking], "5 minutes is too thin to send")
        XCTAssertNil(PopulationContribution.make(from: inputs(minutes(.sitting, count: 5, foot: 33), baseline: calibrated(gait: nil))))
    }

    func testAnUncalibratedBaselineContributesNothing() {
        XCTAssertNil(PopulationContribution.make(from: inputs(minutes(.sitting, count: 40, foot: 33), baseline: PersonalBaseline())))
    }

    func testCohortIsCoarse() {
        XCTAssertEqual(PopulationCohort.make(usage: ["Cold weather", "Outdoor work"], age: 41).key, "outdoor-work|30-59")
        XCTAssertEqual(PopulationCohort.make(usage: [], age: nil).key, "general|unknown")
        XCTAssertEqual(PopulationCohort.make(usage: ["Sports and training"], age: 19).band, "under-30")
        XCTAssertEqual(PopulationCohort.make(usage: ["Everyday comfort"], age: 71).band, "60-plus")
    }

    // MARK: Anonymity of what is written

    func testDocumentsCarryNoIdentityAndNoTimestamp() throws {
        let c = PopulationContribution(cohort: .init(usage: "outdoor-work", band: "30-59"),
                                       values: [.footSitting: 33.1, .steadiness: 0.82, .walkingLean: -0.04])
        let writes = c.documents(now: day)
        XCTAssertEqual(writes.count, 3)
        let allowed: Set<String> = ["v", "metric", "cohort", "usage", "band", "value", "sq", "expireAt"]
        for write in writes {
            XCTAssertEqual(Set(write.data.keys), allowed, "exactly the shape the security rules accept")
            XCTAssertTrue(write.path.hasPrefix("priorSamples/"))
            let id = String(write.path.dropFirst("priorSamples/".count))
            XCTAssertEqual(id.count, 32)
            XCTAssertNil(id.range(of: "u1"))
            let value = try XCTUnwrap(write.data["value"] as? Double)
            XCTAssertEqual(write.data["sq"] as? Double ?? 0, value * value, accuracy: 1e-9)
            XCTAssertGreaterThan(write.data["expireAt"] as! Date, day)
        }
        XCTAssertEqual(Set(writes.map(\.path)).count, 3, "a fresh random ID for every number, so siblings can't be linked")
        XCTAssertTrue(Set(writes.map(\.path)).isDisjoint(with: Set(c.documents(now: day).map(\.path))),
                      "IDs are new each time, never derived from the wearer")
    }

    func testPeriodIsTheCalendarMonthAndDocumentsExpireAfterIt() {
        let oct = Date(timeIntervalSince1970: 1_792_000_000) // 2026-10-14
        XCTAssertEqual(PopulationContribution.period(for: oct), "2026-10")
        let expiry = PopulationContribution.expiry(for: oct)
        XCTAssertEqual(PopulationContribution.period(for: expiry), "2026-11")
        XCTAssertLessThan(expiry.timeIntervalSince(oct), 40 * 24 * 3600, "inside the rules' 40-day cap")
    }

    // MARK: Reading the totals

    /// Plants `count` contributions of one metric in a cohort.
    private func plant(_ store: FakeCloudStore, metric: PopulationMetric, cohort: PopulationCohort, values: [Double]) {
        for value in values {
            let doc = PopulationContribution(cohort: cohort, values: [metric: value]).documents(now: day)[0]
            store.docs[doc.path] = doc.data
        }
    }

    private let outdoor = PopulationCohort(usage: "outdoor-work", band: "30-59")

    func testStatsFromCountMeanAndSumOfSquares() throws {
        let values = (0..<30).map { 31.0 + Double($0 % 6) * 0.5 }
        let mean = values.reduce(0, +) / 30
        let sd = (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 29).squareRoot()
        let stats = try XCTUnwrap(PopulationPriorsReader.stats(count: 30, mean: mean, sumSquares: values.map { $0 * $0 }.reduce(0, +),
                                                               metric: .footSitting))
        XCTAssertEqual(stats.mean, mean, accuracy: 1e-9)
        XCTAssertEqual(stats.sd, sd, accuracy: 1e-6)
        XCTAssertEqual(stats.count, 30)
    }

    func testImpossibleTotalsAreRefused() {
        XCTAssertNil(PopulationPriorsReader.stats(count: 30, mean: 55, sumSquares: 30 * 55 * 55, metric: .footSitting), "mean out of range")
        XCTAssertNil(PopulationPriorsReader.stats(count: 1, mean: 33, sumSquares: 33 * 33, metric: .footSitting))
        XCTAssertEqual(PopulationPriorsReader.stats(count: 30, mean: 33, sumSquares: 30 * 33 * 33 - 5, metric: .footSitting)?.sd, 0,
                       "rounding noise can't make a negative variance")
    }

    func testTheReaderComputesMeanAndSdFromAggregatesAndTheCohortIsTheSpecificOne() async throws {
        let store = FakeCloudStore()
        let values = (0..<40).map { 32.0 + Double($0 % 8) * 0.2 }
        plant(store, metric: .footSitting, cohort: outdoor, values: values)
        let priors = try await PopulationPriorsReader(store: store).fetch(cohort: outdoor, now: day)
        let result = try XCTUnwrap(priors)
        XCTAssertEqual(result.cohort, "outdoor-work|30-59")
        let sitting = try XCTUnwrap(result.footByActivity[.sitting])
        let mean = values.reduce(0, +) / 40
        XCTAssertEqual(sitting.mean, mean, accuracy: 1e-6)
        XCTAssertEqual(sitting.sd, (values.map { ($0 - mean) * ($0 - mean) }.reduce(0, +) / 39).squareRoot(), accuracy: 1e-6)
        XCTAssertEqual(sitting.count, 40)
        XCTAssertNil(result.footByActivity[.walking])
        XCTAssertNil(result.steadiness)
        XCTAssertNotNil(PopulationPriors.usable(sitting))
    }

    func testBelowTheMinimumNothingIsReturned() async throws {
        let store = FakeCloudStore()
        plant(store, metric: .footSitting, cohort: outdoor,
              values: (0..<(PopulationPriors.minimumContributors - 1)).map { 32 + Double($0) * 0.1 })
        let priors = try await PopulationPriorsReader(store: store).fetch(cohort: outdoor, now: day)
        XCTAssertNil(priors, "19 contributors is not enough to be a prior")

        plant(store, metric: .footSitting, cohort: outdoor, values: [33])
        let enough = try await PopulationPriorsReader(store: store).fetch(cohort: outdoor, now: day)
        XCTAssertEqual(enough?.footByActivity[.sitting]?.count, PopulationPriors.minimumContributors)
    }

    func testFallsBackFromCohortToUsageToEveryone() async throws {
        let min = PopulationPriors.minimumContributors
        let spread = { (n: Int) in (0..<n).map { 32 + Double($0 % 5) * 0.3 } }

        // Specific cohort thin, same usage in other age bands plentiful.
        var store = FakeCloudStore()
        plant(store, metric: .footSitting, cohort: outdoor, values: spread(5))
        plant(store, metric: .footSitting, cohort: .init(usage: "outdoor-work", band: "60-plus"), values: spread(min + 5))
        var priors = try await PopulationPriorsReader(store: store).fetch(cohort: outdoor, now: day)
        XCTAssertEqual(priors?.cohort, "outdoor-work")
        XCTAssertEqual(priors?.footByActivity[.sitting]?.count, min + 10)

        // Usage thin too, everyone plentiful.
        store = FakeCloudStore()
        plant(store, metric: .footSitting, cohort: outdoor, values: spread(3))
        plant(store, metric: .footSitting, cohort: .init(usage: "sports", band: "under-30"), values: spread(min + 2))
        priors = try await PopulationPriorsReader(store: store).fetch(cohort: outdoor, now: day)
        XCTAssertEqual(priors?.cohort, "all")
        XCTAssertEqual(priors?.footByActivity[.sitting]?.count, min + 5)
    }

    func testEachNumberFallsBackOnItsOwn() async throws {
        let store = FakeCloudStore()
        let min = PopulationPriors.minimumContributors
        plant(store, metric: .footSitting, cohort: outdoor, values: (0..<min).map { 32 + Double($0 % 4) * 0.2 })
        plant(store, metric: .steadiness, cohort: .init(usage: "sports", band: "under-30"), values: (0..<min).map { 0.85 + Double($0 % 4) * 0.02 })
        let fetched = try await PopulationPriorsReader(store: store).fetch(cohort: outdoor, now: day)
        let priors = try XCTUnwrap(fetched)
        XCTAssertEqual(priors.cohort, "outdoor-work|30-59", "names the most specific cohort that supplied anything")
        XCTAssertEqual(priors.footByActivity[.sitting]?.count, min)
        XCTAssertEqual(priors.steadiness?.count, min, "steadiness came from everyone")
    }

    // MARK: The service

    private func makeService(_ store: FakeCloudStore, source: FakeSource, clock: TestClock) -> (ThermyxCloudService, UserDefaults) {
        let name = "CloudPriorsTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let service = ThermyxCloudService(defaults: defaults, now: { clock.date }, makeStore: { store })
        service.attach(source: source)
        service.accountChanged(ThermyxAccount(uid: "u1", email: nil, displayName: nil))
        return (service, defaults)
    }

    func testPriorsAreRefreshedAtMostWeeklyAndCachedBetween() async {
        let store = FakeCloudStore()
        plant(store, metric: .footSitting, cohort: outdoor, values: (0..<30).map { 32 + Double($0 % 5) * 0.2 })
        let source = FakeSource()
        let clock = TestClock(day)
        let (service, _) = makeService(store, source: source, clock: clock)

        await service.setPopulationEnabled(true)
        XCTAssertEqual(service.priors?.footByActivity[.sitting]?.count, 30)
        let firstCalls = store.aggregateCalls
        XCTAssertGreaterThan(firstCalls, 0)

        clock.advance(6 * 24 * 3600)
        await service.refreshPopulation()
        XCTAssertEqual(store.aggregateCalls, firstCalls, "no query inside the week")
        XCTAssertNotNil(service.priors)

        clock.advance(2 * 24 * 3600)
        await service.refreshPopulation()
        XCTAssertGreaterThan(store.aggregateCalls, firstCalls, "refreshed after a week")
    }

    func testAFailedRefreshWaitsADayAndKeepsTheCache() async {
        let store = FakeCloudStore()
        plant(store, metric: .footSitting, cohort: outdoor, values: (0..<30).map { 32 + Double($0 % 5) * 0.2 })
        let clock = TestClock(day)
        let (service, _) = makeService(store, source: FakeSource(), clock: clock)
        await service.setPopulationEnabled(true)
        XCTAssertNotNil(service.priors)

        clock.advance(8 * 24 * 3600)
        store.failAll = true
        await service.refreshPopulation()
        XCTAssertNotNil(service.priors, "the cached copy stays")
        let calls = store.aggregateCalls
        clock.advance(3600)
        await service.refreshPopulation()
        XCTAssertEqual(store.aggregateCalls, calls, "not retried within a day")
    }

    func testTurningTheOptInOffDropsThePriors() async {
        let store = FakeCloudStore()
        plant(store, metric: .footSitting, cohort: outdoor, values: (0..<30).map { 32 + Double($0 % 5) * 0.2 })
        let (service, defaults) = makeService(store, source: FakeSource(), clock: TestClock(day))
        await service.setPopulationEnabled(true)
        XCTAssertNotNil(service.priors)
        await service.setPopulationEnabled(false)
        XCTAssertNil(service.priors)
        XCTAssertNil(defaults.data(forKey: "thermyx.cloud.priors"))
    }

    func testContributesOncePerMonthAndOnlyWhenOptedIn() async {
        let store = FakeCloudStore()
        let source = FakeSource()
        source.inputs = inputs(minutes(.sitting, count: 30, foot: 33.2), baseline: calibrated(gait: nil))
        let clock = TestClock(day)
        let (service, _) = makeService(store, source: source, clock: clock)

        await service.contributeIfDue()
        XCTAssertFalse(store.calls.contains("setAll"), "nothing is sent before the wearer opts in")

        await service.setPopulationEnabled(true)
        XCTAssertEqual(store.calls.filter { $0 == "setAll" }.count, 1)
        let sent = store.docs.filter { $0.key.hasPrefix("priorSamples/") }
        XCTAssertEqual(sent.count, 1)
        XCTAssertEqual(sent.first?.value["value"] as? Double, 33.2)
        for (path, data) in store.docs {
            XCTAssertFalse(path.contains("u1"), "no user ID in a path")
            XCTAssertFalse(data.values.contains { ($0 as? String)?.contains("u1") == true }, "no user ID in a value")
        }

        clock.advance(24 * 3600)
        await service.contributeIfDue()
        XCTAssertEqual(store.calls.filter { $0 == "setAll" }.count, 1, "once a month")

        clock.advance(40 * 24 * 3600)
        await service.contributeIfDue()
        XCTAssertEqual(store.calls.filter { $0 == "setAll" }.count, 2, "again next month")
    }

    func testDemoModeNeverContributes() async {
        let store = FakeCloudStore()
        let source = FakeSource()
        source.inputs = inputs(minutes(.sitting, count: 30, foot: 33.2), baseline: calibrated(gait: nil))
        source.isDemo = true
        let (service, _) = makeService(store, source: source, clock: TestClock(day))
        await service.setPopulationEnabled(true)
        await service.contributeIfDue()
        XCTAssertFalse(store.calls.contains("setAll"))
    }

    func testARejectedContributionIsRetriedTomorrowNotHammered() async {
        let store = FakeCloudStore()
        let source = FakeSource()
        source.inputs = inputs(minutes(.sitting, count: 30, foot: 33.2), baseline: calibrated(gait: nil))
        let clock = TestClock(day)
        let (service, _) = makeService(store, source: source, clock: clock)
        store.failAll = true
        await service.setPopulationEnabled(true)
        let attempts = store.calls.filter { $0 == "setAll" }.count
        XCTAssertEqual(attempts, 1)
        await service.contributeIfDue()
        XCTAssertEqual(store.calls.filter { $0 == "setAll" }.count, 1, "not again the same day")
        store.failAll = false
        clock.advance(25 * 3600)
        await service.contributeIfDue()
        XCTAssertEqual(store.calls.filter { $0 == "setAll" }.count, 2)
    }
}
