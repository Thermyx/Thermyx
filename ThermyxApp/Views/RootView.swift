import SwiftUI
import UserNotifications

/// Chooses onboarding, the user experience, or the watcher experience.
struct AppRootView: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    var body: some View {
        Group {
            if roles.hasCompletedOnboarding, roles.role == .trustedMember {
                TrustedMemberRoot(roles: roles, settings: settings)
            } else if roles.hasCompletedOnboarding {
                UserRoot(roles: roles, settings: settings)
            } else {
                OnboardingFlow(roles: roles, settings: settings)
            }
        }
        .tint(Thermyx.Ink.ice)
        .preferredColorScheme(.dark)
        .onAppear { ThermyxFontRegistration.verify() }
    }
}

// MARK: - User

enum UserTab: Hashable {
    case home, insights, safety
}

struct UserRoot: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @StateObject private var alerts = ThermyxAlertCoordinator()
    @StateObject private var health = ThermyxHealthService()
    @State private var showingCritical = false
    /// After "I'm OK", the takeover stays quiet for a while unless the level
    /// drops and climbs back to Critical.
    @State private var criticalSnoozedUntil: Date?
    #if DEBUG
    @StateObject private var tour = ThermyxPreviewHarness.Tour.shared
    #endif
    @State private var tab: UserTab = {
        #if DEBUG
        return ThermyxPreviewHarness.initialUserTab
        #else
        return .home
        #endif
    }()

    private static let tabs: [ThermyxTabBar<UserTab>.Item] = [
        .init(.home, label: "Home", systemImage: "house.fill"),
        .init(.insights, label: "Insights", systemImage: "chart.xyaxis.line"),
        .init(.safety, label: "Safety", systemImage: "shield.checkered")
    ]

    /// The tour drives the tab when it is running; otherwise the user does.
    private var tabBinding: Binding<UserTab> {
        #if DEBUG
        if ThermyxPreviewHarness.isTouring {
            return Binding(get: { tour.tab }, set: { tour.tab = $0 })
        }
        #endif
        return $tab
    }

    var body: some View {
        // The control bar sits between the content and the tab bar, on every
        // tab-level screen. Pushed reading screens omit it: they need the
        // vertical room for charts and are one tap from back.
        ThermyxTabScaffold(items: Self.tabs, selection: tabBinding) {
            ThermalControlBar(viewModel: viewModel)
        } content: { tab in
            switch tab {
            case .home:
                HomeView(roles: roles, settings: settings)
            case .insights:
                InsightsHubView(settings: settings, health: health)
            case .safety:
                SafetyView(roles: roles, settings: settings, alerts: alerts, health: health)
            }
        }
        .task {
            viewModel.healthService = health
            await viewModel.history.loadIfNeeded()
            #if DEBUG
            if !ThermyxPreviewHarness.isActive || ThermyxPreviewHarness.isSimulated {
                await alerts.requestPermission()
                alerts.location.requestPermission()
            }
            #else
            await alerts.requestPermission()
            alerts.location.requestPermission()
            #endif
            health.refreshAuthorizationState()
            if settings.healthKitEnabled, health.availability == .authorized {
                await health.refreshContext()
            }
        }
        .onReceive(viewModel.$reading) { reading in
            let assessment = viewModel.assessment
            alerts.isDemoMode = viewModel.ble.isDemoMode
            alerts.evaluate(assessment, reading: reading, settings: settings)
            alerts.evaluateComfort(reading, unit: settings.temperatureUnit)
            if assessment.level == .critical {
                let snoozed = criticalSnoozedUntil.map { Date.now < $0 } ?? false
                if !snoozed, !showingCritical { showingCritical = true }
            } else if assessment.level.severity < ThermyxRiskLevel.high.severity {
                criticalSnoozedUntil = nil
            }
        }
        .fullScreenCover(isPresented: $showingCritical) {
            CriticalAlertView(alerts: alerts, settings: settings) {
                criticalSnoozedUntil = Date.now.addingTimeInterval(10 * 60)
                showingCritical = false
            }
            .environmentObject(viewModel)
        }
    }
}

// MARK: - Trusted member
//
// A watcher gets three tabs and no thermal control bar: they can see and they
// can call, but they cannot actuate somebody else's insole.

enum TrustedTab: Hashable {
    case watch, insights, settings
}

struct TrustedMemberRoot: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @StateObject private var member = TrustedMemberViewModel()
    @State private var tab: TrustedTab = {
        #if DEBUG
        return ThermyxPreviewHarness.initialTrustedTab
        #else
        return .watch
        #endif
    }()

    private static let tabs: [ThermyxTabBar<TrustedTab>.Item] = [
        .init(.watch, label: "Watch", systemImage: "person.2.fill"),
        .init(.insights, label: "Insights", systemImage: "chart.xyaxis.line"),
        .init(.settings, label: "Settings", systemImage: "gearshape.fill")
    ]

    // No thermal control bar here, deliberately: a watcher can see and can
    // call, but cannot actuate somebody else's insole.
    var body: some View {
        ThermyxTabScaffold(items: Self.tabs, selection: $tab) { tab in
            switch tab {
            case .watch:
                TrustedWatchView(roles: roles, member: member, settings: settings)
            case .insights:
                TrustedInsightsView(roles: roles, member: member, settings: settings)
            case .settings:
                TrustedSettingsView(roles: roles, settings: settings, member: member)
            }
        }
        .task {
            #if DEBUG
            if ThermyxPreviewHarness.showsSampleShift { member.isShowingSample = true }
            #endif
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            member.start(settings: settings)
        }
        .onDisappear { member.stop() }
    }
}
