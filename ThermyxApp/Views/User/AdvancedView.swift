import SwiftUI

/// Everything past the everyday settings: the insoles' link, the relay,
/// Apple Health, calibration, and data and role. Admin accounts also get the
/// team's hardware tools, fenced off in their own panel at the end.
struct AdvancedView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var health: ThermyxHealthService
    @Environment(\.isThermyxAdmin) private var isAdmin

    @State private var showingPairing = false
    @State private var showingRoleConfirmation = false
    @State private var showingDeleteConfirmation = false
    @State private var deleteResult: String?
    @State private var legalDocument: LegalDocument.Kind?

    private var unit: TemperatureUnit { settings.temperatureUnit }

    /// Admin accounts, or `-ThermyxAdmin` in a debug build.
    private var showsAdmin: Bool {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-ThermyxAdmin") { return true }
        #endif
        return isAdmin
    }

    var body: some View {
        ThermyxDetailScreen(title: "Advanced", backTitle: "Device") {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                DeviceHealthStrip(now: context.date)
            }
            // Texting the circle, watchers and AI Insights all go through it.
            RelayConnectionCard(settings: settings, role: "wearer")
            healthSection
                .id("health")
            CalibrationSettingsSection(baseline: viewModel.baseline, settings: settings)
            dataSection
            legalRow
            if showsAdmin {
                AdminPanel {
                    DemoModeControl(viewModel: viewModel, ble: viewModel.ble)
                    BoardSettingsSection(board: viewModel.board, ble: viewModel.ble)
                    sensorLayout
                }
                .id("admin")
            }
        }
        .sheet(item: $legalDocument) { kind in
            LegalSheet(selection: kind)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showingPairing) {
            DeviceProfileSheet(roles: roles, settings: settings)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Change role?", isPresented: $showingRoleConfirmation, titleVisibility: .visible) {
            Button("Change role", role: .destructive) { roles.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll go back through onboarding. Your contacts and history stay on this phone.")
        }
        .confirmationDialog("Delete my data?", isPresented: $showingDeleteConfirmation, titleVisibility: .visible) {
            Button("Delete my data", role: .destructive) {
                Task { deleteResult = await DataDeletion.deleteEverything(viewModel: viewModel, settings: settings) ?? "Your data was deleted." }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Removes your history, personal baseline, and trusted contacts from this phone, disconnects the relay, and deletes what the relay holds about you, which also ends every watcher's access. Apple Health data stays in the Health app. This cannot be undone.")
        }
        .alert(deleteResult ?? "", isPresented: Binding(get: { deleteResult != nil }, set: { if !$0 { deleteResult = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }

    // MARK: - Health

    private var healthSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            AppleHealthLabel()

            ThermyxGroupedCard {
                Toggle(isOn: $settings.healthKitEnabled) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Connect Health")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(healthStatusDetail)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                }
                .tint(Thermyx.Ink.signal)
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .disabled(!health.isAvailable)
            }

            if health.availability == .denied {
                PermissionPrompt(asset: "AppleHealth", title: "Health access is off",
                                 detail: "", status: .denied,
                                 deniedAction: ("Open Health", ThermyxPermissions.openHealth)) {}
            }

            Text("Thermyx reads steps, walking steadiness, and workouts, and writes sessions as workouts. It never writes a body temperature — the insole measures contact temperature, not core temperature.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .task(id: settings.healthKitEnabled) {
            guard settings.healthKitEnabled else { return }
            await health.requestAuthorization()
        }
    }

    private var healthStatusDetail: String {
        guard health.isAvailable else { return "Not available on this device" }
        switch health.availability {
        case .authorized: return "Connected"
        case .denied: return "Off — turn it on in the Health app"
        case .notDetermined: return "Not connected"
        case .notEntitled: return "Build isn't signed for HealthKit"
        case .unavailable: return "Not available on this device"
        }
    }

    // MARK: - Data and role

    private var dataSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Data and role")

            ThermyxGroupedCard {
                ThermyxValueRow(
                    label: "Retained readings",
                    value: "\(viewModel.history.minuteSamples.count + viewModel.history.hourSamples.count)",
                    monospaced: true
                )
                ThermyxDivider()
                ThermyxValueRow(
                    label: "Shoe size",
                    value: settings.shoeSizeLabel ?? "Not set"
                )
                ThermyxDivider()
                ThermyxValueRow(label: "Role", value: roles.role?.rawValue ?? "—")
            }

            NavigationLink {
                DataFlowView(settings: settings)
            } label: {
                ThermyxNavigationRow(title: "What leaves your phone?", detail: "Where each kind of data goes, and for how long",
                                     systemImage: "arrow.up.forward.app", iconTint: Thermyx.Ink.textMuted)
            }
            .buttonStyle(.plain)

            Button("Delete my data") { showingDeleteConfirmation = true }
                .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))

            Button("Change role") { showingRoleConfirmation = true }
                .buttonStyle(ThermyxSecondaryButtonStyle())
        }
    }

    // MARK: - Sensor layout
    //
    // A reference, not a readout: where the sensors sit on the sole, so the
    // layout can be checked against the hardware.

    private var sensorLayout: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Sensor layout")

            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    HStack(alignment: .center, spacing: Thermyx.Space.xl) {
                        ForEach(Foot.allCases) { foot in
                            VStack(spacing: 6) {
                                SoleView(foot: foot, reading: viewModel.reading[foot], unit: unit, showsSensorSites: true)
                                    .frame(height: 190)
                                Text(foot.label)
                                    .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Thermyx.Ink.textSupporting)
                            }
                            .frame(maxWidth: .infinity)
                        }
                    }

                    Text(layoutNote)
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var layoutNote: String {
        let base = "Each insole has one temperature sensor, one pressure sensor at the arch (GPIO34), and a motion sensor. The firmware also supports heel and forefoot pressure sensors."
        guard let size = settings.soleSize else {
            return base + " Set a shoe size to see the spacing in millimetres."
        }
        // Heel sensor to forefoot sensor, the span the wiring run has to cover.
        let span = size.millimetres(SoleGeometry.SensorSite.forefoot.position.y - SoleGeometry.SensorSite.heel.position.y)
        return base + String(format: " At %@, the heel-to-forefoot sensor span is %.0f mm.", settings.shoeSizeLabel ?? size.label, span)
    }

    // MARK: - Legal

    private var legalRow: some View {
        VStack(spacing: Thermyx.Space.m) {
            Button { legalDocument = .privacy } label: {
                ThermyxNavigationRow(
                    title: "Privacy & terms",
                    detail: "How Thermyx handles your data",
                    systemImage: "doc.text",
                    iconTint: Thermyx.Ink.textMuted
                )
            }
            .buttonStyle(.plain)

            Text("Thermyx is an investigational heat-risk warning aid. It does not measure core body temperature and does not diagnose heat illness.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Admin: start or leave the demo. Simulated insoles and a month of made-up
/// history, for showing Thermyx without hardware; the real history is kept
/// aside and comes back on exit.
struct DemoModeControl: View {
    @ObservedObject var viewModel: ThermyxViewModel
    @ObservedObject var ble: ThermyxBLEService

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Demo mode") {
                Text(ble.isDemoMode ? "Running" : "Off")
                    .foregroundStyle(ble.isDemoMode ? Thermyx.Ink.ember : Thermyx.Ink.textMuted)
            }
            Text("Simulated insoles that respond to every control, with a month of made-up history behind Insights. Real insoles disconnect while it runs; your real history is set aside, never overwritten, and comes back when you exit.")
                .font(ThermyxFont.caption)
                .foregroundStyle(Thermyx.Ink.textMuted)
                .fixedSize(horizontal: false, vertical: true)
            if ble.isDemoMode {
                Button("Exit demo") { viewModel.exitDemo() }
                    .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ember, border: Thermyx.Tint.emberBorder))
            } else {
                Button {
                    Task { await viewModel.startDemo() }
                } label: {
                    Label(viewModel.isStartingDemo ? "Starting…" : "Start demo", systemImage: "play.fill")
                }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.ember, foreground: Thermyx.Ink.onEmber))
                .disabled(viewModel.isStartingDemo)
            }
        }
    }
}

