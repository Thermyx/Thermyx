import SwiftUI

/// First run (design O1–O4): the photo stack and Google sign-in; a profile
/// (role, what it's for, units); then for a wearer About you, pairing and
/// calibration, and for a watcher, who they watch. The spotlight tutorial
/// runs on Home once onboarding is done.
struct OnboardingFlow: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @EnvironmentObject private var account: ThermyxAccountStore
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @StateObject private var health = ThermyxHealthService()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Hashable {
        case welcome, profile, about, insoles, calibrate, watch

        var label: String {
            switch self {
            case .welcome: return "Welcome"
            case .profile: return "Profile"
            case .about: return "About you"
            case .insoles: return "Insoles"
            case .calibrate: return "Calibrate"
            case .watch: return "Who you watch"
            }
        }
    }

    @State private var step: Step = {
        #if DEBUG
        return ThermyxPreviewHarness.initialOnboardingStep
        #else
        return .welcome
        #endif
    }()
    /// Which way the last move went, so pages slide the right way.
    @State private var forward = true
    @State private var role: ThermyxRole = .user
    @State private var name = ""
    @State private var watchedName = ""

    private var steps: [Step] {
        role == .user ? [.welcome, .profile, .about, .insoles, .calibrate] : [.welcome, .profile, .watch]
    }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            TopographyBackground()
                .opacity(step == .welcome ? 0.5 : 0.35)
                .animation(.easeInOut(duration: 0.6), value: step)

            VStack(spacing: 0) {
                if step != .welcome {
                    OnboardingTopBar(step: index, total: steps.count - 1, label: step.label) {
                        go(to: steps[max(index - 1, 0)])
                    }
                    .transition(.opacity)
                }
                ZStack {
                    page
                        .id(step)
                        .transition(pageTransition)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear {
            if name.isEmpty { name = roles.profileName.isEmpty ? (account.account?.displayName ?? "") : roles.profileName }
            if let stored = roles.role { role = stored }
            if !roles.watchedUserName.isEmpty, roles.role == .trustedMember { watchedName = roles.watchedUserName }
        }
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case .welcome:
            WelcomeScreen { go(to: .profile) }
        case .profile:
            ProfileStep(role: $role, settings: settings) {
                go(to: role == .user ? .about : .watch)
            } onChangeAccount: {
                account.signOut()
                go(to: .welcome)
            }
        case .about:
            AboutYouStep(name: $name, settings: settings, health: health) {
                roles.profileName = name.trimmed
                go(to: .insoles)
            }
        case .insoles:
            InsolesStep(settings: settings, onContinue: { go(to: .calibrate) }, onLater: finish)
        case .calibrate:
            OnboardingCalibrationStep(settings: settings, onFinish: finish)
        case .watch:
            WatchStep(name: $name, watchedName: $watchedName, settings: settings, onFinish: finish)
        }
    }

    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .offset(x: forward ? 48 : -48).combined(with: .opacity),
            removal: .offset(x: forward ? -48 : 48).combined(with: .opacity)
        )
    }

    private func go(to next: Step) {
        let ahead = (steps.firstIndex(of: next) ?? 0) >= index
        // Direction first, so the page leaving takes the right transition.
        forward = ahead
        DispatchQueue.main.async {
            withAnimation(reduceMotion ? SiteMotion.fade : SiteMotion.settle) { step = next }
        }
    }

    private func finish() {
        let trimmed = name.trimmed
        roles.complete(
            role: role,
            name: trimmed.isEmpty ? (account.account?.displayName ?? "") : trimmed,
            watched: role == .trustedMember ? watchedName.trimmed : roles.watchedUserName,
            code: roles.pairingCode
        )
    }
}

extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - Chrome

/// Back, a segmented progress line, and "Step 2 of 4 · About you".
private struct OnboardingTopBar: View {
    let step: Int
    let total: Int
    let label: String
    let onBack: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Button(action: onBack) {
                    Image(systemName: "chevron.left")
                        .font(.system(size: 17, weight: .semibold))
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .frame(width: 44, height: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Back")
                HStack(spacing: 6) {
                    ForEach(0..<max(total, 1), id: \.self) { i in
                        Capsule()
                            .fill(i < step ? Thermyx.Ink.textPrimary : Thermyx.Tint.track)
                            .frame(height: 3)
                    }
                }
                .animation(SiteMotion.settle, value: step)
            }
            Text("Step \(step) of \(total) · \(label)")
                .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .footnote))
                .foregroundStyle(Thermyx.Ink.textMuted)
                .padding(.leading, 46)
        }
        .padding(.horizontal, 16)
        .padding(.top, 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Step \(step) of \(total), \(label)")
    }
}

