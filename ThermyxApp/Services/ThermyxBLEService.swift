import CoreBluetooth
import Foundation

@MainActor
final class ThermyxBLEService: NSObject, ObservableObject {
    // Replace these UUIDs with the UUIDs used by the XIAO firmware.
    nonisolated static let serviceUUID = CBUUID(string: "7B7E0001-7A3B-4D2D-9C9E-000000000001")
    nonisolated static let telemetryUUID = CBUUID(string: "7B7E0002-7A3B-4D2D-9C9E-000000000001")
    nonisolated static let commandUUID = CBUUID(string: "7B7E0003-7A3B-4D2D-9C9E-000000000001")

    @Published private(set) var state: CBManagerState = .unknown
    @Published private(set) var discoveredName: String?
    @Published private(set) var isConnected = false
    @Published private(set) var lastReading: ThermyxReading?
    @Published private(set) var errorMessage: String?

    private var central: CBCentralManager!
    private var peripheral: CBPeripheral?
    private var commandCharacteristic: CBCharacteristic?

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func scan() {
        guard state == .poweredOn else {
            errorMessage = "Bluetooth is unavailable or permission has not been granted."
            return
        }
        errorMessage = nil
        discoveredName = nil
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: false])
    }

    func stopScan() {
        central.stopScan()
    }

    func disconnect() {
        guard let peripheral else { return }
        central.cancelPeripheralConnection(peripheral)
    }

    func send(command: ThermalMode) {
        guard let commandCharacteristic, let peripheral, commandCharacteristic.properties.contains(.write) else {
            errorMessage = "The insole is not ready to receive commands."
            return
        }
        let commandByte: UInt8 = switch command {
        case .off: 0
        case .heating: 1
        case .cooling: 2
        case .ventilation: 3
        }
        let payload = Data([1, commandByte])
        peripheral.writeValue(payload, for: commandCharacteristic, type: .withResponse)
    }

    private func decodeTelemetry(_ data: Data) {
        // Thermyx telemetry v1, little-endian:
        // [0] version, [1] mode, [2] battery %, [3...4] foot temp centi-C,
        // [5...6] ambient temp centi-C, [7...8] gait stability 0...10000,
        // [9...10] pressure balance 0...10000, [11] flags.
        guard data.count >= 12, data[0] == 1 else {
            errorMessage = "Received an incomplete telemetry packet."
            return
        }

        let bytes = [UInt8](data)
        func int16(_ index: Int) -> Int16 { Int16(bitPattern: UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8) }
        func uint16(_ index: Int) -> UInt16 { UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8 }
        let footTemp = Double(int16(3)) / 100.0
        let ambientTemp = Double(int16(5)) / 100.0
        let pressure = Double(uint16(9)) / 10000.0
        let gait = Double(uint16(7)) / 10000.0
        let battery = Int(bytes[2])
        let mode: ThermalMode = switch bytes[1] {
        case 1: .heating
        case 2: .cooling
        case 3: .ventilation
        default: .off
        }

        lastReading = ThermyxReading(
            timestamp: .now,
            footTemperatureC: footTemp,
            ambientTemperatureC: ambientTemp,
            pressureBalance: pressure,
            gaitStability: gait,
            batteryPercent: battery,
            thermalMode: mode
        )
    }
}

extension ThermyxBLEService: CBCentralManagerDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        Task { @MainActor in self.state = central.state }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any], rssi RSSI: NSNumber) {
        Task { @MainActor in
            self.discoveredName = peripheral.name ?? "Thermyx Insole"
            self.peripheral = peripheral
            self.stopScan()
            central.connect(peripheral, options: nil)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        Task { @MainActor in
            self.isConnected = true
            peripheral.delegate = self
            peripheral.discoverServices([Self.serviceUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        Task { @MainActor in
            self.isConnected = false
            self.commandCharacteristic = nil
            if let error { self.errorMessage = error.localizedDescription }
        }
    }
}

extension ThermyxBLEService: CBPeripheralDelegate {
    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.telemetryUUID, Self.commandUUID], for: service)
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard let characteristics = service.characteristics else { return }
        for characteristic in characteristics {
            if characteristic.uuid == Self.commandUUID {
                Task { @MainActor in self.commandCharacteristic = characteristic }
            }
            if characteristic.uuid == Self.telemetryUUID {
                peripheral.setNotifyValue(true, for: characteristic)
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard let data = characteristic.value else { return }
        Task { @MainActor in self.decodeTelemetry(data) }
    }
}
