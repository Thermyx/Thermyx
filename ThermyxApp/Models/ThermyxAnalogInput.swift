import Combine
import Foundation

// MARK: - Wire format

/// The single-sensor XIAO ESP32-C3 test board.
///
/// - service 7a1b0001-…, characteristic 7a1b0002-… (READ + NOTIFY)
/// - each value is one UTF-8 text line `TYPE,CHANNEL,VALUE`, e.g.
///   `NTC,0,2410`, `FSR,1,812`, `TMP102,0,23.50`
/// - a bare integer with no commas is the older firmware: `KNOB,0`
///
/// Separate from the full two-insole protocol (`ThermyxProtocol`). Board
/// readings never become `ThermyxReading`s, so they cannot reach risk levels,
/// alerts, or Apple Health.
enum ThermyxSensorProtocol {
    static let serviceUUIDString = "7A1B0001-3C5D-4E6F-8A9B-0C1D2E3F4A5B"
    static let valueUUIDString = "7A1B0002-3C5D-4E6F-8A9B-0C1D2E3F4A5B"
    static let maxRaw = 4095
    static let referenceVolts = 3.3
    static let maxChannel = 255
    /// TMP102 range with margin; anything outside is a bad reading.
    static let tmp102Range: ClosedRange<Double> = -55...150

    static func parse(_ data: Data) -> SensorPacket? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        return parse(line: text)
    }

    /// Parses one line, or returns nil for anything malformed or out of range.
    static func parse(line: String) -> SensorPacket? {
        let trimmed = line.trimmingCharacters(in: CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: "\0")))
        guard !trimmed.isEmpty, trimmed.allSatisfy(\.isASCII) else { return nil }

        // Older firmware: a bare 0…4095 integer is the test knob.
        if !trimmed.contains(",") {
            guard let raw = rawCount(trimmed) else { return nil }
            return SensorPacket(key: SensorKey(type: .knob, channel: 0), value: .raw(raw))
        }

        let parts = trimmed.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3,
              !parts[0].isEmpty, parts[0].allSatisfy({ $0.isLetter || $0.isNumber || $0 == "_" }),
              parts[1].allSatisfy(\.isNumber), let channel = Int(parts[1]), (0...maxChannel).contains(channel)
        else { return nil }

        let type = SensorType(code: parts[0])
        let value: SensorValue
        switch type {
        case .tmp102:
            guard let celsius = decimal(parts[2]), tmp102Range.contains(celsius) else { return nil }
            value = .celsius(celsius)
        case .ntc, .fsr, .knob:
            guard let raw = rawCount(parts[2]) else { return nil }
            value = .raw(raw)
        case .unknown:
            if let raw = rawCount(parts[2]) {
                value = .raw(raw)
            } else if let number = decimal(parts[2]) {
                value = .number(number)
            } else {
                return nil
            }
        }
        return SensorPacket(key: SensorKey(type: type, channel: channel), value: value)
    }

    /// Digits only, 0…4095.
    private static func rawCount(_ text: String) -> Int? {
        guard !text.isEmpty, text.allSatisfy(\.isNumber), let value = Int(text), (0...maxRaw).contains(value) else { return nil }
        return value
    }

    /// `-12`, `23.5`, `23.50`: no exponents, no "nan", no "inf".
    private static func decimal(_ text: String) -> Double? {
        var body = Substring(text)
        if body.first == "-" { body = body.dropFirst() }
        let pieces = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (1...2).contains(pieces.count),
              pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }),
              let value = Double(text), value.isFinite
        else { return nil }
        return value
    }
}

enum SensorType: Hashable {
    case ntc, tmp102, fsr, knob
    case unknown(String)

    init(code: String) {
        switch code.uppercased() {
        case "NTC": self = .ntc
        case "TMP102": self = .tmp102
        case "FSR": self = .fsr
        case "KNOB": self = .knob
        default: self = .unknown(code.uppercased())
        }
    }

    var code: String {
        switch self {
        case .ntc: return "NTC"
        case .tmp102: return "TMP102"
        case .fsr: return "FSR"
        case .knob: return "KNOB"
        case .unknown(let code): return code
        }
    }

    var isTemperature: Bool { self == .ntc || self == .tmp102 }

