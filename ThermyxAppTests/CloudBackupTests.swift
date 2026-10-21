import Combine
import XCTest
@testable import ThermyxApp

// MARK: - Fakes

/// An in-memory Firestore: documents in a dictionary, aggregations computed
/// the way the server would. No network.
final class FakeCloudStore: CloudDocumentStore, @unchecked Sendable {
    // Called from concurrent tasks (the service probes and syncs in
    // parallel), so every touch of the state goes through one lock.
    private let lock = NSLock()
    private var _docs: [String: [String: Any]] = [:]
    private var _calls: [String] = []

    var docs: [String: [String: Any]] {
        get { lock.lock(); defer { lock.unlock() }; return _docs }
        set { lock.lock(); _docs = newValue; lock.unlock() }
    }
    /// Every call made, so a test can prove nothing was touched.
    var calls: [String] { lock.lock(); defer { lock.unlock() }; return _calls }

    private func mutate(_ body: (inout [String: [String: Any]]) -> Void) {
        lock.lock(); body(&_docs); lock.unlock()
    }
    var aggregateCalls: Int { calls.filter { $0 == "aggregate" }.count }
    var failAll = false
    /// Makes every call wait forever, as an offline Firestore does for writes.
    var hangs = false

    private func enter(_ name: String) async throws {
        lock.lock(); _calls.append(name); lock.unlock()
        if hangs { try await Task.sleep(nanoseconds: 60_000_000_000) }
        if failAll { throw CloudError.timedOut }
    }

    func get(_ path: String) async throws -> CloudDocument? {
        try await enter("get")
        return docs[path].map(CloudDocument.init)
    }

    func set(_ path: String, data: [String: Any]) async throws {
        try await enter("set")
        mutate { $0[path] = data }
    }

    func delete(_ path: String) async throws {
        try await enter("delete")
        mutate { $0[path] = nil }
    }

    func setAll(_ documents: [CloudWrite]) async throws {
        try await enter("setAll")
        mutate { docs in for document in documents { docs[document.path] = document.data } }
    }

    func aggregate(_ request: CloudAggregateRequest) async throws -> CloudAggregate {
        try await enter("aggregate")
        let matching = docs.filter { path, data in
            guard path.hasPrefix(request.collection + "/") else { return false }
            return request.equals.allSatisfy { data[$0.key] as? String == $0.value }
        }.map(\.value)
        func numbers(_ field: String?) -> [Double] {
            guard let field else { return [] }
            return matching.compactMap { ($0[field] as? Double) ?? ($0[field] as? Int).map(Double.init) }
        }
        let averageValues = numbers(request.averageOf)
        let sumValues = numbers(request.sumOf)
        return CloudAggregate(
            count: matching.count,
            average: averageValues.isEmpty ? nil : averageValues.reduce(0, +) / Double(averageValues.count),
            sum: request.sumOf == nil || sumValues.isEmpty ? nil : sumValues.reduce(0, +)
        )
    }

    func path(_ part: CloudPart, uid: String = "u1") -> String { part.path(uid: uid) }

    /// Plants a backup document, as another phone would have written it.
    func plant(_ part: CloudPart, payload: String, at date: Date, device: String = "other-phone", uid: String = "u1") {
        mutate { $0[part.path(uid: uid)] = ["schema": 1, "payload": payload, "updatedAt": date, "deviceId": device] }
    }
}

@MainActor
final class FakeSource: CloudBackupSource, PopulationSource {
    var isDemo = false
    var parts: [CloudPart: String] = [:]
    var has: [CloudPart: Bool] = [:]
    var restorable: Set<CloudPart> = Set(CloudPart.allCases)
    let subject = PassthroughSubject<Void, Never>()
    var populationCohort = PopulationCohort(usage: "outdoor-work", band: "30-59")
    var inputs: PopulationInputs?

    var changes: AnyPublisher<Void, Never> { subject.eraseToAnyPublisher() }
    var populationInputs: PopulationInputs? { isDemo ? nil : inputs }

    func payload(for part: CloudPart) -> String { parts[part] ?? "{}" }
    func hasData(for part: CloudPart) -> Bool { has[part] ?? false }
    func canApply(_ part: CloudPart) -> Bool { restorable.contains(part) }
    func same(_ a: String, _ b: String, part: CloudPart) -> Bool { a == b }