/// A page: a 28 pt headline, a line of context, the content, and the
/// actions pinned above the home indicator.
struct OnboardingPage<Content: View, Actions: View>: View {
    var eyebrow: String?
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    /// v1 marked italic emphasis with asterisks; v2 sets titles plain.
    private var plainTitle: String { title.replacingOccurrences(of: "*", with: "") }

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.group) {
                VStack(alignment: .leading, spacing: 8) {
                    Text(plainTitle)
                        .font(ThermyxFont.onboardingHeadline)
                        .tracking(ThermyxTracking.onboardingHeadline)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)
                    if let subtitle {
                        Text(subtitle)
                            .font(ThermyxFont.bodySmall)
                            .lineSpacing(2)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, Thermyx.Space.wide)
            .padding(.top, 22)
            .padding(.bottom, Thermyx.Space.wide)
            Color.clear.frame(height: 1).id("end")
        }
        #if DEBUG
        .task {
            guard ThermyxPreviewHarness.scrollsToEnd else { return }
            try? await Task.sleep(for: .seconds(1.5))
            proxy.scrollTo("end", anchor: .bottom)
        }
        #endif
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: Thermyx.Space.xs) { actions }
                .padding(.horizontal, Thermyx.Space.wide)
                .padding(.top, Thermyx.Space.m)
                .padding(.bottom, Thermyx.Space.xs)
                .background {
                    // Solid under the buttons and hint, so nothing from the page
                    // shows through; a short fade above hides the cut edge.
                    Color.black.ignoresSafeArea()
                        .overlay(alignment: .top) {
                            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                                .frame(height: 28)
                                .offset(y: -28)
                                .allowsHitTesting(false)
                        }
                }
        }
    }
}

/// Title, then an icon after it: "Continue →".
struct TrailingIconLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Thermyx.Space.xs) {
            configuration.title
            configuration.icon.font(.system(size: 15, weight: .bold))
        }
    }
}

// MARK: - Profile

/// Design O3: the signed-in account, how you'll use Thermyx, what it's
/// mostly for, and units.
private struct ProfileStep: View {
    @EnvironmentObject private var account: ThermyxAccountStore
    @Binding var role: ThermyxRole
    @ObservedObject var settings: ThermyxSettingsStore
    let onContinue: () -> Void
    let onChangeAccount: () -> Void

    @State private var legal: LegalDocument.Kind?

    var body: some View {
        OnboardingPage(title: "How will you use Thermyx?") {
            accountRow
            VStack(spacing: 0) {
                roleRow(.user, title: "I wear the insoles", detail: "See your feet live and control heating and cooling.")
                roleRow(.trustedMember, title: "I'm in someone's circle", detail: "Get alerts and check in on a wearer. You never control their insoles.")
            }
            if role == .user {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Mostly for")
                        .font(ThermyxFont.bodySmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                    UsageChips(settings: settings)
                }
                .transition(.opacity)
            }
            HStack {
                Text("Units")
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                Spacer()
                ThermyxSegmentedControl(options: TemperatureUnit.allCases, label: \.shortLabel,
                                        selection: $settings.temperatureUnit, accessibilityPrefix: "Show temperatures in ")
                    .fixedSize()
            }
            AIInsightsToggle(isOn: $settings.aiInsightsEnabled) { legal = $0 }
        } actions: {
            Button("Continue", action: onContinue)
                .buttonStyle(ThermyxPrimaryButtonStyle())
        }
        .animation(SiteMotion.settle, value: role)
        .sheet(item: $legal) { kind in
            LegalSheet(selection: kind)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
    }

    private var accountRow: some View {
        let name = account.account?.displayName ?? "Signed in"
        let initials = name.split(separator: " ").prefix(2).compactMap { $0.first.map(String.init) }.joined().uppercased()
        return HStack(spacing: 12) {
            Circle()
                .fill(Thermyx.Ink.elevated)
                .frame(width: 44, height: 44)
                .overlay {
                    Text(initials.isEmpty ? "?" : initials)
                        .font(.custom(ThermyxFont.Family.semibold, size: 16, relativeTo: .headline))
                        .foregroundStyle(Thermyx.Ink.ice)
                }
            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                if let email = account.account?.email {
                    Text(email)
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                }
            }
            Spacer()
            Button("Change", action: onChangeAccount)
                .font(.custom(ThermyxFont.Family.medium, size: 14, relativeTo: .subheadline))
                .foregroundStyle(Thermyx.Ink.link)
                .frame(minHeight: 44)
                .accessibilityLabel("Use a different account")
        }
        .padding(.bottom, 18)
        .overlay(alignment: .bottom) { ThermyxDivider() }
        .accessibilityElement(children: .contain)
    }

