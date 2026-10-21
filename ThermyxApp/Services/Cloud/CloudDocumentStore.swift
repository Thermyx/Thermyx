import FirebaseFirestore
import Foundation

/// The slice of Firestore that Thermyx's cloud features use, behind a
/// protocol so the sync and priors logic can be tested against an in-memory
/// fake with no network.
///
/// Values are plain `String`, `Double`, `Int`, `Bool` and `Date`. The real
/// store turns a `Date` into a Firestore timestamp and back.
protocol CloudDocumentStore {
    /// One document, or nil when it doesn't exist.
    func get(_ path: String) async throws -> CloudDocument?
    /// Creates or replaces a document.
    func set(_ path: String, data: [String: Any]) async throws
    /// Deletes a document. Deleting one that isn't there is not an error.
    func delete(_ path: String) async throws
    /// Writes several documents together: all of them or none.
    func setAll(_ documents: [CloudWrite]) async throws
    /// A server-side aggregation over the documents in `collection` whose
    /// string fields equal `equals`. Nothing is downloaded but the totals.
    func aggregate(_ request: CloudAggregateRequest) async throws -> CloudAggregate
}

struct CloudDocument {
    var data: [String: Any]
}

struct CloudWrite {
    var path: String
    var data: [String: Any]
}

struct CloudAggregateRequest: Equatable {
    var collection: String
    var equals: [String: String]
    /// Also ask for the mean of this numeric field.
    var averageOf: String? = nil
    /// Also ask for the sum of this numeric field.
    var sumOf: String? = nil
}

struct CloudAggregate: Equatable {
    /// How many documents matched.
    var count: Int
    var average: Double?
    var sum: Double?
}

enum CloudError: LocalizedError {
    case timedOut
    case notSignedIn
    case notConfigured

    var errorDescription: String? {
        switch self {
        case .timedOut: return "Couldn't reach your account. Check your connection and try again."
        case .notSignedIn: return "Sign in first."
        case .notConfigured: return "Cloud features aren't set up in this build yet."
        }
    }
}

/// Runs `operation`, giving up after `seconds`. Used where the caller must
/// know the outcome (deletes): Firestore itself queues a write while offline
/// and only reports back once the server has it, which can be never.
func cloudWithTimeout<T>(_ seconds: TimeInterval, _ operation: @escaping () async throws -> T) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
        group.addTask { try await operation() }
        group.addTask {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            throw CloudError.timedOut
        }
        defer { group.cancelAll() }
        guard let first = try await group.next() else { throw CloudError.timedOut }
        return first
    }
}

// MARK: - Firestore

/// The real thing. Only create or use it once Firebase is configured
/// (`ThermyxAccountStore.isFirebaseConfigured`); Firestore traps otherwise.
///
/// Offline persistence is on, with a small cache: the backup is a few tens
/// of kilobytes, and the wearer's phone is the source of truth anyway.
struct FirestoreCloudStore: CloudDocumentStore {
    private static let db: Firestore = {
        let db = Firestore.firestore()
        let settings = FirestoreSettings()
        settings.cacheSettings = PersistentCacheSettings(sizeBytes: NSNumber(value: 10 * 1024 * 1024))
        db.settings = settings
        return db
    }()

    func get(_ path: String) async throws -> CloudDocument? {
        let snapshot = try await Self.db.document(path).getDocument()
        guard snapshot.exists, let data = snapshot.data() else { return nil }
        return CloudDocument(data: data.mapValues { value in
            (value as? Timestamp)?.dateValue() ?? value
        })
    }

    func set(_ path: String, data: [String: Any]) async throws {
        try await Self.db.document(path).setData(data)
    }

    func delete(_ path: String) async throws {
        try await Self.db.document(path).delete()
    }

    func setAll(_ documents: [CloudWrite]) async throws {
        let batch = Self.db.batch()
        for document in documents {
            batch.setData(document.data, forDocument: Self.db.document(document.path))
        }
        try await batch.commit()
    }

    func aggregate(_ request: CloudAggregateRequest) async throws -> CloudAggregate {
        var query: Query = Self.db.collection(request.collection)
        for (field, value) in request.equals.sorted(by: { $0.key < $1.key }) {
            query = query.whereField(field, isEqualTo: value)
        }
        // The count and mean come together; the sum is its own query because
        // each aggregated field needs its own index.
        var fields: [AggregateField] = [AggregateField.count()]
        if let average = request.averageOf { fields.append(AggregateField.average(average)) }
        if request.averageOf == nil, let sum = request.sumOf { fields.append(AggregateField.sum(sum)) }
        let first = try await query.aggregate(fields).getAggregation(source: .server)
        var result = CloudAggregate(count: first.count.intValue)
        if let average = request.averageOf {
            result.average = Self.number(try first.get(AggregateField.average(average)))
        }
        if request.averageOf == nil, let sum = request.sumOf {
            result.sum = Self.number(try first.get(AggregateField.sum(sum)))
        } else if let sum = request.sumOf, result.count > 0 {
            let second = try await query.aggregate([AggregateField.sum(sum)]).getAggregation(source: .server)
            result.sum = Self.number(try second.get(AggregateField.sum(sum)))
        }
        return result
    }

    /// Firestore hands back NSNumber, or NSNull when nothing matched.
    private static func number(_ value: Any) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
