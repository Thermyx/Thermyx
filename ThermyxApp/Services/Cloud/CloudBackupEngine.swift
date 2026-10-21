import Combine
import CryptoKit
import Foundation

/// The pieces of a wearer's Thermyx that follow them to a new phone. Each is
/// one document at `users/{uid}/backup/{part}`, so a change to one never
/// rewrites the others, and deleting a backup is a fixed list of four.
///
/// Raw sensor history is deliberately not here: it stays on the phone.
/// Trusted contacts' names and numbers aren't either (they are other people's
/// details, and the relay needs pairing again on a new phone anyway).
enum CloudPart: String, CaseIterable {
    /// Profile, preferences and alert levels.
    case settings
    /// The personal baseline: usual foot temperature and steadiness.
    case baseline
    /// The calibration model.
    case model
    /// Recovery tests and logged recoveries.
    case recoveries

    func path(uid: String) -> String { "users/\(uid)/backup/\(rawValue)" }

    /// How often this part may be written. The baseline learns a new minute
    /// every minute of wear; writing that each time would be a lot of writes
    /// for no benefit, so it goes up every ten minutes and when the app
    /// leaves the screen. The rest are edits the wearer makes by hand.
    var minimumPushInterval: TimeInterval {
        switch self {
        case .baseline, .model: return 10 * 60
        case .settings, .recoveries: return 0
        }
    }
}

/// What the engine needs from the phone: the current state of each part,
/// a way to replace it, and a signal that something may have changed.
@MainActor
protocol CloudBackupSource: AnyObject {
    /// True while Demo Mode (or any made-up data) is showing. Nothing is
    /// read for, or written to, the cloud then.
    var isDemo: Bool { get }
    /// The part as JSON. Always returns something, even for an empty part.
    func payload(for part: CloudPart) -> String
    /// Whether the phone holds anything worth backing up for this part.
    /// A fresh phone has none, which is what makes a restore safe.
    func hasData(for part: CloudPart) -> Bool
    /// Whether this phone can take a restored copy of the part.
    func canApply(_ part: CloudPart) -> Bool
    /// Replaces the part with a copy from the cloud. False when the copy
    /// couldn't be used (corrupt, or from a newer version of the app).
    func apply(_ payload: String, to part: CloudPart) -> Bool
    /// Whether two payloads say the same thing, regardless of key order.
    func same(_ a: String, _ b: String, part: CloudPart) -> Bool
    /// Fires when something the source holds may have changed.
    var changes: AnyPublisher<Void, Never> { get }
}

/// Bookkeeping that lives on this phone only.
struct CloudSyncState: Codable, Equatable {
    struct Part: Codable, Equatable {
        /// When this phone last changed the part (or received it).
        var changedAt: Date?
        /// The `updatedAt` of the copy this phone last agreed with the cloud on.
        var syncedAt: Date?
    }

    /// Hash of the account that backup is turned on for. Another account
    /// signing in on this phone finds it off.
    var backupAccount: String?
    /// Whether this phone has finished its first reconcile with the account.
    /// Until then a difference between phone and cloud is asked about, never
    /// settled by timestamps, so a fresh install can't overwrite a backup.
    var linked = false
    var parts: [String: Part] = [:]
}

