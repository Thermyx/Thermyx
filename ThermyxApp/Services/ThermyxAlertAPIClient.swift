import Foundation

/// Talks to the Thermyx relay (ThermyxBackend). Every call after pairing
/// carries this phone's own token; there is no shared secret.
struct ThermyxAlertAPIClient {
    enum ClientError: LocalizedError, Equatable {
        case invalidURL
        case notPaired
        case codeRejected
        case accessRemoved
        case tooManyAttempts
        case server(Int)
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "That relay address isn't a valid URL."
            case .notPaired: return "This phone isn't connected to a relay yet."
            case .codeRejected: return "That code didn't work. Codes work once and expire after 10 minutes — ask for a new one."
            case .accessRemoved: return "This phone's access to the relay was removed or has expired. Connect again with a new code."
            case .tooManyAttempts: return "Too many tries. Wait a minute and try again."
            case .server(let status): return "The relay returned an error (\(status))."
            case .invalidResponse: return "The relay sent a response the app didn't understand."
            }
        }
    }

    // MARK: Pairing

    struct PairResult: Decodable {
        let role: String
        let token: String
        let deviceID: String?
        let watcherID: String?
        let status: String?
        let smsEnabled: Bool?
    }

    func pair(baseURL: String, code: String, name: String?) async throws -> PairResult {
        var body: [String: String] = ["code": code]
        if let name, !name.isEmpty { body["name"] = name }
        return try await request("POST", "/v1/pair", baseURL: baseURL, token: nil, body: body)
    }

    // MARK: Wearer

    /// What the wearer's phone sends. Phone numbers are included only when
    /// the relay has texting on; location only with consent during an event.
    struct Event: Encodable {
        let level: String
        let kind: String
        let reasons: [String]
        let recipients: [String]?
        let location: ThermyxAlertEvent.AlertLocation?
        let locationConsent: Bool
    }

    struct EventResult: Decodable {
        let smsEnabled: Bool?
        let texted: Int?
        let reason: String?
    }

    func send(event: Event, baseURL: String, token: String) async throws -> EventResult {
        try await request("POST", "/v1/events", baseURL: baseURL, token: token, body: event)
    }

    struct WatcherInvite: Decodable {
        let code: String
        let expiresAt: String
    }

    func createWatcherCode(baseURL: String, token: String) async throws -> WatcherInvite {
        try await request("POST", "/v1/watchers/codes", baseURL: baseURL, token: token, body: Optional<String>.none)
    }

    struct Watcher: Decodable, Identifiable, Equatable {
        let id: String
        let name: String
        /// pending, approved, or expired
        let status: String
        let createdAt: String
        let approvedAt: String?
        let expiresAt: String?

        var expiryDate: Date? { expiresAt.flatMap(ThermyxAlertAPIClient.parseDate) }
    }

    func listWatchers(baseURL: String, token: String) async throws -> [Watcher] {
        struct Envelope: Decodable { let watchers: [Watcher] }
        let envelope: Envelope = try await request("GET", "/v1/watchers", baseURL: baseURL, token: token, body: Optional<String>.none)
        return envelope.watchers
    }

    func approveWatcher(id: String, baseURL: String, token: String) async throws {
        struct Ack: Decodable {}
        let _: Ack = try await request("POST", "/v1/watchers/\(id)/approve", baseURL: baseURL, token: token, body: Optional<String>.none)
    }

    func revokeWatcher(id: String, baseURL: String, token: String) async throws {
        struct Ack: Decodable {}
        let _: Ack = try await request("DELETE", "/v1/watchers/\(id)", baseURL: baseURL, token: token, body: Optional<String>.none)
    }

    /// Delete my data: ends this phone's and every watcher's access and
    /// removes the stored status and location on the relay.
    func deleteDevice(baseURL: String, token: String) async throws {
        struct Ack: Decodable {}
        let _: Ack = try await request("DELETE", "/v1/device", baseURL: baseURL, token: token, body: Optional<String>.none)
    }

    // MARK: Watcher

    /// Stop watching: ends this watcher's own access.
    func leaveWatching(baseURL: String, token: String) async throws {
        struct Ack: Decodable {}
        let _: Ack = try await request("DELETE", "/v1/watch", baseURL: baseURL, token: token, body: Optional<String>.none)
    }

    /// The minimal view a watcher gets: level, kind, freshness, and a
    /// location only during an active event the wearer chose to share.
    struct WatchState: Decodable {
        let level: String
        let kind: String
        let updatedAt: String
        let location: ThermyxAlertEvent.AlertLocation?
    }

    struct WatchResult: Decodable {
        let status: String
        let state: WatchState?
    }

    func watch(baseURL: String, token: String) async throws -> WatchResult {
        try await request("GET", "/v1/watch", baseURL: baseURL, token: token, body: Optional<String>.none)
    }

    // MARK: Plumbing

    static func parseDate(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string) ?? ISO8601DateFormatter().date(from: string)
    }

    private func request<Body: Encodable, Result: Decodable>(
        _ method: String,
        _ path: String,
        baseURL: String,
        token: String?,
        body: Body?
    ) async throws -> Result {
        guard let url = endpoint(baseURL, path: path) else { throw ClientError.invalidURL }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let body { request.httpBody = try JSONEncoder().encode(body) }

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw ClientError.invalidResponse }
        switch http.statusCode {
        case 200..<300:
            do { return try JSONDecoder().decode(Result.self, from: data) }
            catch { throw ClientError.invalidResponse }
        case 401: throw token == nil ? ClientError.codeRejected : ClientError.accessRemoved
        case 403: throw path == "/v1/pair" ? ClientError.codeRejected : ClientError.accessRemoved
        case 429: throw ClientError.tooManyAttempts
        default: throw ClientError.server(http.statusCode)
        }
    }

    private func endpoint(_ base: String, path: String) -> URL? {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, var components = URLComponents(string: trimmed),
              let scheme = components.scheme, ["http", "https"].contains(scheme.lowercased()),
              components.host?.isEmpty == false
        else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + [basePath, path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        return components.url
    }
}
