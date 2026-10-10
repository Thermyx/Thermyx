import MessageUI
import ContactsUI
import SwiftUI
import UIKit

struct SafetyView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var alerts: ThermyxAlertCoordinator
    @ObservedObject var health: ThermyxHealthService

    @State private var path: [SafetyDestination] = {
        #if DEBUG
        return ThermyxPreviewHarness.initialSafetyPath
        #else
        return []
        #endif
    }()
    @State private var showingAddContact = false
    @State private var verifying: ThermyxContact?
    @State private var textDraft: TextDraft?
    @State private var showingSOSConfirmation = false
    @State private var showingCannotCall = false
    @State private var okSentAt: Date?
    @State private var legalDocument: LegalDocument.Kind? = {
        #if DEBUG
        return ThermyxPreviewHarness.opensLegalSheet ? .privacy : nil
        #else
        return nil
        #endif
    }()

    private var level: ThermyxRiskLevel { viewModel.assessment.level }

    var body: some View {
        NavigationStack(path: $path) {
            ThermyxScreen(title: "Profile") {
                sosCard
                imOKRow
                escalationLadder
                trustedCircle
                WatchersSection(settings: settings, alerts: alerts, level: level)
                ProfileSettingsSection(roles: roles, settings: settings)
                advancedRow
                notificationNote
                brandPlate
            }
            .navigationDestination(for: SafetyDestination.self) { destination in
                switch destination {
                case .advanced:
                    AdvancedView(roles: roles, settings: settings, health: health)
                }
            }
        }
        .sheet(item: $legalDocument) { kind in
            LegalSheet(selection: kind)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .background(MessageComposerPresenter(draft: $textDraft))
        .sheet(isPresented: $showingAddContact) {
            AddContactSheet(settings: settings)
                .presentationDetents([.medium])
                .presentationBackground(Thermyx.Ink.midnight)
        }
        .sheet(item: $verifying) { contact in
            VerifyContactSheet(settings: settings, contact: contact)
                .presentationDetents([.medium])
                .presentationBackground(Thermyx.Ink.midnight)
        }
        .confirmationDialog(
            "Call emergency services?",
            isPresented: $showingSOSConfirmation,
            titleVisibility: .visible
        ) {
            Button("Call 911", role: .destructive) { placeEmergencyCall() }
            if !canTextCircle, !enabledContacts.isEmpty {
                Button("Text my circle first") { textCircle(level: .critical, reason: "I pressed SOS.") }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(!canTextCircle
                 ? (enabledContacts.isEmpty
                    ? "This dials 911. Add trusted contacts to also tell someone."
                    : "This dials 911. Texts aren't sent automatically yet, so tap Text my circle first to send one from Messages.")
                 : "This dials 911 and texts \(enabledContacts.count) trusted contact\(enabledContacts.count == 1 ? "" : "s").")
        }
        .alert("This device can't place calls", isPresented: $showingCannotCall) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(canTextCircle
                 ? "Dial 911 from a phone. Your trusted circle was still texted."
                 : "Dial 911 from a phone.")
        }
    }

    /// Texting needs an enabled contact, a paired relay, and texting turned
    /// on at the relay (off until tested with real phones).
    private var canTextCircle: Bool {
        !enabledContacts.isEmpty && settings.isPairedWithRelay && settings.relayTextingEnabled
    }

    private var sosSubtitle: String {
        if enabledContacts.isEmpty { return "Opens your phone's dialer. Add a trusted contact to also text them" }
        if !settings.isPairedWithRelay { return "Opens your phone's dialer. Connect to a relay under Advanced to also text your trusted circle" }
        if !settings.relayTextingEnabled { return "Opens your phone's dialer. Texting your trusted circle isn't turned on yet" }
        return settings.shareLocationDuringEvents && alerts.location.isAuthorized
            ? "Opens your phone's dialer and texts your trusted circle your location"
            : "Opens your phone's dialer and texts your trusted circle"
    }

    // MARK: - I'm OK

    private var imOKRow: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            Button {
                alerts.sendImOK(level: level, reading: viewModel.reading, settings: settings)
                okSentAt = .now
            } label: {
                Label(canTextCircle ? "Tell my watchers and trusted circle I'm OK" : "Tell my watchers I'm OK", systemImage: "hand.thumbsup.fill")
            }
            .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))
            .disabled(!settings.isPairedWithRelay)
            .opacity(settings.isPairedWithRelay ? 1 : 0.5)

            if let okSentAt {
                Text("Sent at \(okSentAt.formatted(date: .omitted, time: .shortened)).")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
            }
        }
    }

    private var enabledContacts: [ThermyxContact] {
        settings.contacts.filter(\.enabled)
    }

    // MARK: - SOS
    //
    // Top of the screen, where a gloved thumb lands, behind one confirmation
    // so a pocket press does not dial emergency services.

    private var sosCard: some View {
        Button {
            showingSOSConfirmation = true
        } label: {
            HStack(spacing: Thermyx.Space.l) {
                Circle()
                    .fill(Color.white.opacity(0.16))
                    .frame(width: 52, height: 52)
                    .overlay {
                        Text("SOS")
                            .narrowLabel(ThermyxFont.statusPillLarge, tracking: 1, color: .white)
                    }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Call 911")
                        .font(ThermyxFont.cardTitle)
                        .tracking(-0.3)
                        .foregroundStyle(.white)
                    Text(sosSubtitle)
                        .font(ThermyxFont.caption)
                        .foregroundStyle(.white.opacity(0.92))
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)
            }
            .padding(Thermyx.Space.xxl)
            .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
            .background(Thermyx.Ink.alarmGradient, in: RoundedRectangle(cornerRadius: Thermyx.Radius.section, style: .continuous))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Call 911")
        .accessibilityHint("Dials emergency services and notifies your trusted circle")
    }

    /// Opens Messages with every enabled contact and the alert filled in;
    /// the wearer taps Send.
    private func textCircle(level: ThermyxRiskLevel, reason: String?) {
        textDraft = TextDraft.alert(
            recipients: enabledContacts.map(\.phoneNumber),
            level: level,
            reasons: reason.map { [$0] } ?? viewModel.assessment.reasons,
            location: settings.shareLocationDuringEvents ? alerts.location.recent : nil
        )
    }

    private func placeEmergencyCall() {
        alerts.notifyTrustedCircle(
            level: .critical,
            reading: viewModel.reading,
            settings: settings,
            reason: "Manual SOS from the Safety screen."
        )
        if !EmergencyCall.dial() { showingCannotCall = true }
    }

    // MARK: - Escalation ladder

    private var escalationLadder: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Escalation ladder")

            // Each rung owns its own dot and connector, so the rail tracks the
            // row heights instead of distributing dots evenly down a separate
            // column and drifting out of alignment.
            VStack(spacing: 0) {
                ForEach(Array(ThermyxRiskLevel.ladder.enumerated()), id: \.offset) { index, rung in
                    rungRow(rung, isLast: index == ThermyxRiskLevel.ladder.count - 1)
                }
            }
        }
    }

    @ViewBuilder
    private func rungRow(_ rung: ThermyxRiskLevel, isLast: Bool) -> some View {
        let isCurrent = rung == level
        let isPassed = level.severity > rung.severity
        let dotSize: CGFloat = isCurrent ? 16 : 12

        HStack(alignment: .top, spacing: Thermyx.Space.m) {
            VStack(spacing: 0) {
                Circle()
                    .fill(isCurrent ? rung.tint : (isPassed ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting.opacity(0.3)))
                    .frame(width: dotSize, height: dotSize)
                    .overlay {
                        if isCurrent {
                            Circle()
                                .strokeBorder(rung.tint.opacity(0.2), lineWidth: 4)
                                .frame(width: dotSize + 8, height: dotSize + 8)
                        }
                    }
                    .frame(height: 24)

                if !isLast {
                    Rectangle()
                        .fill(Thermyx.Ink.textSupporting.opacity(0.25))
                        .frame(width: 2)
                        .frame(maxHeight: .infinity)
                }
            }
            .frame(width: 24)

            VStack(alignment: .leading, spacing: 1) {
                Text(isCurrent ? "\(rung.rawValue) · you are here" : rung.rawValue)
                    .narrowLabel(
                        ThermyxFont.statusPillLarge,
                        tracking: 1.8,
                        color: isCurrent ? rung.tint : Thermyx.Ink.textSupporting
                    )
                Text(rung.ladderDetail)
                    .font(ThermyxFont.caption)
                    .foregroundStyle(isCurrent ? Thermyx.Ink.textSecondary : Thermyx.Ink.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .modifier(CurrentRungHighlight(isCurrent: isCurrent, tint: rung.tint))
            .padding(.bottom, isLast ? 0 : Thermyx.Space.l)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    // MARK: - Trusted circle

    private var trustedCircle: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xs) {
            SectionLabel("Trusted circle · \(settings.contacts.count) of \(ThermyxSettingsStore.maxContacts)") {
                if settings.canAddContact {
                    Button {
                        showingAddContact = true
                    } label: {
                        Text("+ Add")
                            .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: Thermyx.Ink.ice)
                            .frame(minWidth: Thermyx.minimumTapTarget, minHeight: Thermyx.minimumTapTarget)
                            .contentShape(.rect)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add a trusted contact")
                }
            }

            if settings.contacts.isEmpty {
                ThermyxEmptyState(
                    title: "No trusted contacts",
                    message: "Add someone who should hear about a high-risk escalation. Nothing is shared until you add them and turn them on.",
                    systemImage: "person.2",
                    actionTitle: "Add a contact",
                    action: { showingAddContact = true }
                )
            } else {
                ForEach(settings.contacts) { contact in
                    ContactRow(contact: contact) {
                        settings.toggleContact(contact)
                    }
                    .contextMenu {
                        Button("Remove \(contact.name)", role: .destructive) { settings.removeContact(contact) }
                    }
                    if settings.relayContactVerification, settings.relayRole == "wearer", contact.verifiedAt == nil {
                        Button("Confirm \(contact.name)'s number") { verifying = contact }
                            .font(ThermyxFont.captionSmall.weight(.semibold))
                            .foregroundStyle(Thermyx.Ink.ice)
                            .frame(minHeight: Thermyx.minimumTapTarget)
                    }
                }
                Text(settings.canAddContact
                     ? "Up to \(ThermyxSettingsStore.maxContacts) people. Touch and hold a contact to remove it."
                     : "Your circle is full (\(ThermyxSettingsStore.maxContacts) people). Touch and hold a contact to remove it.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                if !enabledContacts.isEmpty {
                    TextingHelpCard(automatic: canTextCircle) {
                        textCircle(level: level == .unavailable ? .normal : level, reason: nil)
                    }
                }
            }
        }
    }

    private var advancedRow: some View {
        NavigationLink(value: SafetyDestination.advanced) {
            ThermyxNavigationRow(
                title: "Advanced",
                detail: "Device, relay, firmware",
                systemImage: "gearshape.fill",
                iconTint: Thermyx.Ink.textSupporting,
                iconFill: Thermyx.Tint.neutralFill
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Brand and legal
    //
    // The horizontal lockup is navy ink, so it needs a light ground — on
    // Midnight it sits at roughly 1.4:1. It gets one here, and doubles as the
    // entry point to the policies, which is where people look for them.

    private var brandPlate: some View {
        VStack(spacing: Thermyx.Space.m) {
            Button {
                legalDocument = .privacy
            } label: {
                VStack(spacing: Thermyx.Space.s) {
                    Image("ThermyxWordmark")
                        .resizable()
                        .scaledToFit()
                        .frame(maxWidth: 200)
                    Text("Privacy Policy · Terms of Service")
                        .narrowLabel(ThermyxFont.axisLabel, tracking: ThermyxTracking.axisLabel, color: Color(hex: 0x1B3552))
                }
                .padding(.vertical, Thermyx.Space.xl)
                .padding(.horizontal, Thermyx.Space.xxl)
                .frame(maxWidth: .infinity)
                .frame(minHeight: Thermyx.minimumTapTarget)
                .background(Color(hex: 0xF4F6FA), in: RoundedRectangle(cornerRadius: Thermyx.Radius.list, style: .continuous))
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Thermyx. Privacy Policy and Terms of Service")
            .accessibilityHint("Opens the legal documents")

            Text("Thermyx is an investigational heat-risk warning aid. It does not measure core body temperature and does not diagnose heat illness.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.top, Thermyx.Space.s)
    }

    private var notificationNote: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Notifications")
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    HStack(spacing: Thermyx.Space.s) {
                        Image(systemName: alerts.notificationsAuthorized ? "bell.badge.fill" : "bell.slash.fill")
                            .foregroundStyle(alerts.notificationsAuthorized ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                        Text(alerts.notificationsAuthorized ? "On" : "Off")
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                    }
                    Text(alerts.notificationsAuthorized
                         ? "You'll get safety alerts, cold and low-battery reminders, and your session summary. Alerts come only from real readings."
                         : "Notifications are off, so Thermyx can only warn you while the app is open.")
                        .font(ThermyxFont.caption)
                        .foregroundStyle(alerts.notificationsAuthorized ? Thermyx.Ink.textSupporting : Thermyx.Ink.amber)
                        .fixedSize(horizontal: false, vertical: true)
                    if alerts.notificationsAuthorized {
                        Button("Send a test notification") { alerts.sendTestNotification() }
                            .buttonStyle(ThermyxSecondaryButtonStyle())
                    } else {
                        Button("Turn on in Settings") {
                            if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                                UIApplication.shared.open(url)
                            }
                        }
                        .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))
                    }
                }
            }
        }
        .task { await alerts.refreshPermission() }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            Task { await alerts.refreshPermission() }
        }
    }
}

