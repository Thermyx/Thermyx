import Combine
import CoreBluetooth
import Foundation

/// Talks to both insoles at once.
///
/// Thermyx is a pair. The wearer is not asked to pick a foot and switch
/// between them — the app holds a link to each and shows whatever it has. One
/// connected and one not is a normal, supported state, not an error.
///
/// Each link is independent: connecting, dropping, and reconnecting one foot
/// never disturbs the other.
@MainActor
final class ThermyxBLEService: NSObject, ObservableObject {
    // Replace these UUIDs with the UUIDs used by the XIAO firmware.
    nonisolated static let serviceUUID = CBUUID(string: "7B7E0001-7A3B-4D2D-9C9E-000000000001")
    nonisolated static let telemetryUUID = CBUUID(string: "7B7E0002-7A3B-4D2D-9C9E-000000000001")
    nonisolated static let commandUUID = CBUUID(string: "7B7E0003-7A3B-4D2D-9C9E-000000000001")

    // MARK: Published state

    @Published private(set) var state: CBManagerState = .unknown
    /// The latest reading from each foot. A foot with no entry has no data,
    /// and its screens show an empty state rather than the other foot's.
    @Published private(set) var readings: [Foot: ThermyxReading] = [:]
    @Published private(set) var connected: Set<Foot> = []
    @Published private(set) var names: [Foot: String] = [:]
    @Published private(set) var rssi: [Foot: Int] = [:]
    @Published private(set) var errorMessage: String?
    /// Everything seen during the current scan, for the pairing list.
    @Published private(set) var discovered: [DiscoveredDevice] = []
    /// Set when a device connects without declaring which foot it is on, so
    /// the UI can ask.
    @Published var awaitingFootAssignment: DiscoveredDevice?

    struct DiscoveredDevice: Identifiable, Equatable {
        let id: UUID
        let name: String
        let rssi: Int
        /// Declared by the peripheral name, when the firmware says so.
        let advertisedFoot: Foot?
        var isStrong: Bool { rssi > -75 }
    }

    // MARK: Private

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// Peripherals we have accepted, keyed by the foot they serve.
    private var links: [Foot: CBPeripheral] = [:]
    private var commandCharacteristics: [Foot: CBCharacteristic] = [:]
    /// A peripheral connected but not yet assigned a foot.
    private var pendingFoot: [UUID: Foot] = [:]
    fileprivate var packetTimestamps: [Foot: [Date]] = [:]
    private var rssiTimer: Timer?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: Queries

    func isConnected(_ foot: Foot) -> Bool { connected.contains(foot) }
    var anyConnected: Bool { !connected.isEmpty }
    var bothConnected: Bool { connected.count == 2 }
    func reading(for foot: Foot) -> ThermyxReading? { readings[foot] }

    /// Observed notification rate for a foot, shown on Advanced. Nil until
    /// enough packets have arrived to measure one honestly.
    func packetRateHz(_ foot: Foot) -> Double? {
        let window = (packetTimestamps[foot] ?? []).filter { $0.timeIntervalSinceNow > -10 }
        guard window.count >= 3, let first = window.first, let last = window.last else { return nil }
        let span = last.timeIntervalSince(first)
        guard span > 0 else { return nil }
        return Double(window.count - 1) / span
    }

    // MARK: Scanning

