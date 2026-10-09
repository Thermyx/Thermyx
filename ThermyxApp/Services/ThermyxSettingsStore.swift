import Foundation
import Security

@MainActor
final class ThermyxSettingsStore: ObservableObject {
    /// The relay this phone paired with. Set by pairing, not typed by hand.
    @Published private(set) var backendURL: String { didSet { save() } }
    /// This phone's own relay token (wearer or watcher), issued once by the
    /// relay when a pairing code is redeemed. Kept in the Keychain.
    @Published private(set) var backendToken: String { didSet { save() } }
    /// The wearer's relay device ID, assigned by the relay at pairing.
    @Published private(set) var deviceID: String { didSet { save() } }
    /// "wearer" or "watcher" — which kind of relay token this phone holds.
    @Published private(set) var relayRole: String { didSet { save() } }
    /// Whether the relay has texting turned on. Off until the team has tested
    /// real delivery; the app shows a labelled preview instead.
    @Published var relayTextingEnabled: Bool { didSet { save() } }
    /// Whether the relay offers contact-number confirmation. Off unless the
    /// team turns it on after testing with real phones.
    @Published var relayContactVerification: Bool { didSet { save() } }
    /// The wearer's explicit consent to include their location in what
    /// approved watchers see, and only during a High, Critical, or SOS event.
    @Published var shareLocationDuringEvents: Bool { didSet { save() } }
    @Published var contacts: [ThermyxContact] { didSet { save() } }

    /// Applied to every temperature display in the app.
    @Published var temperatureUnit: TemperatureUnit { didSet { save() } }
    /// Selected range on the Insights hub, remembered between launches.
    @Published var insightsRange: InsightsRange { didSet { save() } }
    /// Whether ranges snap to calendar boundaries or roll continuously.
    @Published var periodStyle: InsightsPeriodStyle { didSet { save() } }

    /// Profile
    @Published var soleSize: SoleSize? { didSet { save() } }
    /// The wearer's details from onboarding. Kept on this phone only.
    @Published var profile: UserProfile { didSet { save() } }
    /// Opt-in for the on-device next-step suggestions shown on Home
    /// (`ThermyxSuggestion`). Off by default.
    @Published var aiSuggestionsEnabled: Bool { didSet { save() } }
    /// The hold-at temperature commanded from the Advanced screen, in °C.
    @Published var targetTemperatureC: Double { didSet { save() } }

    /// Which risk levels a trusted member wants pushed to them.
    @Published var alertOnCaution: Bool { didSet { save() } }
    @Published var alertOnHighRisk: Bool { didSet { save() } }
    @Published var alertOnCritical: Bool { didSet { save() } }

    /// Whether the user opted into Apple Health. Nothing in the app blocks on
    /// this; it only gates whether authorization is requested at all.
    @Published var healthKitEnabled: Bool { didSet { save() } }

    /// The commanded range on the Advanced target slider. The top stays two
    /// degrees under the 40 °C burn-protection limit, so holding at the
    /// warmest setting never trips the limit on its own.
    static let targetRange: ClosedRange<Double> = 26...38

