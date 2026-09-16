import Foundation

@MainActor
final class TrustedMemberViewModel: ObservableObject {
    @Published private(set) var latestEvent: ThermyxAlertEvent?
    @Published private(set) var isConnected = false
    @Published private(set) var lastError: String?
    private var timer: Timer?
    private let client = ThermyxAlertAPIClient()
    func start(settings: ThermyxSettingsStore, deviceID: String) {
        stop()
        poll(settings: settings, deviceID: deviceID)
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self, weak settings] _ in
            guard let self, let settings else { return }
            Task { @MainActor in self.poll(settings: settings, deviceID: deviceID) }
        }
    }
    func stop() { timer?.invalidate(); timer = nil }
    private func poll(settings: ThermyxSettingsStore, deviceID: String) {
        guard !settings.backendURL.isEmpty else { return }
        Task {
            do { latestEvent = try await client.fetchStatus(deviceID: deviceID, backendURL: settings.backendURL, token: settings.backendToken); isConnected = true; lastError = nil }
            catch { isConnected = false; lastError = error.localizedDescription }
        }
    }
    deinit { timer?.invalidate() }
}
