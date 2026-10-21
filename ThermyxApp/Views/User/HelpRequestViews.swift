import SwiftUI

/// "Ask for help": a message to the trusted circle without calling 911.
/// A preset says what's wrong, a short note says the rest, and the location
/// goes along when the wearer shares it in emergencies.
struct HelpRequestSheet: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var alerts: ThermyxAlertCoordinator
    @ObservedObject var settings: ThermyxSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var preset: ThermyxAlertCoordinator.HelpPreset?
    @State private var note = ""
    @State private var sending = false
    @State private var result: String?
    @FocusState private var noteFocused: Bool

    private static let noteLimit = 80
    private var canSend: Bool { settings.isPairedWithRelay && settings.relayRole == "wearer" && !sending && result == nil }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    Text("Ask for help")
                        .font(ThermyxFont.display)
                        .tracking(-0.4)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .accessibilityAddTraits(.isHeader)
                    Text("Your circle gets a text and a notification now. This doesn't call 911; if it's an emergency, hold the 911 button instead.")
                        .font(ThermyxFont.bodySmall)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }

                LazyVGrid(columns: [GridItem(.flexible(), spacing: Thermyx.Space.xs), GridItem(.flexible(), spacing: Thermyx.Space.xs)],
                          spacing: Thermyx.Space.xs) {
                    ForEach(ThermyxAlertCoordinator.HelpPreset.allCases) { option in
                        let on = preset == option
                        Button { preset = on ? nil : option } label: {
                            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                                Image(systemName: option.symbol)
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(on ? Thermyx.Ink.onPrimary : Thermyx.Ink.amber)
                                Text(option.label)
                                    .font(ThermyxFont.rowTitle)
                                    .foregroundStyle(on ? Thermyx.Ink.onPrimary : Thermyx.Ink.textPrimary)
                            }
                            .frame(maxWidth: .infinity, minHeight: 76, alignment: .leading)
                            .padding(Thermyx.Space.m)
                            .background(on ? Thermyx.Ink.textPrimary : Thermyx.Ink.deck,
                                        in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                                    .strokeBorder(on ? Color.clear : Thermyx.Ink.hairline, lineWidth: 1)
                            }
                        }
                        .buttonStyle(.plain)
                        .sensoryFeedback(.selection, trigger: on)
                        .accessibilityAddTraits(on ? .isSelected : [])
                    }
                }

                VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                    HStack {
                        SectionLabel("Add a note")
                        Spacer()
                        Text("\(note.count)/\(Self.noteLimit)")
                            .font(ThermyxFont.monoCaption)
                            .foregroundStyle(note.count >= Self.noteLimit ? Thermyx.Ink.amber : Thermyx.Ink.textFaint)
                    }
                    TextField("Where you are, what you need", text: $note, axis: .vertical)
                        .lineLimit(2...3)
                        .focused($noteFocused)
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                        .padding(Thermyx.Space.m)
                        .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous)
                                .strokeBorder(noteFocused ? Thermyx.Tint.liveBorder : Thermyx.Ink.hairline, lineWidth: 1)
                        }
                        .onChange(of: note) { _, value in
                            if value.count > Self.noteLimit { note = String(value.prefix(Self.noteLimit)) }
                        }
                    Text(settings.shareLocationDuringEvents ? "Your location goes with it." : "Your location won't be shared (it's off in What your circle gets).")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }

                CircleMessageBubble(text: preview, caption: "What they'll get")

                if let result {
                    Label(result, systemImage: result.hasPrefix("Sent") ? "checkmark.circle.fill" : "exclamationmark.circle")
                        .font(ThermyxFont.bodySmall)
                        .foregroundStyle(result.hasPrefix("Sent") ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !settings.isPairedWithRelay {
                    Text("Your circle can't be reached yet. Connect to the relay under Safety → Advanced.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    sending = true
                    alerts.askForHelp(preset, note: note, reading: viewModel.reading, settings: settings) { outcome in
                        sending = false
                        result = outcome
                    }
                } label: {
                    Label(sending ? "Sending…" : "Send to my circle", systemImage: "paperplane.fill")
                }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.amber, foreground: Thermyx.Ink.onEmber))
                .disabled(!canSend)

                Button(result == nil ? "Cancel" : "Done") { dismiss() }
                    .font(ThermyxFont.controlLabel)
                    .foregroundStyle(Thermyx.Ink.link)
                    .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget)
                    .padding(.bottom, Thermyx.Space.l)
            }
            .padding(Thermyx.Space.screen)
        }
        .scrollDismissesKeyboard(.interactively)
        .background(Thermyx.Ink.midnight.ignoresSafeArea())
    }

    private var preview: String {
        var detail = ThermyxCircleDetail()
        detail.name = settings.circleName.isEmpty ? nil : settings.circleName
        detail.unit = settings.temperatureUnit == .celsius ? "C" : "F"
        detail.time = ThermyxCircleDetail.localTime(.now)
        detail.help = preset?.rawValue
        detail.note = ThermyxCircleMessage.plainNote(note)
        return ThermyxCircleMessage.text(level: ThermyxRiskLevel.normal.rawValue, kind: "help", detail: detail,
                                         locationConsent: settings.shareLocationDuringEvents,
                                         location: settings.shareLocationDuringEvents ? .init(latitude: 29.76043, longitude: -95.36981) : nil)
    }
}

/// Safety: send a labelled test to the whole circle, to check it reaches them.
struct CircleTestButton: View {
    @ObservedObject var alerts: ThermyxAlertCoordinator
    @ObservedObject var settings: ThermyxSettingsStore
    @State private var result: String?
    @State private var confirming = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            Button { confirming = true } label: {
                Label("Send a test alert to my circle", systemImage: "checkmark.message")
            }
            .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))
            .disabled(!settings.isPairedWithRelay)
            Text(result ?? "Your contacts get a text marked TEST, and watchers a notification, so you know it reaches them.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(result == nil ? Thermyx.Ink.textFaint : Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Send a test to your circle?", isPresented: $confirming, titleVisibility: .visible) {
            Button("Send test") {
                alerts.sendCircleTest(settings: settings) { result = $0 }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It says TEST and \"No action needed\". You can send one every 10 minutes.")
        }
    }
}
