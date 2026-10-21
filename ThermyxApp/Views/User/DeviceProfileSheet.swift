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
            .background(Thermyx.Ink.midnight.ignoresSafeArea())
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
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
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
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Device")
            ThermyxGroupedCard {
                ThermyxValueRow(
                    label: "Relay ID",
                    value: settings.deviceID.isEmpty ? "Not connected" : settings.deviceID,
                    valueFont: ThermyxFont.rowTitle,
                    valueTracking: 0
                )
            }
        }
    }

    // MARK: - Profile

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
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

                ShoeSizeField(settings: settings, glass: false)
                    .padding(.horizontal, Thermyx.Space.xl)
                    .padding(.vertical, Thermyx.Space.xs)
            }
        }
    }

    // MARK: - Guidance

    private var assistSection: some View {
        GuidanceSection(settings: settings, store: viewModel.baseline)
    }
}
