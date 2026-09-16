import Foundation

struct ThermyxReading: Equatable {
    let timestamp: Date
    let footTemperatureC: Double?
    let ambientTemperatureC: Double?
    let pressureBalance: Double?
    let gaitStability: Double?
    let batteryPercent: Int?
    let thermalMode: ThermalMode

    static let empty = ThermyxReading(
        timestamp: .now,
        footTemperatureC: nil,
        ambientTemperatureC: nil,
        pressureBalance: nil,
        gaitStability: nil,
        batteryPercent: nil,
        thermalMode: .off
    )
}

enum ThermalMode: String {
    case heating = "Heating"
    case cooling = "Cooling"
    case ventilation = "Ventilation"
    case off = "Off"
}
