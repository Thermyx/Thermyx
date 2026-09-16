import Foundation

struct ThermyxAlertAPIClient {
    enum ClientError: LocalizedError {
        case invalidURL
        case noBackendConfigured
        case invalidResponse

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "The alert backend URL is invalid."
            case .noBackendConfigured: return "Configure an alert backend before enabling family notifications."
            case .invalidResponse: return "The alert backend returned an invalid response."
            }
        }
    }

    func send(event: ThermyxAlertEvent, backendURL: String, token: String) async throws {
        guard let url = endpoint(backendURL, suffix: "/v1/alerts") else { throw ClientError.noBackendConfigured }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONEncoder().encode(event)
        let (_, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClientError.invalidResponse }
    }

    func fetchStatus(deviceID: String, backendURL: String, token: String) async throws -> ThermyxAlertEvent? {
        guard let url = endpoint(backendURL, suffix: "/v1/status/" + deviceID) else { throw ClientError.invalidURL }
        var request = URLRequest(url: url)
        if !token.isEmpty { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode) else { throw ClientError.invalidResponse }
        struct Envelope: Decodable { let event: ThermyxAlertEvent? }
        return try JSONDecoder().decode(Envelope.self, from: data).event
    }

    private func endpoint(_ base: String, suffix: String) -> URL? {
        guard !base.isEmpty, var components = URLComponents(string: base) else { return nil }
        let basePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.path = "/" + ([basePath, suffix].filter { !$0.isEmpty }.joined(separator: "/")).replacingOccurrences(of: "//", with: "/")
        return components.url
    }
}
