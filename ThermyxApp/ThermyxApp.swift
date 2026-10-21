import SwiftUI
import UserNotifications

@main
struct ThermyxApp: App {
    @StateObject private var viewModel = ThermyxViewModel()
    @StateObject private var roles = ThermyxRoleStore()
    @StateObject private var settings = ThermyxSettingsStore()
    @StateObject private var account: ThermyxAccountStore
    @Environment(\.scenePhase) private var scenePhase
    @UIApplicationDelegateAdaptor(ThermyxAppDelegate.self) private var appDelegate

    init() {
        // Before the account store reads Firebase's signed-in user.
        ThermyxAccountStore.configureFirebase()
        UNUserNotificationCenter.current().delegate = ThermyxNotificationRouter.shared
        _account = StateObject(wrappedValue: ThermyxAccountStore())
    }

    var body: some Scene {
        WindowGroup {
            AppRootView(roles: roles, settings: settings)
                .environmentObject(viewModel)
                .environmentObject(account)
                .environment(\.isThermyxAdmin, account.isAdmin)
                // Development-only. `previewHarness` is defined inside a
                // `#if DEBUG` block in ThermyxPreviewHarness.swift and resolves
                // to a no-op extension that does not exist in a Release build —
                // a shipping binary contains no synthetic-data code path at all.
                .previewHarness(roles: roles, settings: settings, viewModel: viewModel)
                .modifier(DemoModeBanner(viewModel: viewModel))
                .onOpenURL { url in
                    // Ours (the Safety widget's SOS), else Google sign-in's.
                    if !ThermyxDeepLink.shared.handle(url) { account.handle(url) }
                }
                // iOS may end the app while it's in the background; an admin's
                // demo comes back as it was rather than dropping to "not connected".
                // Cloud backup and population priors (both off unless the
                // wearer turns them on); follows sign-in by itself.
                .task { account.startCloud(viewModel: viewModel, settings: settings, roles: roles) }
                .task(id: account.isAdmin) {
                    #if DEBUG
                    if ThermyxPreviewHarness.isActive { return }
                    #endif
                    if account.isAdmin { await viewModel.resumeDemoIfNeeded() }
                }
        }
        // History saves on a 5-second debounce. Save straight away when the
        // app leaves the screen, so a suspend or a swipe-away loses nothing.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { viewModel.applyWidgetRequest() }
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
