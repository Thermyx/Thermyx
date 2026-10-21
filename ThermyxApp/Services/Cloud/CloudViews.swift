import SwiftUI

/// Offered on a phone that isn't backing up when the signed-in account
/// already has a backup: the new-phone moment. Safe to show anywhere (it
/// draws nothing otherwise), e.g. under sign-in during onboarding.
struct CloudRestoreOfferCard: View {
    @ObservedObject var cloud: ThermyxCloudService = .shared

    var body: some View {
        if let written = cloud.restoreOffer {
            ThermyxCard(padding: Thermyx.Space.l, fill: Thermyx.Tint.neutralFill, border: Thermyx.Tint.neutralBorder) {
                VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                    Text("Restore your backup?")
                        .font(ThermyxFont.rowTitle)
                        .foregroundStyle(Thermyx.Ink.textPrimary)
                    Text("Your account has a backup from \(written.formatted(date: .abbreviated, time: .omitted)): your profile, preferences, calibration and recoveries. Restoring it also turns on Back up to my account for this phone. Your history never leaves a phone, so it isn't in it.")
                        .font(ThermyxFont.captionSmall)
                        .foregroundStyle(Thermyx.Ink.textSupporting)
                        .fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: Thermyx.Space.m) {
                        Button("Restore") { Task { await cloud.enableBackup() } }
                            .buttonStyle(ThermyxPrimaryButtonStyle())
                        Button("Not now") { cloud.dismissRestoreOffer() }
                            .buttonStyle(ThermyxSecondaryButtonStyle())
                    }
                }
            }
        }
    }
}

/// The wearer's cloud switches, in Device → Your account data.
struct CloudBackupSection: View {
    @ObservedObject private var cloud = ThermyxCloudService.shared
    @State private var confirmingOff = false
    @State private var confirmingPopulation = false
    @State private var confirmingDelete = false

    var body: some View {
        VStack(alignment: .leading, spacing: Thermyx.Space.header) {
            SectionLabel("Your account data")

            CloudRestoreOfferCard(cloud: cloud)

            if cloud.status.isAwaitingChoice {
                choiceCard
            }

            ThermyxGroupedCard {
                toggle("Back up to my account",
                       detail: cloud.statusLine,
                       isOn: Binding(
                        get: { cloud.backupEnabled },
                        set: { on in
                            if on { Task { await cloud.enableBackup() } } else { confirmingOff = true }
                        }))
                    .disabled(!cloud.isSignedIn || cloud.isBusy)
                ThermyxDivider()
                toggle("Help new wearers start smarter",
                       detail: cloud.populationEnabled
                            ? (cloud.priors == nil ? "On. Starting points appear once enough wearers have joined." : "On. Using what's typical for wearers like you.")
                            : "Off. Nothing is sent.",
                       isOn: Binding(
                        get: { cloud.populationEnabled },
                        set: { on in
                            if on { confirmingPopulation = true } else { Task { await cloud.setPopulationEnabled(false) } }
                        }))
                    .disabled(!cloud.isSignedIn)
                if cloud.isSignedIn, cloud.backupEnabled {
                    ThermyxDivider()
                    Button("Delete my cloud backup", role: .destructive) { confirmingDelete = true }
                        .font(ThermyxFont.body)
                        .foregroundStyle(Thermyx.Ink.ember)
                        .frame(maxWidth: .infinity, minHeight: Thermyx.minimumTapTarget, alignment: .leading)
                        .padding(.horizontal, Thermyx.Space.xl)
                        .disabled(cloud.isBusy)
                }
            }

            if let error = cloud.lastError {
                Text(error)
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.amber)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Backup keeps your profile, preferences, calibration and recoveries in your Google account's private space so a new phone can restore them. Your history, trusted contacts and relay key are never included, and nothing is backed up in Demo Mode.")
                .font(ThermyxFont.captionSmall)
                .foregroundStyle(Thermyx.Ink.textFaint)
                .fixedSize(horizontal: false, vertical: true)
        }
        .confirmationDialog("Turn off backup?", isPresented: $confirmingOff, titleVisibility: .visible) {
            Button("Turn off, keep my backup") { Task { await cloud.disableBackup(deleteCopy: false) } }
            Button("Turn off and delete my backup", role: .destructive) { Task { await cloud.disableBackup(deleteCopy: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This phone stops backing up either way. Keeping the backup lets a new phone restore it later.")
        }
        .confirmationDialog("Delete your cloud backup?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete backup and turn it off", role: .destructive) { Task { await cloud.disableBackup(deleteCopy: true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Your profile, calibration and recoveries stay on this phone. Only the copy in your account is removed.")
        }
        .confirmationDialog("Share anonymous numbers?", isPresented: $confirmingPopulation, titleVisibility: .visible) {
            Button("Turn on") { Task { await cloud.setPopulationEnabled(true) } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Once a month, a few rounded averages of your own calm minutes (usual foot temperature while sitting, standing and walking, and how even your steps are) are sent with no name, email or account ID. They're grouped only by what you mostly use Thermyx for and an age band, and expire within about five weeks. In return, Thermyx starts new wearers from what's typical for people like you. Numbers already sent can't be traced back to you, so they can't be recalled.")
        }
    }

    /// Shown when this phone and the account both hold different data and
    /// neither can be assumed newer.
    private var choiceCard: some View {
        ThermyxCard(padding: Thermyx.Space.l, fill: Thermyx.Tint.neutralFill, border: Thermyx.Ink.amber) {
            VStack(alignment: .leading, spacing: Thermyx.Space.m) {
                Text("Which copy should Thermyx keep?")
                    .font(ThermyxFont.rowTitle)
                    .foregroundStyle(Thermyx.Ink.textPrimary)
                Text("Your account already has a backup, and it differs from what's on this phone. Nothing has been changed yet. Choose the one to keep; the other is replaced.")
                    .font(ThermyxFont.captionSmall)
                    .foregroundStyle(Thermyx.Ink.textSupporting)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Use my account's backup") { Task { await cloud.resolveBackupChoice(useAccountCopy: true) } }
                    .buttonStyle(ThermyxPrimaryButtonStyle())
                Button("Keep what's on this phone") { Task { await cloud.resolveBackupChoice(useAccountCopy: false) } }
                    .buttonStyle(ThermyxSecondaryButtonStyle())
            }
        }
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
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .tint(Thermyx.Ink.signal)
        .padding(.horizontal, Thermyx.Space.xl)
        .padding(.vertical, Thermyx.Space.m)
        .frame(minHeight: Thermyx.minimumTapTarget)
    }
}
