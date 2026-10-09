import Foundation

/// The insole wire format from BLE_PROTOCOL.md, as pure functions so it can
/// be tested without Bluetooth. Packet decoding used to live inside the BLE
/// service; pulling it out follows Aaron Qin's protocol work.
enum ThermyxProtocol {
    enum DecodeError: Error, Equatable {
        case unsupportedVersion(UInt8?)
        case tooShort(length: Int, needed: Int)
    }

    /// One telemetry packet, decoded. Every value the insole could not
    /// measure, or reported implausibly, is nil — never a stand-in number.
    struct Telemetry: Equatable {
        var version: UInt8
        var mode: ThermalMode
        var batteryPercent: Int?
        var footTemperatureC: Double?
        var ambientTemperatureC: Double?
        var gaitStability: Double?
        var pressureBalance: Double?
        var declaredFoot: Foot?
        var settingEcho: ThermalSetting?
        var burnCutoff = false
        var zones: FootZoneTemperatures?
        var cadenceStepsPerMinute: Double?
        var standingFraction: Double?
        /// Flags bit 5 says the insole senses whether a foot is on it; bit 6
        /// is whether one is. Nil from firmware that can't tell.
        var footDetected: Bool? = nil

        func reading(for foot: Foot, at time: Date = .now) -> ThermyxReading {
            var reading = ThermyxReading(
                foot: foot,
                timestamp: time,
                footTemperatureC: footTemperatureC,
                ambientTemperatureC: ambientTemperatureC,
                pressureBalance: pressureBalance,
                gaitStability: gaitStability,
                batteryPercent: batteryPercent,
                thermalMode: mode,
                zones: zones,
                cadenceStepsPerMinute: cadenceStepsPerMinute,
                standingFraction: standingFraction
            )
            reading.settingEcho = settingEcho
            reading.burnCutoff = burnCutoff
            reading.footDetected = footDetected
            return reading
        }
    }

    /// Anything outside this is a disconnected or shorted sensor, not a foot.
    static let plausibleC: ClosedRange<Double> = -20...80
    /// "Not measured" markers.
    static let noTemperature = Int16.min
    static let noValue = UInt16.max
    static let noBattery: UInt8 = 0xFF

    static func requiredLength(for version: UInt8) -> Int? {
        switch version {
        case 1: return 12
        case 2: return 18
        case 3: return 22
        default: return nil
        }
    }

