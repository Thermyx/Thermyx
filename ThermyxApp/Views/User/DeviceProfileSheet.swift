import SwiftUI

/// Reached by tapping the Home header. Pairing first, because that is what a
/// disconnected user came for, then the profile settings that used to have
/// nowhere to live.
struct DeviceProfileSheet: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var name: String = ""
    @State private var showingSizePicker = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                    connectionSection
                    deviceIdentitySection
                    profileSection
                    assistSection
                }
                .padding(Thermyx.Space.screen)
            }
            .scrollIndicators(.hidden)
            .background(Thermyx.Ink.midnight)
            .navigationTitle("Device & profile")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { commit(); dismiss() }
                }
            }
        }
        .onAppear { name = roles.profileName }
        .onDisappear {
            commit()
            if viewModel.isScanning { viewModel.toggleScan() }
        }
    }

    private func commit() {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        roles.profileName = trimmed.isEmpty ? roles.profileName : trimmed
    }

    // MARK: - Connection

    @ViewBuilder
    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Insole")

            if viewModel.anyConnected {
                ForEach(viewModel.connectedFeet) { foot in
                    connectedCard(foot)
                }
            }

            if !viewModel.bothConnected {
                Text(viewModel.anyConnected
                     ? "Hold the other insole's button for three seconds until its light pulses blue."
                     : "Hold an insole button for three seconds until the light pulses blue.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)

                Button(viewModel.isScanning ? "Stop scanning" : "Scan for Thermyx") {
                    viewModel.toggleScan()
                }
                .buttonStyle(ThermyxPrimaryButtonStyle())

                deviceList
            }
        }
    }

    private func connectedCard(_ foot: Foot) -> some View {
        ThermyxCard(border: Thermyx.Tint.liveBorder) {
            HStack(spacing: Thermyx.Space.l) {
                SoleView(foot: foot, reading: viewModel.reading[foot], unit: settings.temperatureUnit)
                    .frame(height: 48)
                VStack(alignment: .leading, spacing: 3) {
                    Text(viewModel.ble.names[foot] ?? "\(foot.label) insole")
                        .font(ThermyxFont.cardTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                    Text("\(foot.label) · connected")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.ice)
                }
                Spacer(minLength: Thermyx.Space.xs)
                Button("Disconnect") { viewModel.disconnect(foot) }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
                    .frame(width: 128)
            }
        }
    }

    @ViewBuilder
    private var deviceList: some View {
        if viewModel.ble.discovered.isEmpty {
            ThermyxEmptyState(
                title: viewModel.isScanning ? "Searching…" : "Nothing found yet",
                message: viewModel.isScanning
                    ? "Keep the insole within a few metres of your phone."
                    : "Start a scan to look for nearby Thermyx insoles.",
                systemImage: "dot.radiowaves.left.and.right"
            )
        } else {
            VStack(spacing: Thermyx.Space.s) {
                ForEach(viewModel.ble.discovered) { device in
                    DiscoveredDeviceRow(device: device) { foot in
                        viewModel.connect(to: device, as: foot)
                    }
                    .opacity(device.isStrong ? 1 : 0.65)
                }
            }
        }
    }

    // MARK: - Device identity

    private var deviceIdentitySection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Device")
            ThermyxGroupedCard {
                ThermyxEditableRow(label: "Device ID", placeholder: "thermyx-ab12cd", text: $settings.deviceID)
                ThermyxDivider()
                ThermyxValueRow(label: "Pairing code", value: roles.pairingCode, valueFont: ThermyxFont.rowTitle, valueTracking: 2)
            }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Profile")

            ThermyxGroupedCard {
                HStack(spacing: Thermyx.Space.m) {
                    Text("Name")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                        .frame(width: 96, alignment: .leading)
                    TextField("Your name", text: $name)
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .multilineTextAlignment(.trailing)
                        .textContentType(.givenName)
                }
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.s)
                .frame(minHeight: Thermyx.minimumTapTarget)

                ThermyxDivider()

                Button { showingSizePicker = true } label: {
                    HStack(spacing: Thermyx.Space.m) {
                        Text("Shoe size")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                        Spacer(minLength: Thermyx.Space.xs)
                        Text(settings.soleSize?.label ?? "Not set")
                            .font(ThermyxFont.body)
                            .monospacedDigit()
                            .foregroundStyle(settings.soleSize == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textPrimary)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Thermyx.Ink.textFaint)
                    }
                    .padding(.horizontal, Thermyx.Space.xl)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                    .contentShape(.rect)
                }
                .buttonStyle(.plain)
            }

            if let size = settings.soleSize {
                Text("Insole \(String(format: "%.0f", size.lengthMM)) mm long, \(String(format: "%.0f", size.widthMM)) mm at the ball. Trim only along the toe lines.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(isPresented: $showingSizePicker) {
            SoleSizePicker(settings: settings)
                .presentationDetents([.medium, .large])
                .presentationBackground(Thermyx.Ink.midnight)
        }
    }

    // MARK: - Assistance

    private var assistSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Suggestions")

            ThermyxGroupedCard {
                Toggle(isOn: $settings.aiSuggestionsEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Suggest what to do next")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("Shown on Home, worked out on this phone")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                }
                .tint(Thermyx.Ink.signal)
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
                .frame(minHeight: Thermyx.minimumTapTarget)
            }

            Text("Thermyx uses your live readings to suggest one next step under the risk level on Home: take shade, warm gradually, check your fit. The suggestions are simple rules that run on this phone; nothing is sent anywhere. Off by default.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Sole size.
///
/// Every US size is listed so the range is legible at a glance, but only the
/// sizes the prototype is actually cut for can be chosen. Hiding the rest
/// would leave a wearer wondering whether their size exists; showing them
/// disabled says plainly that it does, just not yet.
struct SoleSizePicker: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: Thermyx.Space.l) {
                    ThermyxCard(fill: Thermyx.Tint.signalFill, border: Thermyx.Tint.signalBorder) {
                        VStack(alignment: .leading, spacing: 6) {
                            SectionLabel("Available now", color: Thermyx.Ink.ice)
                            Text("The Thermyx platform is built for US men's 11–12. The trim lines, the protected no-cut zone, and the thermal cassette are all cut for that range. Other sizes are on the roadmap.")
                                .font(ThermyxFont.caption)
                                .foregroundStyle(Thermyx.Ink.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }

                    LazyVGrid(
                        columns: Array(repeating: GridItem(.flexible(), spacing: Thermyx.Space.xs), count: 4),
                        spacing: Thermyx.Space.xs
                    ) {
                        ForEach(SoleSize.all) { size in
                            sizeCell(size)
                        }
                    }
                }
                .padding(Thermyx.Space.screen)
            }
            .scrollIndicators(.hidden)
            .background(Thermyx.Ink.midnight)
            .navigationTitle("Sole size")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } }
            }
        }
    }

    private func sizeCell(_ size: SoleSize) -> some View {
        let isSelected = settings.soleSize?.usMens == size.usMens
        let isEnabled = size.isSupported
        return Button {
            guard isEnabled else { return }
            settings.soleSize = size
        } label: {
            VStack(spacing: 1) {
                Text(size.label)
                    .font(ThermyxFont.rowTitleRegular)
                    .monospacedDigit()
                    .foregroundStyle(
                        isSelected ? Thermyx.Ink.onSignal
                            : (isEnabled ? Thermyx.Ink.textPrimary : Thermyx.Ink.textFaint)
                    )
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if isEnabled {
                    Text("\(Int(size.lengthMM)) mm")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel,
                                     color: isSelected ? Thermyx.Ink.onSignal : Thermyx.Ink.ice)
                }
            }
            .frame(maxWidth: .infinity)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .background(
                isSelected ? Thermyx.Ink.signal : Thermyx.Tint.neutralFill,
                in: RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous)
                    .strokeBorder(
                        isEnabled && !isSelected ? Thermyx.Tint.liveBorder : .clear,
                        lineWidth: Thermyx.Stroke.hairline
                    )
            }
            .opacity(isEnabled ? 1 : 0.4)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .disabled(!isEnabled)
        .accessibilityLabel(isEnabled ? size.label : "\(size.label), not available yet")
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }
}