/// The current rung sits in a tinted card; the others are plain rows.
private struct CurrentRungHighlight: ViewModifier {
    let isCurrent: Bool
    let tint: Color

    func body(content: Content) -> some View {
        if isCurrent {
            content
                .padding(.horizontal, Thermyx.Space.m)
                .padding(.vertical, Thermyx.Space.s)
                .background(tint.opacity(0.1), in: RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Thermyx.Radius.button, style: .continuous)
                        .strokeBorder(tint.opacity(0.35), lineWidth: Thermyx.Stroke.hairline)
                }
                .padding(.vertical, -6)
        } else {
            content
        }
    }
}

struct ContactRow: View {
    let contact: ThermyxContact
    let toggle: () -> Void

    private var initials: String {
        contact.name
            .split(separator: " ")
            .prefix(2)
            .compactMap { $0.first.map(String.init) }
            .joined()
            .uppercased()
    }

    var body: some View {
        Button(action: toggle) {
            HStack(spacing: Thermyx.Space.m) {
                Circle()
                    .fill(Thermyx.Ink.elevated)
                    .frame(width: 38, height: 38)
                    .overlay {
                        Text(initials.isEmpty ? "?" : initials)
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(contact.enabled ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting)
                    }

                VStack(alignment: .leading, spacing: 1) {
                    Text(contact.name)
                        .font(ThermyxFont.rowTitleRegular)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text(contact.verifiedAt == nil ? contact.phoneNumber : "\(contact.phoneNumber) · confirmed")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                }

                Spacer(minLength: Thermyx.Space.xs)

                Text(contact.enabled ? "On" : "Paused")
                    .narrowLabel(
                        ThermyxFont.axisLabel,
                        tracking: 1.4,
                        color: contact.enabled ? Thermyx.Ink.ice : Thermyx.Ink.textSupporting
                    )
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .background(
                        contact.enabled ? Thermyx.Tint.liveFill : Thermyx.Tint.neutralFill,
                        in: Capsule()
                    )
            }
            .padding(.horizontal, Thermyx.Space.l)
            .padding(.vertical, 13)
            .frame(minHeight: Thermyx.minimumTapTarget)
            .background(Thermyx.Ink.deck, in: RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Thermyx.Radius.compact, style: .continuous)
                    .strokeBorder(Thermyx.Ink.hairline, lineWidth: Thermyx.Stroke.hairline)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(contact.name), \(contact.phoneNumber)")
        .accessibilityValue(contact.enabled ? "Alerts on" : "Alerts paused")
        .accessibilityHint("Double tap to toggle alerts for this contact")
    }
}

struct AddContactSheet: View {
    @ObservedObject var settings: ThermyxSettingsStore
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var phone = ""
    @State private var pickingContact = false

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
                Button {
                    pickingContact = true
                } label: {
                    Label("Choose from Contacts", systemImage: "person.crop.circle.badge.plus")
                }
                .buttonStyle(ThermyxSecondaryButtonStyle())
                .background(ContactPickerPresenter(isPresented: $pickingContact) { pickedName, pickedPhone in
                    name = pickedName
                    phone = pickedPhone
                })

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Name")
                    TextField("Name", text: $name)
                        .textFieldStyle(ThermyxTextFieldStyle())
                        .textContentType(.name)
                }
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Phone number")
                    TextField("Phone number", text: $phone)
                        .textFieldStyle(ThermyxTextFieldStyle())
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                }
                Text("Choosing from Contacts copies only the name and the number you pick. This contact is stored on your phone. Nothing is sent to them until an escalation you configured actually fires.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer()
            }
            .padding(Thermyx.Space.screen)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Thermyx.Ink.midnight)
            .navigationTitle("Trusted contact")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        settings.addContact(name: name, phone: phone)
                        dismiss()
                    }
                    .disabled(!canSave)
                }
            }
        }
    }
}

