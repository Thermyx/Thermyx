import Foundation

/// The single-sensor XIAO ESP32-C3 test firmware.
///
/// Contract (fixed by the firmware, do not change here):
/// - advertises as "Thermyx" with service 7a1b0001-…
/// - one characteristic 7a1b0002-…, READ + NOTIFY
/// - each value is UTF-8 text of an integer 0…4095: a 12-bit ADC reading of
///   0…3.3 V, sent about every 500 ms.
///
/// This is separate from the full two-insole protocol in `ThermyxProtocol`;
/// the app scans for both and handles each on its own path.
enum ThermyxSensorProtocol {
    static let deviceName = "Thermyx"
    static let serviceUUIDString = "7A1B0001-3C5D-4E6F-8A9B-0C1D2E3F4A5B"
    static let valueUUIDString = "7A1B0002-3C5D-4E6F-8A9B-0C1D2E3F4A5B"
    static let maxRaw = 4095
    static let referenceVolts = 3.3

    /// Parses one notification. Anything that is not a whole number in
    /// 0…4095 is rejected rather than clamped, so a garbled packet never
    /// shows up as a plausible value.
    static func parse(_ data: Data) -> Int? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII), let value = Int(trimmed), (0...maxRaw).contains(value) else {
            return nil
        }
        return value
    }
}

/// What the analog pin is wired to. This is the one switch that decides how
/// a raw value is labelled and whether it may feed a body reading.
///
/// - `testInput`: a potentiometer or anything else with no physical meaning.
///   Shown only as the raw value and a percent of full scale.
/// - `fsrLoad`: an FSR402 force-sensitive resistor. Shown as approximate
///   force in newtons and pressure in kPa (see `FSR402`).
/// - `temperature`: a real temperature sensor. Converted to °C only through
///   an explicit `AnalogTemperatureCalibration`; with none set it shows
///   nothing, never a guessed temperature.
enum AnalogSourceKind: String, CaseIterable, Identifiable, Codable {
    case testInput
    case fsrLoad
    case temperature

    var id: String { rawValue }

    var title: String {
        switch self {
        case .testInput: return "Test input"
        case .fsrLoad: return "Force"
        case .temperature: return "Temperature"
        }
    }

    var settingLabel: String {
        switch self {
        case .testInput: return "Test input (knob)"
        case .fsrLoad: return "FSR402 pressure (force N)"
        case .temperature: return "Temperature sensor"
        }
    }

    private static let key = "thermyx.analogSourceKind"

    /// The wiring currently in use. Read when each packet is decoded.
    static var stored: AnalogSourceKind {
        get { UserDefaults.standard.string(forKey: key).flatMap(AnalogSourceKind.init(rawValue:)) ?? .testInput }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: key) }
    }

    /// Temperature needs a calibration before it can be chosen.
    var isAvailable: Bool { self != .temperature || AnalogTemperatureCalibration.current != nil }
}

/// One analog value with what it means.
struct AnalogInput: Equatable {
    /// The ADC count as sent, 0…4095.
    let raw: Int
    let kind: AnalogSourceKind

    /// Share of full scale, 0–100.
    var percent: Double { Double(raw) / Double(ThermyxSensorProtocol.maxRaw) * 100 }
    /// Pin voltage, 0–3.3 V.
    var volts: Double { Double(raw) / Double(ThermyxSensorProtocol.maxRaw) * ThermyxSensorProtocol.referenceVolts }

    /// Approximate force for an FSR source, with the current calibration
    /// scale; nil for any other source.
    var forceN: Double? { kind == .fsrLoad ? FSR402.forceNewtons(raw: raw) : nil }

    /// °C, only for a temperature source with a calibration; otherwise nil.
    var temperatureC: Double? {
        guard kind == .temperature, let calibration = AnalogTemperatureCalibration.current else { return nil }
        return calibration.celsius(fromRaw: raw)
    }
}

/// An FSR402 wired 3.3 V → FSR → ADC node → 10 kΩ → GND, read by a 12-bit
/// ADC over 0–3.3 V. Converts a raw count to approximate force:
///
/// 1. V = raw / 4095 × 3.3
/// 2. raw below 15 is no touch: 0 N
/// 3. R_fsr = 10 kΩ × (3.3 − V) / V
/// 4. G = 1,000,000 / R_fsr (µS), computed as 100 × V / (3.3 − V) so a
///    full-scale reading (R_fsr = 0) never divides by zero
/// 5. F = G / 80 N (approximation from the FSR402 force curve), clamped to
///    0–20 N, then × the calibration scale
/// 6. Pressure = F / 0.1267 kPa over the 12.7 mm round active area
///
/// These are approximations from the datasheet curve, not a calibrated
/// scale; the app labels them "approx." everywhere.
enum FSR402 {
    static let fixedOhms = 10_000.0
    static let noTouchBelowRaw = 15
    static let microsiemensPerNewton = 80.0
    static let maxForceN = 20.0
    /// π × (6.35 mm)² = 126.7 mm², so N / 0.1267 = kPa.
    static let activeAreaFactor = 0.1267
    static let scaleRange: ClosedRange<Double> = 0.1...5.0

    private static let scaleKey = "thermyx.fsrForceScale"

