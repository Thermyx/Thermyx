import Combine
import CoreBluetooth
import Foundation
import UIKit

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
    // The single-sensor XIAO test board (see ThermyxSensorProtocol).
    nonisolated static let sensorServiceUUID = CBUUID(string: ThermyxSensorProtocol.serviceUUIDString)
    nonisolated static let sensorValueUUID = CBUUID(string: ThermyxSensorProtocol.valueUUIDString)

    // MARK: Published state

    @Published private(set) var state: CBManagerState = .unknown
    /// Whether Thermyx may use Bluetooth. Until it's been asked, the radio
    /// stays untouched so iOS doesn't prompt at launch; the insoles step
    /// asks with `requestBluetooth()`.
    @Published private(set) var authorization: CBManagerAuthorization = CBManager.authorization
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
    /// Where the app is in connecting an insole, step by step, so a link
    /// that stalls says where ("Connected, but no Thermyx service" is a
    /// firmware problem; "Waiting for the first reading" is a data one).
    /// Nil once readings arrive.
    @Published private(set) var insoleStep: String?
    /// The last command an insole refused at the Bluetooth level.
    @Published private(set) var lastWriteFailure: WriteFailure?

    struct WriteFailure: Equatable {
        let foot: Foot
        let message: String
        let at: Date
    }

    struct DiscoveredDevice: Identifiable, Equatable {
        enum Kind: Equatable {
            /// Advertises the two-insole service.
            case insole
            /// Advertises the single-sensor test-board service.
            case sensorBoard
            /// Anything else, listed only with "Show all Bluetooth devices".
            case other
        }

        let id: UUID
        let name: String
        let rssi: Int
        /// Declared by the peripheral name, when the firmware says so.
        let advertisedFoot: Foot?
        var kind: Kind = .insole
        /// False when the device advertises no name at all.
        var isNamed = true
        /// Already connected to this iPhone (by iOS, another app, or a
        /// pairing in Settings), so it isn't advertising and has no signal
        /// reading. Tapping it still connects: apps share iOS's link.
        var isSystemConnected = false
        var isStrong: Bool { isSystemConnected || rssi > -75 }

        /// Thermyx by service UUID, or a name that says Thermyx.
        var looksLikeThermyx: Bool {
            kind != .other || name.localizedCaseInsensitiveContains("thermyx")
        }

        /// Fixed list order, so rows don't jump as signal strength changes:
        /// Thermyx devices first, then named, then unnamed; by name within.
        static func listOrder(_ a: DiscoveredDevice, _ b: DiscoveredDevice) -> Bool {
            func group(_ d: DiscoveredDevice) -> Int {
                switch d.kind {
                case .sensorBoard: return 0
                case .insole: return 1
                case .other: return d.looksLikeThermyx ? 2 : (d.isNamed ? 3 : 4)
                }
            }
            if group(a) != group(b) { return group(a) < group(b) }
            let byName = a.name.localizedCaseInsensitiveCompare(b.name)
            if byName != .orderedSame { return byName == .orderedAscending }
            return a.id.uuidString < b.id.uuidString
        }

        /// Merges a new advertisement into what is already listed. iOS
        /// reports advertising and scan-response packets separately, so one
        /// may lack the name or service list: never lose what was seen.
        /// Signal strength is smoothed so the number doesn't flicker.
        func merged(with update: DiscoveredDevice) -> DiscoveredDevice {
            DiscoveredDevice(
                id: id,
                name: update.isNamed ? update.name : name,
                rssi: isSystemConnected ? update.rssi : Int((Double(rssi) * 0.7 + Double(update.rssi) * 0.3).rounded()),
                advertisedFoot: update.advertisedFoot ?? advertisedFoot,
                kind: update.kind != .other ? update.kind : kind,
                isNamed: isNamed || update.isNamed,
                isSystemConnected: false
            )
        }
    }

    // MARK: Test board

    /// Every parsed line from the test board, in arrival order. The board
    /// never becomes a `ThermyxReading`, so it can't reach risk levels,
    /// alerts, or Apple Health.
    let boardPackets = PassthroughSubject<SensorPacket, Never>()
    @Published private(set) var boardState: BoardLinkState = .notConnected
    /// The board the user last connected by hand, and whether they then
    /// disconnected it. Persisted.
    private(set) var boardMemory = BoardMemory.load()
    /// The board's peripheral while connecting or connected.
    private var boardPeripheral: CBPeripheral?
    /// True while the current board connection was started by a tap, so it
    /// is remembered once it proves to be a board.
    private var boardManualConnect = false
    private var boardName = "Thermyx"
    /// Whether the running scan lists every device, not just Thermyx ones.
    private var scanShowsAll = false
    /// When each listed device was last heard, to drop ones that left.
    private var lastHeard: [UUID: Date] = [:]
    /// When each row was last redrawn, to hold the list steady.
    private var lastShown: [UUID: Date] = [:]
    /// The name each device advertises now. iOS caches `peripheral.name`
    /// from older firmware, so this one is preferred.
    private var advertisedNames: [UUID: String] = [:]
    /// Devices not heard for this long leave the list.
    nonisolated static let discoveredTimeout: TimeInterval = 12

    // MARK: Private

    private var central: CBCentralManager!
    private var peripherals: [UUID: CBPeripheral] = [:]
    /// Peripherals we have accepted, keyed by the foot they serve.
    private var links: [Foot: CBPeripheral] = [:]
    private var commandCharacteristics: [Foot: CBCharacteristic] = [:]
    /// Command characteristics found before the insole said which foot.
    private var unassignedCommands: [UUID: CBCharacteristic] = [:]
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
    private static let restoreIdentifier = "com.thermyx.app.a.central"

    /// The simulated pair, when Demo Mode is on (Advanced → Demo Mode, or
    /// `-ThermyxUIPreview simulator` in development). While it runs, every
    /// screen carries "Simulated — not live sensor data", and nothing is sent
    /// to the relay, written to history, Apple Health, or the baseline.
    private(set) var simulator: ThermyxInsoleSimulator?

    /// The clock readings are stamped on: the demo's story clock while it
    /// runs, so a command's "is this reading newer?" check compares like with like.
    var readingClock: Date { simulator?.storyNow ?? .now }
    @Published private(set) var isDemoMode = false
    /// Debug builds only: the preview harness's scripted pair, with
    /// repeatable data that follows calibration's instructions. Runs on the
    /// same simulated radio as the harness (so nothing reaches history,
    /// Health or the relay). Always false in a release build.
    @Published private(set) var isFakeInsole = false

    /// When the app last came back to the foreground. iOS suspends the app
    /// (and its timers) in the background, so silence across that gap isn't
    /// an insole that stopped sending; judge staleness from here instead.
    private var resumedAt = Date.distantPast
    private var resumeObserver: NSObjectProtocol?

    override init() {
        super.init()
        resumeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.resumedAt = .now }
        }
        startWatchdog()
        #if DEBUG
        if ThermyxPreviewHarness.isSimulated {
            state = .poweredOn
            simulator = ThermyxInsoleSimulator(ble: self)
            isDemoMode = true
            return
        }
        #endif
        if CBManager.authorization != .notDetermined { makeCentral() }
    }

    /// Asks iOS for Bluetooth (creating the manager is what prompts).
    func requestBluetooth() {
        guard central == nil, simulator == nil else { return }
        makeCentral()
    }

    /// A manager made only to show iOS's "Turn On Bluetooth" alert, whose
    /// Settings button goes straight to Bluetooth. Apps can't switch the
    /// radio on themselves; this is the supported way to ask.
    private var powerPrompt: CBCentralManager?

    /// Shows iOS's alert for turning Bluetooth on, when it's off.
    func promptPowerOn() {
        guard simulator == nil else { return }
        powerPrompt = CBCentralManager(delegate: nil, queue: nil, options: [CBCentralManagerOptionShowPowerAlertKey: true])
    }

    /// Starts the search over: stops any scan, forgets every device heard so
    /// far (including ones that have since gone quiet), clears the last
    /// error, and scans again. If Bluetooth isn't usable yet it asks for it
    /// instead: the permission prompt, or iOS's turn-on alert. Returns
    /// whether a scan actually started.
    @discardableResult
    func rescan(showAll: Bool = false) -> Bool {
        stopScan()
        discovered.removeAll()
        lastHeard.removeAll()
        lastShown.removeAll()
        errorMessage = nil
        if simulator != nil {
            scan(showAll: showAll)
            return true
        }
        if central == nil {
            requestBluetooth()
            return false
        }
        switch state {
        case .poweredOn:
            scan(showAll: showAll)
            return true
        case .poweredOff:
            promptPowerOn()
            return false
        default:
            return false
        }
    }

    private func makeCentral() {
        // The restore identifier lets iOS relaunch the app in the background
        // and hand back its insole connections (needs the bluetooth-central
        // background mode in Info.plist).
        central = CBCentralManager(
            delegate: self,
            queue: nil,
            options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
        )
    }

    // MARK: - Simulated radio
    //
    // Demo Mode: admin accounts can start it from Advanced (or Home, with no
    // insoles connected) to show Thermyx without hardware, and the debug
    // preview harness uses it for every screen. The whole app is stamped
    // "Simulated insoles" while it runs. The scripted fake insole is debug
    // only.

    /// Swaps the real radio for the simulated pair. Real insoles are
    /// disconnected first so simulated and live readings can never mix.
    /// With `connect` off, the pair is set up but not yet connected, so it
    /// can be configured first.
    func startDemoMode(connect: Bool = true) { startSimulated(scripted: false, connect: connect) }

    #if DEBUG
    /// The scripted pair (see `isFakeInsole`).
    func startFakeInsoles() {
        if simulator != nil { stopDemoMode() }
        startSimulated(scripted: true)
    }
    #endif

    private func startSimulated(scripted: Bool, connect: Bool = true) {
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
            // Drop a real test board too, without forgetting it.
            if let board = boardPeripheral {
                userDisconnects.insert(board.identifier)
                central.cancelPeripheralConnection(board)
            }
        }
        boardPeripheral = nil
        boardManualConnect = false
        boardState = .notConnected
        readings.removeAll()
        discovered.removeAll()
        simulator = ThermyxInsoleSimulator(ble: self, scripted: scripted)
        isDemoMode = true
        isFakeInsole = scripted
        state = .poweredOn
        if connect { simulator?.connectAll() }
    }

    /// Ends Demo Mode and returns to real Bluetooth.
    func stopDemoMode() {
        guard let simulator else { return }
        for foot in Foot.allCases { simulator.disconnect(foot) }
        simulator.disconnectBoard()
        simulator.shutdown()
        self.simulator = nil
        isDemoMode = false
        isFakeInsole = false
        boardState = .notConnected
        readings.removeAll()
        discovered.removeAll()
        userDisconnects.removeAll()
        if central == nil {
            if CBManager.authorization != .notDetermined { makeCentral() }
        } else {
            state = central.state
            reconnectKnownInsoles()
            reconnectRememberedBoard()
        }
    }

    // MARK: - Stale-data watchdog

    private func startWatchdog() {
        watchdogTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.checkForStaleFeet()
                self?.pruneDiscovered()
            }
        }
    }

    /// Drops devices that stopped advertising, so the list shows what is
    /// actually nearby.
    private func pruneDiscovered(now: Date = .now) {
        guard simulator == nil, !lastHeard.isEmpty else { return }
        let gone = Set(lastHeard.filter { now.timeIntervalSince($0.value) > Self.discoveredTimeout }.keys)
        guard !gone.isEmpty else { return }
        for id in gone { lastHeard[id] = nil; lastShown[id] = nil }
        discovered.removeAll { gone.contains($0.id) }
    }

    /// A connected insole that stops sending keeps its link up, so a
    /// disconnect never fires. Clear its reading after `staleAfter` seconds
    /// so the screens fall back to their empty state instead of freezing.
    private func checkForStaleFeet() {
        for foot in connected {
            guard readings[foot] != nil,
                  let packet = packetTimestamps[foot]?.last,
                  Date.now.timeIntervalSince(max(packet, resumedAt)) > Self.staleAfter
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

    /// Lists nearby Thermyx devices: insoles and test boards, matched by
    /// service UUID, never by name. `showAll` lists every Bluetooth device.
    /// Scanning never connects anything by itself.
    func scan(showAll: Bool = false) {
        if let simulator {
            errorMessage = nil
            discovered.removeAll()
            simulator.startScan()
            if !boardState.isConnected, boardPeripheral == nil { boardState = .scanning }
            return
        }
        guard state == .poweredOn else {
            errorMessage = Self.unavailableMessage(state)
            return
        }
        errorMessage = nil
        discovered.removeAll()
        lastHeard.removeAll()
        lastShown.removeAll()
        scanShowsAll = showAll
        if boardPeripheral == nil { boardState = .scanning }
        central.scanForPeripherals(
            withServices: showAll ? nil : [Self.serviceUUID, Self.sensorServiceUUID],
            options: [CBCentralManagerScanOptionAllowDuplicatesKey: true]
        )
        listSystemConnected()
    }

    /// A Thermyx device iOS is already connected to stops advertising, so a
    /// scan never finds it. List those too, so the app can attach to the
    /// existing link instead of waiting for an advertisement that won't come.
    private func listSystemConnected() {
        let ours = Set(links.values.map(\.identifier) + [boardPeripheral?.identifier].compactMap { $0 })
        let groups: [(CBUUID, DiscoveredDevice.Kind)] = [(Self.serviceUUID, .insole), (Self.sensorServiceUUID, .sensorBoard)]
        for (service, kind) in groups {
            for peripheral in central.retrieveConnectedPeripherals(withServices: [service]) where !ours.contains(peripheral.identifier) {
                peripherals[peripheral.identifier] = peripheral
                guard !discovered.contains(where: { $0.id == peripheral.identifier }) else { continue }
                let name = peripheral.name ?? "Thermyx"
                discovered.append(DiscoveredDevice(
                    id: peripheral.identifier,
                    name: name,
                    rssi: 0,
                    advertisedFoot: kind == .insole ? Self.foot(fromName: name) : nil,
                    kind: kind,
                    isNamed: true,
                    isSystemConnected: true
                ))
            }
        }
        discovered.sort(by: DiscoveredDevice.listOrder)
    }

    /// Why a scan can't run, in words that say what to do about it.
    static func unavailableMessage(_ state: CBManagerState) -> String {
        switch state {
        case .poweredOff: return "Bluetooth is off. Turn it on to find your insoles."
        case .unauthorized: return "Bluetooth isn't allowed for Thermyx. Allow it in Settings."
        case .unsupported: return "This device has no Bluetooth LE, so it can't reach the insoles. Use an iPhone."
        case .resetting, .unknown: return "Bluetooth is starting up. Scan again in a moment."
        default: return "Bluetooth isn't ready. Scan again in a moment."
        }
    }

    func stopScan() {
        if case .scanning = boardState { boardState = .notConnected }
        if let simulator { simulator.stopScan(); return }
        guard central != nil else { return }
        central.stopScan()
    }

    // MARK: Test board link

    /// Connects to a device the user tapped in the list. Only ever called
    /// from a tap: the app never picks a board by itself the first time.
    func connectBoard(_ device: DiscoveredDevice) {
        boardName = device.name
        if let simulator {
            simulator.stopScan()
            boardState = .connecting(device.name)
            simulator.connectBoard()
            return
        }
        guard let target = peripherals[device.id] else {
            errorMessage = "\(device.name) is no longer in range. Scan again."
            return
        }
        central.stopScan()
        // One board at a time: let go of the previous one first.
        if let current = boardPeripheral, current.identifier != device.id {
            userDisconnects.insert(current.identifier)
            central.cancelPeripheralConnection(current)
        }
        boardPeripheral = target
        boardManualConnect = true
        userDisconnects.remove(device.id)
        boardState = .connecting(device.name)
        central.connect(target, options: nil)
    }

    /// The user's Disconnect. Stops automatic reconnection until they
    /// connect again from the scan list, including across launches.
    func disconnectBoard() {
        if let simulator {
            simulator.disconnectBoard()
            boardState = .notConnected
            return
        }
        boardMemory = BoardReconnectPolicy.afterUserDisconnect(boardMemory)
        boardMemory.save()
        boardManualConnect = false
        boardState = .notConnected
        guard let peripheral = boardPeripheral else { return }
        boardPeripheral = nil
        userDisconnects.insert(peripheral.identifier)
        central.cancelPeripheralConnection(peripheral)
    }

    /// Rule 4: on launch (and when Bluetooth comes back on), reconnect to the
    /// remembered board unless the user disconnected it.
    fileprivate func reconnectRememberedBoard() {
        guard simulator == nil, central != nil, state == .poweredOn, boardPeripheral == nil,
              let id = BoardReconnectPolicy.boardToReconnectOnLaunch(boardMemory),
              let peripheral = central.retrievePeripherals(withIdentifiers: [id]).first
        else { return }
        boardPeripheral = peripheral
        boardManualConnect = false
        boardName = boardMemory.name ?? peripheral.name ?? "Thermyx"
        boardState = .reconnecting(boardName)
        central.connect(peripheral, options: nil)
    }

    fileprivate func isBoard(_ id: UUID) -> Bool { boardPeripheral?.identifier == id }

    /// The board's value characteristic is subscribed: it is a board.
    fileprivate func boardReady(_ peripheral: CBPeripheral) {
        guard isBoard(peripheral.identifier) else { return }
        if boardManualConnect {
            // Rule 1: remember a board the user connected by hand.
            boardMemory = BoardReconnectPolicy.afterManualConnect(id: peripheral.identifier, name: boardName)
            boardMemory.save()
            boardManualConnect = false
        }
        boardState = .connected(boardName)
        errorMessage = nil
    }

    /// Not a test board after all (no sensor service).
    fileprivate func rejectBoard(_ peripheral: CBPeripheral) {
        guard isBoard(peripheral.identifier) else { return }
        boardPeripheral = nil
        boardManualConnect = false
        boardState = .notConnected
        userDisconnects.insert(peripheral.identifier)
        central.cancelPeripheralConnection(peripheral)
        errorMessage = "\(boardName) isn't a Thermyx sensor (no Thermyx sensor service)."
    }

    /// The connected device turned out to be an insole. If the app had it
    /// down as the sensor board, forget that, so it is never reconnected and
    /// rejected as a board again.
    fileprivate func becomeInsole(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        if isBoard(id) {
            boardPeripheral = nil
            boardManualConnect = false
            boardState = .notConnected
        }
        if boardMemory.peripheralID == id {
            boardMemory = BoardMemory()
            boardMemory.save()
        }
        peripherals[id] = peripheral
        startRSSIPolling()
    }

    /// The connected device turned out to be the sensor board, even if it
    /// was tapped as an insole.
    fileprivate func becomeBoard(_ peripheral: CBPeripheral) {
        guard !isBoard(peripheral.identifier) else { return }
        pendingFoot[peripheral.identifier] = nil
        insoleStep = nil
        boardPeripheral = peripheral
        boardManualConnect = true
        boardName = peripheral.name ?? "Thermyx"
        boardState = .connecting(boardName)
    }

    fileprivate func decodeBoardValue(_ data: Data, from peripheralID: UUID) {
        guard isBoard(peripheralID) else { return }
        // Malformed or out-of-range lines are dropped.
        guard let packet = ThermyxSensorProtocol.parse(data) else { return }
        boardPackets.send(packet)
    }

    /// Connect to a discovered device: insoles go through the pairing flow,
    /// everything else is tried as a test board.
    func connectDevice(_ device: DiscoveredDevice, as foot: Foot? = nil) {
        if device.kind == .insole {
            connect(to: device, as: foot)
        } else {
            connectBoard(device)
        }
    }

    /// Connect to a discovered device. `foot` is used when the firmware did
    /// not declare one; otherwise the declared foot wins.
    func connect(to device: DiscoveredDevice, as foot: Foot? = nil) {
        if case .scanning = boardState { boardState = .notConnected }
        if let simulator { simulator.connect(device, as: foot); return }
        guard let target = peripherals[device.id] else {
            errorMessage = "\(device.name) is no longer in range. Scan again."
            return
        }
        // The tap overrides any earlier disconnect of this device, and a
        // running scan only competes with the connection for the radio.
        userDisconnects.remove(device.id)
        central.stopScan()
        if isBoard(device.id) {
            // Tapped as an insole: stop treating it as the sensor board.
            boardPeripheral = nil
            boardManualConnect = false
            boardState = .notConnected
        }
        let assigned = device.advertisedFoot ?? foot
        if let assigned {
            pendingFoot[device.id] = assigned
        }
        insoleStep = "Connecting to \(device.name)…"
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
        for target in targets {
            guard let characteristic = commandCharacteristics[target],
                  let peripheral = links[target],
                  characteristic.properties.contains(.write)
            else { continue }
            peripheral.writeValue(ThermyxProtocol.command(command), for: characteristic, type: .withResponse)
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
        let packet = ThermyxProtocol.target(celsius)
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
        // The wire format lives in ThermyxProtocol, where it is unit tested.
        let telemetry: ThermyxProtocol.Telemetry
        switch ThermyxProtocol.decode(data) {
        case .success(let decoded):
            telemetry = decoded
        case .failure(.unsupportedVersion):
            errorMessage = "Received a telemetry packet in an unsupported format."
            return
        case .failure(.tooShort):
            errorMessage = "Received an incomplete telemetry packet."
            return
        }

        // The packet's own foot declaration wins; otherwise fall back to what
        // the user assigned at pairing.
        // Firmware that doesn't declare a foot gets a free slot instead of
        // having every packet dropped; the name says which one it took.
        guard let foot = telemetry.declaredFoot ?? pendingFoot[peripheralID] ?? footFor(peripheralID)
            ?? Foot.allCases.first(where: { links[$0] == nil })
        else {
            errorMessage = "Both insole slots are in use, so this insole was ignored."
            return
        }
        adopt(peripheralID, as: foot)
        insoleStep = nil
        readings[foot] = telemetry.reading(for: foot)

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
        if let command = unassignedCommands.removeValue(forKey: peripheralID) {
            commandCharacteristics[foot] = command
        }
        connected.insert(foot)
        names[foot] = advertisedNames[peripheralID] ?? peripheral.name ?? "Thermyx \(foot.label)"
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
        let authorization = CBManager.authorization
        Task { @MainActor in
            self.state = newState
            self.authorization = authorization
            if newState == .poweredOn {
                self.reconnectKnownInsoles()
                self.reconnectRememberedBoard()
            } else if self.simulator == nil {
                // Links are gone with the radio; rule 4 brings the board back
                // when Bluetooth returns.
                self.boardPeripheral = nil
                self.boardManualConnect = false
                self.boardState = .notConnected
            }
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
                if let id = BoardReconnectPolicy.boardToReconnectOnLaunch(self.boardMemory), id == peripheral.identifier {
                    self.boardPeripheral = peripheral
                    self.boardName = self.boardMemory.name ?? peripheral.name ?? "Thermyx"
                    self.boardState = peripheral.state == .connected ? .connecting(self.boardName) : .reconnecting(self.boardName)
                    peripheral.delegate = self
                    if peripheral.state == .connected { peripheral.discoverServices([Self.serviceUUID, Self.sensorServiceUUID]) }
                    continue
                }
                if let foot = known.first(where: { $0.value == peripheral.identifier })?.key {
                    self.pendingFoot[peripheral.identifier] = foot
                }
                peripheral.delegate = self
                if peripheral.state == .connected {
                    peripheral.discoverServices([Self.serviceUUID, Self.sensorServiceUUID])
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
        // The advertised name first: it is what the firmware sends now,
        // where peripheral.name can be a name iOS cached earlier.
        let advertisedName = (advertisementData[CBAdvertisementDataLocalNameKey] as? String)
            ?? peripheral.name
        let trimmedName = advertisedName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let isNamed = !(trimmedName ?? "").isEmpty
        let name = isNamed ? trimmedName! : "Unnamed device"
        let strength = RSSI.intValue
        let identifier = peripheral.identifier
        let services = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID] ?? [])
            + (advertisementData[CBAdvertisementDataOverflowServiceUUIDsKey] as? [CBUUID] ?? [])
        Task { @MainActor in
            // 127 means iOS couldn't measure it; keep the last real value.
            guard strength != 127 else { return }
            self.peripherals[identifier] = peripheral
            if isNamed { self.advertisedNames[identifier] = name }
            let kind: DiscoveredDevice.Kind
            if services.contains(Self.serviceUUID) {
                kind = .insole
            } else if services.contains(Self.sensorServiceUUID) || !self.scanShowsAll {
                // A filtered scan only reports the two Thermyx services.
                kind = .sensorBoard
            } else {
                kind = .other
            }
            let device = DiscoveredDevice(
                id: identifier,
                name: name,
                rssi: strength,
                advertisedFoot: kind == .insole ? Self.foot(fromName: name) : nil,
                kind: kind,
                isNamed: isNamed
            )
            let now = Date.now
            self.lastHeard[identifier] = now
            if let index = self.discovered.firstIndex(where: { $0.id == identifier }) {
                let previous = self.discovered[index]
                let next = previous.merged(with: device)
                // Redraw a row at most once a second unless what it says
                // changed, so the list stays readable.
                let identityChanged = next.name != previous.name || next.kind != previous.kind
                let recentlyShown = self.lastShown[identifier].map { now.timeIntervalSince($0) < 1 } ?? false
                guard identityChanged || !recentlyShown else { return }
                self.lastShown[identifier] = now
                self.discovered[index] = next
                if identityChanged { self.discovered.sort(by: DiscoveredDevice.listOrder) }
            } else {
                self.lastShown[identifier] = now
                self.discovered.append(device)
                self.discovered.sort(by: DiscoveredDevice.listOrder)
            }
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
            // Connected now, so any earlier disconnect request is over.
            self.userDisconnects.remove(peripheral.identifier)
            peripheral.delegate = self
            // Ask for both services and decide what the device is from what
            // it has. The same board keeps its Bluetooth identity across
            // firmware, so what the app remembers about it can be stale.
            if !self.isBoard(peripheral.identifier) {
                self.insoleStep = "Connected to \(peripheral.name ?? "the insole"). Looking for the Thermyx service…"
            }
            peripheral.discoverServices([Self.serviceUUID, Self.sensorServiceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        let identifier = peripheral.identifier
        Task { @MainActor in
            if self.isBoard(identifier) {
                if !self.boardManualConnect,
                   BoardReconnectPolicy.shouldReconnectAfterDrop(self.boardMemory, peripheral: identifier) {
                    self.boardState = .reconnecting(self.boardName)
                    central.connect(peripheral, options: nil)
                } else {
                    self.boardPeripheral = nil
                    self.boardManualConnect = false
                    self.boardState = .notConnected
                    self.errorMessage = error?.localizedDescription ?? "Could not connect to \(self.boardName)."
                }
                return
            }
            self.tearDown(identifier)
            self.insoleStep = nil
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
            if self.userDisconnects.contains(identifier), !self.isBoard(identifier),
               self.footFor(identifier) == nil, self.pendingFoot[identifier] == nil {
                // A board the user disconnected, or a device that wasn't one.
                self.userDisconnects.remove(identifier)
                return
            }
            if self.isBoard(identifier) {
                if self.userDisconnects.remove(identifier) == nil,
                   BoardReconnectPolicy.shouldReconnectAfterDrop(self.boardMemory, peripheral: identifier) {
                    // Rule 2: out of range or power loss. iOS holds the
                    // request open until the board is back.
                    self.boardState = .reconnecting(self.boardName)
                    self.central.connect(peripheral, options: nil)
                } else {
                    self.boardPeripheral = nil
                    self.boardManualConnect = false
                    self.boardState = .notConnected
                }
                return
            }
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
        // An insole service wins: the device is an insole now, whatever the
        // app remembered (e.g. the same ESP32 earlier ran the sensor sketch).
        if let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) {
            Task { @MainActor in
                self.becomeInsole(peripheral)
                self.insoleStep = "Found the Thermyx service. Subscribing to readings…"
            }
            peripheral.discoverCharacteristics([Self.telemetryUUID, Self.commandUUID], for: service)
            return
        }
        if let board = peripheral.services?.first(where: { $0.uuid == Self.sensorServiceUUID }) {
            Task { @MainActor in self.becomeBoard(peripheral) }
            peripheral.discoverCharacteristics([Self.sensorValueUUID], for: board)
            return
        }
        do {
            let name = peripheral.name ?? "The device"
            let failure = error?.localizedDescription
            Task { @MainActor in
                if self.isBoard(peripheral.identifier) {
                    self.rejectBoard(peripheral)
                } else {
                    self.insoleStep = failure.map { "\(name) connected, but reading its services failed: \($0)" }
                        ?? "\(name) connected, but no Thermyx service was found. If it was just reflashed, iOS may remember its old services: forget it in Settings → Bluetooth and turn Bluetooth off and on. Otherwise check the firmware."
                }
            }
        }
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
                    } else {
                        // Attached when the first packet says which foot.
                        self.unassignedCommands[identifier] = characteristic
                    }
                }
            }
            if characteristic.uuid == Self.telemetryUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
            if characteristic.uuid == Self.sensorValueUUID {
                // Subscribe, and read once so a value shows straight away.
                peripheral.setNotifyValue(true, for: characteristic)
                peripheral.readValue(for: characteristic)
                Task { @MainActor in self.boardReady(peripheral) }
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
        let isBoardValue = characteristic.uuid == Self.sensorValueUUID
        Task { @MainActor in
            guard self.simulator == nil else { return }
            if isBoardValue {
                self.decodeBoardValue(data, from: identifier)
            } else {
                self.decodeTelemetry(data, from: identifier)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard characteristic.uuid == Self.telemetryUUID else { return }
        let message = error?.localizedDescription
        let notifying = characteristic.isNotifying
        Task { @MainActor in
            if let message {
                self.insoleStep = "Couldn't subscribe to readings: \(message)"
            } else if notifying, self.insoleStep != nil {
                self.insoleStep = "Subscribed. Waiting for the first reading (the insole sends one a second)…"
            }
        }
    }

    /// Commands are written with response, so a refusal is reported rather
    /// than the app assuming the insole obeyed.
    nonisolated func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let error else { return }
        let identifier = peripheral.identifier
        let message = error.localizedDescription
        Task { @MainActor in
            let foot = self.footFor(identifier)
            let label = foot?.label ?? "An"
            self.errorMessage = "\(label) insole didn't accept the command: \(message)"
            if let foot { self.lastWriteFailure = WriteFailure(foot: foot, message: message, at: .now) }
        }
    }
}


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
        discovered = devices.sorted(by: DiscoveredDevice.listOrder)
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

    fileprivate func simBoardAttached(_ attached: Bool) {
        boardState = attached ? .connected(boardName) : .notConnected
    }

    /// Simulated board lines go through the same parser as real ones.
    fileprivate func simBoardLine(_ line: String) {
        guard simulator != nil, boardState.isConnected, let packet = ThermyxSensorProtocol.parse(line: line) else { return }
        boardPackets.send(packet)
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
    /// A simulated test board: what its one sensor reports, and the knob
    /// that drives it (0…1), so every board card can be tried without one.
    @Published var boardSensor: SimulatedBoardSensor = .knob
    @Published var knob: Double = 0.5
    private var boardConnected = false

    /// The day the simulated wearer is having (see `DemoWearer`): when the
    /// shift began, which sets the walk/stand/sit cycle, and how hot a day
    /// it is. When `followsDay` is off, `ambientC` is used as set.
    var followsDay = true
    var shiftStart = Date.now
    var dayHeat = 0.6
    /// Today's hardware has one temperature sensor and one arch pressure
    /// sensor per insole. Zone temperatures are for previewing the
    /// three-sensor board only.
    var reportsZones = false

    enum SimulatedBoardSensor: String, CaseIterable, Identifiable {
        case knob, ntc, fsr, tmp102
        var id: String { rawValue }
        var label: String {
            switch self {
            case .knob: return "Test knob"
            case .ntc: return "NTC"
            case .fsr: return "FSR402"
            case .tmp102: return "TMP102"
            }
        }
    }

    static let boardID = UUID(uuidString: "5E1A0000-0000-4000-8000-0000000000B0")!

    fileprivate struct Insole {
        var contactC: Double
        var gait: Double
        var battery: Double
        var commanded: ThermalMode = .ventilation
        /// What the firmware is actually doing, which it reports back.
        var active: ThermalMode = .ventilation
        var isConnected = false
        /// A charge level to start from, set before connecting.
        var seeded = false
    }

    private weak var ble: ThermyxBLEService?
    private var insoles: [Foot: Insole]
    private var tickTimer: Timer?
    private var scanWork: [DispatchWorkItem] = []
    private var tick = 0.0
    /// Seeded, so the Demo studio can replay a timeline exactly.
    private var rng = DemoRandom(seed: 0x7E57_1A2B)
    /// Sensor noise on what's reported, apart from the physics, so reporting
    /// (or not, while scrubbing) never changes how the feet evolve.
    private var noise = DemoRandom(seed: 0x51DE)

    // MARK: Timeline (Demo studio)

    /// What the Demo studio's timeline says is happening; nil for the usual day.
    var conditions: DemoConditions?
    /// Minutes into the timeline while one is loaded.
    var timelineMinute: Double?
    /// The timeline's minute zero. Readings are stamped on the timeline's
    /// clock, so detectors that need minutes of evidence see the story's
    /// minutes even when it plays at ×30.
    var timelineEpoch: Date?

    /// The time readings are stamped with: the timeline's clock while one is
    /// loaded, otherwise the wall clock.
    var storyNow: Date {
        timelineEpoch.map { $0.addingTimeInterval((timelineMinute ?? 0) * 60) } ?? .now
    }
    /// Physics seconds per tick while a timeline is loaded: its speed. 0 holds
    /// the feet still (paused) but keeps reporting, so nothing goes stale.
    var stepsPerTick = 1
    /// Called before each physics second of a loaded timeline. Returning
    /// false stops stepping for this tick (the end of the timeline).
    var onStep: (() -> Bool)?

    /// The pair's physical state, for replaying a timeline from its start.
    struct Snapshot {
        fileprivate var insoles: [Foot: Insole]
        fileprivate var tick: Double
        fileprivate var rng: DemoRandom
    }

    func snapshot() -> Snapshot { Snapshot(insoles: insoles, tick: tick, rng: rng) }

    /// Back to a snapshot's feet. What's connected and what each insole was
    /// told to do stay as they are now.
    func restore(_ snapshot: Snapshot) {
        for foot in Foot.allCases {
            guard var restored = snapshot.insoles[foot], let current = insoles[foot] else { continue }
            restored.isConnected = current.isConnected
            restored.commanded = current.commanded
            insoles[foot] = restored
        }
        tick = snapshot.tick
        rng = snapshot.rng
    }

    /// Runs physics seconds without reporting them (a scrub's fast-forward).
    func fastForward(seconds: Int) {
        for _ in 0..<max(0, seconds) {
            if let onStep, !onStep() { break }
            physicsStep()
            reportPhysicsSecond()
        }
    }

    /// Reports both feet as they are now.
    func publishNow() {
        for foot in Foot.allCases where insoles[foot]?.isConnected == true && !(conditions?.dropped.contains(foot) ?? false) {
            publish(foot)
        }
    }

    /// One insole's charge, set outright (a timeline's battery event).
    func setBattery(_ percent: Double, for foot: Foot) {
        insoles[foot]?.battery = percent
    }

    private static let deviceIDs: [Foot: UUID] = [
        .left: UUID(uuidString: "5E1A0000-0000-4000-8000-00000000000A")!,
        .right: UUID(uuidString: "5E1A0000-0000-4000-8000-00000000000B")!
    ]

    /// TEMPORARY fake insole: deterministic data that follows the activity
    /// calibration asks for, instead of the random Demo Mode physics.
    let isScripted: Bool
    private(set) var scriptActivity: CalibrationActivity = .sitting
    private(set) var scriptOutdoor = false

    func setScript(activity: CalibrationActivity, outdoor: Bool) {
        scriptActivity = activity
        scriptOutdoor = outdoor
    }

    init(ble: ThermyxBLEService, scripted: Bool = false) {
        self.ble = ble
        self.isScripted = scripted
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
        if !boardConnected {
            let work = DispatchWorkItem { [weak self] in
                Task { @MainActor in self?.advertiseBoard() }
            }
            scanWork.append(work)
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: work)
        }
    }

    private func advertiseBoard() {
        guard let ble, !boardConnected else { return }
        var devices = ble.discovered.filter { $0.id != Self.boardID }
        devices.append(.init(id: Self.boardID, name: "Thermyx (simulated)", rssi: -52 + Int.random(in: -3...3),
                             advertisedFoot: nil, kind: .sensorBoard))
        ble.simSetDiscovered(devices)
    }

    func connectBoard() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
            Task { @MainActor in
                guard let self, let ble = self.ble else { return }
                self.boardConnected = true
                ble.simSetDiscovered(ble.discovered.filter { $0.id != Self.boardID })
                ble.simBoardAttached(true)
                self.publishBoard()
            }
        }
    }

    func disconnectBoard() {
        boardConnected = false
        ble?.simBoardAttached(false)
    }

    /// One `TYPE,CHANNEL,VALUE` line, as the firmware would send it.
    private func publishBoard() {
        guard boardConnected, let ble else { return }
        let raw = min(max(Int((knob * Double(ThermyxSensorProtocol.maxRaw)).rounded()) + Int.random(in: -6...6), 0), ThermyxSensorProtocol.maxRaw)
        let line: String = switch boardSensor {
        case .knob: "KNOB,0,\(raw)"
        case .ntc: "NTC,0,\(raw)"
        case .fsr: "FSR,0,\(raw)"
        case .tmp102: String(format: "TMP102,0,%.2f", 15 + knob * 25 + Double.random(in: -0.05...0.05))
        }
        ble.simBoardLine(line)
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

    /// Connects only these insoles (a one-insole demo).
    func connect(feet: [Foot]) {
        for foot in feet { attach(foot) }
    }

    /// Carries on from where the back-filled history left off: the same
    /// foot temperature, steadiness and charge, so the live line continues
    /// the drawn one instead of jumping.
    func seed(from readings: [Foot: ThermyxReading]) {
        for (foot, reading) in readings {
            guard var insole = insoles[foot] else { continue }
            if let c = reading.footTemperatureC { insole.contactC = c }
            if let g = reading.gaitStability { insole.gait = g }
            if let b = reading.batteryPercent { insole.battery = Double(b) }
            insole.active = reading.thermalMode
            insole.seeded = true
            insoles[foot] = insole
        }
    }

    /// Minutes into the simulated shift, and what the wearer is doing.
    private var shiftMinute: Double { timelineMinute ?? max(0, Date.now.timeIntervalSince(shiftStart) / 60) }
    private var currentActivity: CalibrationActivity {
        conditions?.activity ?? DemoWearer.activity(minute: Int(shiftMinute))
    }
    private var currentAmbientC: Double {
        if timelineMinute != nil { return conditions?.ambientC ?? DemoScript.baseAmbientC }
        return followsDay ? DemoWearer.ambientC(progress: shiftMinute / 480, heat: dayHeat) : ambientC
    }
    private var faulty: Bool { coolingFault || conditions?.coolingFault == true }

    private func attach(_ foot: Foot) {
        guard let ble, var insole = insoles[foot], !insole.isConnected else { return }
        insole.isConnected = true
        if isScripted {
            insole.contactC = FakeInsoleScript.steadyFootC(activity: scriptActivity, outdoor: scriptOutdoor, foot: foot)
        } else if !insole.seeded {
            insole.contactC = naturalContact(foot) - 0.6
        }
        insoles[foot] = insole
        ble.simAttach(foot, name: isScripted ? "Fake insole · \(foot.label)" : "Thermyx \(foot.label) (simulated)")
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

    /// Where the foot settles with the insole passive: warmer air, warmer
    /// foot, a little warmer walking than sitting.
    private func naturalContact(_ foot: Foot) -> Double {
        DemoWearer.naturalContactC(ambientC: currentAmbientC, activity: currentActivity, foot: foot,
                                   fatigue: min(1, shiftMinute / 480)) + (fatigued || conditions?.limp == foot ? 0.6 : 0)
    }

    /// Hold temperature for Auto: what the app last sent, else the default.
    private func autoTargetC(_ foot: Foot) -> Double {
        targets[foot] ?? 31
    }

    private func step() {
        if isScripted {
            tick += 1
            scriptedStep()
            return
        }
        publishBoard()
        let steps = timelineMinute == nil ? 1 : stepsPerTick
        for _ in 0..<steps {
            if let onStep, !onStep() { break }
            physicsStep()
            if timelineMinute != nil { reportPhysicsSecond() }
        }
        publishNow()
    }

    /// One second of the simulated feet.
    private func physicsStep() {
        tick += 1
        for foot in Foot.allCases {
            guard var insole = insoles[foot], insole.isConnected else { continue }
            let natural = naturalContact(foot)

            // What the firmware does with the command it was given.
            switch faulty ? .off : insole.commanded {
            case .ventilation:
                // Auto: heat below the target, cool above it, fan near it.
                insole.active = DemoWearer.autoDecision(contactC: insole.contactC, targetC: autoTargetC(foot),
                                                        previous: insole.active)
                if insole.active == .heating, insole.contactC >= ThermyxRiskEngine.burnLimitC { insole.active = .ventilation }
            case .heating:
                // Firmware burn-protection cutoff: drops out of heating at
                // the 40 °C limit and resumes below 38.5 °C.
                if insole.contactC >= ThermyxRiskEngine.burnLimitC { insole.active = .ventilation }
                else if insole.contactC < 38.5 { insole.active = .heating }
            case .cooling, .off:
                insole.active = insole.commanded
            }

            // The foot heads for where the actuator can take it, with the
            // lag of a real foot in a shoe (about half a minute).
            var target = DemoWearer.settlingC(natural: natural, active: insole.active)
            if faulty { target = natural + 2 }
            insole.contactC += (target - insole.contactC) * 0.03 + rng.double(in: -0.015...0.015)

            // Steadiness is measured while walking and held otherwise.
            if currentActivity == .walking {
                let steady = DemoWearer.steadiness(progress: min(1, shiftMinute / 480), heat: dayHeat, seconds: tick)
                var gaitTarget = fatigued ? 0.73 : steady
                if conditions?.strained == true { gaitTarget = min(gaitTarget, 0.72) }
                // A limp: the sore foot unsteady, the other compensating.
                if let limp = conditions?.limp { gaitTarget = limp == foot ? 0.62 : min(gaitTarget, 0.84) }
                insole.gait += (gaitTarget - insole.gait) * 0.08 + rng.double(in: -0.004...0.004)
            }

            insole.battery = max(3, insole.battery - DemoWearer.drainPerMinute(insole.active) / 60)

            insoles[foot] = insole
        }
    }

    private func rssiValue(_ foot: Foot) -> Int {
        (foot == .left ? -56 : -61) + Int.random(in: -3...3)
    }

    private func publish(_ foot: Foot) {
        guard let ble, let reading = makeReading(foot) else { return }
        ble.simPublish(reading, rssi: rssiValue(foot))
    }

    /// The pair as it is this physics second, unpublished: what the
    /// left/right monitor watches between reports while a timeline plays fast.
    var onPhysicsSecond: ((BilateralReading) -> Void)?

    private func reportPhysicsSecond() {
        guard let onPhysicsSecond else { return }
        func reading(_ foot: Foot) -> ThermyxReading? {
            guard insoles[foot]?.isConnected == true, !(conditions?.dropped.contains(foot) ?? false) else { return nil }
            return makeReading(foot)
        }
        onPhysicsSecond(BilateralReading(left: reading(.left), right: reading(.right)))
    }

    private func makeReading(_ foot: Foot) -> ThermyxReading? {
        guard let insole = insoles[foot] else { return nil }
        let contact = insole.contactC
        let activity = currentActivity
        let ambient = currentAmbientC + sin(tick / 40) * 0.2 + noise.double(in: -0.03...0.03)
        var load = DemoWearer.archLoad(activity, seconds: tick, foot: foot) + (fatigued && foot == .right ? 0.08 : 0)
        var cadence = DemoWearer.cadence(activity, minute: shiftMinute) * (fatigued ? 0.85 : 1)
        if let limp = conditions?.limp {
            // The sore foot carries less and for less time; steps slow.
            load *= limp == foot ? 0.62 : 1.22
            cadence *= 0.78
        }
        if let lean = conditions?.lean {
            // Standing with most of the weight on one foot.
            load = lean == foot ? 0.86 + 0.02 * sin(tick / 5) : 0.17 + 0.02 * sin(tick / 7)
        }
        let stamp = storyNow
        var reading = ThermyxReading(
            foot: foot,
            timestamp: stamp,
            footTemperatureC: contact,
            ambientTemperatureC: ambient,
            pressureBalance: min(1, max(0, load)),
            gaitStability: min(1, max(0, insole.gait)),
            batteryPercent: Int(insole.battery.rounded()),
            thermalMode: insole.active,
            zones: reportsZones
                ? FootZoneTemperatures(
                    forefootC: contact + 1.3 + noise.double(in: -0.05...0.05),
                    archC: contact + 0.6 + noise.double(in: -0.05...0.05),
                    heelC: contact - 1.9 + noise.double(in: -0.05...0.05)
                  )
                : nil,
            cadenceStepsPerMinute: cadence > 0 ? cadence + noise.double(in: -1.5...1.5) : 0,
            standingFraction: DemoWearer.standingFraction(activity)
        )
        reading.loadIsArchLevel = !reportsZones
        reading.footDetected = true
        // Like the firmware: echo the setting being followed, and flag the
        // burn cutoff while it holds the heater off.
        var echoed = reading
        echoed.settingEcho = switch insole.commanded {
        case .cooling: .cool
        case .heating: .heat
        case .ventilation: .auto
        case .off: nil
        }
        echoed.burnCutoff = insole.commanded == .heating && insole.active != .heating && contact >= 38.5
        return echoed
    }

    // MARK: Fake insole (TEMPORARY)

    /// One second of the scripted pair: the foot settles toward the usual
    /// temperature for the current activity, the actuator follows the
    /// command like the firmware does, and nothing is random.
    private func scriptedStep() {
        let second = Int(tick)
        for foot in Foot.allCases {
            guard var insole = insoles[foot], insole.isConnected else { continue }
            let natural = FakeInsoleScript.steadyFootC(activity: scriptActivity, outdoor: scriptOutdoor, foot: foot)
            insole.active = Self.scriptedDecision(commanded: insole.commanded, contactC: insole.contactC,
                                                  targetC: autoTargetC(foot), active: insole.active)
            let push: Double = switch insole.active {
            case .heating: 2.5
            case .cooling: -2.5
            default: 0
            }
            insole.contactC += (natural + push - insole.contactC) * 0.15
            insole.gait = 0.91
            insole.battery = max(3, insole.battery - (insole.active == .ventilation ? 0.005 : 0.02))
            insoles[foot] = insole
            publishScripted(foot, second: second)
        }
    }

    /// What the fake firmware does with a command. Auto only steps in when
    /// the foot is well away from the target, so the usual temperatures
    /// calibration records stay the activity's own.
    static func scriptedDecision(commanded: ThermalMode, contactC: Double, targetC: Double, active: ThermalMode) -> ThermalMode {
        switch commanded {
        case .ventilation:
            if contactC > targetC + 1.5 { return .cooling }
            if contactC < targetC - 1.5 { return .heating }
            if active == .cooling, contactC > targetC + 0.3 { return .cooling }
            if active == .heating, contactC < targetC - 0.3 { return .heating }
            return .ventilation
        case .heating:
            if contactC >= ThermyxRiskEngine.burnLimitC { return .ventilation }
            if active != .heating, contactC >= 38.5 { return .ventilation }
            return .heating
        case .cooling, .off:
            return commanded
        }
    }

    private func publishScripted(_ foot: Foot, second: Int) {
        guard let ble, let insole = insoles[foot] else { return }
        let v = FakeInsoleScript.values(activity: scriptActivity, outdoor: scriptOutdoor, second: second)
        let contact = insole.contactC + FakeInsoleScript.wobble(second: second, foot: foot)
        var reading = ThermyxReading(
            foot: foot,
            timestamp: .now,
            footTemperatureC: contact,
            ambientTemperatureC: v.ambientC,
            pressureBalance: v.load,
            gaitStability: v.gait,
            batteryPercent: Int(insole.battery.rounded()),
            thermalMode: insole.active,
            zones: FootZoneTemperatures(forefootC: contact + 1.3, archC: contact + 0.6, heelC: contact - 1.9),
            cadenceStepsPerMinute: v.cadence,
            standingFraction: v.standing
        )
        reading.footDetected = true
        reading.settingEcho = switch insole.commanded {
        case .cooling: .cool
        case .heating: .heat
        case .ventilation: .auto
        case .off: nil
        }
        reading.burnCutoff = insole.commanded == .heating && insole.active != .heating && contact >= 38.5
        ble.simPublish(reading, rssi: foot == .left ? -55 : -60)
    }
}


/// The fake insole's script: what each activity looks like, so calibration
/// gets data it can learn from. Shared by the live fake pair and the
/// "skip the wait" recording, so both teach the model the same thing.
enum FakeInsoleScript {
    struct Values: Equatable {
        var ambientC: Double
        var load: Double
        var gait: Double?
        var cadence: Double
        var standing: Double
    }

    static func steadyFootC(activity: CalibrationActivity, outdoor: Bool, foot: Foot) -> Double {
        let base: Double = switch activity {
        case .sitting: 30.2
        case .standing: 31.0
        case .walking: 32.4
        }
        return base + (outdoor ? 1.2 : 0) + (foot == .right ? 0.3 : 0)
    }

    static func values(activity: CalibrationActivity, outdoor: Bool, second t: Int) -> Values {
        let s = Double(t)
        let ambient = (outdoor ? 31.0 : 23.0) + 0.2 * sin(s / 40)
        switch activity {
        case .sitting:
            return Values(ambientC: ambient, load: 0.30 + 0.01 * sin(s / 5), gait: nil, cadence: 0, standing: 0.05)
        case .standing:
            return Values(ambientC: ambient, load: 0.55 + 0.01 * sin(s / 6), gait: nil, cadence: 0, standing: 0.95)
        case .walking:
            return Values(ambientC: ambient, load: 0.5 + (t % 2 == 0 ? 0.15 : -0.15), gait: 0.91 + 0.01 * sin(s / 4),
                          cadence: 104 + 2 * sin(s / 3), standing: 0.10)
        }
    }

    /// Small, repeatable wobble on the foot temperature.
    static func wobble(second t: Int, foot: Foot) -> Double { 0.1 * sin(Double(t) / 9 + (foot == .left ? 0 : 1.3)) }

    /// A pre-recorded calibration step, for "skip the wait".
    static func samples(activity: CalibrationActivity, outdoor: Bool, seconds: Int, start: Date = .now) -> [CalibrationSample] {
        (0..<seconds).map { t in
            let v = values(activity: activity, outdoor: outdoor, second: t)
            return CalibrationSample(
                time: start.addingTimeInterval(Double(t)),
                footC: steadyFootC(activity: activity, outdoor: outdoor, foot: .right) + wobble(second: t, foot: .right),
                ambientC: v.ambientC,
                load: v.load,
                gait: v.gait,
                cadence: v.cadence,
                standing: v.standing
            )
        }
    }
}