enum SafetyDestination: Hashable {
    case advanced
}

// MARK: - Emergency call

enum EmergencyCall {
    /// Opens the dialer on 911. Returns false on a device that cannot place
    /// calls (the simulator, most iPads, a phone with no service), so the
    /// caller can say so instead of failing silently.
    @MainActor
    @discardableResult
    static func dial() -> Bool {
        guard let url = URL(string: "tel://911"), UIApplication.shared.canOpenURL(url) else { return false }
        UIApplication.shared.open(url)
        return true
    }
}

// MARK: - Critical alert

/// Full-screen takeover when the risk reaches Critical. One tap calls 911,
/// one tap says "I'm OK". If nobody answers within the countdown, the
/// trusted circle is texted automatically.
struct CriticalAlertView: View {
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var alerts: ThermyxAlertCoordinator
    @ObservedObject var settings: ThermyxSettingsStore
    let onDismiss: () -> Void

    static let countdownSeconds = 60

    @State private var remaining = CriticalAlertView.countdownSeconds
    @State private var circleNotified = false
    @State private var showingCannotCall = false
    @State private var showingWhy = false
    @State private var textDraft: TextDraft?

    private var assessment: ThermyxRiskAssessment { viewModel.assessment }
    private var canTextCircle: Bool {
        settings.contacts.contains(where: \.enabled) && settings.isPairedWithRelay && settings.relayTextingEnabled
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
            Spacer(minLength: 0)

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .bold))
                .foregroundStyle(.white)

            Text(assessment.level == .critical ? "Stop and get help now" : "Risk has dropped to \(assessment.level.rawValue)")
                .font(ThermyxFont.onboardingHeadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Text(assessment.reasons.isEmpty ? ThermyxRiskLevel.critical.explanation : assessment.reasons.joined(separator: " "))
                .font(ThermyxFont.bodyLarge)
                .foregroundStyle(.white.opacity(0.92))
                .fixedSize(horizontal: false, vertical: true)

            WhyButton(tint: .white) { showingWhy = true }

            Text(countdownText)
                .font(ThermyxFont.rowTitle)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 0)

            VStack(spacing: Thermyx.Space.s) {
                Button {
                    notifyCircle(reason: "The wearer pressed Call 911 from the Critical alert.")
                    if !EmergencyCall.dial() { showingCannotCall = true }
                } label: {
                    Label("Call 911", systemImage: "phone.fill")
                }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: .white, foreground: Thermyx.Ink.onEmber))

                if !canTextCircle, settings.contacts.contains(where: \.enabled) {
                    Button {
                        textDraft = TextDraft.alert(
                            recipients: settings.contacts.filter(\.enabled).map(\.phoneNumber),
                            level: .critical,
                            reasons: assessment.reasons,
                            location: settings.shareLocationDuringEvents ? alerts.location.recent : nil
                        )
                    } label: {
                        Label("Text my circle", systemImage: "message.fill")
                    }
                    .buttonStyle(ThermyxSecondaryButtonStyle(tint: .white, border: .white.opacity(0.7)))
                }

                Button {
                    alerts.sendImOK(level: assessment.level, reading: viewModel.reading, settings: settings)
                    onDismiss()
                } label: {
                    Text("I'm OK")
                }
                .buttonStyle(ThermyxSecondaryButtonStyle(tint: .white, border: .white.opacity(0.7)))
            }
        }
        .padding(.horizontal, Thermyx.Space.wide)
        .padding(.vertical, Thermyx.Space.xxl)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        .background(Thermyx.Ink.alarmGradient.ignoresSafeArea())
        .background(MessageComposerPresenter(draft: $textDraft))
        .task {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            while remaining > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            if !Task.isCancelled && !circleNotified {
                notifyCircle(reason: "No response to a Critical alert for \(Self.countdownSeconds) seconds.")
            }
        }
        .sheet(isPresented: $showingWhy) {
            RiskExplanationSheet(settings: settings)
                .presentationDetents([.medium, .large])
        }
        .alert("This device can't place calls", isPresented: $showingCannotCall) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("Dial 911 from a phone.")
        }
        .accessibilityElement(children: .contain)
    }

    private var countdownText: String {
        if circleNotified { return canTextCircle ? "Your trusted circle is being texted." : "No trusted contacts could be texted. Call for help if you need it." }
        if canTextCircle { return "Texting your trusted circle in \(remaining) s unless you tap I'm OK." }
        if !settings.contacts.contains(where: \.enabled) {
            return "Tap I'm OK if you're safe. Add trusted contacts on the Profile tab so someone is told next time."
        }
        if !settings.isPairedWithRelay {
            return "Tap I'm OK if you're safe. Connect to a relay under Profile → Advanced so your trusted circle can be told next time."
        }
        return "Tap I'm OK if you're safe, or Text my circle to send a message from Messages. Approved watchers see that you're at Critical."
    }

    private func notifyCircle(reason: String) {
        guard !circleNotified else { return }
        circleNotified = true
        // Always tell the relay, so approved watchers see it; contacts are
        // texted only when texting is on (the coordinator decides).
        alerts.notifyTrustedCircle(level: .critical, reading: viewModel.reading, settings: settings, reason: reason)
    }
}