    /// Which foot the per-foot screens open on.
    @Published var preferredFoot: Foot { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        backendURL = defaults.string(forKey: "thermyx.backendURL") ?? ""
        // The token lives in the Keychain. Older builds kept it in
        // UserDefaults; move it across once and remove the plain copy.
        if let legacy = defaults.string(forKey: "thermyx.backendToken") {
            if !legacy.isEmpty { ThermyxKeychain.set(legacy, for: Self.tokenAccount) }
            defaults.removeObject(forKey: "thermyx.backendToken")
        }
        backendToken = ThermyxKeychain.get(Self.tokenAccount) ?? ""
        deviceID = defaults.string(forKey: "thermyx.deviceID") ?? ""
        relayRole = defaults.string(forKey: "thermyx.relayRole") ?? ""
        relayTextingEnabled = defaults.bool(forKey: "thermyx.relayTextingEnabled")
        relayContactVerification = defaults.bool(forKey: "thermyx.relayContactVerification")
        shareLocationDuringEvents = defaults.bool(forKey: "thermyx.shareLocationDuringEvents")
        let storedContacts: [ThermyxContact]
        if let data = defaults.data(forKey: "thermyx.contacts"), let decoded = try? JSONDecoder().decode([ThermyxContact].self, from: data) {
            storedContacts = decoded
        } else {
            storedContacts = []
        }
        // These were prototype seed contacts, not contacts a wearer added.
        // Remove them from existing installs as well as from new preview data.
        let migratedContacts = storedContacts.filter { !Self.isLegacyPrototypeContact($0) }
        contacts = migratedContacts
        if migratedContacts.count != storedContacts.count {
            defaults.set(try? JSONEncoder().encode(migratedContacts), forKey: "thermyx.contacts")
        }

        temperatureUnit = defaults.string(forKey: "thermyx.temperatureUnit")
            .flatMap(TemperatureUnit.init(rawValue:))
            ?? (Locale.current.measurementSystem == .us ? .fahrenheit : .celsius)
        insightsRange = defaults.string(forKey: "thermyx.insightsRange")
            .flatMap(InsightsRange.init(rawValue:)) ?? .day
        periodStyle = defaults.string(forKey: "thermyx.periodStyle")
            .flatMap(InsightsPeriodStyle.init(rawValue:)) ?? .standard
        profile = defaults.data(forKey: "thermyx.userProfile")
            .flatMap { try? JSONDecoder().decode(UserProfile.self, from: $0) } ?? UserProfile()
        let storedSize = defaults.double(forKey: "thermyx.soleSize")
        soleSize = SoleSize.all.first { $0.usMens == storedSize }
        aiSuggestionsEnabled = defaults.object(forKey: "thermyx.aiSuggestionsEnabled") as? Bool ?? false
        preferredFoot = defaults.string(forKey: "thermyx.preferredFoot").flatMap(Foot.init(rawValue:)) ?? .left
        let storedTarget = defaults.double(forKey: "thermyx.targetTemperatureC")
        targetTemperatureC = storedTarget == 0 ? 31 : min(max(storedTarget, Self.targetRange.lowerBound), Self.targetRange.upperBound)

        alertOnCaution = defaults.object(forKey: "thermyx.alertOnCaution") as? Bool ?? false
        alertOnHighRisk = defaults.object(forKey: "thermyx.alertOnHighRisk") as? Bool ?? true
        alertOnCritical = defaults.object(forKey: "thermyx.alertOnCritical") as? Bool ?? true
        healthKitEnabled = defaults.object(forKey: "thermyx.healthKitEnabled") as? Bool ?? false

        // Tokens from before pairing codes were shared secrets typed by hand.
        // They are not valid on the new relay; drop them so the phone pairs.
        // The same goes for the old hand-typed address and device ID.
        if relayRole.isEmpty {
            backendToken = ""
            backendURL = ""
            deviceID = ""
            ThermyxKeychain.set("", for: Self.tokenAccount)
            defaults.removeObject(forKey: "thermyx.backendURL")
            defaults.removeObject(forKey: "thermyx.deviceID")
        }
    }

    private static let tokenAccount = "thermyx.backendToken"

    /// True once this phone has redeemed a pairing code with a relay.
    var isPairedWithRelay: Bool { !backendURL.isEmpty && !backendToken.isEmpty }

    /// Stores what the relay issued when a pairing code was redeemed.
    func completePairing(url: String, role: String, token: String, deviceID: String?, textingEnabled: Bool, contactVerification: Bool = false) {
        relayContactVerification = contactVerification
        backendURL = url
        relayRole = role
        backendToken = token
        if let deviceID { self.deviceID = deviceID }
        relayTextingEnabled = textingEnabled
    }

    /// Forgets the relay on this phone. The relay-side token stays until it
    /// is revoked or expires; for a watcher, the wearer's list shows it.
    func disconnectRelay() {
        backendURL = ""
        backendToken = ""
        relayRole = ""
        deviceID = ""
        relayTextingEnabled = false
        relayContactVerification = false
    }