@MainActor
final class CloudSyncStore {
    private let defaults: UserDefaults
    private static let key = "thermyx.cloud.sync"
    private static let deviceKey = "thermyx.cloud.deviceID"
    private(set) var state: CloudSyncState

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        state = defaults.data(forKey: Self.key).flatMap { try? JSONDecoder().decode(CloudSyncState.self, from: $0) } ?? CloudSyncState()
    }

    func update(_ change: (inout CloudSyncState) -> Void) {
        change(&state)
        defaults.set(try? JSONEncoder().encode(state), forKey: Self.key)
    }

    /// A random ID for this install. A reinstall is a new device, so it isn't
    /// kept in the Keychain.
    var deviceID: String {
        if let id = defaults.string(forKey: Self.deviceKey) { return id }
        let id = UUID().uuidString
        defaults.set(id, forKey: Self.deviceKey)
        return id
    }

    /// A short hash of the Firebase user ID, so the raw ID isn't written to
    /// preferences and nothing logs it.
    static func accountKey(uid: String) -> String {
        SHA256.hash(data: Data(uid.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

/// Backs the phone up to the signed-in wearer's account and brings it back.
///
/// - **Offline first.** The phone is always the source of truth; Firestore's
///   own queue delivers writes when there's a connection.
/// - **Last writer wins, per document.** Each document carries `updatedAt`
///   and the writing phone's `deviceId`; the later edit wins, and a tie goes
///   to the larger device ID so every phone agrees.
/// - **First sync is asked about.** A phone that has never synced with the
///   account restores into empty parts without asking, backs up parts the
///   cloud lacks, and, when both sides have different data, waits for the
///   wearer to pick one.
/// - **Never in Demo Mode.** Every entry point checks the source first.
@MainActor
final class CloudBackupEngine: ObservableObject {
    enum Status: Equatable {
        case idle
        case syncing
        case upToDate(Date)
        /// Phone and account both have different data and the wearer must
        /// choose which to keep.
        case needsChoice([CloudPart])
        case paused(String)
        case failed(String)
    }

    @Published private(set) var status: Status = .idle

    private struct Remote {
        var payload: String
        var updatedAt: Date
        var deviceID: String
    }

    private let store: CloudDocumentStore
    private let source: CloudBackupSource
    private let sync: CloudSyncStore
    private let now: () -> Date
    private let debounce: TimeInterval

    private var uid: String?
    private var lastSeen: [CloudPart: String] = [:]
    private var lastPush: [CloudPart: Date] = [:]
    private var held: [CloudPart: Remote] = [:]
    private var scheduled: Task<Void, Never>?
    private var observer: AnyCancellable?
    private var pushing = false
    private var rerun = false

    /// Writes per part are coalesced for this long.
    static let defaultDebounce: TimeInterval = 5

    init(store: CloudDocumentStore, source: CloudBackupSource, sync: CloudSyncStore,
         now: @escaping () -> Date = { .now }, debounce: TimeInterval = CloudBackupEngine.defaultDebounce) {
        self.store = store
        self.source = source
        self.sync = sync
        self.now = now
        self.debounce = debounce
    }

    var isRunning: Bool { uid != nil }

    /// Whether the phone has edits the cloud doesn't have yet.
    var hasUnsyncedChanges: Bool {
        guard uid != nil, sync.state.linked, !source.isDemo else { return false }
        return CloudPart.allCases.contains { isDirty($0) || differsFromSeen($0) }
    }

    // MARK: Lifecycle

    /// Starts syncing for the signed-in wearer and reconciles once.
    func start(uid: String) async {
        self.uid = uid
        observer = source.changes.sink { [weak self] in self?.localDidChange() }
        await reconcile()
    }

    func stop() {
        scheduled?.cancel()
        scheduled = nil
        observer = nil
        uid = nil
        held = [:]
        status = .idle
    }

    /// Something on the phone may have changed. Looks again after a short
    /// wait, so a burst of edits becomes one write.
    func localDidChange() {
        guard uid != nil, sync.state.linked else { return }
        schedule(after: debounce)
    }

    private func schedule(after delay: TimeInterval) {
        guard scheduled == nil else { return }
        scheduled = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled, let self else { return }
            self.scheduled = nil
            await self.flush()
        }
    }

    // MARK: Reconcile

    /// Compares the phone with the cloud, part by part. Called at sign-in,
    /// when backup is turned on, and when the app comes back to the front.
    func reconcile() async {
        guard let uid else { return }
        guard !source.isDemo else { status = .paused("Paused in Demo Mode"); return }
        status = .syncing
        // Changes made while the network call is in flight are noticed by
        // comparing against this.
        for part in CloudPart.allCases { lastSeen[part] = source.payload(for: part) }

        var remotes: [CloudPart: Remote] = [:]
        do {
            for part in CloudPart.allCases {
                if let document = try await store.get(part.path(uid: uid)), let remote = Self.remote(document) {
                    remotes[part] = remote
                }
            }
        } catch {
            status = .failed("Couldn't reach your account.")
            return
        }
        // The user may have gone into Demo Mode, or signed out, meanwhile.
        guard self.uid == uid, !source.isDemo else { return }

        let firstSync = !sync.state.linked
        var conflicts: [CloudPart] = []
        held = [:]

        for part in CloudPart.allCases {
            let local = source.payload(for: part)
            let hasLocal = source.hasData(for: part)
            guard let remote = remotes[part] else {
                // Nothing in the cloud yet: back up what the phone has.
                if hasLocal {
                    await pushNow(part, stamp: sync.state.parts[part.rawValue]?.changedAt ?? now(), payload: local)
                }
                continue
            }
            if source.same(local, remote.payload, part: part) {
                markSynced(part, at: remote.updatedAt)
            } else if firstSync {
                if hasLocal {
                    // Don't guess which side is the keeper.
                    conflicts.append(part)
                    held[part] = remote
                } else {
                    // A fresh phone: this is the restore.
                    pull(part, remote)
                }
            } else if remoteWins(part, remote) {
                pull(part, remote)
            } else {
                await pushNow(part, stamp: sync.state.parts[part.rawValue]?.changedAt ?? now(), payload: local)
            }
        }

        if !conflicts.isEmpty {
            status = .needsChoice(conflicts)
            return
        }
        sync.update { $0.linked = true }
        if case .failed = status { return }
        status = .upToDate(now())
        localDidChange()
    }

    /// Settles the first-sync disagreement the wearer was asked about.
    func resolve(useAccountCopy: Bool) async {
        guard uid != nil, case .needsChoice(let parts) = status else { return }
        for part in parts {
            guard let remote = held[part] else { continue }
            if useAccountCopy {
                pull(part, remote)
            } else {
                // Later than the copy it replaces, so every phone agrees.
                let stamp = max(now(), remote.updatedAt.addingTimeInterval(0.001))
                await pushNow(part, stamp: stamp, payload: source.payload(for: part))
            }
        }
        held = [:]
        sync.update { $0.linked = true }
        if case .failed = status { return }
        status = .upToDate(now())
    }

    private func remoteWins(_ part: CloudPart, _ remote: Remote) -> Bool {
        let changed = sync.state.parts[part.rawValue]?.changedAt ?? .distantPast
        let remoteAt = Self.ms(remote.updatedAt), localAt = Self.ms(changed)
        if remoteAt != localAt { return remoteAt > localAt }
        return remote.deviceID > sync.deviceID
    }

    private func pull(_ part: CloudPart, _ remote: Remote) {
        guard source.canApply(part), source.apply(remote.payload, to: part) else { return }
        lastSeen[part] = source.payload(for: part)
        sync.update { $0.parts[part.rawValue] = .init(changedAt: Self.ms(remote.updatedAt), syncedAt: Self.ms(remote.updatedAt)) }
    }

    private func markSynced(_ part: CloudPart, at date: Date) {
        sync.update { $0.parts[part.rawValue] = .init(changedAt: Self.ms(date), syncedAt: Self.ms(date)) }
    }

    // MARK: Writing

    /// Notices what changed on the phone and writes it. `force` skips the
    /// per-part wait (when the app is leaving the screen).
    func flush(force: Bool = false) async {
        guard uid != nil, sync.state.linked, !source.isDemo else { return }
        detectChanges()
        await pushDirty(force: force)
    }

    private func detectChanges() {
        let stamp = Self.ms(now())
        for part in CloudPart.allCases where differsFromSeen(part) {
            lastSeen[part] = source.payload(for: part)
            sync.update { $0.parts[part.rawValue, default: .init()].changedAt = stamp }
        }
    }

    private func differsFromSeen(_ part: CloudPart) -> Bool {
        guard let seen = lastSeen[part] else { return true }
        return !source.same(seen, source.payload(for: part), part: part)
    }

    private func isDirty(_ part: CloudPart) -> Bool {
        guard let entry = sync.state.parts[part.rawValue], let changed = entry.changedAt else { return false }
        guard let synced = entry.syncedAt else { return true }
        return changed > synced
    }

    private func pushDirty(force: Bool) async {
        if pushing { rerun = true; return }
        pushing = true
        defer { pushing = false }
        repeat {
            rerun = false
            var wait: TimeInterval?
            for part in CloudPart.allCases where isDirty(part) {
                let since = lastPush[part].map { now().timeIntervalSince($0) } ?? .infinity
                if !force, since < part.minimumPushInterval {
                    wait = min(wait ?? .infinity, part.minimumPushInterval - since)
                    continue
                }
                guard !source.isDemo, uid != nil else { return }
                guard let stamp = sync.state.parts[part.rawValue]?.changedAt else { continue }
                await pushNow(part, stamp: stamp, payload: source.payload(for: part))
                if case .failed = status { schedule(after: 60); return }
            }
            if let wait { schedule(after: wait) }
        } while rerun
        if case .syncing = status, !CloudPart.allCases.contains(where: isDirty) { status = .upToDate(now()) }
    }

    private func pushNow(_ part: CloudPart, stamp: Date, payload: String) async {
        guard let uid, !source.isDemo else { return }
        let stamp = Self.ms(stamp)
        status = .syncing
        do {
            try await store.set(part.path(uid: uid), data: [
                "schema": 1,
                "payload": payload,
                "updatedAt": stamp,
                "deviceId": sync.deviceID,
            ])
            lastPush[part] = now()
            sync.update {
                var entry = $0.parts[part.rawValue] ?? .init()
                entry.syncedAt = stamp
                if entry.changedAt == nil || entry.changedAt! < stamp { entry.changedAt = stamp }
                $0.parts[part.rawValue] = entry
            }
            status = .upToDate(now())
        } catch {
            status = .failed("Couldn't back up just now. It will retry.")
        }
    }

    // MARK: Deleting

    /// Removes the account's copy: the four documents, nothing else exists.
    /// Waits for the server, so the caller knows it's really gone; throws
    /// `CloudError.timedOut` when the server can't be reached.
    func deleteCloudCopy(uid: String, timeout: TimeInterval = 12) async throws {
        let store = self.store
        try await cloudWithTimeout(timeout) {
            for part in CloudPart.allCases { try await store.delete(part.path(uid: uid)) }
        }
        sync.update { $0.parts = [:]; $0.linked = false }
        held = [:]
    }

    // MARK: Parsing

    private static func remote(_ document: CloudDocument) -> Remote? {
        guard let payload = document.data["payload"] as? String,
              let updatedAt = document.data["updatedAt"] as? Date else { return nil }
        return Remote(payload: payload, updatedAt: updatedAt, deviceID: document.data["deviceId"] as? String ?? "")
    }

    /// Whole milliseconds, which is what survives a round trip.
    static func ms(_ date: Date) -> Date {
        Date(timeIntervalSince1970: (date.timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