/// The system contact picker. It runs outside the app, so Thermyx needs no
/// Contacts permission and only sees the one number the wearer taps.
///
/// Presented from a plain view controller rather than as a SwiftUI sheet:
/// `CNContactPickerViewController` dismisses itself at once when wrapped
/// directly in a sheet.
struct ContactPickerPresenter: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    let onPick: (String, String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard isPresented, host.presentedViewController == nil else { return }
        let picker = CNContactPickerViewController()
        picker.delegate = context.coordinator
        picker.displayedPropertyKeys = [CNContactPhoneNumbersKey]
        // Only people with a number; with several, the wearer picks one.
        picker.predicateForEnablingContact = NSPredicate(format: "phoneNumbers.@count > 0")
        picker.predicateForSelectionOfContact = NSPredicate(format: "phoneNumbers.@count == 1")
        DispatchQueue.main.async { host.present(picker, animated: true) }
    }

    final class Coordinator: NSObject, CNContactPickerDelegate {
        var parent: ContactPickerPresenter
        init(_ parent: ContactPickerPresenter) { self.parent = parent }

        func contactPickerDidCancel(_ picker: CNContactPickerViewController) {
            parent.isPresented = false
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect contact: CNContact) {
            if let number = contact.phoneNumbers.first?.value.stringValue {
                parent.onPick(Self.name(contact), number)
            }
            parent.isPresented = false
        }

        func contactPicker(_ picker: CNContactPickerViewController, didSelect property: CNContactProperty) {
            if let number = (property.value as? CNPhoneNumber)?.stringValue {
                parent.onPick(Self.name(property.contact), number)
            }
            parent.isPresented = false
        }

        static func name(_ contact: CNContact) -> String {
            CNContactFormatter.string(from: contact, style: .fullName) ?? contact.givenName
        }
    }
}

