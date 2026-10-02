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
    private var watchdogTimer: Timer?
    /// Peripherals the user asked to disconnect. Anything else that drops is
    /// reconnected automatically.
    private var userDisconnects: Set<UUID> = []

    /// Seconds without a packet before a foot's reading is treated as stale
    /// and cleared, rather than left on screen looking live.
    nonisolated static let staleAfter: TimeInterval = 5
    private static let knownInsolesKey = "thermyx.knownInsoles"
    private static let restoreIdentifier = "com.thermyx.app.central"

    /// The simulated pair, when Demo Mode is on (Advanced → Demo Mode, or
    /// `-ThermyxUIPreview simulator` in development). While it runs, every
    /// screen carries "Simulated — not live sensor data", and nothing is sent
    /// to the relay, written to history, Apple Health, or the baseline.
    private(set) var simulator: ThermyxInsoleSimulator?
    @Published private(set) var isDemoMode = false

    override init() {
        super.init()
        startWatchdog()
        #if DEBUG
        if ThermyxPreviewHarness.isSimulated {
            state = .poweredOn
            simulator = ThermyxInsoleSimulator(ble: self)
            isDemoMode = true
            return
        }
        #endif
        // The restore identifier lets iOS relaunch the app in the background
        // and hand back its insole connections (needs the bluetooth-central
        // background mode in Info.plist).
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Demo Mode

    /// Swaps the real radio for the simulated pair. Real insoles are
    /// disconnected first so simulated and live readings can never mix.
    func startDemoMode() {
        guard simulator == nil else { return }
        // Drop real links without forgetting the insoles, so they reconnect
        // when Demo Mode ends. Pending reconnects are cancelled too.
        if central != nil {
            if central.state == .poweredOn { central.stopScan() }
            let ids = Set(links.values.map(\.identifier)).union(pendingFoot.keys)
            for id in ids {
                userDisconnects.insert(id)
                if let peripheral = links.values.first(where: { $0.identifier == id }) ?? peripherals[id] {
                    central.cancelPeripheralConnection(peripheral)
                }
                tearDown(id)
            }
            pendingFoot.removeAll()
        }
        readings.removeAll()
        discovered.removeAll()
        simulator = ThermyxInsoleSimulator(ble: self)
        isDemoMode = true
        state = .poweredOn
        simulator?.connectAll()
    }

    /// Ends Demo Mode and returns to real Bluetooth.
    func stopDemoMode() {
        guard let simulator else { return }
        for foot in Foot.allCases { simulator.disconnect(foot) }
        simulator.shutdown()
        self.simulator = nil
        isDemoMode = false
        readings.removeAll()
        discovered.removeAll()
        userDisconnects.removeAll()
        if central == nil {
            central = CBCentralManager(
                delegate: self,
                queue: nil,
                options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
            )
        } else {
            state = central.state
            reconnectKnownInsoles()
        }
    }

    // MARK: - Stale-data watchdog

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkForStaleFeet() }
        }
    }

    /// A connected insole that stops sending keeps its link up, so a
    /// disconnect never fires. Clear its reading after `staleAfter` seconds
    /// so the screens fall back to their empty state instead of freezing.
    private func checkForStaleFeet() {
        for foot in connected {
            guard readings[foot] != nil,
                  let last = packetTimestamps[foot]?.last,
                  Date.now.timeIntervalSince(last) > Self.staleAfter
            else { continue }
            readings[foot] = nil
            errorMessage = "\(foot.label) insole stopped sending data. Readings will return when it does."
        }
    }

    // MARK: - Remembered insoles

    private var knownInsoles: [Foot: UUID] {
        get {
            let stored = UserDefaults.standard.dictionary(forKey: Self.knownInsolesKey) as? [String: String] ?? [:]
            var result: [Foot: UUID] = [:]
            for (key, value) in stored {
                if let foot = Foot(rawValue: key), let id = UUID(uuidString: value) { result[foot] = id }
            }
            return result
        }
        set {
            let encoded = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.rawValue, $0.value.uuidString) })
            UserDefaults.standard.set(encoded, forKey: Self.knownInsolesKey)
        }
    }

    /// Reconnects the insoles paired in an earlier session. iOS holds the
    /// request open, so each connects as soon as it is switched on in range.
    fileprivate func reconnectKnownInsoles() {
        let known = knownInsoles.filter { !connected.contains($0.key) }
        guard !known.isEmpty else { return }
        let found = central.retrievePeripherals(withIdentifiers: Array(known.values))
        for peripheral in found {
            guard let foot = known.first(where: { $0.value == peripheral.identifier })?.key else { continue }
            peripherals[peripheral.identifier] = peripheral
            pendingFoot[peripheral.identifier] = foot
            central.connect(peripheral, options: nil)
        }
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
        if let simulator {
            errorMessage = nil
            discovered.removeAll()
            simulator.startScan()
            return
        }
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

    func stopScan() {
        if let simulator { simulator.stopScan(); return }
        central.stopScan()
    }

    /// Connect to a discovered device. `foot` is used when the firmware did
    /// not declare one; otherwise the declared foot wins.
    func connect(to device: DiscoveredDevice, as foot: Foot? = nil) {
        if let simulator { simulator.connect(device, as: foot); return }
        guard let target = peripherals[device.id] else { return }
        let assigned = device.advertisedFoot ?? foot
        if let assigned {
            pendingFoot[device.id] = assigned
        }
        central.connect(target, options: nil)
    }

    func disconnect(_ foot: Foot) {
        if let simulator { simulator.disconnect(foot); return }
        guard let peripheral = links[foot] else { return }
        userDisconnects.insert(peripheral.identifier)
        var known = knownInsoles
        known[foot] = nil
        knownInsoles = known
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
        if let simulator {
            for target in targets { simulator.command(command, to: target) }
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

    /// Sends the hold temperature used by Auto: `[2, int16 °C × 100]`,
    /// little-endian (see BLE_PROTOCOL.md). Firmware that predates the
    /// command ignores it.
    func send(targetTemperatureC celsius: Double, to foot: Foot? = nil) {
        let targets: [Foot] = foot.map { [$0] } ?? Array(connected)
        if let simulator {
            for target in targets { simulator.setTarget(celsius, for: target) }
            return
        }
        let centi = Int16(clamping: Int((celsius * 100).rounded()))
        let raw = UInt16(bitPattern: centi)
        let packet = Data([2, UInt8(raw & 0xFF), UInt8(raw >> 8)])
        for target in targets {
            guard let characteristic = commandCharacteristics[target],
                  let peripheral = links[target],
                  characteristic.properties.contains(.write)
            else { continue }
            peripheral.writeValue(packet, for: characteristic, type: .withResponse)
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

        // A disconnected or shorted thermistor reads far outside anything a
        // foot or the air can be. Treat it as missing, never as a reading.
        func plausible(_ celsius: Double) -> Double? { (-20...80).contains(celsius) ? celsius : nil }

        readings[foot] = ThermyxReading(
            foot: foot,
            timestamp: .now,
            footTemperatureC: plausible(centidegrees(3)),
            ambientTemperatureC: plausible(centidegrees(5)),
            // 0xFFFF / 0xFF mean "not measured" (e.g. no steps yet, no load,
            // no battery sense fitted) and are shown as missing.
            pressureBalance: uint16(9) == UInt16.max ? nil : min(1, Double(uint16(9)) / 10000.0),
            gaitStability: uint16(7) == UInt16.max ? nil : min(1, Double(uint16(7)) / 10000.0),
            batteryPercent: bytes[2] <= 100 ? Int(bytes[2]) : nil,
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
        userDisconnects.remove(peripheralID)
        var known = knownInsoles
        known[foot] = peripheralID
        knownInsoles = known
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
        let newState = central.state
        Task { @MainActor in
            self.state = newState
            if newState == .poweredOn { self.reconnectKnownInsoles() }
        }
    }

    /// iOS relaunched the app in the background and is handing back the
    /// connections it kept alive. Re-adopt them so monitoring carries on.
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        Task { @MainActor in
            let known = self.knownInsoles
            for peripheral in restored {
                self.peripherals[peripheral.identifier] = peripheral
                if let foot = known.first(where: { $0.value == peripheral.identifier })?.key {
                    self.pendingFoot[peripheral.identifier] = foot
                }
                peripheral.delegate = self
                if peripheral.state == .connected {
                    peripheral.discoverServices([Self.serviceUUID])
                    self.startRSSIPolling()
                }
            }
        }
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
            // A real insole must never join a simulated session.
            if self.simulator != nil {
                self.userDisconnects.insert(peripheral.identifier)
                central.cancelPeripheralConnection(peripheral)
                return
            }
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
            let foot = self.footFor(identifier) ?? self.pendingFoot[identifier]
            self.tearDown(identifier)
            if self.connected.isEmpty { self.stopRSSIPolling() }
            if self.userDisconnects.remove(identifier) != nil {
                if let error { self.errorMessage = error.localizedDescription }
                return
            }
            // Dropped, not disconnected by the user: ask iOS to reconnect. The
            // request stays open, so it completes when the insole is back in
            // range, without the wearer re-pairing mid-shift.
            if let foot {
                self.pendingFoot[identifier] = foot
                self.errorMessage = "\(foot.label) insole dropped out. Reconnecting…"
            }
            self.central.connect(peripheral, options: nil)
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
        Task { @MainActor in
            guard self.simulator == nil else { return }
            self.decodeTelemetry(data, from: identifier)
        }
    }

    /// Commands are written with response, so a refusal is reported rather
    /// than the app assuming the insole obeyed.
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        let identifier = peripheral.identifier
        let message = error.localizedDescription
        Task { @MainActor in
            let label = self.footFor(identifier)?.label ?? "An"
            self.errorMessage = "\(label) insole didn't accept the command: \(message)"
        }
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

// MARK: - Simulated insoles
//
// Demo Mode and development. Stands in for the XIAO firmware so every control in the
// app can be exercised on the iOS Simulator, which has no Bluetooth. It hooks
// in at the BLE layer, so scanning, pairing, disconnecting, and mode commands
// all run through the same view model and screens as real hardware — only the
// radio is fake. The temperatures respond to commands: Cool pulls the foot
// down, Heat pushes it up, Auto regulates towards the target temperature set
// on the Advanced screen. The whole app is stamped "Simulated insoles" while
// this runs, so nothing it shows can be mistaken for a measurement.

extension ThermyxBLEService {
    fileprivate func simSetDiscovered(_ devices: [DiscoveredDevice]) {
        discovered = devices.sorted { $0.rssi > $1.rssi }
    }

    fileprivate func simAttach(_ foot: Foot, name: String) {
        connected.insert(foot)
        names[foot] = name
        errorMessage = nil
    }

    fileprivate func simPublish(_ reading: ThermyxReading, rssi value: Int) {
        guard connected.contains(reading.foot) else { return }
        readings[reading.foot] = reading
        rssi[reading.foot] = value
        var stamps = packetTimestamps[reading.foot] ?? []
        stamps.append(.now)
        if stamps.count > 32 { stamps.removeFirst(stamps.count - 32) }
        packetTimestamps[reading.foot] = stamps
    }

    fileprivate func simDetach(_ foot: Foot) {
        connected.remove(foot)
        names[foot] = nil
        rssi[foot] = nil
        packetTimestamps[foot] = nil
        readings[foot] = nil
    }
}

@MainActor
final class ThermyxInsoleSimulator: ObservableObject {
    /// Air temperature around the simulated wearer, °C.
    @Published var ambientC: Double = 27
    /// Simulates a tiring wearer: gait stability falls and load shifts to one foot.
    @Published var fatigued = false
    /// Simulates a failed Peltier and fan: the insole can neither cool nor
    /// heat, and heat builds up in the shoe. Used to demonstrate Critical.
    @Published var coolingFault = false

    private struct Insole {
        var contactC: Double
        var gait: Double
        var battery: Double
        var commanded: ThermalMode = .ventilation
        /// What the firmware is actually doing, which it reports back.
        var active: ThermalMode = .ventilation
        var isConnected = false
    }

    private weak var ble: ThermyxBLEService?
    private var insoles: [Foot: Insole]
    private var tickTimer: Timer?
    private var scanWork: [DispatchWorkItem] = []
    private var tick = 0.0

    private static let deviceIDs: [Foot: UUID] = [
        .left: UUID(uuidString: "5E1A0000-0000-4000-8000-00000000000A")!,
        .right: UUID(uuidString: "5E1A0000-0000-4000-8000-00000000000B")!
    ]

    init(ble: ThermyxBLEService) {
        self.ble = ble
        insoles = [
            .left: Insole(contactC: 32.4, gait: 0.91, battery: 86),
            .right: Insole(contactC: 32.8, gait: 0.90, battery: 79)
        ]
        tickTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.step() }
        }
    }

    // MARK: Radio

    func startScan() {
        stopScan()
        for (index, foot) in Foot.allCases.enumerated() where insoles[foot]?.isConnected == false {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.advertise(foot) }
            }
            scanWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8 + Double(index) * 0.7, execute: work)
        }
    }

    func stopScan() {
        scanWork.forEach { $0.cancel() }
        scanWork.removeAll()
    }

    private func advertise(_ foot: Foot) {
        guard let ble, insoles[foot]?.isConnected == false, let id = Self.deviceIDs[foot] else { return }
        var devices = ble.discovered.filter { $0.id != id }
        devices.append(.init(id: id, name: "Thermyx \(foot.label) (simulated)", rssi: rssiValue(foot), advertisedFoot: foot))
        ble.simSetDiscovered(devices)
    }

    func connect(_ device: ThermyxBLEService.DiscoveredDevice, as chosen: Foot?) {
        guard let foot = Self.deviceIDs.first(where: { $0.value == device.id })?.key ?? device.advertisedFoot ?? chosen else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in self?.attach(foot) }
        }
    }

    func connectAll() {
        for foot in Foot.allCases { attach(foot) }
    }

    private func attach(_ foot: Foot) {
        guard let ble, var insole = insoles[foot], !insole.isConnected else { return }
        insole.isConnected = true
        insole.contactC = naturalContact(foot) + Double.random(in: -0.4...0.4)
        insoles[foot] = insole
        ble.simAttach(foot, name: "Thermyx \(foot.label) (simulated)")
        ble.simSetDiscovered(ble.discovered.filter { $0.id != Self.deviceIDs[foot] })
        publish(foot)
    }

    func disconnect(_ foot: Foot) {
        insoles[foot]?.isConnected = false
        ble?.simDetach(foot)
    }

    func shutdown() {
        tickTimer?.invalidate()
        tickTimer = nil
        stopScan()
    }

    func command(_ mode: ThermalMode, to foot: Foot) {
        insoles[foot]?.commanded = mode
    }

    /// The simulated firmware's hold temperature for Auto, as sent by the
    /// target-temperature command.
    private var targets: [Foot: Double] = [:]

    func setTarget(_ celsius: Double, for foot: Foot) {
        targets[foot] = celsius
    }

    // MARK: Physics

    /// Where the foot settles with the insole passive: warmer air, warmer foot.
    private func naturalContact(_ foot: Foot) -> Double {
        30.5 + (ambientC - 22) * 0.4 + (fatigued ? 0.6 : 0) + (foot == .right ? 0.35 : 0)
    }

    /// Hold temperature for Auto: what the app last sent, else the default.
    private func autoTargetC(_ foot: Foot) -> Double {
        targets[foot] ?? 31
    }

    private func step() {
        tick += 1
        for foot in Foot.allCases {
            guard var insole = insoles[foot], insole.isConnected else { continue }
            let natural = naturalContact(foot)

            // What the firmware does with the command it was given.
            switch coolingFault ? .off : insole.commanded {
            case .ventilation:
                // Auto: regulate towards the target with a little hysteresis.
                let target = autoTargetC(foot)
                if insole.contactC > target + 0.6 { insole.active = .cooling }
                else if insole.contactC < target - 0.6 { insole.active = .heating }
                else if abs(insole.contactC - target) < 0.2 { insole.active = .ventilation }
            case .heating:
                // Firmware burn-protection cutoff: drops out of heating at
                // the 40 °C limit and resumes below 38.5 °C.
                if insole.contactC >= ThermyxRiskEngine.burnLimitC { insole.active = .ventilation }
                else if insole.contactC < 38.5 { insole.active = .heating }
            case .cooling, .off:
                insole.active = insole.commanded
            }

            var (target, rate): (Double, Double) = switch insole.active {
            case .heating: (42, 0.035)
            case .cooling: (natural - 8, 0.035)
            case .ventilation: (natural - 1.2, 0.02)
            case .off: (natural, 0.015)
            }
            if coolingFault { (target, rate) = (natural + 2, 0.04) }
            insole.contactC += (target - insole.contactC) * rate + Double.random(in: -0.04...0.04)

            let gaitTarget = fatigued ? 0.73 : 0.91
            insole.gait += (gaitTarget - insole.gait) * 0.08 + Double.random(in: -0.01...0.01)

            let drain = insole.active == .ventilation ? 0.01 : 0.03
            insole.battery = max(3, insole.battery - drain)

            insoles[foot] = insole
            publish(foot)
        }
    }

    private func rssiValue(_ foot: Foot) -> Int {
        (foot == .left ? -56 : -61) + Int.random(in: -3...3)
    }

    private func publish(_ foot: Foot) {
        guard let ble, let insole = insoles[foot] else { return }
        let contact = insole.contactC
        let sway = sin(tick / 7 + (foot == .left ? 0 : 1.3)) * 0.02
        let loadBias = foot == .right ? (fatigued ? 0.07 : 0.015) : 0
        let ambient = ambientC + sin(tick / 40) * 0.3 + Double.random(in: -0.05...0.05)
        let reading = ThermyxReading(
            foot: foot,
            timestamp: .now,
            footTemperatureC: contact,
            ambientTemperatureC: ambient,
            pressureBalance: min(1, max(0, 0.5 + sway + loadBias)),
            gaitStability: min(1, max(0, insole.gait)),
            batteryPercent: Int(insole.battery.rounded()),
            thermalMode: insole.active,
            zones: FootZoneTemperatures(
                forefootC: contact + 1.3 + Double.random(in: -0.08...0.08),
                archC: contact + 0.6 + Double.random(in: -0.08...0.08),
                heelC: contact - 1.9 + Double.random(in: -0.08...0.08)
            ),
            cadenceStepsPerMinute: (fatigued ? 88 : 104) + Double.random(in: -2...2),
            standingFraction: fatigued ? 0.42 : 0.28
        )
        ble.simPublish(reading, rssi: rssiValue(foot))
    }
}