    func scan() {
        guard state == .poweredOn else {
            errorMessage = "Bluetooth is unavailable or permission has not been granted."
            return
        }
        errorMessage = nil
        discovered.removeAll()
        central.scanForPeripherals(
            withServices: [Self.serviceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
    }

    func stopScan() { central.stopScan() }

    /// Connect to a discovered device. `foot` is used when the firmware did
    /// not declare one; otherwise the declared foot wins.
    func connect(to device: DiscoveredDevice, as foot: Foot? = nil) {
        guard let target = peripherals[device.id] else { return }
        let assigned = device.advertisedFoot ?? foot
        if let assigned {
            pendingFoot[device.id] = assigned
        }
        central.connect(target, options: nil)
    }

    func disconnect(_ foot: Foot) {
        guard let peripheral = links[foot] else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    func disconnectAll() {
        for foot in links.keys { disconnect(foot) }
    }

    // MARK: Commands

    /// Sends a mode to one foot, or to both when `foot` is nil.
    ///
    /// Commanding both by default is deliberate: a wearer setting Cool means
    /// both feet, and making them set each foot separately would be a chore
    /// with a real failure mode — one foot left heating.
    func send(command: ThermalMode, to foot: Foot? = nil) {
        let targets: [Foot] = foot.map { [$0] } ?? Array(connected)
        guard !targets.isEmpty else {
            errorMessage = "No insole is connected to receive commands."
            return
        }
        let commandByte: UInt8 = switch command {
        case .off: 0
        case .heating: 1
        case .cooling: 2
        case .ventilation: 3
        }
        for target in targets {
            guard let characteristic = commandCharacteristics[target],
                  let peripheral = links[target],
                  characteristic.properties.contains(.write)
            else { continue }
            peripheral.writeValue(Data([1, commandByte]), for: characteristic, type: .withResponse)
        }
    }

    // MARK: Decoding

    private func decodeTelemetry(_ data: Data, from peripheralID: UUID) {
        // Thermyx telemetry, little-endian. See BLE_PROTOCOL.md.
        // [0] version, [1] mode, [2] battery %, [3...4] foot temp centi-C,
        // [5...6] ambient centi-C, [7...8] gait 0...10000,
        // [9...10] pressure balance 0...10000, [11] flags (bits 0-1 = foot),
        // v2+: [12...17] forefoot/arch/heel centi-C,
        // v3+: [18...19] cadence spm x10, [20...21] standing fraction x10000.
        let bytes = [UInt8](data)
        guard let version = bytes.first, (1...3).contains(version) else {
            errorMessage = "Received a telemetry packet in an unsupported format."
            return
        }
        let requiredLength: Int = switch version {
        case 3: 22
        case 2: 18
        default: 12
        }
        guard bytes.count >= requiredLength else {
            errorMessage = "Received an incomplete telemetry packet."
            return
        }

        func int16(_ index: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8) }
        func uint16(_ index: Int) -> UInt16 { UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 }
        func centidegrees(_ index: Int) -> Double { Double(int16(index)) / 100.0 }

        // The packet's own foot declaration wins; otherwise fall back to what
        // the user assigned at pairing.
        guard let foot = Foot.from(flags: bytes[11]) ?? pendingFoot[peripheralID] ?? footFor(peripheralID) else {
            errorMessage = "An insole connected without saying which foot it is on."
            return
        }
        adopt(peripheralID, as: foot)

        var zones: FootZoneTemperatures?
        if version >= 2 {
            let candidate = FootZoneTemperatures(
                forefootC: centidegrees(12),
                archC: centidegrees(14),
                heelC: centidegrees(16)
            )
            // A disconnected or failed thermistor reports a sentinel; treat
            // any implausible zone as all three absent rather than drawing a
            // heat map off a broken channel.
            let plausible = [candidate.forefootC, candidate.archC, candidate.heelC]
                .allSatisfy { (-20...80).contains($0) }
            zones = plausible ? candidate : nil
        }

        var cadence: Double?
        var standing: Double?
        if version >= 3 {
            let rawCadence = uint16(18)
            if rawCadence != UInt16.max { cadence = Double(rawCadence) / 10.0 }
            let rawStanding = uint16(20)
            if rawStanding != UInt16.max { standing = min(1, Double(rawStanding) / 10000.0) }
        }

        let mode: ThermalMode = switch bytes[1] {
        case 1: .heating
        case 2: .cooling
        case 3: .ventilation
        default: .off
        }

        readings[foot] = ThermyxReading(
            foot: foot,
            timestamp: .now,
            footTemperatureC: centidegrees(3),
            ambientTemperatureC: centidegrees(5),
            pressureBalance: Double(uint16(9)) / 10000.0,
            gaitStability: Double(uint16(7)) / 10000.0,
            batteryPercent: Int(bytes[2]),
            thermalMode: mode,
            zones: zones,
            cadenceStepsPerMinute: cadence,
            standingFraction: standing
        )

        var stamps = packetTimestamps[foot] ?? []
        stamps.append(.now)
        if stamps.count > 32 { stamps.removeFirst(stamps.count - 32) }
        packetTimestamps[foot] = stamps
        errorMessage = nil
    }

    private func footFor(_ peripheralID: UUID) -> Foot? {
        links.first { $0.value.identifier == peripheralID }?.key
    }

    private func adopt(_ peripheralID: UUID, as foot: Foot) {
        guard links[foot]?.identifier != peripheralID, let peripheral = peripherals[peripheralID] else { return }
        links[foot] = peripheral
        connected.insert(foot)
        names[foot] = peripheral.name ?? "Thermyx \(foot.label)"
        pendingFoot[peripheralID] = nil
    }

    fileprivate func tearDown(_ peripheralID: UUID) {
        guard let foot = footFor(peripheralID) else { return }
        links[foot] = nil
        commandCharacteristics[foot] = nil
        connected.remove(foot)
        rssi[foot] = nil
        packetTimestamps[foot] = nil
        // Readings stop at the last packet. A stale reading is treated as no
        // reading rather than left on screen looking live.
        readings[foot] = nil
    }
}

// MARK: - Central manager

extension ThermyxBLEService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in self.state = central.state }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let name = peripheral.name
            ?? (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? "Unknown device"
        let strength = RSSI.intValue
        let identifier = peripheral.identifier
        Task { @MainActor in
            self.peripherals[identifier] = peripheral
            let device = DiscoveredDevice(
                id: identifier,
                name: name,
                rssi: strength,
                advertisedFoot: Self.foot(fromName: name)
            )
            if let index = self.discovered.firstIndex(where: { $0.id == identifier }) {
                self.discovered[index] = device
            } else {
                self.discovered.append(device)
            }
            self.discovered.sort { $0.rssi > $1.rssi }
        }
    }