// MARK: - Texting the trusted circle

/// A text ready to send from Messages.
struct TextDraft: Identifiable, Equatable {
    let id = UUID()
    let recipients: [String]
    let body: String

    static func alert(recipients: [String], level: ThermyxRiskLevel, reasons: [String],
                      location: ThermyxAlertEvent.AlertLocation?) -> TextDraft {
        var parts = [level.severity >= ThermyxRiskLevel.high.severity
                     ? "Thermyx alert: I'm at \(level.rawValue)."
                     : "Thermyx check-in from me."]
        if !reasons.isEmpty { parts.append(reasons.joined(separator: " ")) }
        if let location {
            parts.append(String(format: "Where I am: https://maps.apple.com/?ll=%.5f,%.5f", location.latitude, location.longitude))
        }
        if level.severity >= ThermyxRiskLevel.high.severity { parts.append("Please check on me.") }
        return TextDraft(recipients: recipients, body: parts.joined(separator: " "))
    }
}

/// How texting works, with a button that always works: Messages, filled in.
struct TextingHelpCard: View {
    /// True when the relay sends texts on its own.
    let automatic: Bool
    let onText: () -> Void
    @State private var showingHow = false

    var body: some View {
        ThermyxCard {
            VStack(alignment: .leading, spacing: Thermyx.Space.s) {
                SectionLabel("Texting your circle", color: automatic ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                Text(automatic
                     ? "On. Thermyx texts your circle automatically at High risk, Critical and SOS. You can also send a text yourself."
                     : "Automatic texts are off. Tap Text my circle to open Messages with your contacts and the alert filled in, then tap Send. The Critical alert and SOS offer the same button.")
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button { onText() } label: {
                    Label("Text my circle", systemImage: "message.fill")
                }
                .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.ice, border: Thermyx.Tint.liveBorder))
                if !automatic {
                    Button(showingHow ? "Hide how to turn on automatic texts" : "How to turn on automatic texts") {
                        withAnimation(.easeOut(duration: 0.2)) { showingHow.toggle() }
                    }
                    .font(ThermyxFont.captionSmall.weight(.semibold))
                    .foregroundStyle(Thermyx.Ink.ice)
                    .frame(minHeight: Thermyx.minimumTapTarget)
                    if showingHow {
                        Text("Automatic texts are sent by your Thermyx relay through Twilio, so they work even if you can't tap anything. 1) Connect this phone to the relay in Profile → Advanced. 2) On the relay, set SMS_ENABLED=true plus TWILIO_ACCOUNT_SID, TWILIO_AUTH_TOKEN and TWILIO_FROM_NUMBER from a Twilio account, then restart it. 3) Reopen this screen: it says On once the relay reports texting is enabled.")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
    }
}

/// Presents the system Messages composer. Nothing is sent until the
/// wearer taps Send there. Devices that can't text (the Simulator, some
/// iPads) get an explanation instead.
struct MessageComposerPresenter: UIViewControllerRepresentable {
    @Binding var draft: TextDraft?

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeUIViewController(context: Context) -> UIViewController { UIViewController() }

    func updateUIViewController(_ host: UIViewController, context: Context) {
        context.coordinator.parent = self
        guard let draft, host.presentedViewController == nil else { return }
        let controller: UIViewController
        if MFMessageComposeViewController.canSendText() {
            let composer = MFMessageComposeViewController()
            composer.recipients = draft.recipients
            composer.body = draft.body
            composer.messageComposeDelegate = context.coordinator
            controller = composer
        } else {
            let alert = UIAlertController(
                title: "This device can't send texts",
                message: "Use an iPhone with Messages set up. The message would have been: \(draft.body)",
                preferredStyle: .alert
            )
            let coordinator = context.coordinator
            alert.addAction(UIAlertAction(title: "OK", style: .cancel) { _ in coordinator.parent.draft = nil })
            controller = alert
        }
        DispatchQueue.main.async { host.present(controller, animated: true) }
    }

    final class Coordinator: NSObject, MFMessageComposeViewControllerDelegate {
        var parent: MessageComposerPresenter
        init(_ parent: MessageComposerPresenter) { self.parent = parent }

        func messageComposeViewController(_ controller: MFMessageComposeViewController, didFinishWith result: MessageComposeResult) {
            controller.dismiss(animated: true)
            parent.draft = nil
        }
    }
}
