#if DEBUG
import Foundation
import SwiftUI
import UserNotifications

/// A development-only harness for driving the app into a given screen and
/// state, so layouts can be reviewed without a physical insole.
///
/// **This is not a demo mode and never ships.** It is compiled out of Release
/// entirely, and even in Debug it does nothing unless the app is launched with
/// `-ThermyxUIPreview <state>`. The values it injects are obviously synthetic
/// and exist only so screenshots can be taken during development.
enum ThermyxPreviewHarness {

    enum State: String {
        /// Signed out, on the welcome screen.
        case onboardingWelcome
        case onboardingRole
        case onboardingAbout
        case onboardingPair
        case onboardingCalibrate
        case home
        case homeZones
        case homeOneFoot
        case tour
        case homeCaution
        case profile
        case insights
        case health
        case temperature
        case movement
        case movementAdvanced
        case balance
        /// Insights → the weekly report.
        case weekly
        /// Every widget surface at its real size, from sample data.
        case widgets
        /// The Thermal Recovery Test at each stage, from a hot afternoon.
        case recoveryTest
        case recoveryHold
        case recoveryResult
        /// Insights, scrolled to the readiness profile and the safety plan.
        case readiness
        case safetyPlan
        /// The watcher's status card mid-event, from sample data.
        case trustedHandoff
        /// The same card after the wearer checked in and it eased.
        case trustedRecovered
        /// Safety with "What your circle gets" open, as on a first contact.
        case circleSharing
        case learning
        case article
        case safety
        case advanced
        case trusted
        case trustedSample
        case trustedSampleInsights
        case legal
        /// The Simulator tab (the educational thermal simulator).
        case thermalSimulator
        /// Safety → Device.
        case device
        /// Simulated insole pair, already paired, with a day of history.
        /// Every control works: the insoles respond to Cool / Auto / Heat.
        case simulator
        /// Simulated insoles, starting from the beginning of onboarding.
        case simulatorOnboarding
        /// Simulated insoles advertising, on the insoles step.
        case simulatorPair
        /// The fake insole connected, on the calibration step.
        case simulatorCalibrate
    }

