import Foundation

@MainActor
final class ThermyxSettingsStore: ObservableObject {
    @Published var backendURL: String { didSet { save() } }
    @Published var backendToken: String { didSet { save() } }
    @Published var deviceID: String { didSet { save() } }
    @Published var contacts: [ThermyxContact] { didSet { save() } }

    /// Applied to every temperature display in the app.
    @Published var temperatureUnit: TemperatureUnit { didSet { save() } }
    /// Selected range on the Insights hub, remembered between launches.
    @Published var insightsRange: InsightsRange { didSet { save() } }
    /// Whether ranges snap to calendar boundaries or roll continuously.
    @Published var periodStyle: InsightsPeriodStyle { didSet { save() } }

    /// Profile
    @Published var soleSize: SoleSize? { didSet { save() } }
    /// Opt-in for future on-device suggestions. Nothing acts on this yet — it
    /// is stored so the preference exists before the feature does, and the UI
    /// says as much rather than implying a capability that is not there.
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

    /// The commanded range on the Advanced target slider.
    static let targetRange: ClosedRange<Double> = 26...40

    /// Which foot the per-foot screens open on.
    @Published var preferredFoot: Foot { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        backendURL = defaults.string(forKey: "thermyx.backendURL") ?? ""
        backendToken = defaults.string(forKey: "thermyx.backendToken") ?? ""
        deviceID = defaults.string(forKey: "thermyx.deviceID") ?? "thermyx-right-01"
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
        let storedSize = defaults.double(forKey: "thermyx.soleSize")
        soleSize = SoleSize.all.first { $0.usMens == storedSize }
        aiSuggestionsEnabled = defaults.object(forKey: "thermyx.aiSuggestionsEnabled") as? Bool ?? false
        preferredFoot = defaults.string(forKey: "thermyx.preferredFoot").flatMap(Foot.init(rawValue:)) ?? .left
        let storedTarget = defaults.double(forKey: "thermyx.targetTemperatureC")
        targetTemperatureC = storedTarget == 0 ? 31 : storedTarget

        alertOnCaution = defaults.object(forKey: "thermyx.alertOnCaution") as? Bool ?? false
        alertOnHighRisk = defaults.object(forKey: "thermyx.alertOnHighRisk") as? Bool ?? true
        alertOnCritical = defaults.object(forKey: "thermyx.alertOnCritical") as? Bool ?? true
        healthKitEnabled = defaults.object(forKey: "thermyx.healthKitEnabled") as? Bool ?? false
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
        defaults.set(backendToken, forKey: "thermyx.backendToken")
        defaults.set(deviceID, forKey: "thermyx.deviceID")
        defaults.set(try? JSONEncoder().encode(contacts), forKey: "thermyx.contacts")
        defaults.set(temperatureUnit.rawValue, forKey: "thermyx.temperatureUnit")
        defaults.set(insightsRange.rawValue, forKey: "thermyx.insightsRange")
        defaults.set(periodStyle.rawValue, forKey: "thermyx.periodStyle")
        defaults.set(soleSize?.usMens ?? 0, forKey: "thermyx.soleSize")
        defaults.set(aiSuggestionsEnabled, forKey: "thermyx.aiSuggestionsEnabled")
        defaults.set(preferredFoot.rawValue, forKey: "thermyx.preferredFoot")
        defaults.set(targetTemperatureC, forKey: "thermyx.targetTemperatureC")
        defaults.set(alertOnCaution, forKey: "thermyx.alertOnCaution")
        defaults.set(alertOnHighRisk, forKey: "thermyx.alertOnHighRisk")
        defaults.set(alertOnCritical, forKey: "thermyx.alertOnCritical")
        defaults.set(healthKitEnabled, forKey: "thermyx.healthKitEnabled")
    }
}
