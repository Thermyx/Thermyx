import SwiftUI

/// Profile tab: who you are and what Insights focuses on, editable any time.
struct ProfileSettingsSection: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @ObservedObject var health: ThermyxHealthService
    @State private var editing = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.section) {
            profile
            CloudBackupSection()
        }
        .sheet(isPresented: $editing) { editSheet }
    }

    private var profile: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Your profile")
            ThermyxCard {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(roles.profileName.isEmpty ? "No name yet" : roles.profileName)
                                .font(ThermyxFont.cardTitle)
                                .foregroundStyle(Thermyx.Ink.textPrimary)
                            Text(details)
                                .font(ThermyxFont.caption)
                                .foregroundStyle(Thermyx.Ink.textSupporting)
                        }
                        Spacer()
                        Button("Edit") { editing = true }
                            .font(ThermyxFont.rowTitle)
                            .foregroundStyle(Thermyx.Ink.link)
                            .frame(minWidth: Thermyx.minimumTapTarget, minHeight: Thermyx.minimumTapTarget)
                    }

                    HStack {
                        SectionLabel("Insight preference")
                        Spacer(minLength: Thermyx.Space.s)
                        ThermyxSegmentedControl(options: UserProfile.Focus.allCases, label: \.label,
                                                selection: Binding(get: { settings.profile.focus ?? .health },
                                                                   set: { settings.profile.focus = $0 }),
                                                accessibilityPrefix: "Insights lead with ")
                            .fixedSize()
                    }
                    Text((settings.profile.focus ?? .health) == .health
                         ? "Health: safety, comfort and circulation come first."
                         : "Performance: training, recovery and gait efficiency come first.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)

                    SectionLabel("Mostly for")
                        .padding(.top, Thermyx.Space.xs)
                    UsageChips(settings: settings)
                    Text("Shapes the Simulator's first scenario and, with AI Insights on, the daily summary's suggestions.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                        .fixedSize(horizontal: false, vertical: true)

                    Text("Your profile stays on this phone unless you turn on Back up to my account, below.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textFaint)
                }
            }
        }
    }

    private var editSheet: some View {
        NavigationStack {
            ScrollView {
                AboutYouForm(name: $roles.profileName, settings: settings, health: health)
                    .padding(.horizontal, Thermyx.Space.screen)
                    .padding(.vertical, Thermyx.Space.m)
            }
            .scrollDismissesKeyboard(.interactively)
            .background(Thermyx.Site.bg.ignoresSafeArea())
            .navigationTitle("About you")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) { Button("Done") { editing = false } }
            }
        }
        .presentationDetents([.large])
        .presentationBackground(Thermyx.Site.bg)
    }

    private var details: String {
        let p = settings.profile
        var parts: [String] = []
        if let age = p.age { parts.append("\(age) yrs") }
        if let cm = p.heightCm {
            if settings.temperatureUnit == .fahrenheit {
                let inches = Int((cm / 2.54).rounded())
                parts.append("\(inches / 12)′\(inches % 12)″")
            } else {
                parts.append("\(Int(cm.rounded())) cm")
            }
        }
        if let kg = p.weightKg {
            parts.append(settings.temperatureUnit == .fahrenheit ? "\(Int((kg / 0.453_592).rounded())) lb" : "\(Int(kg.rounded())) kg")
        }
        if let sex = p.sex { parts.append(sex.label) }
        if let size = settings.shoeSizeLabel { parts.append(size) }
        return parts.isEmpty ? "Add your details" : parts.joined(separator: " · ")
    }
}

/// Profile tab: the signed-in account, sign out, and delete account.
struct AccountSection: View {
    @EnvironmentObject private var account: ThermyxAccountStore
    @EnvironmentObject private var viewModel: ThermyxViewModel
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore

    @State private var confirmingDelete = false
    @State private var deleteError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Account")
            ThermyxGroupedCard {
                ThermyxValueRow(label: "Signed in with Google", value: account.account?.email ?? account.account?.displayName ?? "Google account")
                if account.isAdmin {
                    ThermyxDivider()
                    ThermyxValueRow(label: "Access", value: "Admin · test tools on")
                }
                ThermyxDivider()
                Button("Sign out") { account.signOut() }
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.link)
                    .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                    .padding(.horizontal, Thermyx.Space.xl)
                ThermyxDivider()
                Button("Delete account", role: .destructive) { confirmingDelete = true }
                    .font(ThermyxFont.body)
                    .foregroundStyle(Thermyx.Ink.ember)
                    .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                    .padding(.horizontal, Thermyx.Space.xl)
                    .disabled(account.isWorking)
            }
            if let deleteError {
                Text(deleteError)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .confirmationDialog("Delete your Thermyx account?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete account and data", role: .destructive) { Task { await delete() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Google will ask you to confirm. Your account, its cloud backup if you had one, and the history, calibration and profile on this phone are deleted. This can't be undone.")
        }
    }

    private func delete() async {
        do {
            try await account.deleteAccount()
            _ = await DataDeletion.deleteEverything(viewModel: viewModel, settings: settings)
            settings.profile = UserProfile()
            roles.profileName = ""
            roles.reset()
        } catch {
            deleteError = "The account wasn't deleted. \(error.localizedDescription)"
        }
    }
}
