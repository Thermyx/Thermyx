import CoreBluetooth
import Foundation

@MainActor
final class ThermyxViewModel: ObservableObject {
    @Published private(set) var reading = ThermyxReading.empty
    @Published private(set) var isScanning = false

    let ble = ThermyxBLEService()

    init() {
        ble.$lastReading
            .compactMap { $0 }
            .assign(to: &$reading)
    }

    var connectionLabel: String {
        if ble.isConnected { return "Connected" }
        if isScanning { return "Searching for Thermyx…" }
        return "Not connected"
    }

    func toggleScan() {
        if isScanning {
            ble.stopScan()
            isScanning = false
        } else {
            ble.scan()
            isScanning = true
        }
    }

    func setMode(_ mode: ThermalMode) {
        ble.send(command: mode)
    }
}
