import CoreBluetooth
import Foundation

// Scan nearby; for strong-signal devices, connect and enumerate services.
// Flags any device exposing the AhaKey custom service (0x7340) or HID (0x1812).
// Usage: swift ble-probe.swift [minRSSI] [seconds]

let minRSSI = CommandLine.arguments.count > 1 ? Int(CommandLine.arguments[1]) ?? -65 : -65
let duration = CommandLine.arguments.count > 2 ? Double(CommandLine.arguments[2]) ?? 25.0 : 25.0

final class Prober: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var probing = Set<String>()
    var done = Set<String>()
    let start = Date()

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { print("BT off"); exit(1) }
        central.scanForPeripherals(withServices: nil, options: nil)
        print("scanning, probing devices with RSSI > \(minRSSI) ...")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        guard RSSI.intValue >= minRSSI, !probing.contains(id), !done.contains(id) else { return }
        probing.insert(id)
        print("probing \(peripheral.name ?? "<unnamed>") \(id) RSSI \(RSSI)")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        done.insert(peripheral.identifier.uuidString)
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let svcs = peripheral.services?.map(\.uuid.uuidString) ?? []
        let tags = svcs.map { s -> String in
            if s.lowercased().contains("7340") { return s + " <-- AHAKEY" }
            if s.lowercased().contains("1812") { return s + " <-- HID" }
            return s
        }
        print("  \(peripheral.name ?? peripheral.identifier.uuidString): \(tags.joined(separator: ", "))")
    }
}

let prober = Prober()
RunLoop.main.run(until: Date().addingTimeInterval(duration))
print("--- probe finished ---")