    func apply(_ payload: String, to part: CloudPart) -> Bool {
        parts[part] = payload
        has[part] = true
        return true
    }

    /// The wearer changes something on the phone.
    func edit(_ part: CloudPart, _ payload: String) {
        parts[part] = payload
        has[part] = true
        subject.send()
    }
}

/// A clock a test moves by hand.
final class TestClock {
    var date: Date
    init(_ date: Date = Date(timeIntervalSince1970: 1_800_000_000)) { self.date = date }
    func advance(_ seconds: TimeInterval) { date = date.addingTimeInterval(seconds) }
}

// MARK: - Backup engine

@MainActor
final class CloudBackupTests: XCTestCase {
    private var defaults: UserDefaults!
    private var store: FakeCloudStore!
    private var source: FakeSource!
    private var clock: TestClock!
    private var sync: CloudSyncStore!

    override func setUp() {
        super.setUp()
        let name = "CloudBackupTests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: name)
        defaults.removePersistentDomain(forName: name)
        store = FakeCloudStore()
        source = FakeSource()
        clock = TestClock()
        sync = CloudSyncStore(defaults: defaults)
    }

    private func makeEngine() -> CloudBackupEngine {
        // A long debounce: tests drive `flush()` by hand.
        CloudBackupEngine(store: store, source: source, sync: sync, now: { [clock] in clock!.date }, debounce: 3600)
    }

    // MARK: First sync

    func testNewPhoneRestoresWhatTheAccountHolds() async {
        store.plant(.settings, payload: "{\"name\":\"Ada\"}", at: clock.date)
        store.plant(.recoveries, payload: "[1,2]", at: clock.date)
        let engine = makeEngine()
        await engine.start(uid: "u1")
        XCTAssertEqual(source.parts[.settings], "{\"name\":\"Ada\"}")
        XCTAssertEqual(source.parts[.recoveries], "[1,2]")
        XCTAssertEqual(engine.status, .upToDate(clock.date))
        XCTAssertTrue(sync.state.linked)
        XCTAssertFalse(store.calls.contains("set"), "restoring must not write")
    }

