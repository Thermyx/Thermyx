import SwiftUI
import UserNotifications

/// Chooses sign-in and onboarding, the user experience, or the watcher
/// experience.
struct AppRootView: View {
    @EnvironmentObject private var account: ThermyxAccountStore
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    var body: some View {
        Group {
            #if DEBUG
            if ThermyxPreviewHarness.state == .widgets {
                WidgetGallery()
            } else { content }
            #else
            content
            #endif
        }
        .animation(.easeInOut(duration: 0.35), value: account.isSignedIn && roles.hasCompletedOnboarding)
        .tint(Thermyx.Ink.ice)
        .preferredColorScheme(.dark)
        .onAppear { ThermyxFontRegistration.verify() }
    }

    @ViewBuilder
    private var content: some View {
        Group {
            if !account.isSignedIn || !roles.hasCompletedOnboarding {
                OnboardingFlow(roles: roles, settings: settings)
                    .transition(.opacity)
            } else if roles.role == .trustedMember {
                TrustedMemberRoot(roles: roles, settings: settings)
            } else {
                UserRoot(roles: roles, settings: settings)
            }
        }
    }
}

// MARK: - User

enum UserTab: Hashable {
    case home, insights, learn, simulator, safety
}

struct UserRoot: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @ObservedObject private var tutorial = TutorialCenter.shared
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
        .init(.home, label: "Home", systemImage: "house", selectedImage: "house.fill"),
        .init(.insights, label: "Insights", systemImage: "chart.bar", selectedImage: "chart.bar.fill"),
        .init(.learn, label: "Learn", systemImage: "newspaper", selectedImage: "newspaper.fill"),
        .init(.simulator, label: "Simulator", systemImage: "dial.medium", selectedImage: "dial.medium.fill"),
        .init(.safety, label: "Safety", systemImage: "shield", selectedImage: "shield.fill")
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
        // The thermal control sits between the content and the tab bar on
        // every screen, pushed ones included.
        ThermyxTabScaffold(items: Self.tabs, selection: tabBinding) {
            ThermalControlBar(viewModel: viewModel, settings: settings)
        } content: { tab in
            switch tab {
            case .home:
                HomeView(roles: roles, settings: settings)
            case .insights:
                InsightsHubView(settings: settings, health: health)
            case .learn:
                LearnTab(settings: settings)
            case .simulator:
                SimulatorTab(settings: settings)
            case .safety:
                SafetyView(roles: roles, settings: settings, alerts: alerts, health: health)
            }
        }
        .overlayPreferenceValue(SpotlightAnchors.self) { anchors in
            if tutorial.isShowing {
                SpotlightTutorial(anchors: anchors, viewModel: viewModel, center: tutorial)
                    .transition(.opacity)
            }
        }
        .animation(SiteMotion.settle, value: tutorial.isShowing)
        .onChange(of: tutorial.replayRequest) { _, _ in tab = .home }
        .onChange(of: tutorial.requestedTab) { _, requested in
            if let requested { withAnimation(SiteMotion.fade) { tab = requested } }
        }
        .task {
            // Once, after onboarding, on Home.
            try? await Task.sleep(for: .seconds(0.8))
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("-ThermyxTutorial") { tutorial.replay(); return }
            if ThermyxPreviewHarness.isActive { return }
            #endif
            if !tutorial.hasSeen { tab = .home }
            tutorial.showIfFirstRun()
        }
        .onChange(of: settings.temperatureUnit, initial: true) { _, unit in
            viewModel.widgets.fahrenheit = unit == .fahrenheit
        }
        .task {
            viewModel.healthService = health
            await viewModel.history.loadIfNeeded()
            #if DEBUG
            // `-ThermyxNoPrompts`: screenshots without permission alerts.
            if !ProcessInfo.processInfo.arguments.contains("-ThermyxNoPrompts"),
               !ThermyxPreviewHarness.isActive || ThermyxPreviewHarness.isSimulated {
                await alerts.requestPermission()
                alerts.location.requestPermission()
            }
            #else
            await alerts.requestPermission()
            alerts.location.requestPermission()
            #endif
            health.refreshAuthorizationState()
            // Yesterday's AI summary, if it was worn and never got one.
            alerts.catchUpSummary(history: viewModel.history, settings: settings)
            ThermyxWeeklyReminder.schedule()
            if settings.healthKitEnabled, health.availability == .authorized {
                await health.refreshContext()
            }
        }
        .onReceive(viewModel.$reading) { reading in
            let assessment = viewModel.assessment
            alerts.isDemoMode = viewModel.ble.isDemoMode
            alerts.evaluate(assessment, reading: reading, settings: settings)
            alerts.evaluateComfort(reading, unit: settings.temperatureUnit, conditions: settings.profile.conditionSet)
            if assessment.level == .critical {
                let snoozed = criticalSnoozedUntil.map { Date.now < $0 } ?? false
                if !snoozed, !showingCritical { showingCritical = true }
            } else if assessment.level.severity < ThermyxRiskLevel.high.severity {
                criticalSnoozedUntil = nil
            }
        }
        .onChange(of: viewModel.sessionEndedAt) { _, ended in
            guard ended != nil else { return }
            alerts.deliverSessionSummary(history: viewModel.history, settings: settings)
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
            member.start(settings: settings)
            #if DEBUG
            if ThermyxPreviewHarness.isActive { return }
            #endif
            _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
            ThermyxPushRegistrar.shared.register()
        }
        .onDisappear { member.stop() }
    }
}
