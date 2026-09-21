import SwiftUI

/// Step three. For the wearer this is a live scan with a radar sweep; for a
/// watcher it is the pairing code and backend the two phones share.
struct OnboardingPair: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    let role: ThermyxRole
    @Binding var name: String
    @Binding var watchedName: String
    @Binding var pairingCode: String
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var showingBackend = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                if role == .user {
                    RadarSweep()
                        .frame(height: 200)
                        .frame(maxWidth: .infinity)
                        .riseIn(delay: 0)
                }

                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    Text(role == .user ? "Looking for your insole" : "Connect to your user")
                        .font(ThermyxFont.onboardingHeadline)
                        .tracking(ThermyxTracking.onboardingHeadline)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityAddTraits(.isHeader)

                    Text(role == .user
                         ? "Hold the insole button for three seconds until the light pulses blue."
                         : "Use the same pairing code and backend address on both phones.")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .riseIn(delay: 0.1)

                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    field("Your name", text: $name, placeholder: "Name")

                    if role == .trustedMember {
                        field("Who you're watching", text: $watchedName, placeholder: "Their name")
                    }

                    field("Pairing code", text: $pairingCode, placeholder: "THERMYX-01", emphasized: true, tracking: 3)

                    if role == .user { discoveryList }

                    backendDisclosure
                }
                .riseIn(delay: 0.2)
            }
            .padding(.bottom, Thermyx.Space.m)
        }
        .scrollIndicators(.hidden)
    }

    private func field(
        _ label: String,
        text: Binding<String>,
        placeholder: String,
        emphasized: Bool = false,
        tracking: CGFloat = 0
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(label)
            TextField(placeholder, text: text)
                .font(ThermyxFont.bodyLarge)
                .tracking(tracking)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .autocorrectionDisabled()
                .padding(.horizontal, Thermyx.Space.xl)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                        .strokeBorder(
                            emphasized ? Thermyx.Ink.signal : Thermyx.Tint.neutralBorder,
                            lineWidth: emphasized ? Thermyx.Stroke.emphasis : Thermyx.Stroke.hairline
                        )
                }
        }
    }

    // MARK: - Discovery
    //
    // Two insoles, paired independently. Neither is required to move on: a
    // wearer who only has one today should not be blocked at onboarding.

    @ViewBuilder
    private var discoveryList: some View {
        VStack(spacing: Thermyx.Space.s) {
            HStack(spacing: Thermyx.Space.s) {
                ForEach(Foot.allCases) { foot in
                    footStatus(foot)
                }
            }

            if viewModel.ble.discovered.isEmpty {
                HStack(spacing: Thermyx.Space.m) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(Thermyx.Ink.ice)
                    Text(viewModel.isScanning ? "Searching for nearby insoles…" : "Not scanning")
                        .font(ThermyxFont.bodySmall)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                    Spacer(minLength: 0)
                    if !viewModel.isScanning {
                        Button("Scan") { viewModel.toggleScan() }
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.ice)
                    }
                }
                .padding(Thermyx.Space.xl)
                .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                .background(Thermyx.Tint.liveFill.opacity(0.6), in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                        .strokeBorder(Thermyx.Tint.liveBorder.opacity(0.7), lineWidth: Thermyx.Stroke.hairline)
                }
            } else {
                ForEach(viewModel.ble.discovered) { device in
                    DiscoveredDeviceRow(device: device) { foot in
                        viewModel.connect(to: device, as: foot)
                    }
                    .opacity(device.isStrong ? 1 : 0.65)
                }
            }

            Text("You can pair one insole now and the other later. Thermyx never shows one foot's reading for the other.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Per-foot pairing control.
    ///
    /// These used to be status pills with button chrome and no action, which
    /// is the worst of both: they looked tappable and were not. Now the two
    /// states are visibly different things — an unconnected foot is a button
    /// that scans for it, a connected one is a settled status that does not
    /// invite a tap.
    @ViewBuilder
    private func footStatus(_ foot: Foot) -> some View {
        if viewModel.isConnected(foot) {
            footPill(foot, isOn: true)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(foot.label) insole connected")
        } else {
            Button {
                viewModel.scanFor(foot)
            } label: {
                footPill(foot, isOn: false)
                    .contentShape(.capsule)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Scan for the \(foot.label.lowercased()) insole")
            .accessibilityHint("Not connected yet")
        }
    }

    private func footPill(_ foot: Foot, isOn: Bool) -> some View {
        HStack(spacing: 6) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "dot.radiowaves.left.and.right")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(isOn ? Thermyx.Ink.ice : Thermyx.Ink.ice)
            VStack(spacing: 0) {
                Text(foot.label)
                    .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.axisLabel,
                                 color: isOn ? Thermyx.Ink.ice : Thermyx.Ink.textPrimary)
                Text(isOn ? "Connected" : "Tap to scan")
                    .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel,
                                 color: isOn ? Thermyx.Ink.textSupporting : Thermyx.Ink.ice)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: Thermyx.minimumTapTarget)
        .background(isOn ? Thermyx.Tint.liveFill : Thermyx.Tint.neutralFill, in: Capsule())
        .overlay {
            Capsule().strokeBorder(isOn ? Thermyx.Tint.liveBorder : Thermyx.Tint.neutralBorder,
                                   lineWidth: Thermyx.Stroke.hairline)
        }
    }

    // MARK: - Backend

    private var backendDisclosure: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            Button {
                withAnimation(.easeOut(duration: 0.22)) { showingBackend.toggle() }
            } label: {
                HStack(spacing: 6) {
                    Text("Advanced: shared backend setup")
                        .narrowLabel(ThermyxFont.statusPill, tracking: 1.8, color: Thermyx.Ink.textSupporting)
                    Image(systemName: showingBackend ? "chevron.up" : "chevron.down")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                    Spacer(minLength: 0)
                }
                .frame(minHeight: Thermyx.minimumTapTarget)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityAddTraits(showingBackend ? [.isButton, .isSelected] : .isButton)

            if showingBackend {
                ThermyxGroupedCard {
                    ThermyxEditableRow(label: "Endpoint", placeholder: "https://…", text: $settings.backendURL, keyboard: .URL)
                    ThermyxDivider()
                    ThermyxEditableRow(label: "Token", placeholder: "Optional", text: $settings.backendToken, isSecure: true)
                    ThermyxDivider()
                    ThermyxEditableRow(label: "Device ID", placeholder: "thermyx-right-01", text: $settings.deviceID)
                }
                .transition(.opacity)
            }
        }
    }
}