    var label: String {
        switch self {
        case .ntc: return "Temperature (NTC)"
        case .tmp102: return "Temperature (TMP102)"
        case .fsr: return "Force (FSR402)"
        case .knob: return "Test input"
        case .unknown(let code): return "Unknown sensor (\(code))"
        }
    }
}

struct SensorKey: Hashable, Comparable, Identifiable {
    let type: SensorType
    let channel: Int

    var id: String { "\(type.code)#\(channel)" }

    /// Order for lists and the main page when nothing else decides:
    /// TMP102, NTC, FSR, KNOB, unknown, then channel.
    var rank: Int {
        switch type {
        case .tmp102: return 0
        case .ntc: return 1
        case .fsr: return 2
        case .knob: return 3
        case .unknown: return 4
        }
    }

    static func < (a: SensorKey, b: SensorKey) -> Bool {
        if a.rank != b.rank { return a.rank < b.rank }
        if a.type.code != b.type.code { return a.type.code < b.type.code }
        return a.channel < b.channel
    }
}

enum SensorValue: Equatable {
    /// 0…4095, where 4095 = 3.3 V.
    case raw(Int)
    /// Already in °C (TMP102).
    case celsius(Double)
    /// A decimal from a sensor type the app doesn't know.
    case number(Double)

    var raw: Int? { if case .raw(let r) = self { return r } else { return nil } }
}

struct SensorPacket: Equatable {
    let key: SensorKey
    let value: SensorValue
}

/// What the board says it is, or what the user forces it to be.
enum SensorTypeOverride: String, CaseIterable, Identifiable {
    case auto, ntc, fsr, knob

    var id: String { rawValue }

    var label: String {
        switch self {
        case .auto: return "Auto (from the board)"
        case .ntc: return "NTC thermistor"
        case .fsr: return "FSR402 force"
        case .knob: return "Test input (knob)"
        }
    }

    /// Applies to raw 0…4095 readings only; a TMP102's °C is never relabelled.
    func apply(to packet: SensorPacket) -> SensorPacket {
        guard packet.value.raw != nil else { return packet }
        let forced: SensorType
        switch self {
        case .auto: return packet
        case .ntc: forced = .ntc
        case .fsr: forced = .fsr
        case .knob: forced = .knob
        }
        return SensorPacket(key: SensorKey(type: forced, channel: packet.key.channel), value: packet.value)
    }
}

// MARK: - Conversions

enum AnalogPin {
    static func volts(raw: Int) -> Double {
        Double(min(max(raw, 0), ThermyxSensorProtocol.maxRaw)) / Double(ThermyxSensorProtocol.maxRaw) * ThermyxSensorProtocol.referenceVolts
    }
}

/// 10 kΩ NTC, B = 3950, wired 3.3 V → thermistor → ADC → 10 kΩ → GND, so
/// the raw count rises as it warms.
///
/// R = 10 kΩ × (4095 / raw − 1); 1/T = 1/298.15 + ln(R / 10 kΩ) / 3950.
/// raw 2048 → about 25.0 °C.
enum NTCThermistor {
    static let fixedOhms = 10_000.0
    static let nominalOhms = 10_000.0
    static let beta = 3950.0
    static let nominalKelvin = 298.15
    /// Readings outside this show "--".
    static let displayRange: ClosedRange<Double> = -20...100
    static let smoothingWindow = 5

    /// °C before smoothing and calibration, or nil at the rails
    /// (raw 0 = open circuit, raw 4095 = short), which would divide by zero.
    static func celsius(raw: Int) -> Double? {
        guard raw > 0, raw < ThermyxSensorProtocol.maxRaw else { return nil }
        let ohms = fixedOhms * (Double(ThermyxSensorProtocol.maxRaw) / Double(raw) - 1)
        guard ohms > 0 else { return nil }
        let inverse = 1 / nominalKelvin + log(ohms / nominalOhms) / beta
        guard inverse > 0 else { return nil }
        let celsius = 1 / inverse - 273.15
        return celsius.isFinite ? celsius : nil
    }
}

