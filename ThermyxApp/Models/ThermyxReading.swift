import Foundation

/// A decoded telemetry packet.
///
/// Every sensor value is optional, and that is load-bearing: the app shows an
/// empty state rather than an estimate whenever a value is missing. Nothing
/// here is ever defaulted to a plausible number.
struct ThermyxReading: Equatable {
    /// Which insole this came from. Every reading in the app is attributed to
    /// a foot; there is no such thing as an unattributed reading.
    let foot: Foot
    let timestamp: Date
    /// Aggregate foot-contact temperature reported by the insole.
    let footTemperatureC: Double?
    let ambientTemperatureC: Double?
    let pressureBalance: Double?
    let gaitStability: Double?
    let batteryPercent: Int?
    let thermalMode: ThermalMode
    /// Per-zone contact temperatures. Present only on protocol v2 hardware;
    /// `nil` on a v1 insole, where the UI collapses to `footTemperatureC`.
    let zones: FootZoneTemperatures?
    /// Steps per minute, from the controller's IMU. Protocol v3 and above.
    let cadenceStepsPerMinute: Double?
    /// Proportion of the reporting window spent loaded but not stepping,
    /// 0...1. Protocol v3 and above.
    let standingFraction: Double?
    /// The setting the insole says it is following (flags bits 2–3), when the
    /// firmware reports it. Lets the app confirm a command actually landed.
    var settingEcho: ThermalSetting?
    /// True while the firmware's own burn cutoff is holding the heater off
    /// (flags bit 4).
    var burnCutoff = false
    /// Whether a foot is on the insole (flags bits 5–6), from firmware that
    /// senses it. Nil when the insole can't tell.
    var footDetected: Bool?

    init(
        foot: Foot,
        timestamp: Date,
        footTemperatureC: Double?,
        ambientTemperatureC: Double?,
        pressureBalance: Double?,
        gaitStability: Double?,
        batteryPercent: Int?,
        thermalMode: ThermalMode,
        zones: FootZoneTemperatures? = nil,
        cadenceStepsPerMinute: Double? = nil,
        standingFraction: Double? = nil
    ) {
        self.foot = foot
        self.timestamp = timestamp
        self.footTemperatureC = footTemperatureC
        self.ambientTemperatureC = ambientTemperatureC
        self.pressureBalance = pressureBalance
        self.gaitStability = gaitStability
        self.batteryPercent = batteryPercent
        self.thermalMode = thermalMode
        self.zones = zones
        self.cadenceStepsPerMinute = cadenceStepsPerMinute
        self.standingFraction = standingFraction
    }

    static func empty(_ foot: Foot) -> ThermyxReading {
        ThermyxReading(
            foot: foot,
            timestamp: .now,
            footTemperatureC: nil,
            ambientTemperatureC: nil,
            pressureBalance: nil,
            gaitStability: nil,
            batteryPercent: nil,
            thermalMode: .off,
            zones: nil,
            cadenceStepsPerMinute: nil,
            standingFraction: nil
        )
    }

    /// True when the packet carried no sensor values at all.
    var hasSensorData: Bool {
        footTemperatureC != nil || ambientTemperatureC != nil
            || pressureBalance != nil || gaitStability != nil
            || cadenceStepsPerMinute != nil
    }
}

/// Forefoot / arch / heel contact temperatures in °C.
///
/// Three-zone sensing is a hardware goal, not a launch dependency: the v2
/// decoder is in place, but a v1 insole simply reports no zones and the app
/// degrades to a single average.
struct FootZoneTemperatures: Equatable {
    let forefootC: Double
    let archC: Double
    let heelC: Double

    var average: Double { (forefootC + archC + heelC) / 3 }

    subscript(zone: FootZone) -> Double {
        switch zone {
        case .forefoot: return forefootC
        case .arch: return archC
        case .heel: return heelC
        }
    }
}

enum FootZone: String, CaseIterable, Identifiable, Codable {
    case forefoot
    case arch
    case heel

    var id: String { rawValue }

    var label: String {
        switch self {
        case .forefoot: return "Forefoot"
        case .arch: return "Arch"
        case .heel: return "Heel"
        }
    }
}

enum ThermalMode: String {
    case heating = "Heating"
    case cooling = "Cooling"
    case ventilation = "Ventilation"
    case off = "Off"

    /// The all-caps form shown in the control bar status slot.
    var statusLabel: String {
        switch self {
        case .heating: return "Heating"
        case .cooling: return "Cooling"
        case .ventilation: return "Auto · ventilating"
        case .off: return "Idle"
        }
    }

    /// Lower-case form for "Cool sent · insole ventilating".
    var shortStatus: String {
        switch self {
        case .heating: return "heating"
        case .cooling: return "cooling"
        case .ventilation: return "ventilating"
        case .off: return "idle"
        }
    }
}

/// What the user selected on the control bar. The device reports back a
/// `ThermalMode`, which may differ — the insole can drop out of heating on its
/// own safety cutoff, and the status slot always shows what the device says.
enum ThermalSetting: String, CaseIterable, Identifiable {
    case cool
    case auto
    case heat

    var id: String { rawValue }

    var label: String {
        switch self {
        case .cool: return "Cool"
        case .auto: return "Auto"
        case .heat: return "Heat"
        }
    }

    var symbol: String {
        switch self {
        case .cool: return "snowflake"
        case .auto: return "a.circle"
        case .heat: return "flame.fill"
        }
    }

    var command: ThermalMode {
        switch self {
        case .cool: return .cooling
        case .auto: return .ventilation
        case .heat: return .heating
        }
    }
}
