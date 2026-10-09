import SwiftUI

struct OnboardingFlow: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var step: Int = {
        #if DEBUG
        return ThermyxPreviewHarness.initialOnboardingStep
        #else
        return 0
        #endif
    }()
    @State private var selectedRole: ThermyxRole = .user
    @State private var name = ""
    @State private var watchedName = ""
    @State private var pairingCode = "THERMYX-01"
    @State private var calibrating = false

    /// The wearer gets a fourth step, calibration; a watcher finishes at pairing.
    private var lastStep: Int { selectedRole == .user ? 3 : 2 }

    var body: some View {
        ZStack {
            AuroraBackground()

            VStack(spacing: Thermyx.Space.wide) {
                OnboardingHeader(step: step, total: lastStep + 1)

                Group {
                    switch step {
                    case 0: OnboardingIntro()
                    case 1: OnboardingRole(selection: $selectedRole)
                    case 3: OnboardingCalibrate { calibrating = true }
                    default:
                        OnboardingPair(
                            role: selectedRole,
                            name: $name,
                            watchedName: $watchedName,
                            pairingCode: $pairingCode,
                            settings: settings
                        )
                    }
                }
                .frame(maxHeight: .infinity)
                // Re-running the entrance stagger on each step is the point:
                // every screen rises in the same way.
                .id(step)

                Button(step == lastStep ? (step == 3 ? "Calibrate later" : "Enter Thermyx") : "Continue") { advance() }
                    .buttonStyle(ThermyxPrimaryButtonStyle())
                    .riseIn(delay: step == 0 ? 0.38 : 0.2)
            }
            .padding(.horizontal, Thermyx.Space.wide)
            .padding(.top, Thermyx.Space.m)
            .padding(.bottom, 32)
        }
        .onAppear { startScanIfNeeded(for: step) }
        .onChange(of: step) { _, newValue in
            startScanIfNeeded(for: newValue)
        }
        .onDisappear { if viewModel.isScanning { viewModel.toggleScan() } }
        .fullScreenCover(isPresented: $calibrating, onDismiss: { advance() }) {
            NavigationStack { CalibrationView(viewModel: viewModel, settings: settings) }
                .environmentObject(viewModel)
        }
    }

    /// Starts scanning as the pairing step appears, but only for the wearer —
    /// a watcher never touches the insole.
    private func startScanIfNeeded(for step: Int) {
        guard step == 2, selectedRole == .user, !viewModel.anyConnected, !viewModel.isScanning else { return }
        viewModel.toggleScan()
    }

    private func advance() {
        if step < lastStep {
            withAnimation(.easeOut(duration: 0.25)) { step += 1 }
            return
        }
        roles.complete(
            role: selectedRole,
            name: name.trimmed.isEmpty ? (selectedRole == .user ? "Thermyx user" : "Trusted member") : name.trimmed,
            watched: watchedName.trimmed.isEmpty ? "Thermyx user" : watchedName.trimmed,
            code: pairingCode.trimmed.isEmpty ? "THERMYX-01" : pairingCode.trimmed
        )
    }
}

// MARK: - Header

struct OnboardingHeader: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: Thermyx.Space.s) {
            Image("ThermyxBadge")
                .resizable().scaledToFit()
                .frame(width: 48, height: 48)
            Text("Thermyx")
                .narrowLabel(ThermyxFont.wordmark, tracking: ThermyxTracking.wordmark, color: Thermyx.Ink.textPrimary)
            Spacer()
            HStack(spacing: 5) {
                ForEach(0..<total, id: \.self) { index in
                    Capsule()
                        .fill(index == step ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting.opacity(0.3))
                        .frame(width: index == step ? 22 : 10, height: 4)
                }
            }
            .animation(.easeOut(duration: 0.25), value: step)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Thermyx, step \(step + 1) of \(total)")
    }
}

// MARK: - Step 1