    func testFirstBackupWritesOnlyPartsThatHaveData() async throws {
        source.edit(.settings, "{\"unit\":\"c\"}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        let doc = try XCTUnwrap(store.docs[CloudPart.settings.path(uid: "u1")])
        XCTAssertEqual(doc["payload"] as? String, "{\"unit\":\"c\"}")
        XCTAssertEqual(doc["schema"] as? Int, 1)
        XCTAssertEqual(doc["deviceId"] as? String, sync.deviceID)
        XCTAssertNotNil(doc["updatedAt"] as? Date)
        XCTAssertEqual(Set(doc.keys), ["schema", "payload", "updatedAt", "deviceId"])
        XCTAssertEqual(store.docs.count, 1, "empty parts are not written")
    }

    func testDifferentDataOnBothSidesAsksAndChangesNothing() async {
        source.edit(.settings, "{\"on\":\"phone\"}")
        store.plant(.settings, payload: "{\"on\":\"cloud\"}", at: clock.date)
        let engine = makeEngine()
        await engine.start(uid: "u1")
        XCTAssertEqual(engine.status, .needsChoice([.settings]))
        XCTAssertEqual(source.parts[.settings], "{\"on\":\"phone\"}")
        XCTAssertEqual(store.docs[CloudPart.settings.path(uid: "u1")]?["payload"] as? String, "{\"on\":\"cloud\"}")
        XCTAssertFalse(sync.state.linked, "syncing stays paused until the wearer chooses")

        // Edits while the question is open are not pushed.
        source.edit(.settings, "{\"on\":\"phone2\"}")
        await engine.flush()
        XCTAssertEqual(store.docs[CloudPart.settings.path(uid: "u1")]?["payload"] as? String, "{\"on\":\"cloud\"}")
    }

    func testChoosingTheAccountCopyReplacesThePhone() async {
        source.edit(.settings, "{\"on\":\"phone\"}")
        store.plant(.settings, payload: "{\"on\":\"cloud\"}", at: clock.date)
        let engine = makeEngine()
        await engine.start(uid: "u1")
        await engine.resolve(useAccountCopy: true)
        XCTAssertEqual(source.parts[.settings], "{\"on\":\"cloud\"}")
        XCTAssertTrue(sync.state.linked)
        XCTAssertEqual(engine.status, .upToDate(clock.date))
    }

    func testChoosingThePhoneReplacesTheCloudAndWinsOverAFutureStamp() async {
        source.edit(.settings, "{\"on\":\"phone\"}")
        store.plant(.settings, payload: "{\"on\":\"cloud\"}", at: clock.date.addingTimeInterval(120))
        let engine = makeEngine()
        await engine.start(uid: "u1")
        await engine.resolve(useAccountCopy: false)
        let doc = store.docs[CloudPart.settings.path(uid: "u1")]
        XCTAssertEqual(doc?["payload"] as? String, "{\"on\":\"phone\"}")
        XCTAssertGreaterThan(doc?["updatedAt"] as! Date, clock.date.addingTimeInterval(120))
    }

    func testIdenticalDataOnBothSidesJustLinks() async {
        source.edit(.settings, "{\"a\":1}")
        store.plant(.settings, payload: "{\"a\":1}", at: clock.date)
        let engine = makeEngine()
        await engine.start(uid: "u1")
        XCTAssertEqual(engine.status, .upToDate(clock.date))
        XCTAssertFalse(store.calls.contains("set"))
    }

    // MARK: Last writer wins

    func testALaterEditOnThisPhoneIsPushed() async {
        source.edit(.settings, "{\"v\":1}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        clock.advance(60)
        source.edit(.settings, "{\"v\":2}")
        await engine.flush()
        let doc = store.docs[CloudPart.settings.path(uid: "u1")]
        XCTAssertEqual(doc?["payload"] as? String, "{\"v\":2}")
        XCTAssertEqual(doc?["updatedAt"] as? Date, CloudBackupEngine.ms(clock.date))
    }

    func testALaterEditFromAnotherPhoneWinsOnReconcile() async {
        source.edit(.settings, "{\"v\":1}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        clock.advance(600)
        store.plant(.settings, payload: "{\"v\":\"theirs\"}", at: clock.date)
        await engine.reconcile()
        XCTAssertEqual(source.parts[.settings], "{\"v\":\"theirs\"}")
    }

    func testAnOlderCloudCopyDoesNotOverwriteANewerEditOnThisPhone() async {
        source.edit(.settings, "{\"v\":1}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        let old = clock.date.addingTimeInterval(-3600)
        clock.advance(600)
        source.edit(.settings, "{\"v\":\"mine\"}")
        // The edit is noticed, but another phone's older write lands first.
        store.plant(.settings, payload: "{\"v\":\"old\"}", at: old)
        await engine.flush()
        XCTAssertEqual(source.parts[.settings], "{\"v\":\"mine\"}")
        XCTAssertEqual(store.docs[CloudPart.settings.path(uid: "u1")]?["payload"] as? String, "{\"v\":\"mine\"}")
    }

    func testATieGoesToTheLargerDeviceID() async {
        source.edit(.settings, "{\"v\":\"mine\"}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        let stamp = clock.date.addingTimeInterval(5)
        clock.advance(10)
        sync.update { $0.parts[CloudPart.settings.rawValue] = .init(changedAt: CloudBackupEngine.ms(stamp), syncedAt: CloudBackupEngine.ms(stamp)) }

        store.plant(.settings, payload: "{\"v\":\"high\"}", at: stamp, device: "\u{10FFFF}")
        await engine.reconcile()
        XCTAssertEqual(source.parts[.settings], "{\"v\":\"high\"}", "a larger device ID wins a tie")

        sync.update { $0.parts[CloudPart.settings.rawValue] = .init(changedAt: CloudBackupEngine.ms(stamp), syncedAt: CloudBackupEngine.ms(stamp)) }
        source.parts[.settings] = "{\"v\":\"mine\"}"
        store.plant(.settings, payload: "{\"v\":\"low\"}", at: stamp, device: "")
        await engine.reconcile()
        XCTAssertEqual(source.parts[.settings], "{\"v\":\"mine\"}", "a smaller device ID loses a tie")
        XCTAssertEqual(store.docs[CloudPart.settings.path(uid: "u1")]?["payload"] as? String, "{\"v\":\"mine\"}")
    }

    func testABurstOfEditsIsOneWrite() async {
        let engine = makeEngine()
        await engine.start(uid: "u1")
        for n in 1...5 { source.edit(.settings, "{\"n\":\(n)}") }
        await engine.flush()
        XCTAssertEqual(store.calls.filter { $0 == "set" }.count, 1)
        XCTAssertEqual(store.docs[CloudPart.settings.path(uid: "u1")]?["payload"] as? String, "{\"n\":5}")
    }

    func testTheBaselineIsWrittenAtMostEveryTenMinutesUnlessForced() async {
        source.edit(.baseline, "{\"m\":1}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        XCTAssertEqual(store.calls.filter { $0 == "set" }.count, 1)

        clock.advance(60)
        source.edit(.baseline, "{\"m\":2}")
        await engine.flush()
        XCTAssertEqual(store.docs[CloudPart.baseline.path(uid: "u1")]?["payload"] as? String, "{\"m\":1}", "too soon")

        clock.advance(11 * 60)
        await engine.flush()
        XCTAssertEqual(store.docs[CloudPart.baseline.path(uid: "u1")]?["payload"] as? String, "{\"m\":2}")

        clock.advance(30)
        source.edit(.baseline, "{\"m\":3}")
        await engine.flush(force: true)
        XCTAssertEqual(store.docs[CloudPart.baseline.path(uid: "u1")]?["payload"] as? String, "{\"m\":3}", "leaving the app forces it")
    }

    func testAPartThePhoneCannotRestoreIsLeftAlone() async {
        source.restorable.remove(.baseline)
        store.plant(.baseline, payload: "{\"m\":9}", at: clock.date)
        let engine = makeEngine()
        await engine.start(uid: "u1")
        XCTAssertNil(source.parts[.baseline])
    }

    // MARK: Demo Mode

    func testDemoModeNeverTouchesTheCloud() async {
        source.isDemo = true
        source.edit(.settings, "{\"demo\":true}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        XCTAssertTrue(store.calls.isEmpty, "no reads or writes in Demo Mode, got \(store.calls)")
        XCTAssertEqual(engine.status, .paused("Paused in Demo Mode"))
        await engine.flush(force: true)
        XCTAssertTrue(store.calls.isEmpty)
    }

    func testEditsMadeInDemoModeAreNotPushedAndLeavingDemoIsQuiet() async {
        source.edit(.settings, "{\"real\":1}")
        let engine = makeEngine()
        await engine.start(uid: "u1")
        let writes = store.calls.filter { $0 == "set" }.count

        source.isDemo = true
        source.edit(.settings, "{\"made\":\"up\"}")
        await engine.flush(force: true)
        XCTAssertEqual(store.calls.filter { $0 == "set" }.count, writes)
        XCTAssertFalse(engine.hasUnsyncedChanges)

        // Back to the real data: nothing differs, so nothing is written.
        source.isDemo = false
        source.edit(.settings, "{\"real\":1}")
        await engine.flush(force: true)
        XCTAssertEqual(store.calls.filter { $0 == "set" }.count, writes)
    }

    // MARK: Failures and deleting

    func testBeingOfflineAtStartIsReportedNotFatal() async {
        store.failAll = true
        let engine = makeEngine()
        await engine.start(uid: "u1")
        guard case .failed = engine.status else { return XCTFail("expected failed, got \(engine.status)") }
        XCTAssertFalse(sync.state.linked)
    }

    func testDeletingTheCloudCopyRemovesEveryPart() async throws {
        for part in CloudPart.allCases { store.plant(part, payload: "{}", at: clock.date) }
        let engine = makeEngine()
        try await engine.deleteCloudCopy(uid: "u1")
        XCTAssertTrue(store.docs.isEmpty)
    }

    func testDeletingTimesOutRatherThanClaimingSuccessWhenOffline() async {
        store.plant(.settings, payload: "{}", at: clock.date)
        store.hangs = true
        let engine = makeEngine()
        do {
            try await engine.deleteCloudCopy(uid: "u1", timeout: 0.2)
            XCTFail("should have timed out")
        } catch {
            guard case CloudError.timedOut = error else { return XCTFail("wrong error \(error)") }
        }
    }

    func testAccountKeyIsAShortHashNotTheUID() {
        let key = CloudSyncStore.accountKey(uid: "abc123")
        XCTAssertEqual(key.count, 20)
        XCTAssertFalse(key.contains("abc123"))
        XCTAssertNotEqual(key, CloudSyncStore.accountKey(uid: "abc124"))
    }

    // MARK: Service

    private func makeService(signedIn: Bool = true) -> ThermyxCloudService {
        let service = ThermyxCloudService(defaults: defaults, now: { [clock] in clock!.date }, makeStore: { [store] in store })
        service.attach(source: source)
        if signedIn { service.accountChanged(ThermyxAccount(uid: "u1", email: "a@example.com", displayName: "A")) }
        return service
    }

    func testEverythingIsOffByDefault() async {
        source.edit(.settings, "{\"a\":1}")
        let service = makeService()
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(service.backupEnabled)
        XCTAssertFalse(service.populationEnabled)
        XCTAssertNil(service.priors)
        XCTAssertFalse(store.calls.contains("set"), "nothing is written until the wearer opts in")
        XCTAssertFalse(store.calls.contains("setAll"))
    }

    func testANewPhoneIsOfferedARestoreWithoutTouchingAnything() async {
        store.plant(.settings, payload: "{\"a\":1}", at: clock.date)
        let service = makeService()
        for _ in 0..<50 where service.restoreOffer == nil { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertNotNil(service.restoreOffer)
        XCTAssertNil(source.parts[.settings], "offered, not applied")
        await service.enableBackup()
        XCTAssertEqual(source.parts[.settings], "{\"a\":1}")
        XCTAssertTrue(service.backupEnabled)
        XCTAssertNil(service.restoreOffer)
    }

    func testBackupSwitchBelongsToOneAccount() async {
        let service = makeService()
        await service.enableBackup()
        XCTAssertTrue(service.backupEnabled)
        service.accountChanged(ThermyxAccount(uid: "someone-else", email: nil, displayName: nil))
        XCTAssertFalse(service.backupEnabled, "another account must not inherit the switch")
        service.accountChanged(ThermyxAccount(uid: "u1", email: nil, displayName: nil))
        XCTAssertTrue(service.backupEnabled, "the same account gets it back")
    }

    func testDeleteMyDataClearsTheCloudCopyAndBothSwitches() async {
        source.edit(.settings, "{\"a\":1}")
        let service = makeService()
        await service.enableBackup()
        await service.setPopulationEnabled(true)
        XCTAssertNotNil(store.docs[CloudPart.settings.path(uid: "u1")])

        let message = await service.deleteEverything()
        XCTAssertNil(message)
        XCTAssertTrue(store.docs.keys.filter { $0.hasPrefix("users/") }.isEmpty)
        XCTAssertFalse(service.backupEnabled)
        XCTAssertFalse(service.populationEnabled)
        XCTAssertNil(service.priors)
        XCTAssertFalse(sync.state.linked)
        XCTAssertFalse(defaults.bool(forKey: "thermyx.cloud.population"))
    }

    func testDeleteMyDataSaysSoWhenTheCloudCannotBeReached() async {
        source.edit(.settings, "{\"a\":1}")
        let service = makeService()
        await service.enableBackup()
        store.failAll = true
        let message = await service.deleteEverything()
        XCTAssertNotNil(message)
        XCTAssertFalse(service.backupEnabled, "local switches still go off")
    }

    func testAccountDeletionStopsIfTheBackupCannotBeConfirmedGone() async {
        source.edit(.settings, "{\"a\":1}")
        let service = makeService()
        await service.enableBackup()
        store.failAll = true
        do {
            try await service.deleteForAccountDeletion()
            XCTFail("must throw so the account is kept")
        } catch {}
    }

    func testSigningOutStopsSyncing() async {
        let service = makeService()
        await service.enableBackup()
        let writes = store.calls.filter { $0 == "set" }.count
        service.accountChanged(nil)
        source.edit(.settings, "{\"later\":1}")
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(store.calls.filter { $0 == "set" }.count, writes)
        XCTAssertFalse(service.backupEnabled)
    }
}
