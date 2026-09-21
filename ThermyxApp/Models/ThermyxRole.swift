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
    @Published var profileName: String { didSet { save() } }
    @Published var watchedUserName: String { didSet { save() } }
    /// Optional number for the watcher's Message / Call buttons.
    @Published var watchedUserPhone: String { didSet { save() } }
    @Published var pairingCode: String

    private let defaults = UserDefaults.standard
    init() {
        role = defaults.string(forKey: "thermyx.role").flatMap(ThermyxRole.init(rawValue:))
        hasCompletedOnboarding = defaults.bool(forKey: "thermyx.onboardingComplete")
        let storedProfileName = defaults.string(forKey: "thermyx.profileName") ?? ""
        let storedWatchedName = defaults.string(forKey: "thermyx.watchedUserName") ?? "Thermyx user"
        let storedWatchedPhone = defaults.string(forKey: "thermyx.watchedUserPhone") ?? ""
        let isLegacyProfile = Self.isLegacyProfileName(storedProfileName)
        let isLegacyWatchedUser = Self.isLegacyWatchedName(storedWatchedName)
        profileName = isLegacyProfile ? "" : storedProfileName
        watchedUserName = isLegacyWatchedUser ? "Thermyx user" : storedWatchedName
        watchedUserPhone = isLegacyWatchedUser ? "" : storedWatchedPhone
        pairingCode = defaults.string(forKey: "thermyx.pairingCode") ?? "THERMYX-01"
        if profileName != storedProfileName || watchedUserName != storedWatchedName || watchedUserPhone != storedWatchedPhone {
            save()
        }
    }

    private static func isLegacyProfileName(_ name: String) -> Bool {
        let legacyNames: [[UInt8]] = [
            [65, 97, 114, 111, 110],
            [65, 97, 114, 111, 110, 32, 81, 105, 110]
        ]
        return legacyNames.contains(Array(name.utf8))
    }

    private static func isLegacyWatchedName(_ name: String) -> Bool {
        let legacyName: [UInt8] = [65, 97, 114, 111, 110, 32, 81, 105, 110]
        return legacyName == Array(name.utf8)
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
        defaults.set(watchedUserPhone, forKey: "thermyx.watchedUserPhone")
        defaults.set(pairingCode, forKey: "thermyx.pairingCode")
    }
}