    /// A firmware that names itself `thermyx-left-01` saves the user a step.
    nonisolated static func foot(fromName name: String) -> Foot? {
        let lower = name.lowercased()
        if lower.contains("left") { return .left }
        if lower.contains("right") { return .right }
        return nil
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.errorMessage = nil
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
            self.startRSSIPolling()
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let identifier = peripheral.identifier
        Task { @MainActor in
            self.tearDown(identifier)
            self.errorMessage = error?.localizedDescription ?? "Could not connect to the insole."
        }
    }

    nonisolated func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        let identifier = peripheral.identifier
        Task { @MainActor in
            self.tearDown(identifier)
            if self.connected.isEmpty { self.stopRSSIPolling() }
            if let error { self.errorMessage = error.localizedDescription }
        }
    }
}

// MARK: - Peripheral

extension ThermyxBLEService {
    func startRSSIPolling() {
        guard rssiTimer == nil else { return }
        rssiTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                for peripheral in self.links.values { peripheral.readRSSI() }
            }
        }
    }

    func stopRSSIPolling() {
        rssiTimer?.invalidate()
        rssiTimer = nil
    }
}

extension ThermyxBLEService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        let value = RSSI.intValue
        let identifier = peripheral.identifier
        Task { @MainActor in
            guard let foot = self.footFor(identifier) else { return }
            self.rssi[foot] = value
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.telemetryUUID, Self.commandUUID], for: service)
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard let characteristics = service.characteristics else { return }
        let identifier = peripheral.identifier
        for characteristic in characteristics {
            if characteristic.uuid == Self.commandUUID {
                Task { @MainActor in
                    // The foot is known once the first packet arrives; until
                    // then hold the characteristic against the pending foot.
                    if let foot = self.pendingFoot[identifier] ?? self.footFor(identifier) {
                        self.commandCharacteristics[foot] = characteristic
                    }
                }
            }
            if characteristic.uuid == Self.telemetryUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    nonisolated func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard let data = characteristic.value else { return }
        let identifier = peripheral.identifier
        Task { @MainActor in self.decodeTelemetry(data, from: identifier) }
    }
}

#if DEBUG
extension ThermyxBLEService {
    /// Development-only. Pushes a synthetic reading through the same path a
    /// real packet takes. Compiled out of Release builds.
    func injectPreviewReading(_ reading: ThermyxReading) {
        let foot = reading.foot
        connected.insert(foot)
        names[foot] = "thermyx-\(foot.rawValue)-01 (preview)"
        rssi[foot] = foot == .left ? -58 : -63
        readings[foot] = reading
        var stamps = packetTimestamps[foot] ?? []
        stamps.append(.now)
        if stamps.count > 32 { stamps.removeFirst(stamps.count - 32) }
        packetTimestamps[foot] = stamps
    }

    func injectPreviewDisconnect(_ foot: Foot) {
        connected.remove(foot)
        readings[foot] = nil
        rssi[foot] = nil
    }
}
#endif