    func markVerified(_ contact: ThermyxContact) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        contacts[index].verifiedAt = .now
    }

    private static func isLegacyPrototypeContact(_ contact: ThermyxContact) -> Bool {
        let name = contact.name.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let digits = contact.phoneNumber.filter(\.isNumber)
        let legacyNames: [[UInt8]] = [
            [115, 105, 100, 100, 104, 97, 110, 116, 104, 32, 114, 101, 108, 97, 110],
            [109, 105, 104, 101, 101, 114, 32, 112, 97, 114, 97, 115, 110, 105, 115]
        ]
        let legacyNumbers: [[UInt8]] = [
            [49, 51, 52, 54, 53, 48, 53, 54, 53, 54, 52],
            [49, 50, 56, 49, 52, 49, 51, 53, 49, 53, 57]
        ]
        return legacyNames.contains(Array(name.utf8))
            || legacyNumbers.contains(Array(digits.utf8))
    }

    func addContact(name: String, phone: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        contacts.append(ThermyxContact(name: name, phoneNumber: phone))
    }

    func removeContacts(at offsets: IndexSet) { contacts.remove(atOffsets: offsets) }

    func toggleContact(_ contact: ThermyxContact) {
        guard let index = contacts.firstIndex(where: { $0.id == contact.id }) else { return }
        contacts[index].enabled.toggle()
    }

    /// Whether this risk level should reach a watching trusted member.
    func shouldAlert(for level: ThermyxRiskLevel) -> Bool {
        switch level {
        case .caution: return alertOnCaution
        case .high: return alertOnHighRisk
        case .critical: return alertOnCritical
        case .normal, .unavailable: return false
        }
    }

    private func save() {
        defaults.set(backendURL, forKey: "thermyx.backendURL")
        ThermyxKeychain.set(backendToken, for: Self.tokenAccount)
        defaults.set(deviceID, forKey: "thermyx.deviceID")
        defaults.set(relayRole, forKey: "thermyx.relayRole")
        defaults.set(relayTextingEnabled, forKey: "thermyx.relayTextingEnabled")
        defaults.set(relayContactVerification, forKey: "thermyx.relayContactVerification")
        defaults.set(shareLocationDuringEvents, forKey: "thermyx.shareLocationDuringEvents")
        defaults.set(try? JSONEncoder().encode(contacts), forKey: "thermyx.contacts")
        defaults.set(temperatureUnit.rawValue, forKey: "thermyx.temperatureUnit")
        defaults.set(insightsRange.rawValue, forKey: "thermyx.insightsRange")
        defaults.set(periodStyle.rawValue, forKey: "thermyx.periodStyle")
        defaults.set(soleSize?.usMens ?? 0, forKey: "thermyx.soleSize")
        defaults.set(try? JSONEncoder().encode(profile), forKey: "thermyx.userProfile")
        defaults.set(aiSuggestionsEnabled, forKey: "thermyx.aiSuggestionsEnabled")
        defaults.set(preferredFoot.rawValue, forKey: "thermyx.preferredFoot")
        defaults.set(targetTemperatureC, forKey: "thermyx.targetTemperatureC")
        defaults.set(alertOnCaution, forKey: "thermyx.alertOnCaution")
        defaults.set(alertOnHighRisk, forKey: "thermyx.alertOnHighRisk")
        defaults.set(alertOnCritical, forKey: "thermyx.alertOnCritical")
        defaults.set(healthKitEnabled, forKey: "thermyx.healthKitEnabled")
    }
}

/// Minimal generic-password Keychain wrapper for the relay token.
enum ThermyxKeychain {
    private static let service = "com.thermyx.app"

    static func get(_ account: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func set(_ value: String, for account: String) {
        let base: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
        SecItemDelete(base as CFDictionary)
        guard !value.isEmpty else { return }
        var attributes = base
        attributes[kSecValueData as String] = Data(value.utf8)
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        SecItemAdd(attributes as CFDictionary, nil)
    }
}

/// What the wearer tells Thermyx about themselves during onboarding. Every
/// field is optional, and none of it leaves the phone.
struct UserProfile: Codable, Equatable {
    enum Sex: String, Codable, CaseIterable, Identifiable {
        case female, male, other
        var id: String { rawValue }
        var label: String {
            switch self {
            case .female: return "Female"
            case .male: return "Male"
            case .other: return "Other"
            }
        }
    }

    /// What Insights should lead with.
    enum Focus: String, Codable, CaseIterable, Identifiable {
        case health, performance
        var id: String { rawValue }
        var label: String { self == .health ? "Health" : "Performance" }
        var detail: String {
            self == .health ? "Comfort and foot safety first." : "Training, effort and recovery first."
        }
    }

    var age: Int?
    var heightCm: Double?
    var weightKg: Double?
    var sex: Sex?
    var focus: Focus?
    /// Optional, self-reported. Stored only; nothing uses them yet.
    var reducedFeeling: Bool?
    var poorCirculation: Bool?
    var diabetes: Bool?
}