    private func roleRow(_ value: ThermyxRole, title: String, detail: String) -> some View {
        let selected = role == value
        return Button {
            withAnimation(SiteMotion.settle) { role = value }
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Circle()
                    .strokeBorder(selected ? Thermyx.Ink.ice : Color(hex: 0x3A3D43), lineWidth: 2)
                    .frame(width: 22, height: 22)
                    .overlay { Circle().fill(selected ? Thermyx.Ink.ice : .clear).frame(width: 10, height: 10) }
                    .padding(.top, 1)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.custom(ThermyxFont.Family.semibold, size: 17, relativeTo: .headline))
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(detail)
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 16)
            .overlay(alignment: .bottom) { ThermyxDivider() }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// What the wearer mostly uses Thermyx for: chips, any number on. Shapes the
/// Simulator's first scenario and the AI summary's suggestions.
struct UsageChips: View {
    @ObservedObject var settings: ThermyxSettingsStore

    var body: some View {
        FlowRow(spacing: 8) {
            ForEach(ThermyxSettingsStore.usageOptions, id: \.self) { option in
                chip(option)
            }
        }
    }

    private func chip(_ label: String) -> some View {
        let on = settings.usage.contains(label)
        return Button {
            if on { settings.usage.removeAll { $0 == label } } else { settings.usage.append(label) }
        } label: {
            Text(label)
                .font(.custom(ThermyxFont.Family.medium, size: 14, relativeTo: .subheadline))
                .foregroundStyle(on ? Thermyx.Ink.onPrimary : Thermyx.Ink.textPrimary)
                .padding(.horizontal, 16)
                .frame(height: 44)
                .background(on ? Thermyx.Ink.textPrimary : .clear, in: Capsule())
                .overlay { Capsule().strokeBorder(on ? .clear : Color(hex: 0x2A2D33), lineWidth: 1) }
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: on)
        .accessibilityAddTraits(on ? [.isButton, .isSelected] : .isButton)
    }
}

/// Scales in slightly on touch-down, for cards and rows.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(SiteMotion.press, value: configuration.isPressed)
    }
}

// MARK: - Watcher

private struct WatchStep: View {
    @Binding var name: String
    @Binding var watchedName: String
    @ObservedObject var settings: ThermyxSettingsStore
    let onFinish: () -> Void

    private var ready: Bool { !name.trimmed.isEmpty && !watchedName.trimmed.isEmpty }

    var body: some View {
        OnboardingPage(eyebrow: "Watching", title: "Who are you *looking out for?*",
                       subtitle: "They'll invite you from their phone. You'll see their safety alerts, never their controls.") {
            VStack(spacing: Thermyx.Space.m) {
                OnboardingTextField(label: "Your name", text: $name, placeholder: "Name", contentType: .name)
                OnboardingTextField(label: "Their name", text: $watchedName, placeholder: "Name", contentType: .name)
            }
            VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                SiteEyebrow("Their invite code")
                RelayConnectionCard(settings: settings, role: "watcher", watcherName: name)
                Text("No code yet? You can add it later in Settings.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Site.textFaint)
            }
        } actions: {
            Button("Done", action: onFinish)
                .buttonStyle(SitePrimaryButtonStyle())
                .disabled(!ready)
        }
    }
}

/// A labelled field on glass.
struct OnboardingTextField: View {
    let label: String
    @Binding var text: String
    var placeholder: String = ""
    var contentType: UITextContentType?
    var keyboard: UIKeyboardType = .default
    var suffix: String?

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Text(label)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Site.textMuted)
            Spacer(minLength: Thermyx.Space.s)
            TextField(placeholder, text: $text, prompt: Text(placeholder).foregroundStyle(Thermyx.Site.textFaint))
                .font(ThermyxFont.bodyLarge)
                .foregroundStyle(Thermyx.Site.text)
                .multilineTextAlignment(.trailing)
                .keyboardType(keyboard)
                .textContentType(contentType)
                .autocorrectionDisabled()
            if let suffix {
                Text(suffix)
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Site.textFaint)
            }
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .frame(minHeight: 54)
        .siteGlass(radius: Thermyx.Radius.control)
        .accessibilityElement(children: .combine)
    }
}