    static let state: State? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ThermyxUIPreview"),
              index + 1 < arguments.count
        else { return nil }
        return State(rawValue: arguments[index + 1])
    }()

    static var isActive: Bool { state != nil }

    /// True when the app runs on the simulated insoles: every state that
    /// shows readings. They respond to Cool, Auto, Heat and the target like
    /// the firmware, so a demo can be driven by hand. Onboarding (before
    /// pairing) and the watcher's views don't simulate anything.
    static var isSimulated: Bool {
        guard let state else { return false }
        switch state {
        case .onboardingWelcome, .onboardingRole, .onboardingAbout, .onboardingPair, .onboardingCalibrate,
             .trusted, .trustedSample, .trustedSampleInsights, .widgets, .trustedHandoff, .trustedRecovered:
            return false
        default:
            return true
        }
    }

    /// The states made for trying the simulated insoles by hand, from
    /// pairing on. They run as an admin account.
    static var isSimulatorState: Bool { [.simulator, .simulatorOnboarding, .simulatorPair, .simulatorCalibrate].contains(state) }

    /// Shows notification banners while the app is open, so the risk alerts
    /// can be seen during a simulated session.
    final class ForegroundNotifications: NSObject, UNUserNotificationCenterDelegate {
        static let shared = ForegroundNotifications()
        func userNotificationCenter(
            _ center: UNUserNotificationCenter,
            willPresent notification: UNNotification,
            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
        ) {
            completionHandler([.banner, .list, .sound])
        }
    }

    /// Drives a scripted walk through the tabs, so a screen recording of the
    /// real app can be captured without a hand on the device.
    @MainActor
    final class Tour: ObservableObject {
        @Published var tab: UserTab = .home
        private var timer: Timer?
        private let steps: [(UserTab, TimeInterval)] = [
            (.home, 7), (.insights, 7), (.learn, 4), (.simulator, 5), (.safety, 5)
        ]
        private var index = 0

        static let shared = Tour()

        func start() {
            guard ThermyxPreviewHarness.state == .tour, timer == nil else { return }
            schedule()
        }

        private func schedule() {
            let (next, hold) = steps[index % steps.count]
            tab = next
            index += 1
            timer = Timer.scheduledTimer(withTimeInterval: hold, repeats: false) { [weak self] _ in
                Task { @MainActor in
                    self?.timer = nil
                    self?.schedule()
                }
            }
        }
    }

    static var isTouring: Bool { state == .tour }

    /// `-ThermyxStartCalibration`: calibration starts by itself.
    static var startsCalibration: Bool { ProcessInfo.processInfo.arguments.contains("-ThermyxStartCalibration") }
    /// `-ThermyxScrollToEnd`: onboarding pages open scrolled to the bottom.
    static var scrollsToEnd: Bool { ProcessInfo.processInfo.arguments.contains("-ThermyxScrollToEnd") }

    /// `-ThermyxScrollTo <id>`: a screen opens scrolled to the view with
    /// that id ("end" for the bottom), so long screens can be reviewed.
    static var scrollTarget: String? {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ThermyxScrollTo"), index + 1 < arguments.count else { return nil }
        return arguments[index + 1]
    }

    static var isOnboarding: Bool {
        [.onboardingWelcome, .onboardingRole, .onboardingAbout, .onboardingPair, .onboardingCalibrate].contains(state)
    }

    /// A watermark shown over the whole app whenever the harness is feeding
    /// synthetic readings.
    ///
    /// The app's central promise is that it never shows a number it did not
    /// measure. A development harness that injects readings is the one thing
    /// that could break that promise by accident — a screenshot taken with it
    /// running would look exactly like live data. So when it runs, it says so,
    /// in a way that cannot be cropped out of a demo without noticing.
    struct Watermark: ViewModifier {
        func body(content: Content) -> some View {
            // A top inset rather than an overlay: it must never sit on top of
            // a screen title or a reading, because the point is to be read,
            // not to obscure the thing it is warning about.
            content.safeAreaInset(edge: .bottom, spacing: 0) {
                // Hidden during a tour and on onboarding screens, which show
                // no readings. Simulated insoles get the always-compiled Demo
                // Mode banner.
                if ThermyxPreviewHarness.isActive, !ThermyxPreviewHarness.isTouring, !ThermyxPreviewHarness.isSimulated,
                   !ThermyxPreviewHarness.isOnboarding {
                    Text("Simulated — not live sensor data")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.onEmber)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 5)
                        .background(Thermyx.Ink.ember)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Simulated. This is not live sensor data.")
                }
            }
        }
    }

    /// Which tab the requested state should open on.
    static var initialUserTab: UserTab {
        switch state {
        case .insights, .health, .temperature, .movement, .movementAdvanced, .balance, .weekly, .readiness, .safetyPlan: return .insights
        case .learning, .article: return .learn
        case .safety, .advanced, .legal, .device, .circleSharing: return .safety
        case .thermalSimulator: return .simulator
        default: return .home
        }
    }

    /// Which onboarding step to open on.
    static var initialOnboardingStep: OnboardingFlow.Step {
        switch state {
        case .onboardingRole: return .profile
        case .onboardingAbout: return .about
        case .onboardingPair, .simulatorPair: return .insoles
        case .onboardingCalibrate, .simulatorCalibrate: return .calibrate
        default: return .welcome
        }
    }

    /// The account a preview runs as: none on the welcome screen, otherwise
    /// a stand-in. Simulated insoles, or `-ThermyxAdmin`, run as an admin.
    static var account: ThermyxAccount? {
        guard let state, state != .onboardingWelcome else { return nil }
        let admin = isSimulatorState || ProcessInfo.processInfo.arguments.contains("-ThermyxAdmin")
        return ThermyxAccount(uid: "preview", email: admin ? ThermyxAdmins.emails.sorted().first : nil,
                              displayName: "Jordan Taylor")
    }

    /// Which tab a trusted-member state opens on.
    static var initialTrustedTab: TrustedTab {
        state == .trustedSampleInsights ? .insights : .watch
    }

    /// Opens the legal sheet directly.
    static var opensLegalSheet: Bool { state == .legal }

    /// Opens the device and profile sheet directly.
    static var opensProfileSheet: Bool { state == .profile }

    /// A pushed screen to open on, so detail layouts can be reviewed directly.
    static var initialInsightsPath: [InsightsDestination] {
        switch state {
        case .temperature: return [.temperature]
        case .movement: return [.movement]
        case .movementAdvanced: return [.movement, .movementAdvanced]
        case .balance: return [.balance]
        case .weekly: return [.week]
        default: return []
        }
    }

    /// The Learn tab opens on an article for the `article` state.
    static var initialLearnPath: [InsightsDestination] {
        state == .article ? [.article("overheating")] : []
    }

    static var initialSafetyPath: [SafetyDestination] {
        switch state {
        case .advanced: return [.device, .advanced]
        case .device: return [.device]
        default: return []
        }
    }

    /// Seeds role and settings so the requested screen is reachable on launch.
    @MainActor
    static func seed(roles: ThermyxRoleStore, settings: ThermyxSettingsStore) {
        guard let state else { return }

        switch state {
        case .onboardingWelcome, .onboardingRole, .onboardingAbout, .onboardingPair, .onboardingCalibrate,
             .simulatorOnboarding, .simulatorPair, .simulatorCalibrate:
            roles.reset()
        case .trusted, .trustedSample, .trustedSampleInsights, .trustedHandoff, .trustedRecovered:
            roles.complete(role: .trustedMember, name: "Watcher", watched: "Morgan Lee", code: "THERMYX-01")
            // 555-0100 through 555-0199 are reserved fictional NANPA numbers.
            roles.watchedUserPhone = "+12025550108"
        default:
            roles.complete(role: .user, name: "Jordan Taylor", watched: "Thermyx user", code: "THERMYX-01")
        }

        if state == .health { settings.healthKitEnabled = true }

        settings.contacts = [
            ThermyxContact(name: "Casey Morgan", phoneNumber: "+1 (202) 555-0148"),
            ThermyxContact(name: "Riley Chen", phoneNumber: "+1 (202) 555-0199", enabled: false)
        ]
    }

    /// A month of generated history, then the simulated insoles carrying on
    /// live from where it ends: the same wearer, so the charts continue
    /// without a jump, and every control responds.
    @MainActor
    static func start(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore) async {
        guard isSimulated, let state else { return }
        UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
        await viewModel.history.loadIfNeeded()
        switch state {
        case .simulatorCalibrate:
            viewModel.ble.startFakeInsoles()
            return
        case .simulatorOnboarding, .simulatorPair:
            return
        default:
            break
        }
        if state == .tour { Tour.shared.start() }

        var options = ThermyxViewModel.DemoOptions()
        options.feet = state == .homeOneFoot ? [.left] : Foot.allCases
        options.zones = state == .homeZones
        if state == .homeCaution || state == .recoveryTest || state == .recoveryHold || state == .recoveryResult {
            // One rule firing: a foot past 38 °C because the cooling has
            // failed, in air that isn't hot enough to add a second.
            let feet = options.feet
            options.configure = { simulator in
                simulator.followsDay = false
                simulator.ambientC = 33.5
                simulator.coolingFault = true
                simulator.seed(from: Dictionary(uniqueKeysWithValues: feet.map { foot in
                    (foot, ThermyxReading(foot: foot, timestamp: .now, footTemperatureC: foot == .right ? 38.6 : 38.1,
                                          ambientTemperatureC: 33.5, pressureBalance: nil, gaitStability: 0.88,
                                          batteryPercent: 60, thermalMode: .off))
                }))
            }
        }
        await viewModel.startDemo(options)
    }
}

extension View {
    /// Attaches the development harness: seeds state, starts the synthetic
    /// reading stream, and stamps the preview watermark over everything.
    func previewHarness(
        roles: ThermyxRoleStore,
        settings: ThermyxSettingsStore,
        viewModel: ThermyxViewModel
    ) -> some View {
        task {
            ThermyxPreviewHarness.seed(roles: roles, settings: settings)
            await ThermyxPreviewHarness.start(viewModel: viewModel, settings: settings)
        }
        .modifier(ThermyxPreviewHarness.Watermark())
    }
}
#endif
