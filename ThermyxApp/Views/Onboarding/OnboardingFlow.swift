import SwiftUI

/// First run: sign in, choose a role, then for a wearer About you, the
/// insoles and calibration; for a watcher, who they watch.
struct OnboardingFlow: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @EnvironmentObject private var account: ThermyxAccountStore
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @StateObject private var health = ThermyxHealthService()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    enum Step: Hashable {
        case welcome, role, about, insoles, calibrate, watch
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
        role == .user ? [.welcome, .role, .about, .insoles, .calibrate] : [.welcome, .role, .watch]
    }
    private var index: Int { steps.firstIndex(of: step) ?? 0 }

    var body: some View {
        ZStack {
            TopographyBackground()
                // Quieter behind forms, so the copy is what's read.
                .opacity(step == .welcome ? 1 : 0.55)
                .animation(.easeInOut(duration: 0.6), value: step)

            VStack(spacing: 0) {
                if step != .welcome {
                    OnboardingTopBar(progress: index, total: steps.count - 1) { go(to: steps[max(index - 1, 0)]) }
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
            WelcomeSlides { go(to: .role) }
        case .role:
            RoleStep(selection: $role) { go(to: role == .user ? .about : .watch) }
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

/// Back, and a segmented progress line, the way iOS setup shows it.
private struct OnboardingTopBar: View {
    let progress: Int
    let total: Int
    let onBack: () -> Void

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Button(action: onBack) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(Thermyx.Site.text)
                    .frame(width: 44, height: 44)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Back")

            HStack(spacing: 6) {
                ForEach(0..<max(total, 1), id: \.self) { i in
                    Capsule()
                        .fill(i < progress ? Thermyx.Site.text : Thermyx.Site.hairlineStrong)
                        .frame(height: 3)
                }
            }
            .animation(SiteMotion.settle, value: progress)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(progress) of \(total)")

            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, Thermyx.Space.m)
        .padding(.top, 4)
    }
}

/// A page: eyebrow, serif headline, one line of context, the content, and
/// the actions pinned above the home indicator.
struct OnboardingPage<Content: View, Actions: View>: View {
    var eyebrow: String?
    let title: String
    var subtitle: String?
    @ViewBuilder var content: Content
    @ViewBuilder var actions: Actions

    var body: some View {
        ScrollViewReader { proxy in
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    if let eyebrow { SiteEyebrow(eyebrow) }
                    RevealHeadline(text: title)
                    if let subtitle {
                        Text(subtitle)
                            .font(ThermyxFont.bodyLarge)
                            .lineSpacing(3)
                            .foregroundStyle(Thermyx.Site.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                content
            }
            .padding(.horizontal, Thermyx.Space.wide)
            .padding(.top, Thermyx.Space.m)
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
                    Rectangle().fill(.ultraThinMaterial)
                        .overlay(Thermyx.Site.bg.opacity(0.55))
                        .ignoresSafeArea()
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

// MARK: - Role

private struct RoleStep: View {
    @Binding var selection: ThermyxRole
    let onContinue: () -> Void

    var body: some View {
        OnboardingPage(eyebrow: "Getting started", title: "How will you use *Thermyx?*",
                       subtitle: "You can change this later in Settings.") {
            VStack(spacing: Thermyx.Space.m) {
                card(.user, title: "I wear the insoles", detail: "Live comfort and safety, and control of heating and cooling.")
                card(.trustedMember, title: "I'm watching someone", detail: "Their safety alerts on your phone. You never control their insoles.")
            }
        } actions: {
            Button(action: onContinue) {
                Label("Continue", systemImage: "arrow.right").labelStyle(TrailingIconLabelStyle())
            }
            .buttonStyle(SitePrimaryButtonStyle())
        }
    }

    private func card(_ role: ThermyxRole, title: String, detail: String) -> some View {
        let selected = selection == role
        return Button {
            withAnimation(SiteMotion.settle) { selection = role }
        } label: {
            HStack(alignment: .top, spacing: Thermyx.Space.l) {
                Image(systemName: role.icon)
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundStyle(selected ? Thermyx.Ink.ice : Thermyx.Site.textMuted)
                    .frame(width: 28)
                    .padding(.top, 2)
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(ThermyxFont.cardTitle)
                        .foregroundStyle(Thermyx.Site.text)
                    Text(detail)
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Site.textMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: Thermyx.Space.xs)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 22))
                    .foregroundStyle(selected ? Thermyx.Ink.signal : Thermyx.Site.hairlineStrong)
                    .contentTransition(.symbolEffect(.replace))
            }
            .padding(Thermyx.Space.xxl)
            .frame(maxWidth: .infinity, alignment: .leading)
            .siteGlass(radius: Thermyx.Radius.section, highlighted: selected)
            .contentShape(Rectangle())
        }
        .buttonStyle(PressableStyle())
        .sensoryFeedback(.selection, trigger: selected)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
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
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
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
