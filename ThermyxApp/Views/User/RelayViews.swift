import SwiftUI

// MARK: - Connect to relay

/// Pairs this phone with the relay using a one-time code. Wearers get a code
/// from the team (`npm run admin wearer-code`); watchers get one from the
/// wearer's Safety screen. No token is ever typed by hand.
struct RelayConnectionCard: View {
    @ObservedObject var settings: ThermyxSettingsStore
    /// "wearer" or "watcher": which kind of code this screen expects.
    let role: String
    /// The watcher's name, shown to the wearer on their approval list.
    var watcherName: String = ""

    @State private var url = ""
    @State private var code = ""
    @State private var isWorking = false
    @State private var error: String?
    @State private var showingDisconnect = false

    private let client = ThermyxAlertAPIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Relay")
            if settings.isPairedWithRelay {
                connected
            } else {
                form
            }
        }
        .confirmationDialog("Disconnect from the relay?", isPresented: $showingDisconnect, titleVisibility: .visible) {
            Button("Disconnect", role: .destructive) { settings.disconnectRelay() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(role == "wearer"
                 ? "Watchers will stop receiving your status. You'll need a new code from your team to reconnect."
                 : "You'll stop seeing their status and need a new invite to reconnect.")
        }
    }

    private var connected: some View {
        ThermyxCard(padding: Thermyx.Space.xxl, border: Thermyx.Tint.liveBorder) {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                HStack(spacing: Thermyx.Space.s) {
                    Image(systemName: "checkmark.seal.fill").foregroundStyle(Thermyx.Ink.ice)
                    Text(role == "wearer" ? "Connected as \(settings.deviceID)" : "Connected as a watcher")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                }
                Text(settings.backendURL)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if role == "wearer" {
                    Text(settings.relayTextingEnabled
                         ? "Texting to trusted contacts is on."
                         : "Texting to trusted contacts isn't turned on yet. Approved watchers still see your status.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(settings.relayTextingEnabled ? Thermyx.Ink.textMuted : Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Disconnect") { showingDisconnect = true }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
                    .padding(.top, Thermyx.Space.xs)
            }
        }
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            ThermyxGroupedCard {
                ThermyxEditableRow(label: "Relay", placeholder: "https://…", text: $url, keyboard: .URL)
                ThermyxDivider()
                ThermyxEditableRow(label: "Code", placeholder: "ABCD-2345", text: $code)
            }
            Text(role == "wearer"
                 ? "Get a one-time code from your team. It works once and expires after 10 minutes."
                 : "Ask the person you're watching to invite you from their Safety screen. They'll need to approve you before you see anything.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)

            Button(isWorking ? "Connecting…" : "Connect") { Task { await connect() } }
                .buttonStyle(ThermyxPrimaryButtonStyle())
                .disabled(isWorking || url.isEmpty || code.count < 8)
                .opacity(isWorking || url.isEmpty || code.count < 8 ? 0.5 : 1)

            if let error {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func connect() async {
        isWorking = true
        defer { isWorking = false }
        error = nil
        do {
            let result = try await client.pair(baseURL: url, code: code, name: role == "watcher" ? watcherName : nil)
            guard result.role == role else {
                error = role == "wearer"
                    ? "That's a watcher invite. Wearers connect with a code from the team."
                    : "That's a wearer code. Watchers connect with an invite from the person they're watching."
                return
            }
            settings.completePairing(
                url: url.trimmingCharacters(in: .whitespacesAndNewlines),
                role: result.role,
                token: result.token,
                deviceID: result.deviceID,
                textingEnabled: result.smsEnabled ?? false
            )
            code = ""
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Watchers (wearer side)

/// Who can see the wearer's status. Nobody has access by default: every
/// watcher is approved here, can be removed in one tap, and expires after
/// 90 days unless renewed.
struct WatchersSection: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var alerts: ThermyxAlertCoordinator
    let level: ThermyxRiskLevel

    @State private var watchers: [ThermyxAlertAPIClient.Watcher] = []
    @State private var invite: ThermyxAlertAPIClient.WatcherInvite?
    @State private var error: String?
    @State private var removing: ThermyxAlertAPIClient.Watcher?
    @State private var isLoading = false

    private let client = ThermyxAlertAPIClient()

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Who can see your status")

            if !settings.isPairedWithRelay {
                Text("Nobody. Connect to a relay under Advanced to invite watchers.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                if watchers.isEmpty {
                    Text(isLoading ? "Loading…" : "Nobody yet. Watchers you invite appear here, and see nothing until you approve them.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(Thermyx.Ink.textMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                ForEach(watchers) { watcher in row(watcher) }

                Button {
                    Task { await createInvite() }
                } label: {
                    Label("Invite a watcher", systemImage: "person.badge.plus")
                }
                .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))

                locationConsent
            }

            if let error {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task(id: settings.isPairedWithRelay) { await refresh() }
        .sheet(item: $invite, onDismiss: { Task { await refresh() } }) { invite in
            InviteSheet(invite: invite)
                .presentationDetents([.medium])
                .presentationBackground(Thermyx.Ink.midnight)
        }
        .confirmationDialog(
            "Remove \(removing?.name ?? "this watcher")?",
            isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }),
            titleVisibility: .visible
        ) {
            Button("Remove", role: .destructive) {
                if let watcher = removing { Task { await revoke(watcher) } }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("They lose access immediately and need a new invite to watch again.")
        }
    }

    private func row(_ watcher: ThermyxAlertAPIClient.Watcher) -> some View {
        ThermyxCard(padding: Thermyx.Space.xl, border: watcher.status == "approved" ? Thermyx.Tint.liveBorder : Thermyx.Tint.amberBorder) {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                HStack {
                    Text(watcher.name)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Spacer(minLength: Thermyx.Space.xs)
                    Text(statusText(watcher))
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(watcher.status == "approved" ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                }
                HStack(spacing: Thermyx.Space.xs) {
                    if watcher.status != "approved" {
                        Button(watcher.status == "pending" ? "Approve" : "Renew") { Task { await approve(watcher) } }
                            .buttonStyle(ThermyxPrimaryButtonStyle())
                    } else {
                        Button("Renew 90 days") { Task { await approve(watcher) } }
                            .buttonStyle(ThermyxSecondaryButtonStyle())
                    }
                    Button("Remove") { removing = watcher }
                        .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))
                }
            }
        }
        .accessibilityElement(children: .contain)
    }

    private func statusText(_ watcher: ThermyxAlertAPIClient.Watcher) -> String {
        switch watcher.status {
        case "pending": return "Waiting for your approval"
        case "expired": return "Access expired"
        default:
            if let date = watcher.expiryDate { return "Can see your status until \(date.formatted(date: .abbreviated, time: .omitted))" }
            return "Can see your status"
        }
    }

    /// Location is never shared unless this is on, and even then only during
    /// a High, Critical, or SOS event, for at most an hour.
    private var locationConsent: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            ThermyxGroupedCard {
                Toggle(isOn: Binding(
                    get: { settings.shareLocationDuringEvents },
                    set: { newValue in
                        if newValue { settings.shareLocationDuringEvents = true }
                        else { alerts.stopSharingLocation(level: level, settings: settings) }
                    }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Share my location during a safety event")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("Only with approved watchers, only at High risk, Critical, or SOS, and for at most an hour.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .tint(Thermyx.Ink.signal)
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
            }
            if settings.shareLocationDuringEvents && level.severity >= ThermyxRiskLevel.high.severity {
                Button {
                    alerts.stopSharingLocation(level: level, settings: settings)
                } label: {
                    Label("Stop sharing location", systemImage: "location.slash.fill")
                }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: Thermyx.Ink.amber, foreground: Thermyx.Ink.onEmber))
            }
        }
    }

    // MARK: Actions

    private func refresh() async {
        guard settings.isPairedWithRelay else { watchers = []; return }
        isLoading = true
        defer { isLoading = false }
        do {
            watchers = try await client.listWatchers(baseURL: settings.backendURL, token: settings.backendToken)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func createInvite() async {
        do {
            invite = try await client.createWatcherCode(baseURL: settings.backendURL, token: settings.backendToken)
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func approve(_ watcher: ThermyxAlertAPIClient.Watcher) async {
        do {
            try await client.approveWatcher(id: watcher.id, baseURL: settings.backendURL, token: settings.backendToken)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func revoke(_ watcher: ThermyxAlertAPIClient.Watcher) async {
        removing = nil
        do {
            try await client.revokeWatcher(id: watcher.id, baseURL: settings.backendURL, token: settings.backendToken)
            await refresh()
        } catch {
            self.error = error.localizedDescription
        }
    }
}

extension ThermyxAlertAPIClient.WatcherInvite: Identifiable {
    var id: String { code }
}

/// Shows a one-time watcher code to read out or send.
private struct InviteSheet: View {
    let invite: ThermyxAlertAPIClient.WatcherInvite

    private var expiry: String {
        ThermyxAlertAPIClient.parseDate(invite.expiresAt)?.formatted(date: .omitted, time: .shortened) ?? "in 10 minutes"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.l) {
            SectionLabel("Watcher invite")
            Text(invite.code)
                .font(ThermyxFont.pullStat)
                .tracking(3)
                .monospaced()
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .textSelection(.enabled)
            Text("Works once and expires at \(expiry). On their phone: choose Trusted member, then enter this code under Settings → Relay. You'll still need to approve them before they see anything.")
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
            ShareLink(item: "Thermyx watcher invite: \(invite.code) (works once, expires at \(expiry))") {
                Label("Send invite", systemImage: "square.and.arrow.up")
            }
            .buttonStyle(ThermyxPrimaryButtonStyle())
            Spacer(minLength: 0)
        }
        .padding(Thermyx.Space.wide)
    }
}

// MARK: - Texting preview

/// While texting is off, show exactly what a trusted contact would receive —
/// clearly labelled as a preview that was not sent.
struct TextingPreviewCard: View {
    @ObservedObject var settings: ThermyxSettingsStore
    let level: ThermyxRiskLevel
    let reasons: [String]

    var body: some View {
        ThermyxCard(padding: Thermyx.Space.xl, fill: Thermyx.Tint.amberFill, border: Thermyx.Tint.amberBorder) {
            VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
                SectionLabel("Preview · not sent", color: Thermyx.Ink.amber)
                Text("Texting isn't turned on yet. If it were, your enabled contacts would get:")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text(ThermyxAlertCoordinator.previewMessage(
                    level: level.severity >= ThermyxRiskLevel.high.severity ? level : .high,
                    reasons: reasons,
                    deviceID: settings.deviceID,
                    includesLocation: settings.shareLocationDuringEvents
                ))
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .padding(Thermyx.Space.m)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.control, style: .continuous))
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Preview of a text to trusted contacts. Not sent; texting is not turned on yet.")
    }
}