    static func decode(_ data: Data) -> Result<Telemetry, DecodeError> {
        let bytes = [UInt8](data)
        guard let version = bytes.first, let needed = requiredLength(for: version) else {
            return .failure(.unsupportedVersion(bytes.first))
        }
        // A version 3 packet cut to 20 bytes by a 23-byte ATT MTU (the ESP32
        // Arduino default) still carries every version 2 field intact; only
        // cadence and standing are lost. Decode what arrived rather than
        // dropping every packet, which would leave the insole never showing
        // as connected.
        let truncatedV3 = version == 3 && bytes.count >= 18 && bytes.count < needed
        guard bytes.count >= needed || truncatedV3 else { return .failure(.tooShort(length: bytes.count, needed: needed)) }

        func int16(_ i: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8) }
        func uint16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i + 1]) << 8 }
        func temperature(_ i: Int) -> Double? {
            let c = Double(int16(i)) / 100
            return plausibleC.contains(c) ? c : nil
        }
        func fraction(_ i: Int) -> Double? {
            let raw = uint16(i)
            guard raw != noValue, raw <= 10000 else { return nil }
            return Double(raw) / 10000
        }

        let flags = bytes[11]
        var telemetry = Telemetry(
            version: version,
            mode: mode(from: bytes[1]),
            batteryPercent: bytes[2] <= 100 ? Int(bytes[2]) : nil,
            footTemperatureC: temperature(3),
            ambientTemperatureC: temperature(5),
            gaitStability: fraction(7),
            pressureBalance: fraction(9),
            declaredFoot: Foot.from(flags: flags),
            settingEcho: setting(fromFlags: flags),
            burnCutoff: flags & 0b1_0000 != 0
        )
        if flags & 0b10_0000 != 0 { telemetry.footDetected = flags & 0b100_0000 != 0 }

        if version >= 2, let forefoot = temperature(12), let arch = temperature(14), let heel = temperature(16) {
            // All three or none: a heat map off one broken channel would mislead.
            telemetry.zones = FootZoneTemperatures(forefootC: forefoot, archC: arch, heelC: heel)
        }
        if version >= 3, !truncatedV3 {
            let cadence = uint16(18)
            if cadence != noValue { telemetry.cadenceStepsPerMinute = Double(cadence) / 10 }
            telemetry.standingFraction = fraction(20)
        }
        return .success(telemetry)
    }

    static func mode(from byte: UInt8) -> ThermalMode {
        switch byte {
        case 1: return .heating
        case 2: return .cooling
        case 3: return .ventilation
        default: return .off
        }
    }

    static func byte(for mode: ThermalMode) -> UInt8 {
        switch mode {
        case .off: return 0
        case .heating: return 1
        case .cooling: return 2
        case .ventilation: return 3
        }
    }

    /// Flags bits 2–3: 0 = not reported (older firmware), 1 = Cool,
    /// 2 = Auto, 3 = Heat.
    static func setting(fromFlags flags: UInt8) -> ThermalSetting? {
        switch (flags >> 2) & 0b11 {
        case 1: return .cool
        case 2: return .auto
        case 3: return .heat
        default: return nil
        }
    }

    static func flags(foot: Foot?, echo: ThermalSetting?, burnCutoff: Bool, footDetected: Bool? = nil) -> UInt8 {
        var footBits: UInt8 = 0
        if let foot { footBits = foot == .left ? 1 : 2 }
        var echoBits: UInt8 = 0
        if let echo {
            switch echo {
            case .cool: echoBits = 1
            case .auto: echoBits = 2
            case .heat: echoBits = 3
            // Off has no echo code; the active mode byte (0) confirms it.
            case .off: echoBits = 0
            }
        }
        let footSense: UInt8 = footDetected.map { $0 ? 0b110_0000 : 0b10_0000 } ?? 0
        return footBits | echoBits << 2 | (burnCutoff ? 0b1_0000 : 0) | footSense
    }

    // MARK: Commands

    static func command(_ mode: ThermalMode) -> Data { Data([1, byte(for: mode)]) }

    static func target(_ celsius: Double) -> Data {
        let raw = UInt16(bitPattern: Int16(clamping: Int((celsius * 100).rounded())))
        return Data([2, UInt8(raw & 0xFF), UInt8(raw >> 8)])
    }

    // MARK: Encoding (tests and documentation)

    /// Builds a version 3 packet, as the firmware would.
    static func encode(_ t: Telemetry) -> Data {
        var bytes = [UInt8](repeating: 0, count: 22)
        func put(_ value: UInt16, at i: Int) { bytes[i] = UInt8(value & 0xFF); bytes[i + 1] = UInt8(value >> 8) }
        func putTemp(_ c: Double?, at i: Int) {
            put(UInt16(bitPattern: c.map { Int16(clamping: Int(($0 * 100).rounded())) } ?? noTemperature), at: i)
        }
        func putFraction(_ f: Double?, at i: Int) { put(f.map { UInt16(($0 * 10000).rounded()) } ?? noValue, at: i) }
        bytes[0] = 3
        bytes[1] = byte(for: t.mode)
        bytes[2] = t.batteryPercent.map { UInt8(clamping: $0) } ?? noBattery
        putTemp(t.footTemperatureC, at: 3)
        putTemp(t.ambientTemperatureC, at: 5)
        putFraction(t.gaitStability, at: 7)
        putFraction(t.pressureBalance, at: 9)
        bytes[11] = flags(foot: t.declaredFoot, echo: t.settingEcho, burnCutoff: t.burnCutoff, footDetected: t.footDetected)
        putTemp(t.zones?.forefootC, at: 12)
        putTemp(t.zones?.archC, at: 14)
        putTemp(t.zones?.heelC, at: 16)
        put(t.cadenceStepsPerMinute.map { UInt16(($0 * 10).rounded()) } ?? noValue, at: 18)
        putFraction(t.standingFraction, at: 20)
        return Data(bytes)
    }
}