struct OnboardingIntro: View {
    var body: some View {
        VStack(spacing: Thermyx.Space.l) {
            ZStack {
                ExpandingRings(color: Thermyx.Ink.ice.opacity(0.5), alternateColor: Thermyx.Ink.ember.opacity(0.45))
                OnboardingDemoVideo()
                    .frame(maxHeight: 450)
                    .shadow(color: .black.opacity(0.45), radius: 24, y: 10)
            }
            .frame(maxHeight: .infinity)

            VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                Text("Climate control\nfor every step")
                    .font(ThermyxFont.onboardingHeadlineLarge)
                    .tracking(ThermyxTracking.onboardingHeadlineLarge)
                    .lineSpacing(-2)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .riseIn(delay: 0)
                    .accessibilityAddTraits(.isHeader)

                Text("A smart insole that senses your foot temperature, pressure, and movement — then heats or cools in real time.")
                    .font(ThermyxFont.bodyLarge)
                    .lineSpacing(4)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .riseIn(delay: 0.14)

                HStack(spacing: Thermyx.Space.xs) {
                    capabilityPill("Heat", tint: Thermyx.Ink.amber, fill: Thermyx.Tint.emberFill, border: Thermyx.Tint.emberBorder)
                    capabilityPill("Cool", tint: Thermyx.Ink.ice, fill: Thermyx.Tint.signalFill, border: Thermyx.Tint.signalBorder)
                    capabilityPill("Sense", tint: Thermyx.Ink.textSecondary, fill: Thermyx.Tint.neutralFill, border: Thermyx.Tint.neutralBorder)
                }
                .riseIn(delay: 0.26)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func capabilityPill(_ text: String, tint: Color, fill: Color, border: Color) -> some View {
        Text(text)
            .narrowLabel(ThermyxFont.statusPillLarge, tracking: 1.8, color: tint)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(fill, in: Capsule())
            .overlay { Capsule().strokeBorder(border, lineWidth: 1) }
    }
}

// MARK: - Step 2

struct OnboardingRole: View {
    @Binding var selection: ThermyxRole

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xxl) {
            Spacer(minLength: 0)

            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                Text("How will you use Thermyx?")
                    .font(ThermyxFont.onboardingHeadline)
                    .tracking(ThermyxTracking.onboardingHeadline)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("You can switch roles later under Advanced.")
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            .riseIn(delay: 0)

            VStack(spacing: Thermyx.Space.m) {
                roleCard(.user, title: "I wear the insole", detail: "Live comfort, safety, and thermal control.")
                roleCard(.trustedMember, title: "I'm watching someone", detail: "Get their safety events on your phone.")
            }
            .riseIn(delay: 0.14)

            Spacer(minLength: 0)
        }
    }

    private func roleCard(_ role: ThermyxRole, title: String, detail: String) -> some View {
        let isSelected = selection == role
        return Button {
            selection = role
        } label: {
            HStack(spacing: Thermyx.Space.l) {
                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                    .fill(isSelected ? Thermyx.Tint.iceWash : Thermyx.Tint.neutralFill)
                    .frame(width: 44, height: 44)
                    .overlay {
                        Image(systemName: role.icon)
                            .font(.system(size: 20, weight: .semibold))
                            .foregroundStyle(isSelected ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting)
                    }

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(ThermyxFont.cardTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(detail)
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: Thermyx.Space.xs)

                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(isSelected ? Thermyx.Ink.signal : Thermyx.Ink.textSupporting.opacity(0.35))
            }
            .padding(Thermyx.Space.xxl)
            .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
            .background(
                isSelected ? Thermyx.Tint.signalFill : Thermyx.Ink.deck,
                in: RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous)
                    .strokeBorder(
                        isSelected ? Thermyx.Ink.signal : Thermyx.Ink.hairline,
                        lineWidth: isSelected ? Thermyx.Stroke.emphasis : Thermyx.Stroke.hairline
                    )
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}


/// Onboarding step 4 (wearer only): offer calibration now or later.
struct OnboardingCalibrate: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    let onStart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            Text("Teach Thermyx your normal")
                .font(ThermyxFont.onboardingHeadline)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Wear the insole for about 6 minutes: sit, stand and walk indoors, then the same outside (that half can wait). Thermyx learns how warm your feet usually run for each, sets Auto to what feels comfortable, and learns to tell what you're doing. It all stays on this phone.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("Calibrate now") { onStart() }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .disabled(!viewModel.anyConnected)
            if !viewModel.anyConnected {
                Text("Connect your insole first, or calibrate later from Home.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
            }
            Spacer(minLength: 0)
        }
    }
}
