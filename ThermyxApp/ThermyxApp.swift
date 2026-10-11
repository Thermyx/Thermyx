import SwiftUI

@main
struct ThermyxApp: App {
    @StateObject private var viewModel = ThermyxViewModel()
    @StateObject private var roles = ThermyxRoleStore()
    @StateObject private var settings = ThermyxSettingsStore()
    @StateObject private var account: ThermyxAccountStore
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Before the account store reads Firebase's signed-in user.
        ThermyxAccountStore.configureFirebase()
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
                .modifier(DemoModeBanner(ble: viewModel.ble))
                .onOpenURL { account.handle($0) }
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
