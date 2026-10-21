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
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
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

            Text("Your alerts are worked out on this phone, and none of this is sent anywhere. Thermyx needs about \(PersonalBaseline.calibrationMinutes) calm minutes of wear to learn what's normal for you. After that, a foot running well above your usual, steps much less steady than usual, or a fast rise can add a Caution. It can only make things more careful, never less. A session name is just a note for you.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            if store.baseline.minutesLearned > 0 {
                Button("Forget what's usual for me") { confirmingReset = true }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
            }
        }
        .confirmationDialog("Start learning again?", isPresented: $confirmingReset, titleVisibility: .visible) {
            Button("Reset", role: .destructive) { store.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Thermyx forgets what's usual for you and learns it again over your next \(PersonalBaseline.calibrationMinutes) calm minutes of wear.")
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
    @ObservedObject private var cloud = ThermyxCloudService.shared

    private struct Item: Identifiable {
        let title: String
        let detail: String
        var id: String { title }
    }

    private var staysHere: [Item] {
        [
            Item(title: "Live readings", detail: "Shown live and folded into minute summaries. Raw packets are not kept."),
            Item(title: "History", detail: "Minute summaries for 7 days, hourly summaries for 180 days, risk events for 30 days. Older data is deleted automatically."),
            Item(title: "What's usual for you", detail: "Your usual foot temperature and steadiness. Deleted if unused for 90 days. Copied to your account only if you turn on Back up to my account."),
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

    private var account: [Item] {
        [
            Item(title: "Back up to my account — \(cloud.backupEnabled ? "on" : "off")",
                 detail: cloud.backupEnabled
                    ? "Your profile, settings, what Thermyx has learned about you, and your recovery checks are copied to a private space in your account, so a new phone can pick up where you left off. Only you can read it. Your history, contacts and location stay on this phone."
                    : "Nothing is copied. Turn it on in Device to keep your profile, calibration and recoveries with your account."),
            Item(title: "Anonymous numbers for new wearers — \(cloud.populationEnabled ? "on" : "off")",
                 detail: cloud.populationEnabled
                    ? "Once a month, a few rounded averages from your own calm minutes go out with no name, email or account ID, grouped only by what you mostly use Thermyx for and an age band. They can't be traced back to you, and expire within about five weeks."
                    : "Nothing is sent. Turn it on in Device to start from what's typical for people like you, and to add your numbers to that.")
        ]
    }

    private let never = [
        "Raw sensor readings or history",
        "Your trusted contacts' names or numbers, to your account",
        "Your Apple Health data, to anyone",
        "Analytics, ads, or tracking of any kind",
        "Anything to emergency services — Call 911 opens your phone's dialer"
    ]

    var body: some View {
        ThermyxDetailScreen(title: "What leaves your phone?", backTitle: "Advanced") {
            VStack(alignment: .leading, spacing: Thermyx.Space.section) {
                group("Stays on this phone", items: staysHere)
                VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                    SectionLabel(settings.isPairedWithRelay ? "Goes to the relay" : "Would go to the relay (not connected)")
                    list(relay)
                }
                VStack(alignment: .leading, spacing: Thermyx.Space.header) {
                    HStack(spacing: Thermyx.Space.xs) {
                        AIMark(size: 22)
                        SectionLabel("AI Insights — \(settings.aiInsightsEnabled ? "on" : "off")", color: Thermyx.Ink.ai)
                    }
                    list([
                        Item(title: "One day's totals and averages",
                             detail: settings.aiInsightsEnabled
                                ? "Sent through the relay to Anthropic's Claude API, which writes the day's summary. No live readings, name, contacts or location. The relay keeps nothing."
                                : "Nothing is sent. Turn AI Insights on in Device to get a daily summary written by Claude.")
                    ])
                }
                group("Your Thermyx account — only if you turn it on", items: account)
                group("Local weather — only with location allowed", items: [
                    Item(title: "Your location, rounded to about 1 km", detail: "Sent to Open-Meteo during calibration's outdoor half, for the air temperature.")
                ])
                group("Apple Health — only if you turn it on", items: [
                    Item(title: "Walk sessions", detail: "Start, end, and heat-exposure time. Managed in the Health app.")
                ])
                VStack(alignment: .leading, spacing: Thermyx.Space.header) {
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
        }
    }

    private func group(_ title: String, items: [Item]) -> some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
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
/// relay and the wearer's account backup hold about them.
enum DataDeletion {
    @MainActor
    static func deleteEverything(viewModel: ThermyxViewModel, settings: ThermyxSettingsStore,
                                 cloud: ThermyxCloudService = .shared) async -> String? {
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
        // The account's backup too, and both cloud switches go back to off.
        // First, so wiping this phone below isn't backed up as an empty
        // phone. Numbers already sent anonymously can't be traced to this
        // wearer, so they can't be pulled back; they expire on their own.
        let cloudError = await cloud.deleteEverything()
        settings.disconnectRelay()
        settings.contacts = []
        settings.shareLocationDuringEvents = false
        viewModel.history.deleteAll()
        viewModel.recovery.deleteAll()
        await viewModel.history.save()
        viewModel.baseline.deleteAll()
        return [relayError, cloudError].compactMap { $0 }.joined(separator: " ").nilIfEmpty
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}

// MARK: - Demo Mode banner

/// Stamped along the bottom of every screen while Demo Mode runs, in debug
/// and release builds alike, so a screenshot can never pass simulated
/// readings off as live ones. Its Exit button leaves the demo: the simulated
/// insoles disconnect, their made-up history is cleared, and the app goes
/// back to real Bluetooth.
struct DemoModeBanner: ViewModifier {
    @ObservedObject var viewModel: ThermyxViewModel
    @ObservedObject var ble: ThermyxBLEService
    @State private var confirming = false

    init(viewModel: ThermyxViewModel) {
        self.viewModel = viewModel
        self.ble = viewModel.ble
    }

    func body(content: Content) -> some View {
        content.safeAreaInset(edge: .bottom, spacing: 0) {
            if ble.isDemoMode {
                HStack(spacing: Thermyx.Space.m) {
                    Image(systemName: "waveform.path")
                        .font(.system(size: 14, weight: .bold))
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(ble.isFakeInsole ? "Fake insole" : "Simulated insoles")
                            .font(.custom(ThermyxFont.Family.bold, size: 14, relativeTo: .subheadline))
                        Text("Not live sensor data")
                            .font(.custom(ThermyxFont.Family.medium, size: 12, relativeTo: .caption))
                            .opacity(0.8)
                    }
                    Spacer(minLength: Thermyx.Space.s)
                    Button {
                        confirming = true
                    } label: {
                        Text("Exit demo")
                            .font(.custom(ThermyxFont.Family.bold, size: 15, relativeTo: .subheadline))
                            .foregroundStyle(.white)
                            .padding(.horizontal, Thermyx.Space.l)
                            .frame(height: 36)
                            .background(Thermyx.Ink.onEmber, in: Capsule())
                            .frame(minHeight: Thermyx.minimumTapTarget)
                            .contentShape(Capsule())
                    }
                    .buttonStyle(PressableStyle())
                    .accessibilityLabel("Exit the demo")
                    .accessibilityHint("Disconnects the simulated insoles and returns to real Bluetooth.")
                }
                .foregroundStyle(Thermyx.Ink.onEmber)
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.vertical, 2)
                .frame(maxWidth: .infinity)
                .background(Thermyx.Ink.ember.ignoresSafeArea(edges: .bottom))
                .accessibilityElement(children: .contain)
                .confirmationDialog("Leave the demo?", isPresented: $confirming, titleVisibility: .visible) {
                    Button("Exit demo", role: .destructive) { exit() }
                    Button("Keep demoing", role: .cancel) {}
                } message: {
                    Text("The simulated insoles disconnect and the made-up history goes away. Your real history comes back as it was, and Thermyx goes back to real Bluetooth.")
                }
            }
        }
    }

    private func exit() {
        viewModel.exitDemo()
    }
}
