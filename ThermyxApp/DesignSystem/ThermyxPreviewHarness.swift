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
        case onboardingRole
        case onboardingPair
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
        case learning
        case article
        case safety
        case advanced
        case trusted
        case trustedSample
        case trustedSampleInsights
        case legal
        /// Simulated insole pair, already paired, with a day of history.
        /// Every control works: the insoles respond to Cool / Auto / Heat.
        case simulator
        /// Simulated insoles, starting from the beginning of onboarding.
        case simulatorOnboarding
    }

    static let state: State? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "-ThermyxUIPreview"),
              index + 1 < arguments.count
        else { return nil }
        return State(rawValue: arguments[index + 1])
    }()

    static var isActive: Bool { state != nil }

    /// True when the BLE layer is driving simulated insoles rather than the
    /// scripted preview stream.
    static var isSimulated: Bool { state == .simulator || state == .simulatorOnboarding }

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
    /// real app can be captured without a hand on the device. Used to produce
    /// the placeholder onboarding walkthrough.
    @MainActor
    final class Tour: ObservableObject {
        @Published var tab: UserTab = .home
        private var timer: Timer?
        private let steps: [(UserTab, TimeInterval)] = [
            (.home, 7), (.insights, 7), (.safety, 5)
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
                // Hidden during a tour: the recording is captured for use as
                // the onboarding walkthrough, where the banner would be wrong.
                // Every other preview state still carries it.
                // Simulated insoles get the always-compiled Demo Mode banner.
                if ThermyxPreviewHarness.isActive, !ThermyxPreviewHarness.isTouring, !ThermyxPreviewHarness.isSimulated {
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
        case .insights, .health, .temperature, .movement, .movementAdvanced, .balance, .learning, .article: return .insights
        case .safety, .advanced, .legal: return .safety
        default: return .home
        }
    }

    /// Which onboarding step to open on.
    static var initialOnboardingStep: Int {
        switch state {
        case .onboardingRole: return 1
        case .onboardingPair: return 3
        default: return 0
        }
    }

    /// Which tab a trusted-member state opens on.
    static var initialTrustedTab: TrustedTab {
        state == .trustedSampleInsights ? .insights : .watch
    }

    static var showsSampleShift: Bool {
        state == .trustedSample || state == .trustedSampleInsights
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
        case .learning: return [.learning]
        case .article: return [.learning, .article("feet-first")]
        default: return []
        }
    }

    static var initialSafetyPath: [SafetyDestination] {
        state == .advanced ? [.advanced] : []
    }

    /// Seeds role and settings so the requested screen is reachable on launch.
    @MainActor
    static func seed(roles: ThermyxRoleStore, settings: ThermyxSettingsStore) {
        guard let state else { return }

        switch state {
        case .onboardingRole, .onboardingPair, .simulatorOnboarding:
            roles.reset()
        case .trusted, .trustedSample, .trustedSampleInsights:
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

    /// A synthetic telemetry stream, plus enough back-dated history for the
    /// charts to have something to draw.
    @MainActor
    static func start(viewModel: ThermyxViewModel) async {
        if isSimulated {
            UNUserNotificationCenter.current().delegate = ForegroundNotifications.shared
            await viewModel.history.loadIfNeeded()
            if state == .simulator {
                // A day of back-filled history so the charts have something to
                // draw, then pair both simulated insoles.
                viewModel.history.deleteAll()
                viewModel.injectPreviewHistory(includeZones: true, feet: Foot.allCases)
                viewModel.ble.simulator?.connectAll()
            }
            return
        }
        guard let state,
              state != .onboardingRole, state != .onboardingPair,
              state != .trusted, state != .trustedSample, state != .trustedSampleInsights
        else { return }

        // Let the real store finish loading, then clear it: otherwise the load
        // lands after the injection and replaces it with whatever the previous
        // run persisted.
        await viewModel.history.loadIfNeeded()
        viewModel.history.deleteAll()

        let feet: [Foot] = state == .homeOneFoot ? [.left] : Foot.allCases
        if state == .tour { Tour.shared.start() }
        let includeZones = (state == .homeZones || state == .homeOneFoot || state == .profile || state == .insights || state == .health
                            || state == .temperature || state == .movementAdvanced || state == .balance
                            || state == .tour)
        let hot = (state == .homeCaution)

        viewModel.injectPreviewHistory(includeZones: includeZones, feet: feet)

        func live(_ foot: Foot) -> ThermyxReading {
            hot
                ? makeReading(foot: foot, includeZones: includeZones, hot: true)
                : shiftReading(foot: foot, includeZones: includeZones, progress: 1, at: .now)
        }
        Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            Task { @MainActor in
                for foot in feet { viewModel.injectPreviewReading(live(foot)) }
            }
        }
        for foot in feet { viewModel.injectPreviewReading(live(foot)) }
    }

    /// A point on the synthetic shift curve. `progress` runs 0 (shift start)
    /// to 1 (now).
    @MainActor
    static func shiftReading(foot: Foot, includeZones: Bool, progress: Double, at date: Date) -> ThermyxReading {
        let jitter = sin(date.timeIntervalSinceReferenceDate / 90) * 0.3
        let curve = sin(progress * .pi * 0.94)
        // The right foot drifts warmer and more loaded as the shift wears on,
        // rather than sitting at a fixed offset — a flat gap would draw a flat
        // line and tell you nothing about whether the chart works.
        let bias = foot == .right ? (0.15 + progress * 1.6) : 0.0
        let contact = 29.2 + curve * 8.4 + jitter + bias * 1.2
        let ambient = 22.5 + curve * 12.5 + jitter
        return ThermyxReading(
            foot: foot,
            timestamp: date,
            footTemperatureC: contact,
            ambientTemperatureC: ambient,
            pressureBalance: 0.47 + curve * 0.12 + bias * 0.05,
            gaitStability: 0.93 - curve * 0.2 - bias * 0.03,
            batteryPercent: max(40, 96 - Int(progress * 56)) - Int(bias * 6),
            thermalMode: curve > 0.6 ? .cooling : .ventilation,
            zones: includeZones
                ? FootZoneTemperatures(forefootC: contact + 1.8, archC: contact, heelC: contact - 3.2)
                : nil,
            cadenceStepsPerMinute: 104 - curve * 13,
            standingFraction: min(1, 0.3 + curve * 0.25)
        )
    }

    @MainActor
    static func makeReading(foot: Foot, includeZones: Bool, hot: Bool, at date: Date = .now) -> ThermyxReading {
        let phase = sin(date.timeIntervalSinceReferenceDate / 90)
        let bias = foot == .right ? 1.0 : 0.0
        let contact = (hot ? 38.4 : 34.8) + phase * 0.4 + bias * 1.1
        return ThermyxReading(
            foot: foot,
            timestamp: date,
            footTemperatureC: contact,
            ambientTemperatureC: (hot ? 36.4 : 28.6) + phase * 0.6,
            pressureBalance: 0.54 + phase * 0.03 + bias * 0.06,
            gaitStability: (hot ? 0.74 : 0.88) + phase * 0.02,
            batteryPercent: 72 - Int(bias * 8),
            thermalMode: hot ? .cooling : .ventilation,
            zones: includeZones
                ? FootZoneTemperatures(
                    forefootC: contact + 1.6,
                    archC: contact,
                    heelC: contact - 3.6
                  )
                : nil
        )
    }
}

extension ThermyxViewModel {
    /// Feeds one synthetic reading through the normal ingest path.
    @MainActor
    func injectPreviewReading(_ reading: ThermyxReading) {
        ble.injectPreviewReading(reading)
    }

    /// Back-fills history so the Insights charts have a series to draw.
    @MainActor
    func injectPreviewHistory(includeZones: Bool, feet: [Foot]) {
        let now = Date.now
        for minutesAgo in stride(from: 480, through: 1, by: -4) {
            let date = now.addingTimeInterval(-Double(minutesAgo) * 60)
            let progress = 1 - Double(minutesAgo) / 480
            for foot in feet {
                let reading = ThermyxPreviewHarness.shiftReading(
                    foot: foot,
                    includeZones: includeZones,
                    progress: progress,
                    at: date
                )
                history.record(reading, assessment: ThermyxRiskEngine.assess(reading))
            }
        }
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
            await ThermyxPreviewHarness.start(viewModel: viewModel)
        }
        .modifier(ThermyxPreviewHarness.Watermark())
    }
}
#endif
