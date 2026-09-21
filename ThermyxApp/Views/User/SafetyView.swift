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
    @State private var showingSOSConfirmation = false
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
            ThermyxScreen(title: "Safety") {
                sosCard
                escalationLadder
                trustedCircle
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
        .sheet(isPresented: $showingAddContact) {
            AddContactSheet(settings: settings)
                .presentationDetents([.medium])
                .presentationBackground(Thermyx.Ink.midnight)
        }
        .confirmationDialog(
            "Call emergency services?",
            isPresented: $showingSOSConfirmation,
            titleVisibility: .visible
        ) {
            Button("Call 911", role: .destructive) { placeEmergencyCall() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text(enabledContacts.isEmpty
                 ? "This dials 911. No trusted contacts are enabled, so nobody else will be notified."
                 : "This dials 911 and notifies \(enabledContacts.count) trusted contact\(enabledContacts.count == 1 ? "" : "s").")
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
                    Text(enabledContacts.isEmpty
                         ? "Add a trusted contact to also share your location"
                         : "Also texts your trusted circle your location")
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

    private func placeEmergencyCall() {
        alerts.notifyTrustedCircle(
            level: .critical,
            reading: viewModel.reading,
            settings: settings,
            reason: "Manual SOS from the Safety screen."
        )
        if let url = URL(string: "tel://911"), UIApplication.shared.canOpenURL(url) {
            UIApplication.shared.open(url)
        }
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
            SectionLabel("Trusted circle") {
                Button {
                    showingAddContact = true
                } label: {
                    Text("+ Add")
                        .narrowLabel(ThermyxFont.statusPill, tracking: ThermyxTracking.statusPill, color: Thermyx.Ink.ice)
                        .frame(minHeight: 32)
                        .contentShape(.rect)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add a trusted contact")
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
                }
            }
        }
    }

    private var advancedRow: some View {
        NavigationLink(value: SafetyDestination.advanced) {
            ThermyxNavigationRow(
                title: "Advanced",
                detail: "Device, backend, firmware",
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
        Text(alerts.notificationsAuthorized
             ? "Alerts escalate only from real readings received by the connected insole."
             : "Notifications are turned off, so Thermyx can only warn you while the app is open. Turn them on in Settings.")
            .font(ThermyxFont.captionSmall)
            .foregroundStyle(alerts.notificationsAuthorized ? Thermyx.Ink.textFaint : Thermyx.Ink.amber)
            .fixedSize(horizontal: false, vertical: true)
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
                    Text(contact.phoneNumber)
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

    private var canSave: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: Thermyx.Space.xl) {
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
                Text("This contact is stored on your phone. Nothing is sent to them until an escalation you configured actually fires.")
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
