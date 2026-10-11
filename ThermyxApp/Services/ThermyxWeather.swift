import CoreLocation
import Foundation

/// The air outside, from the phone's location and Open-Meteo's free
/// forecast service (no key). The insole has no air sensor, so this gives
/// the outdoor half of calibration its context.
///
/// Only a rounded location (about 1 km) is sent, and only when asked.
@MainActor
final class ThermyxWeather: NSObject, ObservableObject, CLLocationManagerDelegate {
    struct Current: Equatable {
        let airC: Double
        let feelsLikeC: Double?
        let humidity: Double?
        let at: Date
    }

    static let shared = ThermyxWeather()

    /// Whether Thermyx may use the phone's location.
    @Published private(set) var authorization: CLAuthorizationStatus = .notDetermined
    var isAuthorized: Bool { authorization == .authorizedWhenInUse || authorization == .authorizedAlways }

    private let manager = CLLocationManager()
    private var located: CheckedContinuation<CLLocation?, Never>?
    private var authorized: CheckedContinuation<Void, Never>?

    override private init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyKilometer
        authorization = manager.authorizationStatus
    }

    /// Shows iOS's location prompt, if it hasn't been answered yet.
    func requestPermission() {
        if manager.authorizationStatus == .notDetermined { manager.requestWhenInUseAuthorization() }
    }

    /// Current conditions here, or nil without location or network.
    func current() async -> Current? {
        guard let location = await locate() else { return nil }
        let lat = (location.coordinate.latitude * 100).rounded() / 100
        let lon = (location.coordinate.longitude * 100).rounded() / 100
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")!
        components.queryItems = [
            .init(name: "latitude", value: String(lat)),
            .init(name: "longitude", value: String(lon)),
            .init(name: "current", value: "temperature_2m,apparent_temperature,relative_humidity_2m"),
        ]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let decoded = try? JSONDecoder().decode(Response.self, from: data)
        else { return nil }
        return Current(airC: decoded.current.temperature_2m, feelsLikeC: decoded.current.apparent_temperature,
                       humidity: decoded.current.relative_humidity_2m, at: .now)
    }

    private struct Response: Decodable {
        struct Now: Decodable {
            let temperature_2m: Double
            let apparent_temperature: Double?
            let relative_humidity_2m: Double?
        }
        let current: Now
    }

    // MARK: Location

    private func locate() async -> CLLocation? {
        if manager.authorizationStatus == .notDetermined {
            await withCheckedContinuation { continuation in
                authorized = continuation
                manager.requestWhenInUseAuthorization()
            }
        }
        guard [.authorizedWhenInUse, .authorizedAlways].contains(manager.authorizationStatus) else { return nil }
        return await withCheckedContinuation { continuation in
            located?.resume(returning: nil)
            located = continuation
            manager.requestLocation()
        }
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        MainActor.assumeIsolated {
            authorization = manager.authorizationStatus
            guard manager.authorizationStatus != .notDetermined else { return }
            authorized?.resume()
            authorized = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        MainActor.assumeIsolated {
            located?.resume(returning: locations.last)
            located = nil
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        MainActor.assumeIsolated {
            located?.resume(returning: nil)
            located = nil
        }
    }
}
