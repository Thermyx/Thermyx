import SwiftUI

@main
struct ThermyxApp: App {
    @StateObject private var viewModel = ThermyxViewModel()
    @StateObject private var roles = ThermyxRoleStore()
    @StateObject private var settings = ThermyxSettingsStore()

    var body: some Scene {
        WindowGroup {
            AppRootView(roles: roles, settings: settings)
                .environmentObject(viewModel)
                // Development-only. `previewHarness` is defined inside a
                // `#if DEBUG` block in ThermyxPreviewHarness.swift and resolves
                // to a no-op extension that does not exist in a Release build —
                // a shipping binary contains no synthetic-data code path at all.
                .previewHarness(roles: roles, settings: settings, viewModel: viewModel)
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
