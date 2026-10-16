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
    @State private var showingCircleSharing = false
    /// What to do once "What your circle gets" is acknowledged the first time.
    @State private var afterCircleSharing: (() -> Void)?
    @State private var verifying: ThermyxContact?
    @State private var showingSOSConfirmation = false
    @State private var showingCannotCall = false
    @State private var okSentAt: Date?
    @ObservedObject private var permissions = ThermyxPermissions.shared
    @ObservedObject private var location: ThermyxLocationProvider
    @Environment(\.scenePhase) private var scenePhase

    init(roles: ThermyxRoleStore, settings: ThermyxSettingsStore, alerts: ThermyxAlertCoordinator, health: ThermyxHealthService) {
        self.roles = roles
        self.settings = settings
        self.alerts = alerts
        self.health = health
        self.location = alerts.location
    }

    private var level: ThermyxRiskLevel { viewModel.assessment.level }

    var body: some View {
        NavigationStack(path: $path) {
            ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    titleRow
                    status
                        .padding(.top, Thermyx.Space.item)
                    HoldToCallButton(subtitle: sosSubtitle, onCall: placeEmergencyCall) {
                        showingSOSConfirmation = true
                    }
                    .spotlightTarget(.holdToCall)
                    .padding(.top, Thermyx.Space.titleGap)
                    imOKRow
                    readiness
                    ladder
                        .padding(.top, Thermyx.Space.section)
                    trustedCircle
                        .padding(.top, Thermyx.Space.section)
                        .id("circle")
                    WatchersSection(settings: settings, alerts: alerts, level: level, explainFirst: explainFirst)
                        .padding(.top, Thermyx.Space.section)
                    footnote
                        .padding(.top, Thermyx.Space.section)
                    Color.clear.frame(height: 1).id("end")
                }
                .padding(.horizontal, Thermyx.Space.screen)
                .padding(.bottom, Thermyx.Space.xxl)
            }
            .debugScroll(proxy)
            }
            .scrollIndicators(.hidden)
            .thermyxTopScrim()
            .thermyxNavigationRoot()
            .task { await permissions.refresh() }
            #if DEBUG
            .onAppear { if ThermyxPreviewHarness.state == .circleSharing { showingCircleSharing = true } }
            #endif
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { Task { await permissions.refresh() } }
            }
            .toolbar(.hidden, for: .navigationBar)
            .navigationDestination(for: SafetyDestination.self) { destination in
                switch destination {
                case .device:
                    DeviceView(roles: roles, settings: settings, health: health)
                case .advanced:
                    AdvancedView(roles: roles, settings: settings, health: health)
                }
            }
        }
        .sheet(isPresented: $showingAddContact) {
            AddContactSheet(settings: settings)
                .presentationDetents([.medium])
                .thermyxSheetBackground()
        }
        .sheet(isPresented: $showingCircleSharing, onDismiss: { afterCircleSharing = nil }) {
            CircleSharingSheet(settings: settings, alerts: alerts, reading: viewModel.reading) {
                let next = afterCircleSharing
                afterCircleSharing = nil
                // Let this sheet finish closing before the next one opens.
                if let next { DispatchQueue.main.asyncAfter(deadline: .now() + 0.45, execute: next) }
            }
            .presentationDetents([.large])
            .thermyxSheetBackground()
        }
        .sheet(item: $verifying) { contact in
            VerifyContactSheet(settings: settings, contact: contact)
                .presentationDetents([.medium])
                .thermyxSheetBackground()
        }
        .confirmationDialog(
            "Call emergency services?",
            isPresented: $showingSOSConfirmation,
            titleVisibility: .visible
        ) {
            Button("Call 911", role: .destructive) { placeEmergencyCall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(!canTextCircle
                 ? "This dials 911. No trusted contacts can be texted, so nobody else will be notified."
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

    // MARK: Header

    private var titleRow: some View {
        HStack {
            Text("Safety")
                .font(ThermyxFont.screenTitle)
                .tracking(ThermyxTracking.screenTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .accessibilityAddTraits(.isHeader)
            Spacer()
            NavigationLink(value: SafetyDestination.device) {
                Image(systemName: "gearshape")
                    .font(.system(size: 21, weight: .regular))
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .frame(width: 44, height: 44)
                    .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Device and settings")
        }
        .padding(.top, Thermyx.Space.titleTop)
    }

    /// "Normal. Your circle hears from Thermyx at High risk."
    private var status: some View {
        let lead = level == .unavailable ? "No readings." : "\(level.rawValue)."
        let rest = enabledContacts.isEmpty
            ? " Add someone below and Thermyx alerts them at High risk."
            : " Your circle hears from Thermyx at High risk."
        return (Text(lead).font(.custom(ThermyxFont.Family.semibold, size: 15, relativeTo: .subheadline)).foregroundColor(level.tint)
                + Text(rest).font(ThermyxFont.bodySmall).foregroundColor(Thermyx.Ink.textMuted))
            .fixedSize(horizontal: false, vertical: true)
    }

    /// Texting needs an enabled contact, a paired relay, and texting turned
    /// on at the relay (off until tested with real phones).
    private var canTextCircle: Bool {
        !enabledContacts.isEmpty && settings.isPairedWithRelay && settings.relayTextingEnabled
    }

    private var sosSubtitle: String {
        if enabledContacts.isEmpty { return "Opens your dialer. Add a trusted contact to also text them." }
        if !settings.isPairedWithRelay || !settings.relayTextingEnabled {
            return "Opens your dialer. Texting your circle isn't set up yet."
        }
        let names = enabledContacts.prefix(2).map { $0.name.components(separatedBy: " ").first ?? $0.name }
        let who = enabledContacts.count > 2 ? "your circle" : names.joined(separator: " and ")
        return settings.shareLocationDuringEvents && alerts.location.isAuthorized
            ? "Also alerts \(who) with your location"
            : "Also alerts \(who)"
    }

    private var enabledContacts: [ThermyxContact] {
        settings.contacts.filter(\.enabled)
    }

    // MARK: Readiness

    /// The iOS switches the safety features need, each with the button that
    /// turns it on. Gone once they're all on.
    @ViewBuilder
    private var readiness: some View {
        let needsLocation = settings.shareLocationDuringEvents && !location.isAuthorized
        if !permissions.notificationsAllowed || needsLocation {
            VStack(spacing: Thermyx.Space.item) {
                PermissionPrompt(symbol: "bell.badge.fill", title: "Notifications",
                                 detail: "So Thermyx can warn you when the app isn't open.",
                                 status: .init(permissions.notifications)) {
                    Task { await permissions.requestNotifications() }
                }
                if needsLocation {
                    PermissionPrompt(symbol: "location.fill", title: "Location",
                                     detail: "You chose to share where you are during an emergency. Thermyx needs location for that.",
                                     status: .init(location.authorization)) {
                        location.requestPermission()
                    }
                }
            }
            .padding(.top, Thermyx.Space.m)
            .animation(SiteMotion.settle, value: permissions.notifications)
        }
    }

    // MARK: I'm OK

    @ViewBuilder
    private var imOKRow: some View {
        if settings.isPairedWithRelay {
            VStack(alignment: .leading, spacing: 6) {
                Button {
                    alerts.sendImOK(level: level, reading: viewModel.reading, settings: settings)
                    okSentAt = .now
                } label: {
                    Label(canTextCircle ? "Tell my watchers and circle I'm OK" : "Tell my watchers I'm OK", systemImage: "hand.thumbsup")
                }
                .buttonStyle(ThermyxSecondaryButtonStyle())
                if let okSentAt {
                    Text("Sent at \(okSentAt.formatted(date: .omitted, time: .shortened)).")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
            }
            .padding(.top, Thermyx.Space.m)
        }
    }

    /// The first contact or watcher waits for "What your circle gets".
    private func explainFirst(_ action: @escaping () -> Void) {
        if settings.circlePrivacyAcknowledged { action(); return }
        afterCircleSharing = action
        showingCircleSharing = true
    }

    private func placeEmergencyCall() {
        alerts.notifyTrustedCircle(
            level: .critical,
            reading: viewModel.reading,
            settings: settings,
            trigger: .pressed
        )
        if !EmergencyCall.dial() { showingCannotCall = true }
    }

    // MARK: Levels

    private var ladder: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            Text("What happens at each level")
                .font(ThermyxFont.sectionTitle)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .accessibilityAddTraits(.isHeader)
            VStack(spacing: 0) {
                ForEach(Array(ThermyxRiskLevel.ladder.enumerated()), id: \.offset) { index, rung in
                    rungRow(rung, isLast: index == ThermyxRiskLevel.ladder.count - 1)
                }
            }
        }
    }

    private func rungRow(_ rung: ThermyxRiskLevel, isLast: Bool) -> some View {
        let isCurrent = rung == level
        return HStack(alignment: .top, spacing: 16) {
            VStack(spacing: 0) {
                Group {
                    if isCurrent {
                        Circle().fill(rung.tint)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(rung.tint.opacity(0.18)).frame(width: 22, height: 22))
                    } else if rung == .critical {
                        Circle().fill(rung.tint).frame(width: 12, height: 12)
                    } else {
                        Circle().strokeBorder(rung.tint, lineWidth: 2).frame(width: 12, height: 12)
                    }
                }
                .frame(width: 22, height: 20)
                if !isLast {
                    Rectangle().fill(Thermyx.Tint.track).frame(width: 2).frame(maxHeight: .infinity)
                        .padding(.vertical, 4)
                }
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack {
                    Text(rung.rawValue)
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(isCurrent ? rung.tint : Thermyx.Ink.textPrimary)
                    Spacer()
                    if isCurrent {
                        Text("You're here")
                            .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .caption))
                            .foregroundStyle(rung.tint)
                    }
                }
                Text(ladderText(rung))
                    .font(ThermyxFont.caption)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.bottom, isLast ? 0 : 18)
        }
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func ladderText(_ rung: ThermyxRiskLevel) -> String {
        switch rung {
        case .high: return "Stop, hydrate, cool down. Trusted circle notified. Heating locks out."
        default: return rung.ladderDetail
        }
    }

    // MARK: Trusted circle

    private var trustedCircle: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text("Trusted circle")
                    .font(ThermyxFont.sectionTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                    .accessibilityAddTraits(.isHeader)
                Text("\(settings.contacts.count) of \(ThermyxSettingsStore.maxContacts)")
                    .font(ThermyxFont.monoCaption)
                    .foregroundStyle(Thermyx.Ink.textFaint)
                Spacer()
                if settings.canAddContact {
                    Button("Add") { explainFirst { showingAddContact = true } }
                        .font(.custom(ThermyxFont.Family.medium, size: 15, relativeTo: .subheadline))
                        .foregroundStyle(Thermyx.Ink.ice)
                        .frame(minWidth: 44, minHeight: 44, alignment: .trailing)
                        .accessibilityLabel("Add a trusted contact")
                }
            }
            if settings.contacts.isEmpty {
                Text("Add someone who should hear about a High-risk escalation. Nothing is shared until you add them.")
                    .font(ThermyxFont.bodySmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.vertical, 6)
            } else {
                ForEach(Array(settings.contacts.enumerated()), id: \.element.id) { index, contact in
                    ContactRow(contact: contact, isLast: index == settings.contacts.count - 1) {
                        settings.toggleContact(contact)
                    }
                    .contextMenu {
                        Button("Remove \(contact.name)", role: .destructive) { settings.removeContact(contact) }
                    }
                    if settings.relayContactVerification, settings.relayRole == "wearer", contact.verifiedAt == nil {
                        Button("Confirm \(contact.name)'s number") { verifying = contact }
                            .font(ThermyxFont.controlLabel)
                            .foregroundStyle(Thermyx.Ink.ice)
                            .frame(minHeight: Thermyx.minimumTapTarget)
                    }
                }
                if !settings.relayTextingEnabled, !enabledContacts.isEmpty {
                    TextingPreviewCard(settings: settings, alerts: alerts, reading: viewModel.reading)
                        .padding(.top, 10)
                }
            }
            if !settings.contacts.isEmpty || settings.isPairedWithRelay {
                CircleSettingsRows(settings: settings, alerts: alerts, level: level) {
                    showingCircleSharing = true
                }
                .padding(.top, Thermyx.Space.xs)
            }
        }
    }

    // MARK: Footnote

    private var footnote: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.item) {
            Text("Thermyx is an investigational heat-risk warning aid. It does not measure core body temperature and does not diagnose heat illness.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Hold for two seconds to call 911. Built to read as a physical emergency
/// button: deep red with a lit top edge and a glaze, sitting on its own
/// glow. It presses in the moment it's touched, a ring fills around the
/// handset as it's held, and letting go early cancels. VoiceOver gets the
/// same call through an action, behind a confirmation.
struct HoldToCallButton: View {
    let subtitle: String
    let onCall: () -> Void
    let onAccessibleCall: () -> Void

    @State private var progress: Double = 0
    @State private var holding = false
    @State private var fired = false
    @State private var ticker: Task<Void, Never>?

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private static let holdSeconds = 2.0
    private static let radius: CGFloat = 24

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: Self.radius, style: .continuous) }

    var body: some View {
        HStack(spacing: Thermyx.Space.l) {
            handset
            VStack(alignment: .leading, spacing: 3) {
                Text(fired ? "Calling 911" : "Hold to call 911")
                    .font(.custom(ThermyxFont.Family.bold, size: 20, relativeTo: .title3))
                    .tracking(-0.2)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.25), radius: 0, y: 1)
                Text(fired ? "Your circle is being alerted" : subtitle)
                    .font(.custom(ThermyxFont.Family.medium, size: 13, relativeTo: .caption))
                    .foregroundStyle(.white.opacity(0.86))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Text(holding && !fired ? String(format: "%.1f", max(0, Self.holdSeconds * (1 - progress))) : "2 s")
                .font(.custom(ThermyxFont.Family.monoMedium, size: 13, relativeTo: .caption))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.78))
                .contentTransition(.numericText(countsDown: true))
                .opacity(fired ? 0 : 1)
        }
        .padding(.leading, Thermyx.Space.l)
        .padding(.trailing, Thermyx.Space.xl)
        .frame(maxWidth: .infinity, minHeight: 96)
        .background { face }
        .overlay { bevel }
        .compositingGroup()
        .shadow(color: Thermyx.Ink.emergency.opacity(holding ? 0.25 : 0.42), radius: holding ? 10 : 20, y: holding ? 4 : 10)
        .shadow(color: .black.opacity(0.5), radius: 2, y: 1)
        .scaleEffect(holding ? 0.985 : 1)
        .animation(SiteMotion.press, value: holding)
        .contentShape(shape)
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in if !holding { begin() } }
                .onEnded { _ in end() }
        )
        .sensoryFeedback(.impact(weight: .light), trigger: holding) { _, now in now }
        .sensoryFeedback(.impact(weight: .heavy), trigger: fired) { _, now in now }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Call 911")
        .accessibilityValue(subtitle)
        .accessibilityHint("Touch and hold for two seconds. Or use the action to call after confirming.")
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { onAccessibleCall() }
    }

    /// The white handset disc, ringed by the hold's progress.
    private var handset: some View {
        ZStack {
            Circle()
                .fill(LinearGradient(colors: [.white, Color(hex: 0xF1E4E4)], startPoint: .top, endPoint: .bottom))
                .shadow(color: .black.opacity(0.28), radius: 3, y: 2)
            Image(systemName: fired ? "phone.arrow.up.right.fill" : "phone.fill")
                .font(.system(size: 21, weight: .semibold))
                .foregroundStyle(Thermyx.Ink.emergencyDeep)
                .contentTransition(.symbolEffect(.replace))
            Circle()
                .trim(from: 0, to: progress)
                .stroke(.white, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .padding(-6)
                .opacity(progress > 0 ? 1 : 0)
            Circle()
                .stroke(.white.opacity(0.22), lineWidth: 3)
                .padding(-6)
                .opacity(holding || fired ? 1 : 0)
        }
        .frame(width: 52, height: 52)
        .padding(6)
    }

    /// Red, lit from above, with the hold sweeping a darker red across it.
    private var face: some View {
        ZStack(alignment: .leading) {
            shape.fill(LinearGradient(colors: [Color(hex: 0xF4433F), Thermyx.Ink.emergency, Color(hex: 0xB3121A)],
                                      startPoint: .top, endPoint: .bottom))
            GeometryReader { proxy in
                Rectangle()
                    .fill(Thermyx.Ink.emergencyDeep.opacity(0.55))
                    .frame(width: proxy.size.width * progress)
            }
            .clipShape(shape)
            // The glaze: a soft sheet of light across the top half, inset
            // from the edges as a highlight on a curved face would be.
            shape
                .inset(by: 2)
                .fill(LinearGradient(stops: [.init(color: .white.opacity(0.30), location: 0),
                                             .init(color: .white.opacity(0.08), location: 0.42),
                                             .init(color: .white.opacity(0), location: 0.55)],
                                     startPoint: .top, endPoint: .bottom))
                .blendMode(.screen)
            // A faint specular streak along the upper left.
            Ellipse()
                .fill(RadialGradient(colors: [.white.opacity(0.22), .white.opacity(0)], center: .center, startRadius: 0, endRadius: 90))
                .frame(width: 180, height: 46)
                .offset(x: 30, y: -30)
                .blendMode(.screen)
                .allowsHitTesting(false)
        }
        .clipShape(shape)
    }

    /// Light catching the top edge, and a darker rim where the face meets
    /// the screen.
    private var bevel: some View {
        ZStack {
            shape.strokeBorder(Color(hex: 0x6E070C).opacity(0.85), lineWidth: 1)
            shape
                .inset(by: 1)
                .strokeBorder(LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.06), .clear],
                                             startPoint: .top, endPoint: .bottom), lineWidth: 1)
        }
        .allowsHitTesting(false)
    }

    private func begin() {
        holding = true
        fired = false
        ticker?.cancel()
        ticker = Task { @MainActor in
            let start = Date.now
            while !Task.isCancelled {
                let elapsed = Date.now.timeIntervalSince(start)
                progress = min(1, elapsed / Self.holdSeconds)
                if progress >= 1 {
                    fired = true
                    onCall()
                    return
                }
                try? await Task.sleep(for: .milliseconds(16))
            }
        }
    }

    private func end() {
        holding = false
        ticker?.cancel()
        if !fired {
            withAnimation(reduceMotion ? SiteMotion.fade : SiteMotion.settle) { progress = 0 }
        } else {
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(3))
                withAnimation(SiteMotion.settle) { progress = 0; fired = false }
            }
        }
    }
}