/// FSR402 wired 3.3 V → FSR → ADC → 10 kΩ → GND.
///
/// V = raw/4095 × 3.3; raw < 15 is 0 N; R = 10 kΩ × (3.3 − V)/V;
/// G = 1,000,000 / R µS; F = G / 80 N, clamped to 0–20 N, × scale;
/// kPa = F / 0.1267 (12.7 mm round pad). Approximations from the datasheet.
enum FSR402 {
    static let fixedOhms = 10_000.0
    static let noTouchBelowRaw = 15
    static let microsiemensPerNewton = 80.0
    static let maxForceN = 20.0
    static let activeAreaFactor = 0.1267
    static let scaleRange: ClosedRange<Double> = 0.1...5.0

    /// µS, computed as 100 × V / (3.3 − V) so full scale (R = 0) is
    /// infinity rather than a divide by zero.
    static func conductanceMicrosiemens(raw: Int) -> Double {
        let volts = AnalogPin.volts(raw: raw)
        let headroom = ThermyxSensorProtocol.referenceVolts - volts
        guard volts > 0 else { return 0 }
        guard headroom > 0 else { return .infinity }
        return 1_000_000 * volts / (fixedOhms * headroom)
    }

    static func forceNewtons(raw: Int, scale: Double) -> Double {
        guard raw >= noTouchBelowRaw else { return 0 }
        let force = min(max(conductanceMicrosiemens(raw: raw) / microsiemensPerNewton, 0), maxForceN)
        return force * scale
    }

    static func pressureKPa(forceN: Double) -> Double { forceN / activeAreaFactor }
}

func fahrenheit(_ celsius: Double) -> Double { celsius * 9 / 5 + 32 }

/// Calibration that applies to board readings, read on each conversion.
struct SensorCalibration: Equatable {
    var ntcOffsetC: Double = 0
    var fsrScale: Double = 1
}

// MARK: - Live table

/// One sensor's current state on the board.
struct SensorChannel: Identifiable, Equatable {
    let key: SensorKey
    var value: SensorValue
    var lastSeen: Date
    /// The last few NTC conversions (°C, before the offset), for the
    /// 5-sample moving average.
    var ntcWindow: [Double] = []
    /// Two minutes of chart values, oldest first.
    var trace: [SensorTracePoint] = []

    var id: String { key.id }
}

struct SensorTracePoint: Equatable, Identifiable {
    let time: Date
    let value: Double
    var id: Date { time }
}

/// What a sensor shows, in its own units.
struct SensorDisplay: Equatable {
    let title: String
    /// "24.9 °C", "1.25 N", "2048", or "--".
    let primary: String
    /// "76.8 °F", "9.9 kPa approx.", "1.65 V", or nil.
    let secondary: String?
    /// The number the graphs plot, in `chartUnit`; nil when there is none.
    let chartValue: Double?
    let chartUnit: String
}

enum SensorReadout {
    static func display(_ channel: SensorChannel, calibration: SensorCalibration) -> SensorDisplay {
        let title = channel.key.type.label
        switch channel.key.type {
        case .ntc:
            guard let c = ntcCelsius(channel, calibration: calibration) else {
                return SensorDisplay(title: title, primary: "--", secondary: nil, chartValue: nil, chartUnit: "°C")
            }
            return temperature(c, title: title)
        case .tmp102:
            guard case .celsius(let c) = channel.value else {
                return SensorDisplay(title: title, primary: "--", secondary: nil, chartValue: nil, chartUnit: "°C")
            }
            return temperature(c, title: title)
        case .fsr:
            let force = FSR402.forceNewtons(raw: channel.value.raw ?? 0, scale: calibration.fsrScale)
            return SensorDisplay(
                title: title,
                primary: String(format: "%.2f N", force),
                secondary: String(format: "%.1f kPa approx.", FSR402.pressureKPa(forceN: force)),
                chartValue: force,
                chartUnit: "N"
            )
        case .knob:
            let raw = channel.value.raw ?? 0
            return SensorDisplay(
                title: title,
                primary: "\(raw)",
                secondary: String(format: "%.2f V", AnalogPin.volts(raw: raw)),
                chartValue: Double(raw),
                chartUnit: "raw"
            )
        case .unknown:
            let text: String
            let number: Double
            switch channel.value {
            case .raw(let r): text = "\(r)"; number = Double(r)
            case .celsius(let c), .number(let c): text = String(format: "%g", c); number = c
            }
            return SensorDisplay(title: title, primary: text, secondary: nil, chartValue: number, chartUnit: "raw")
        }
    }

