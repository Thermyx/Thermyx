import Foundation

@MainActor
final class ThermyxSettingsStore: ObservableObject {
    @Published var backendURL: String { didSet { save() } }
    @Published var backendToken: String { didSet { save() } }
    @Published var deviceID: String { didSet { save() } }
    @Published var contacts: [ThermyxContact] { didSet { save() } }

    private let defaults = UserDefaults.standard

    init() {
        backendURL = defaults.string(forKey: "thermyx.backendURL") ?? ""
        backendToken = defaults.string(forKey: "thermyx.backendToken") ?? ""
        deviceID = defaults.string(forKey: "thermyx.deviceID") ?? "thermyx-right-01"
        if let data = defaults.data(forKey: "thermyx.contacts"), let decoded = try? JSONDecoder().decode([ThermyxContact].self, from: data) {
            contacts = decoded
        } else {
            contacts = []
        }
    }

    func addContact(name: String, phone: String) {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !phone.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        contacts.append(ThermyxContact(name: name, phoneNumber: phone))
    }

    func removeContacts(at offsets: IndexSet) { contacts.remove(atOffsets: offsets) }

    private func save() {
        defaults.set(backendURL, forKey: "thermyx.backendURL")
        defaults.set(backendToken, forKey: "thermyx.backendToken")
        defaults.set(deviceID, forKey: "thermyx.deviceID")
        defaults.set(try? JSONEncoder().encode(contacts), forKey: "thermyx.contacts")
    }
}
