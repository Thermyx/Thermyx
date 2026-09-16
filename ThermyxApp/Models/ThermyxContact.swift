import Foundation

struct ThermyxContact: Codable, Identifiable, Equatable {
    let id: UUID
    var name: String
    var phoneNumber: String
    var enabled: Bool

    init(name: String, phoneNumber: String, enabled: Bool = true) {
        self.id = UUID()
        self.name = name
        self.phoneNumber = phoneNumber
        self.enabled = enabled
    }
}

struct ThermyxAlertEvent: Codable {
    let deviceID: String
    let level: String
    let reasons: [String]
    let recipients: [String]
    let timestamp: Date
    let readings: AlertReadings

    struct AlertReadings: Codable {
        let footTemperatureC: Double?
        let ambientTemperatureC: Double?
        let gaitStability: Double?
        let pressureBalance: Double?
        let batteryPercent: Int?
    }
}