    /// Smoothed NTC °C with the offset, or nil if out of -20…100 °C.
    static func ntcCelsius(_ channel: SensorChannel, calibration: SensorCalibration) -> Double? {
        guard !channel.ntcWindow.isEmpty else { return nil }
        let mean = channel.ntcWindow.reduce(0, +) / Double(channel.ntcWindow.count) + calibration.ntcOffsetC
        return NTCThermistor.displayRange.contains(mean) ? mean : nil
    }

    private static func temperature(_ c: Double, title: String) -> SensorDisplay {
        SensorDisplay(
            title: title,
            primary: String(format: "%.1f °C", c),
            secondary: String(format: "%.1f °F", fahrenheit(c)),
            chartValue: c,
            chartUnit: "°C"
        )
    }
}

/// The board's live sensors, keyed by (TYPE, CHANNEL). Pure, so the 5-second
/// rule and smoothing are unit tested.
struct SensorTable: Equatable {
    static let timeout: TimeInterval = 5
    static let traceSeconds: TimeInterval = 120

    private(set) var channels: [SensorKey: SensorChannel] = [:]

    mutating func ingest(_ packet: SensorPacket, at time: Date, calibration: SensorCalibration) {
        var channel = channels[packet.key] ?? SensorChannel(key: packet.key, value: packet.value, lastSeen: time)
        channel.value = packet.value
        channel.lastSeen = time
        if packet.key.type == .ntc, let raw = packet.value.raw, let c = NTCThermistor.celsius(raw: raw) {
            channel.ntcWindow.append(c)
            if channel.ntcWindow.count > NTCThermistor.smoothingWindow {
                channel.ntcWindow.removeFirst(channel.ntcWindow.count - NTCThermistor.smoothingWindow)
            }
        }
        if let value = SensorReadout.display(channel, calibration: calibration).chartValue {
            channel.trace.append(SensorTracePoint(time: time, value: value))
            let cutoff = time.addingTimeInterval(-Self.traceSeconds)
            channel.trace.removeAll { $0.time < cutoff }
        }
        channels[packet.key] = channel
    }

    /// Drops sensors with no reading in the last 5 seconds. Returns true if
    /// anything was removed.
    @discardableResult
    mutating func expire(now: Date) -> Bool {
        let before = channels.count
        channels = channels.filter { now.timeIntervalSince($0.value.lastSeen) <= Self.timeout }
        return channels.count != before
    }

    mutating func removeAll() { channels.removeAll() }

    /// Connected sensors in display order.
    var connected: [SensorChannel] { channels.values.sorted { $0.key < $1.key } }

    /// The one sensor the main page shows: any temperature first (TMP102
    /// before NTC, then the lowest channel), otherwise FSR, then KNOB, then
    /// unknown.
    static func mainSensor(among keys: [SensorKey]) -> SensorKey? {
        keys.min()
    }
}

// MARK: - Reconnect rules

/// What the app remembers about the board between launches.
struct BoardMemory: Codable, Equatable {
    var peripheralID: UUID?
    var name: String?
    /// True once the user taps Disconnect, until they connect again by hand.
    var userDisconnected = false

    private static let key = "thermyx.board.memory"

    static func load(_ defaults: UserDefaults = .standard) -> BoardMemory {
        guard let data = defaults.data(forKey: key), let memory = try? JSONDecoder().decode(BoardMemory.self, from: data) else {
            return BoardMemory()
        }
        return memory
    }

    func save(_ defaults: UserDefaults = .standard) {
        if let data = try? JSONEncoder().encode(self) { defaults.set(data, forKey: Self.key) }
    }
}

/// The four reconnect rules, as pure functions.
enum BoardReconnectPolicy {
    /// 1. A board the user connected by hand is remembered.
    static func afterManualConnect(id: UUID, name: String) -> BoardMemory {
        BoardMemory(peripheralID: id, name: name, userDisconnected: false)
    }

    /// 3. Disconnect stops automatic reconnection until the next manual connect.
    static func afterUserDisconnect(_ memory: BoardMemory) -> BoardMemory {
        var next = memory
        next.userDisconnected = true
        return next
    }

    /// 2. An unexpected drop reconnects to the remembered board.
    static func shouldReconnectAfterDrop(_ memory: BoardMemory, peripheral: UUID) -> Bool {
        memory.peripheralID == peripheral && !memory.userDisconnected
    }

