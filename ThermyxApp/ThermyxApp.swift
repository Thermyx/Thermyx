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
        }
    }
}