/// The scanning radar: static rings, a rotating conic sweep, a core, and one
/// expanding ring. Under Reduce Motion the sweep and ring stop and the core
/// stays lit — the screen still says "scanning", it just doesn't spin.
struct RadarSweep: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        TimelineView(.animation(minimumInterval: reduceMotion ? nil : 1.0 / 30.0, paused: reduceMotion)) { context in
            let angle = reduceMotion
                ? 0
                : (context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 2.8) / 2.8) * 360

            ZStack {
                ForEach([170.0, 112.0, 56.0], id: \.self) { diameter in
                    Circle()
                        .strokeBorder(Thermyx.Ink.ice.opacity(diameter == 56 ? 0.4 : (diameter == 112 ? 0.3 : 0.22)), lineWidth: 1)
                        .frame(width: diameter, height: diameter)
                }

                if !reduceMotion {
                    Circle()
                        .fill(
                            AngularGradient(
                                gradient: Gradient(stops: [
                                    .init(color: Thermyx.Ink.ice.opacity(0.42), location: 0),
                                    .init(color: Thermyx.Ink.ice.opacity(0), location: 0.28)
                                ]),
                                center: .center
                            )
                        )
                        .frame(width: 170, height: 170)
                        .rotationEffect(.degrees(angle))

                    ExpandingRings(color: Thermyx.Ink.ice.opacity(0.4), baseSize: 190, count: 1, duration: 3.2, stagger: 0)
                }

                Circle()
                    .fill(Thermyx.Ink.ice)
                    .frame(width: 14, height: 14)
            }
        }
        .accessibilityElement()
        .accessibilityLabel("Scanning for nearby insoles")
    }
}
