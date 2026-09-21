import SwiftUI

struct TrustedSettingsView: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var member: TrustedMemberViewModel

    @State private var showingRoleConfirmation = false
    @State private var legalDocument: LegalDocument.Kind?
    @State private var myName: String = ""
    @State private var theirName: String = ""

    var body: some View {
        NavigationStack {
            ThermyxScreen(title: "Settings") {
                watchedCard
                profileSection
                alertToggles
                sampleSection
                connectionSection
                unitSection
                legalRow

                Button("Change role") { showingRoleConfirmation = true }
                    .buttonStyle(ThermyxSecondaryButtonStyle(tint: Thermyx.Ink.amber, border: Thermyx.Tint.emberBorder))
            }
            .trustedSampleBanner(member: member, watchedName: roles.watchedUserName)
        }
        .onAppear {
            myName = roles.profileName
            theirName = roles.watchedUserName
        }
        .onDisappear { commitNames() }
        .sheet(item: $legalDocument) { kind in
            LegalSheet(selection: kind)
                .presentationDetents([.large])
                .presentationDragIndicator(.visible)
        }
        .confirmationDialog("Change role?", isPresented: $showingRoleConfirmation, titleVisibility: .visible) {
            Button("Change role", role: .destructive) { roles.reset() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("You'll go back through onboarding.")
        }
    }

    private var watchedCard: some View {
        ThermyxCard(padding: Thermyx.Space.xxl) {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                HStack(spacing: Thermyx.Space.l) {
                    Circle()
                        .fill(Thermyx.Ink.elevated)
                        .frame(width: 46, height: 46)
                        .overlay {
                            Text(initials)
                                .font(ThermyxFont.cardTitle)
                                .foregroundStyle(Thermyx.Ink.ice)
                        }
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Watching \(roles.watchedUserName)")
                            .font(ThermyxFont.cardTitle)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text(member.isConnected ? "Receiving status" : "Not receiving status")
                            .font(ThermyxFont.caption)
                            .foregroundStyle(member.isConnected ? Thermyx.Ink.ice : Thermyx.Ink.amber)
                    }
                    Spacer(minLength: 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel("Their phone number")
                    TextField("Optional", text: $roles.watchedUserPhone)
                        .textFieldStyle(ThermyxTextFieldStyle())
                        .keyboardType(.phonePad)
                        .textContentType(.telephoneNumber)
                    Text("Used only by the Message and Call buttons on the Watch tab. It stays on this phone.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    private var initials: String { roles.watchedUserName.thermyxInitials }

    private func commitNames() {
        let mine = myName.trimmingCharacters(in: .whitespacesAndNewlines)
        let theirs = theirName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !mine.isEmpty { roles.profileName = mine }
        if !theirs.isEmpty { roles.watchedUserName = theirs }
    }

    private var profileSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Profile")
            ThermyxGroupedCard {
                nameRow("Your name", placeholder: "Your name", text: $myName)
                ThermyxDivider()
                nameRow("Watching", placeholder: "Their name", text: $theirName)
            }
            Text("Both names are stored only on this phone.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
        }
    }

    private func nameRow(_ label: String, placeholder: String, text: Binding<String>) -> some View {
        HStack(spacing: Thermyx.Space.m) {
            Text(label)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textSupporting)
                .frame(width: 96, alignment: .leading)
            TextField(placeholder, text: text)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
                .multilineTextAlignment(.trailing)
                .textContentType(.name)
        }
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.s)
        .frame(minHeight: Thermyx.minimumTapTarget)
    }

    private var sampleSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Learning")
            ThermyxGroupedCard {
                Toggle(isOn: $member.isShowingSample) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Show a sample shift")
                            .font(ThermyxFont.body)
                            .foregroundStyle(Thermyx.Ink.textPrimary)
                        Text("Fills the screens with a worked example")
                            .font(ThermyxFont.captionSmall)
                            .foregroundStyle(Thermyx.Ink.textSupporting)
                    }
                }
                .tint(Thermyx.Ink.signal)
                .padding(.horizontal, Thermyx.Space.xl)
                .padding(.vertical, Thermyx.Space.m)
                .frame(minHeight: Thermyx.minimumTapTarget)
            }
            Text("Every screen is marked while the sample is showing, so it can never be mistaken for \(roles.watchedUserName)'s real readings.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var legalRow: some View {
        Button { legalDocument = .privacy } label: {
            ThermyxNavigationRow(
                title: "Privacy & terms",
                detail: "How Thermyx handles data",
                systemImage: "doc.text.fill",
                iconTint: Thermyx.Ink.textSupporting,
                iconFill: Thermyx.Tint.neutralFill
            )
        }
        .buttonStyle(.plain)
    }

    private var alertToggles: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Alert me when")

            ThermyxGroupedCard {
                toggleRow("Caution", isOn: $settings.alertOnCaution)
                ThermyxDivider()
                toggleRow("High risk", isOn: $settings.alertOnHighRisk)
                ThermyxDivider()
                toggleRow("Critical", isOn: $settings.alertOnCritical)
            }
        }
    }

    private func toggleRow(_ label: String, isOn: Binding<Bool>) -> some View {
        Toggle(isOn: isOn) {
            Text(label)
                .font(ThermyxFont.body)
                .foregroundStyle(Thermyx.Ink.textPrimary)
        }
        .tint(Thermyx.Ink.signal)
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.l)
        .frame(minHeight: Thermyx.minimumTapTarget)
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Connection")

            ThermyxGroupedCard {
                ThermyxValueRow(
                    label: "Pairing code",
                    value: roles.pairingCode,
                    valueFont: ThermyxFont.rowTitle,
                    valueTracking: 2
                )
                ThermyxDivider()
                ThermyxEditableRow(label: "Backend", placeholder: "https://…", text: $settings.backendURL, keyboard: .URL)
                ThermyxDivider()
                ThermyxEditableRow(label: "Token", placeholder: "Optional", text: $settings.backendToken, isSecure: true)
                ThermyxDivider()
                ThermyxEditableRow(label: "Device ID", placeholder: "thermyx-right-01", text: $settings.deviceID)
            }

            if let error = member.lastError {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var unitSection: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.s) {
            SectionLabel("Units")
            ThermyxSegmentedControl(
                options: TemperatureUnit.allCases,
                label: \.shortLabel,
                selection: $settings.temperatureUnit,
                font: ThermyxFont.rowTitleRegular,
                tracking: 0,
                uppercase: false,
                accessibilityPrefix: "Show temperatures in "
            )
            .fixedSize()
        }
    }
}