/// One trusted contact: initials, name, when they're alerted, and a switch.
struct ContactRow: View {
    let contact: ThermyxContact
    var isLast = false
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
        HStack(spacing: Thermyx.Space.m) {
            Circle()
                .fill(Thermyx.Ink.elevated)
                .frame(width: 38, height: 38)
                .overlay {
                    Text(initials.isEmpty ? "?" : initials)
                        .font(.custom(ThermyxFont.Family.semibold, size: 14, relativeTo: .subheadline))
                        .foregroundStyle(contact.enabled ? Thermyx.Ink.ice : Thermyx.Ink.textFaint)
                }
            VStack(alignment: .leading, spacing: 1) {
                Text(contact.name)
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text(contact.enabled
                     ? (contact.verifiedAt == nil ? "Alerted at High" : "Confirmed · alerted at High")
                     : "Paused")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textMuted)
            }
            Spacer(minLength: Thermyx.Space.xs)
            Toggle("", isOn: Binding(get: { contact.enabled }, set: { _ in toggle() }))
                .labelsHidden()
                .tint(Thermyx.Ink.signal)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { if !isLast { ThermyxDivider() } }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(contact.name), \(contact.phoneNumber)")
        .accessibilityValue(contact.enabled ? "Alerts on" : "Alerts paused")
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
    case device
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
                    notifyCircle(.pressed)
                    if !EmergencyCall.dial() { showingCannotCall = true }
                } label: {
                    Label("Call 911", systemImage: "phone.fill")
                }
                .buttonStyle(ThermyxPrimaryButtonStyle(fill: .white, foreground: Thermyx.Ink.onEmber))

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
        .task {
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            while remaining > 0 && !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                remaining -= 1
            }
            if !Task.isCancelled && !circleNotified {
                notifyCircle(.noResponse)
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
            return "Tap I'm OK if you're safe. Add trusted contacts on the Safety tab so someone is told next time."
        }
        if !settings.isPairedWithRelay {
            return "Tap I'm OK if you're safe. Connect to a relay under Safety → Advanced so your trusted circle can be told next time."
        }
        return "Tap I'm OK if you're safe. Texting isn't turned on yet, so nobody will be texted automatically. Approved watchers see that you're at Critical."
    }

    private func notifyCircle(_ trigger: ThermyxAlertCoordinator.SOSTrigger) {
        guard !circleNotified else { return }
        circleNotified = true
        // Always tell the relay, so approved watchers see it; contacts are
        // texted only when texting is on (the coordinator decides).
        alerts.notifyTrustedCircle(level: .critical, reading: viewModel.reading, settings: settings, trigger: trigger)
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
