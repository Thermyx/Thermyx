import Combine
import Foundation
import UIKit

/// Everything Thermyx does with the cloud, behind two switches that are both
/// off until the wearer turns them on:
///
/// - **Back up to my account**: profile, preferences, baseline, calibration
///   model and recoveries follow the wearer's Google account to a new phone.
/// - **Population starting points**: the wearer sends a few rounded,
///   anonymous numbers once a month and, in return, gets `priors`, what's
///   typical for wearers like them, for the ML layer to start from.
///
/// Neither runs in Demo Mode, in the preview harness, or without a signed-in
/// account. Raw readings never leave the phone.
@MainActor
final class ThermyxCloudService: ObservableObject {
    static let shared = ThermyxCloudService()

    /// What's typical for wearers like this one, from the last successful
    /// weekly refresh (or the cached copy while offline). Nil when the wearer
    /// hasn't opted in, signed out, or no cohort has enough contributors yet.
    /// Pass it to the ML layer: it already respects `PopulationPriors.usable`.
    @Published private(set) var priors: PopulationPriors?

    @Published private(set) var backupEnabled = false
    @Published private(set) var populationEnabled: Bool
    @Published private(set) var status: CloudBackupEngine.Status = .idle
    /// Set when this phone isn't backing up but the signed-in account has a
    /// backup (a new phone): when it was last written. Offer to restore.
    @Published private(set) var restoreOffer: Date?
    @Published private(set) var isSignedIn = false
    @Published private(set) var isBusy = false
    @Published var lastError: String?

    private let makeStore: @MainActor () -> CloudDocumentStore?
    private let defaults: UserDefaults
    private let sync: CloudSyncStore
    private let now: () -> Date

    private var store: CloudDocumentStore?
    private var engine: CloudBackupEngine?
    private var engineStatus: AnyCancellable?
    private var source: (CloudBackupSource & PopulationSource)?
    private var uid: String?
    private var lastForeground: Date = .distantPast
    private var observers: [NSObjectProtocol] = []

    private static let populationKey = "thermyx.cloud.population"
    private static let periodKey = "thermyx.cloud.population.lastPeriod"
    private static let attemptKey = "thermyx.cloud.population.lastAttempt"
    private static let priorsKey = "thermyx.cloud.priors"
    private static let priorsAttemptKey = "thermyx.cloud.priors.lastAttempt"

    /// Priors are refreshed at most this often.
    static let priorsRefreshInterval: TimeInterval = 7 * 24 * 3600
    /// A failed attempt (offline, rules not deployed) isn't repeated sooner.
    static let retryInterval: TimeInterval = 24 * 3600

    private struct PriorsCache: Codable {
        var cohort: String
        var fetchedAt: Date
        var priors: PopulationPriors?
    }

