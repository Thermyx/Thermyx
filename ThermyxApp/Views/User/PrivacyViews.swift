import SwiftUI

// MARK: - Guidance

/// Next-step guidance on Home and the personal baseline that may add
/// caution. Called "Personalized guidance" only once a baseline exists.
struct GuidanceSection: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var store: PersonalBaselineStore
    @State private var confirmingReset = false

    private var title: String {
        store.isEnabled && store.baseline.isCalibrated ? "Personalized guidance" : "Guidance"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel(title)

            ThermyxGroupedCard {
                toggle("Show what to do next", detail: "One step under the risk level on Home", isOn: $settings.aiSuggestionsEnabled)
                ThermyxDivider()
                toggle("Learn my normal", detail: baselineDetail, isOn: $store.isEnabled)
                ThermyxDivider()
                HStack {
                    Text("Session label")
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Spacer()
                    TextField("Optional", text: $store.sessionLabel)
                        .multilineTextAlignment(.trailing)
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textSecondary)
                        .submitLabel(.done)
                }
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
                .frame(minHeight: Thermyx.minimumTapTarget)
            }

            Text("Guidance is a set of simple rules that run on this phone, not AI, and nothing is sent anywhere. Learning your normal takes \(PersonalBaseline.calibrationMinutes) calm minutes of wear. After that, a foot temperature well above your usual, steadiness well below it, or a fast rise can add a Caution. It never lowers a level the fixed rules set. A session label is just a note; there is one baseline.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            if store.baseline.minutesLearned > 0 {
                Button("Reset my baseline") { confirmingReset = true }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
            }
        }
        .confirmationDialog("Reset your baseline?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Thermyx forgets your usual readings and calibrates again over the next \(PersonalBaseline.calibrationMinutes) calm minutes.")
        }
    }

    private var baselineDetail: String {
        guard store.isEnabled else { return "Off — fixed rules only" }
        let b = store.baseline
        return b.isCalibrated ? "Learned · adds caution only" : "Calibrating · \(b.minutesLearned)/\(PersonalBaseline.calibrationMinutes) min"
    }

    private func toggle(_ title: String, detail: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(detail)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
            }
        }
        .tint(Thermyx.Ink.signal)
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.m)
        .frame(minHeight: Thermyx.minimumTapTarget)
    }
}

// MARK: - What leaves your phone?

/// A plain account of where each kind of data goes and how long it is kept.
struct DataFlowView: View {
    @ObservedObject var settings: ThermyxSettingsStore

    private struct Item: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    private var staysHere: [Item] {
        [
            Item(title: "Live readings", detail: "Shown live and folded into minute summaries. Raw packets are not kept."),
            Item(title: "History", detail: "Minute summaries for 7 days, hourly summaries for 180 days, risk events for 30 days. Older data is deleted automatically."),
            Item(title: "Personal baseline", detail: "Your usual foot temperature and steadiness. Deleted if unused for 90 days."),
            Item(title: "Trusted contacts", detail: "Names and numbers stay on this phone unless texting is turned on."),
            Item(title: "Relay key", detail: "Kept in the iPhone Keychain.")
        ]
    }

    private var relay: [Item] {
        var items = [
            Item(title: "Your current level and when it changed", detail: "Approved watchers see this. It is deleted 7 days after the last update."),
        ]
        items.append(Item(
            title: "Your location — only during a High, Critical, or SOS event",
            detail: settings.shareLocationDuringEvents
                ? "You've allowed this. It expires after 1 hour and is cleared as soon as the event ends."
                : "Off. You can allow it under Safety → Who can see your status."
        ))
        items.append(Item(
            title: "Contact numbers and alert reasons",
            detail: settings.relayTextingEnabled
                ? "Sent only with an alert so the relay can text your contacts. Not stored."
                : "Not sent: texting is off until it has been tested with real phones."
        ))
        return items
    }

    private let never = [
        "Raw sensor readings, history, or your baseline",
        "Analytics, ads, or tracking of any kind",
        "Anything to emergency services — Call 911 opens your phone's dialer"
    ]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                group("Stays on this phone", items: staysHere)
                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    SectionLabel(settings.isPairedWithRelay ? "Goes to the relay" : "Would go to the relay (not connected)")
                    list(relay)
                }
                group("Apple Health — only if you turn it on", items: [
                    Item(title: "Walk sessions", detail: "Start, end, and heat-exposure time. Managed in the Health app.")
                ])
                VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                    SectionLabel("Never leaves")
                    ThermyxCard(padding: Thermyx.Space.l) {
                        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                            ForEach(never, id: \.self) { line in
                                Label(line, systemImage: "xmark.circle")
                                    .font(ThermyxFont.caption)
                                    .foregroundStyle(Thermyx.Ink.textSecondary)
                            }
                        }
                    }
                }
                Text("The relay is a competition prototype that stores tokens and codes only as hashes, over HTTPS when hosted. Delete my data removes what it holds about you.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(Thermyx.Space.screen)
        }
        .scrollIndicators(.hidden)
        .background(Thermyx.Ink.midnight)
        .navigationTitle("What leaves your phone?")
        .navigationBarTitleDisplayMode(.inline)
    }

    private func group(_ title: String, items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel(title)
            list(items)
        }
    }

    private func list(_ items: [Item]) -> some View {
        ThermyxCard(padding: Thermyx.Space.l) {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                ForEach(items) { item in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.title)
                            .font(ThermyxFont.rowTitleRegular)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(item.detail)
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textMuted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

// MARK: - Delete my data

/// Removes what Thermyx stored on this phone and, when connected, what the
/// relay holds about this wearer.
enum DataDeletion {
    @MainActor
    static func deleteEverything(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore) async -> String? {
        var relayError: String?
        if settings.isPairedWithRelay {
            do {
                if settings.relayRole == "wearer" {
                    try await ThermyxAlertAPIClient().deleteDevice(baseURL: settings.backendURL, token: settings.backendToken)
                } else {
                    try await ThermyxAlertAPIClient().leaveWatching(baseURL: settings.backendURL, token: settings.backendToken)
                }
            } catch ThermyxAlertAPIClient.ClientError.accessRemoved {
                // Already gone on the relay.
            } catch {
                relayError = "This phone's data was deleted, but the relay couldn't be reached. Its copy expires within 7 days, or ask the team to remove this device."
            }
        }
        settings.disconnectRelay()
        settings.contacts = []
        settings.shareLocationDuringEvents = false
        viewModel.history.deleteAll()
        await viewModel.history.save()
        viewModel.baseline.deleteAll()
        return relayError
    }
}

// MARK: - Demo Mode banner

/// Stamped along the bottom of every screen while Demo Mode runs, in debug
/// and release builds alike, so a screenshot can never pass simulated
/// readings off as live ones.
struct DemoModeBanner: ViewModifier {
    @ObservedObject var ble: ThermyxBLEService

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if ble.isDemoMode {
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