/// The team's hardware tools, fenced off from everything a wearer uses: a
/// dashed amber border and a header that says who it's for. Only admin
/// accounts see it.
struct AdminPanel<Content: View>: View {
    @ViewBuilder var content: Content

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous) }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.section) {
            HStack(alignment: .center, spacing: Thermyx.Space.m) {
                Image(systemName: "wrench.and.screwdriver.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(Thermyx.Ink.amber)
                    .frame(width: 36, height: 36)
                    .background(Thermyx.Tint.amberFill, in: RoundedRectangle(cornerRadius: 9, style: .continuous))
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Admin")
                        .font(ThermyxFont.sectionTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text("Hardware test tools for the Thermyx team. Wearers never see this.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Text("Team only")
                    .font(.custom(ThermyxFont.Family.medium, size: 12, relativeTo: .caption))
                    .foregroundStyle(Thermyx.Ink.amber)
                    .padding(.horizontal, 8)
                    .frame(height: 24)
                    .overlay { Capsule().strokeBorder(Thermyx.Tint.amberBorder, lineWidth: 1) }
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            content
        }
        .padding(Thermyx.Space.xl)
        .background(shape.fill(Thermyx.Tint.amberFill.opacity(0.35)))
        .overlay { shape.strokeBorder(Thermyx.Tint.amberBorder, style: StrokeStyle(lineWidth: 1, dash: [6, 4])) }
    }
}

/// A label with an inline editable value, used in the backend card.
struct ThermyxEditableRow: View {
    let label: String
    var placeholder: String = ""
    @Binding var text: String
    var isSecure: Bool = false
    var keyboard: UIKeyboardType = .default

    var body: some View {
        HStack(spacing: Thermyx.Space.m) {
            Text(label)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSupporting)
                .frame(width: 96, alignment: .leading)

            Group {
                if isSecure {
                    SecureField(placeholder, text: $text)
                } else {
                    TextField(placeholder, text: $text)
                }
            }
            .font(ThermyxFont.body)
            .foregroundStyle(Thermyx.Ink.textPrimary)
            .multilineTextAlignment(.trailing)
            .keyboardType(keyboard)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.s)
        .frame(minHeight: Thermyx.minimumTapTarget)
    }
}

private extension Double {
    func rounded(toNearest step: Double) -> Double {
        (self / step).rounded() * step
    }
}