    /// Calibration multiplier, set in Safety → Advanced → Test board.
    static var scale: Double {
        get {
            let stored = UserDefaults.standard.double(forKey: scaleKey)
            return stored == 0 ? 1.0 : min(max(stored, scaleRange.lowerBound), scaleRange.upperBound)
        }
        set { UserDefaults.standard.set(newValue, forKey: scaleKey) }
    }

    /// Conductance in µS; infinite at full scale (the FSR reads 0 Ω).
    static func conductanceMicrosiemens(raw: Int) -> Double {
        let vref = ThermyxSensorProtocol.referenceVolts
        let volts = Double(min(max(raw, 0), ThermyxSensorProtocol.maxRaw)) / Double(ThermyxSensorProtocol.maxRaw) * vref
        let headroom = vref - volts
        guard volts > 0 else { return 0 }
        guard headroom > 0 else { return .infinity }
        // 1e6 / (R_fixed × (Vref − V) / V)
        return 1_000_000 * volts / (fixedOhms * headroom)
    }

    static func forceNewtons(raw: Int, scale: Double = FSR402.scale) -> Double {
        guard raw >= noTouchBelowRaw else { return 0 }
        let force = min(max(conductanceMicrosiemens(raw: raw) / microsiemensPerNewton, 0), maxForceN)
        return force * scale
    }

    static func pressureKPa(forceN: Double) -> Double { forceN / activeAreaFactor }
}

/// Converts a raw ADC count to °C for a real temperature sensor. There is
/// deliberately no default: set `current` in code once the sensor and its
/// wiring are known, e.g.
///
///     AnalogTemperatureCalibration.current = .ntcDivider()      // 10 kΩ NTC, B3950, 10 kΩ to GND
///     AnalogTemperatureCalibration.current = .linear(offsetMillivolts: 500, millivoltsPerC: 10)  // TMP36
struct AnalogTemperatureCalibration {
    let celsius: (Int) -> Double?

    func celsius(fromRaw raw: Int) -> Double? {
        guard let c = celsius(raw), (-20...80).contains(c) else { return nil }
        return c
    }

    static var current: AnalogTemperatureCalibration?

    /// An NTC thermistor on the low side of a divider (fixed resistor to 3.3 V).
    static func ntcDivider(fixedOhms: Double = 10_000, nominalOhms: Double = 10_000, beta: Double = 3950, nominalC: Double = 25) -> AnalogTemperatureCalibration {
        AnalogTemperatureCalibration { raw in
            let fraction = Double(raw) / Double(ThermyxSensorProtocol.maxRaw)
            guard fraction > 0.01, fraction < 0.99 else { return nil }   // open or shorted
            let ohms = fixedOhms * fraction / (1 - fraction)
            let kelvin = 1 / (1 / (nominalC + 273.15) + log(ohms / nominalOhms) / beta)
            return kelvin - 273.15
        }
    }

    /// A linear analog sensor (TMP36-style): °C = (mV − offset) / mV-per-°C.
    static func linear(offsetMillivolts: Double, millivoltsPerC: Double) -> AnalogTemperatureCalibration {
        AnalogTemperatureCalibration { raw in
            let mv = Double(raw) / Double(ThermyxSensorProtocol.maxRaw) * ThermyxSensorProtocol.referenceVolts * 1000
            return (mv - offsetMillivolts) / millivoltsPerC
        }
    }
}

/// A timestamped analog value, for the live trace.
struct AnalogPoint: Equatable, Identifiable {
    let time: Date
    let raw: Int
    let kind: AnalogSourceKind
    /// Force as computed when the value arrived, so changing the calibration
    /// scale later does not rewrite what was shown.
    var forceN: Double? = nil
    var percent: Double { Double(raw) / Double(ThermyxSensorProtocol.maxRaw) * 100 }
    var id: Date { time }
}

/// One minute of analog history, kept beside (not inside) the body-sensor
/// history so a test knob can never appear on a temperature chart.
struct AnalogSample: Codable, Equatable, Identifiable {
    let start: Date
    var kind: AnalogSourceKind
    var count = 0
    var rawMean: Double = 0
    var rawMin = Int.max
    var rawMax = Int.min
    /// Mean approximate force for an FSR minute. Optional so older history
    /// still loads.
    var forceMeanN: Double?

    var id: Date { start }
    var percentMean: Double { rawMean / Double(ThermyxSensorProtocol.maxRaw) * 100 }

    init(start: Date, kind: AnalogSourceKind) {
        self.start = start
        self.kind = kind
    }

    mutating func add(_ raw: Int, forceN: Double? = nil) {
        let n = Double(count)
        rawMean = (rawMean * n + Double(raw)) / (n + 1)
        if let forceN { forceMeanN = ((forceMeanN ?? 0) * n + forceN) / (n + 1) }
        rawMin = min(rawMin, raw)
        rawMax = max(rawMax, raw)
        count += 1
    }
}

/// How the analog link stands, for the status shown in the app.
enum SensorLinkStatus: Equatable {
    case bluetoothUnavailable(String)
    case searching
    case connected(String)
    case disconnected(reconnecting: Bool)

    var label: String {
        switch self {
        case .bluetoothUnavailable(let reason): return reason
        case .searching: return "Searching…"
        case .connected(let name): return "Connected · \(name)"
        case .disconnected(let reconnecting): return reconnecting ? "Disconnected · reconnecting…" : "Disconnected"
        }
    }
}
