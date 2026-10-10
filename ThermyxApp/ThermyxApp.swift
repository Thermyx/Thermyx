import SwiftUI
import UserNotifications

@main
struct ThermyxApp: App {
    @StateObject private var viewModel = ThermyxViewModel()
    @StateObject private var roles = ThermyxRoleStore()
    @StateObject private var settings = ThermyxSettingsStore()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Without a delegate, iOS drops notifications while the app is open,
        // so a safety alert or summary would never show on screen.
        UNUserNotificationCenter.current().delegate = ThermyxNotificationPresenter.shared
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(roles: roles, settings: settings)
                .environmentObject(viewModel)
                // Development-only. `previewHarness` is defined inside a
                // `#if DEBUG` block in ThermyxPreviewHarness.swift and resolves
                // to a no-op extension that does not exist in a Release build —
                // a shipping binary contains no synthetic-data code path at all.
                .previewHarness(roles: roles, settings: settings, viewModel: viewModel)
                .modifier(DemoModeBanner(ble: viewModel.ble))
        }
        // History saves on a 5-second debounce. Save straight away when the
        // app leaves the screen, so a suspend or a swipe-away loses nothing.
        .onChange(of: scenePhase) { _, phase in
            if phase == .background {
                let history = viewModel.history
                Task { await history.save() }
            }
        }
    }
}

#if !DEBUG
private extension View {
    /// Release builds have no harness to host.
    @inline(__always)
    func previewHarness(roles: ThermyxRoleStore, settings: ThermyxSettingsStore, viewModel: ThermyxViewModel) -> Self { self }
}
#endif

/// Shows Thermyx notifications as banners even while the app is open.
final class ThermyxNotificationPresenter: NSObject, UNUserNotificationCenterDelegate {
    static let shared = ThermyxNotificationPresenter()

    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .list, .sound])
    }
}