    init(defaults: UserDefaults = .standard,
         now: @escaping () -> Date = { .now },
         makeStore: @escaping @MainActor () -> CloudDocumentStore? = ThermyxCloudService.defaultStore) {
        self.defaults = defaults
        self.now = now
        self.makeStore = makeStore
        self.sync = CloudSyncStore(defaults: defaults)
        populationEnabled = defaults.bool(forKey: Self.populationKey)
        if populationEnabled, let cache = cachedPriors, cache.priors?.version == PopulationPriors.currentVersion {
            priors = cache.priors
        }
        observers = [
            NotificationCenter.default.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.appDidBecomeActive() }
            },
            NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.appDidEnterBackground() }
            },
        ]
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    /// The real Firestore, only when Firebase is configured and the preview
    /// harness isn't standing in for an account.
    @MainActor
    static func defaultStore() -> CloudDocumentStore? {
        #if DEBUG
        if ThermyxPreviewHarness.isActive { return nil }
        #endif
        return ThermyxAccountStore.isFirebaseConfigured ? FirestoreCloudStore() : nil
    }

    // MARK: Wiring

    /// Gives the service the phone's stores. Call once at launch.
    func attach(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore, roles: ThermyxRoleStore?) {
        attach(source: CloudLiveSource(viewModel: viewModel, settings: settings, roles: roles))
    }

    func attach(source: CloudBackupSource & PopulationSource) {
        self.source = source
        if uid != nil { startForAccount() }
    }

    /// Called whenever the signed-in account changes.
    func accountChanged(_ account: ThermyxAccount?) {
        guard account?.uid != uid else { return }
        stopEngine()
        uid = account?.uid
        restoreOffer = nil
        backupEnabled = false
        isSignedIn = uid != nil
        guard uid != nil else {
            // Priors need an account to be read; they come back on sign-in.
            priors = nil
            return
        }
        startForAccount()
    }

    private var accountKey: String? { uid.map(CloudSyncStore.accountKey(uid:)) }

    private func resolvedStore() -> CloudDocumentStore? {
        if store == nil { store = makeStore() }
        return store
    }

    private func startForAccount() {
        guard uid != nil, source != nil, resolvedStore() != nil else { return }
        if sync.state.backupAccount == accountKey {
            backupEnabled = true
            startEngine()
            if let engine, let uid { Task { await engine.start(uid: uid) } }
        } else {
            Task { await probeForBackup() }
        }
        if populationEnabled {
            if let cache = cachedPriors, cache.priors?.version == PopulationPriors.currentVersion { priors = cache.priors }
            Task { await refreshPopulation() }
        }
    }

    // MARK: Backup

    /// Turns backup on for the signed-in account and reconciles. A fresh
    /// phone restores; a phone that already has different data asks.
    func enableBackup() async {
        guard let key = accountKey, source != nil, resolvedStore() != nil else {
            lastError = CloudError.notSignedIn.localizedDescription
            return
        }
        lastError = nil
        sync.update { $0 = CloudSyncState(backupAccount: key) }
        backupEnabled = true
        restoreOffer = nil
        startEngine()
        if let engine, let uid { await engine.start(uid: uid) }
    }

    /// Turns backup off. With `deleteCopy`, the account's copy is removed
    /// first and nothing changes if that can't be done.
    func disableBackup(deleteCopy: Bool) async {
        lastError = nil
        let wasRunning = engine?.isRunning == true
        engine?.stop()
        if deleteCopy {
            isBusy = true
            defer { isBusy = false }
            do {
                try await deleteBackupDocuments()
            } catch {
                lastError = "Your backup wasn't deleted, so backup is still on. \(error.localizedDescription)"
                if wasRunning, let engine, let uid { await engine.start(uid: uid) }
                return
            }
        }
        stopEngine()
        sync.update { $0 = CloudSyncState() }
        backupEnabled = false
        status = .idle
        if !deleteCopy { Task { await probeForBackup() } }
    }

    /// Settles the first-sync question the wearer was asked.
    func resolveBackupChoice(useAccountCopy: Bool) async {
        await engine?.resolve(useAccountCopy: useAccountCopy)
    }

    private func startEngine() {
        guard let store = resolvedStore(), let source, engine == nil, uid != nil else { return }
        let engine = CloudBackupEngine(store: store, source: source, sync: sync, now: now)
        engineStatus = engine.$status.sink { [weak self] in self?.status = $0 }
        self.engine = engine
    }

    private func stopEngine() {
        engine?.stop()
        engine = nil
        engineStatus = nil
        status = .idle
    }

    private func probeForBackup() async {
        guard let uid, !backupEnabled, let store = resolvedStore(), source?.isDemo != true else { return }
        let found = try? await store.get(CloudPart.settings.path(uid: uid))
        guard self.uid == uid, !backupEnabled else { return }
        restoreOffer = found.flatMap { $0.data["updatedAt"] as? Date }
    }

    func dismissRestoreOffer() { restoreOffer = nil }

    private func deleteBackupDocuments() async throws {
        guard let uid, let store = resolvedStore() else { return }
        try await cloudWithTimeout(12) {
            for part in CloudPart.allCases { try await store.delete(part.path(uid: uid)) }
        }
    }

    /// Whether the phone has edits not yet in the cloud.
    var hasUnsyncedChanges: Bool { engine?.hasUnsyncedChanges == true }

    /// Writes what's pending, for up to `timeout` seconds. Before sign-out,
    /// which would stop Firestore's queue from being accepted.
    func flushBeforeSignOut(timeout: TimeInterval = 3) async {
        guard let engine else { return }
        _ = try? await cloudWithTimeout(timeout) { await engine.flush(force: true) }
    }

    // MARK: Deleting

    /// Delete my data: removes the account's backup, turns both switches off
    /// and forgets the cached priors. Returns a message when the cloud copy
    /// couldn't be confirmed deleted.
    func deleteEverything() async -> String? {
        stopEngine()
        var message: String?
        if uid != nil, resolvedStore() != nil {
            do {
                try await deleteBackupDocuments()
            } catch {
                message = "This phone's data was deleted, but your account's backup couldn't be reached. Connect and delete it from Device → Back up to my account."
            }
        }
        resetLocalState()
        return message
    }

    /// Before the Firebase user is deleted, which would lock the backup
    /// away for good. Throws when the backup can't be confirmed gone, so the
    /// account stays and the wearer can try again.
    func deleteForAccountDeletion() async throws {
        stopEngine()
        if uid != nil, resolvedStore() != nil { try await deleteBackupDocuments() }
        resetLocalState()
    }

    private func resetLocalState() {
        sync.update { $0 = CloudSyncState() }
        backupEnabled = false
        restoreOffer = nil
        populationEnabled = false
        priors = nil
        for key in [Self.populationKey, Self.periodKey, Self.attemptKey, Self.priorsKey, Self.priorsAttemptKey] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: Population

    func setPopulationEnabled(_ on: Bool) async {
        populationEnabled = on
        defaults.set(on, forKey: Self.populationKey)
        if on {
            await refreshPopulation(force: true)
            await contributeIfDue()
        } else {
            priors = nil
            defaults.removeObject(forKey: Self.priorsKey)
            defaults.removeObject(forKey: Self.priorsAttemptKey)
        }
    }

    private var cachedPriors: PriorsCache? {
        defaults.data(forKey: Self.priorsKey).flatMap { try? JSONDecoder().decode(PriorsCache.self, from: $0) }
    }

    /// Reads the aggregates for the wearer's cohort: at most weekly, and a
    /// failed attempt waits a day. The cached copy serves in between.
    func refreshPopulation(force: Bool = false) async {
        guard populationEnabled, uid != nil, let store = resolvedStore(), let source else { return }
        let cohort = source.populationCohort
        let current = now()
        if !force {
            if let cache = cachedPriors, cache.cohort == cohort.key,
               current.timeIntervalSince(cache.fetchedAt) < Self.priorsRefreshInterval { return }
            if let last = defaults.object(forKey: Self.priorsAttemptKey) as? Date,
               current.timeIntervalSince(last) < Self.retryInterval { return }
        }
        defaults.set(current, forKey: Self.priorsAttemptKey)
        do {
            let fresh = try await PopulationPriorsReader(store: store).fetch(cohort: cohort, now: current)
            guard populationEnabled else { return }
            priors = fresh
            let cache = PriorsCache(cohort: cohort.key, fetchedAt: current, priors: fresh)
            defaults.set(try? JSONEncoder().encode(cache), forKey: Self.priorsKey)
            defaults.removeObject(forKey: Self.priorsAttemptKey)
        } catch {
            // Keep whatever is cached; try again tomorrow.
        }
    }

    /// Sends this month's anonymous numbers, once. See `PopulationContribution`.
    func contributeIfDue() async {
        guard populationEnabled, uid != nil, let store = resolvedStore(), let source,
              let inputs = source.populationInputs else { return }
        let current = now()
        let period = PopulationContribution.period(for: current)
        guard defaults.string(forKey: Self.periodKey) != period else { return }
        if let last = defaults.object(forKey: Self.attemptKey) as? Date,
           current.timeIntervalSince(last) < Self.retryInterval { return }
        guard let contribution = PopulationContribution.make(from: inputs) else { return }
        // Marked first: Firestore queues the write offline and delivers it
        // later, so a second attempt would send a duplicate.
        defaults.set(period, forKey: Self.periodKey)
        defaults.set(current, forKey: Self.attemptKey)
        do {
            try await store.setAll(contribution.documents(now: current))
        } catch {
            // Rejected by the server (rules, quota). Try again tomorrow.
            defaults.removeObject(forKey: Self.periodKey)
        }
    }

    // MARK: App lifecycle

    func appDidBecomeActive() {
        let current = now()
        guard uid != nil, current.timeIntervalSince(lastForeground) > 5 * 60 else { return }
        lastForeground = current
        Task {
            if let engine, !(status.isAwaitingChoice) { await engine.reconcile() }
            await refreshPopulation()
            await contributeIfDue()
        }
    }

    func appDidEnterBackground() {
        guard let engine else { return }
        var task = UIBackgroundTaskIdentifier.invalid
        task = UIApplication.shared.beginBackgroundTask { UIApplication.shared.endBackgroundTask(task) }
        Task {
            await engine.flush(force: true)
            UIApplication.shared.endBackgroundTask(task)
        }
    }

    // MARK: Describing

    /// One line for the settings row.
    var statusLine: String {
        guard isSignedIn else { return "Sign in to back up" }
        guard backupEnabled else { return "Off. Your data stays on this phone." }
        switch status {
        case .idle: return "On"
        case .syncing: return "Backing up…"
        case .upToDate(let date): return "Backed up \(date.formatted(.relative(presentation: .named)))"
        case .needsChoice: return "Choose which copy to keep"
        case .paused(let why): return why
        case .failed(let why): return why
        }
    }
}

extension CloudBackupEngine.Status {
    var isAwaitingChoice: Bool {
        if case .needsChoice = self { return true }
        return false
    }
}
