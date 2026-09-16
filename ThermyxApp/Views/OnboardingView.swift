import SwiftUI

struct OnboardingView: View {
    @ObservedObject var roles: ThermyxRoleStore
    @ObservedObject var settings: ThermyxSettingsStore
    @StateObject private var model = OnboardingModel()
    var body: some View {
        ZStack {
            AppTheme.background.ignoresSafeArea()
            VStack(spacing: 22) {
                HStack { Image("ThermyxLogo").resizable().scaledToFit().frame(width: 48, height: 48).clipShape(RoundedRectangle(cornerRadius: 12)); Text("THERMYX").font(.headline.bold()).tracking(2).foregroundStyle(.cyan); Spacer(); Text("\(model.page + 1) / 3").font(.caption).foregroundStyle(.white.opacity(0.55)) }
                Spacer()
                if model.page == 0 { intro } else if model.page == 1 { roleStep } else { connectStep }
                Spacer()
                Button(model.page == 2 ? "Enter Thermyx" : "Continue") { advance() }.buttonStyle(.borderedProminent).tint(.cyan).controlSize(.large)
            }.padding(24)
        }.preferredColorScheme(.dark)
    }
    private var intro: some View { VStack(alignment: .leading, spacing: 18) { Image(systemName: "waveform.path.ecg").font(.system(size: 62)).foregroundStyle(.cyan); Text("Comfort that keeps moving with you.").font(.largeTitle.bold()); Text("Thermyx connects a smart insole to live temperature, movement, pressure, and safety insights in one calm, simple experience.").font(.title3).foregroundStyle(.white.opacity(0.72)); HStack { Pill(text: "Heat"); Pill(text: "Cool"); Pill(text: "Sense") } } }
    private var roleStep: some View { VStack(alignment: .leading, spacing: 16) { Text("How will you use Thermyx?").font(.largeTitle.bold()); Text("Choose the view that fits your role. You can change this later in settings.").foregroundStyle(.white.opacity(0.7)); ForEach(ThermyxRole.allCases) { role in Button { model.selectedRole = role } label: { HStack(spacing: 14) { Image(systemName: role.icon).font(.title2).foregroundStyle(model.selectedRole == role ? .cyan : .white.opacity(0.65)); VStack(alignment: .leading) { Text(role.rawValue).font(.headline); Text(role.detail).font(.subheadline).foregroundStyle(.white.opacity(0.62)) }; Spacer(); Image(systemName: model.selectedRole == role ? "checkmark.circle.fill" : "circle").foregroundStyle(model.selectedRole == role ? .cyan : .white.opacity(0.3)) }.padding(16).background(Color.white.opacity(model.selectedRole == role ? 0.12 : 0.06), in: RoundedRectangle(cornerRadius: 18)) } } } }
    private var connectStep: some View { VStack(alignment: .leading, spacing: 16) { Text(model.selectedRole == .user ? "Set up your insole" : "Connect to your user").font(.largeTitle.bold()); Text(model.selectedRole == .user ? "Give your profile a name, then pair the insole from the Device tab." : "Use the same pairing code and backend address on both phones for the live Congressional App demo.").foregroundStyle(.white.opacity(0.7)); TextField("Your name", text: $model.name).textFieldStyle(.roundedBorder); if model.selectedRole == .trustedMember { TextField("User name", text: $model.watched).textFieldStyle(.roundedBorder) }; TextField("Pairing code", text: $model.code).textFieldStyle(.roundedBorder); TextField("Shared backend URL", text: $settings.backendURL).textFieldStyle(.roundedBorder); SecureField("Backend token", text: $settings.backendToken).textFieldStyle(.roundedBorder) } }
    private func advance() { if model.page < 2 { model.page += 1 } else { roles.complete(role: model.selectedRole, name: model.name.isEmpty ? (model.selectedRole == .user ? "Thermyx user" : "Trusted member") : model.name, watched: model.watched.isEmpty ? "Thermyx user" : model.watched, code: model.code); settings.deviceID = "thermyx-right-01" } }
}

@MainActor final class OnboardingModel: ObservableObject {
    @Published var page = 0
    @Published var selectedRole: ThermyxRole = .user
    @Published var name = ""
    @Published var watched = ""
    @Published var code = "THERMYX-01"
}

struct Pill: View { let text: String; var body: some View { Text(text).font(.caption.bold()).padding(.horizontal, 12).padding(.vertical, 8).background(Color.white.opacity(0.08), in: Capsule()).foregroundStyle(.white.opacity(0.8)) } }
