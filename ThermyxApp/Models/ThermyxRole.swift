import Foundation

enum ThermyxRole: String, CaseIterable, Identifiable {
    case user = "User"
    case trustedMember = "Trusted member"
    var id: String { rawValue }
    var icon: String { self == .user ? "figure.walk" : "person.2.fill" }
    var detail: String {
        self == .user ? "Wear the insole and view your live comfort and safety insights." : "Keep an eye on someone you trust and receive their safety updates."
    }
}

@MainActor
final class ThermyxRoleStore: ObservableObject {
    @Published var role: ThermyxRole?
    @Published var hasCompletedOnboarding: Bool
    @Published var profileName: String
    @Published var watchedUserName: String
    @Published var pairingCode: String

    private let defaults = UserDefaults.standard
    init() {
        role = defaults.string(forKey: "thermyx.role").flatMap(ThermyxRole.init(rawValue:))
        hasCompletedOnboarding = defaults.bool(forKey: "thermyx.onboardingComplete")
        profileName = defaults.string(forKey: "thermyx.profileName") ?? ""
        watchedUserName = defaults.string(forKey: "thermyx.watchedUserName") ?? "Thermyx user"
        pairingCode = defaults.string(forKey: "thermyx.pairingCode") ?? "THERMYX-01"
    }
    func complete(role: ThermyxRole, name: String, watched: String, code: String) {
        self.role = role; profileName = name; watchedUserName = watched; pairingCode = code; hasCompletedOnboarding = true; save()
    }
    func reset() { role = nil; hasCompletedOnboarding = false; save() }
    private func save() {
        defaults.set(role?.rawValue, forKey: "thermyx.role")
        defaults.set(hasCompletedOnboarding, forKey: "thermyx.onboardingComplete")
        defaults.set(profileName, forKey: "thermyx.profileName")
        defaults.set(watchedUserName, forKey: "thermyx.watchedUserName")
        defaults.set(pairingCode, forKey: "thermyx.pairingCode")
    }
}