    /// 4. On launch, reconnect only if the user didn't disconnect last time.
    /// Never connects to a board that was never chosen by hand.
    static func boardToReconnectOnLaunch(_ memory: BoardMemory) -> UUID? {
        memory.userDisconnected ? nil : memory.peripheralID
    }
}

/// Connection state shown to the user.
enum BoardLinkState: Equatable {
    case notConnected
    case scanning
    case connecting(String)
    case connected(String)
    case reconnecting(String)

    var label: String {
        switch self {
        case .notConnected: return "Not connected"
        case .scanning: return "Scanning…"
        case .connecting: return "Connecting…"
        case .connected(let name): return "Connected · \(name)"
        case .reconnecting: return "Reconnecting…"
        }
    }

    var isConnected: Bool { if case .connected = self { return true } else { return false } }
}

// MARK: - Store

/// Feeds board packets into the live table, expires quiet sensors, and
/// keeps per-minute history. Lives beside (never inside) the insole data.
@MainActor
final class SensorBoardStore: ObservableObject {
    @Published private(set) var table = SensorTable()
    @Published var typeOverride: SensorTypeOverride {
        didSet { UserDefaults.standard.set(typeOverride.rawValue, forKey: Self.overrideKey) }
    }
    @Published var calibration: SensorCalibration {
        didSet {
            UserDefaults.standard.set(calibration.ntcOffsetC, forKey: Self.offsetKey)
            UserDefaults.standard.set(calibration.fsrScale, forKey: Self.scaleKey)
        }
    }
    /// The last raw count per sensor, for the debug line on Advanced.
    var debugRaw: [(SensorKey, Int)] {
        table.connected.compactMap { channel in channel.value.raw.map { (channel.key, $0) } }
    }

    private weak var history: ThermyxHistoryStore?
    /// False in Demo Mode, so simulated values are never kept.
    var recordsHistory: () -> Bool = { true }
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?

    private static let overrideKey = "thermyx.board.override"
    private static let offsetKey = "thermyx.board.ntcOffsetC"
    private static let scaleKey = "thermyx.fsrForceScale"

    init(packets: AnyPublisher<SensorPacket, Never>, history: ThermyxHistoryStore?) {
        let defaults = UserDefaults.standard
        typeOverride = defaults.string(forKey: Self.overrideKey).flatMap(SensorTypeOverride.init(rawValue:)) ?? .auto
        let scale = defaults.double(forKey: Self.scaleKey)
        calibration = SensorCalibration(
            ntcOffsetC: defaults.double(forKey: Self.offsetKey),
            fsrScale: scale == 0 ? 1 : min(max(scale, FSR402.scaleRange.lowerBound), FSR402.scaleRange.upperBound)
        )
        self.history = history
        packets
            .receive(on: RunLoop.main)
            .sink { [weak self] packet in self?.ingest(packet, at: .now) }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.expire(now: .now) }
        }
    }

    func ingest(_ packet: SensorPacket, at time: Date) {
        let packet = typeOverride.apply(to: packet)
        table.ingest(packet, at: time, calibration: calibration)
        if recordsHistory(), let channel = table.channels[packet.key],
           let value = SensorReadout.display(channel, calibration: calibration).chartValue {
            history?.recordSensor(key: packet.key.id, value: value, at: time)
        }
    }

    func expire(now: Date) {
        var next = table
        if next.expire(now: now) { table = next }
    }

    func clear() { table.removeAll() }

    func display(_ channel: SensorChannel) -> SensorDisplay {
        SensorReadout.display(channel, calibration: calibration)
    }

    var mainChannel: SensorChannel? {
        SensorTable.mainSensor(among: table.connected.map(\.key)).flatMap { table.channels[$0] }
    }
}

/// One minute of a board sensor's chart value, kept beside (not inside) the
/// body-sensor history.
struct SensorMinute: Codable, Equatable, Identifiable {
    /// `TYPE#CHANNEL`, e.g. `NTC#0`.
    let key: String
    let start: Date
    var count = 0
    var mean: Double = 0

    var id: String { "\(key)-\(start.timeIntervalSince1970)" }

    init(key: String, start: Date) {
        self.key = key
        self.start = start
    }

    mutating func add(_ value: Double) {
        mean = (mean * Double(count) + value) / Double(count + 1)
        count += 1
    }
}
