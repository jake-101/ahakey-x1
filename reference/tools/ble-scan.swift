import CoreBluetooth
import Foundation

// BLE scanner: prints all peripherals advertising nearby, with names, RSSI, service UUIDs.
// Usage: swift ble-scan.swift [seconds] [name-filter]

let duration = CommandLine.arguments.count > 1 ? Double(CommandLine.arguments[1]) ?? 10.0 : 10.0
let filter = CommandLine.arguments.count > 2 ? CommandLine.arguments[2].lowercased() : nil

final class Scanner: NSObject, CBCentralManagerDelegate {
    var central: CBCentralManager!
    var seen = Set<String>()
    let filter: String?
    let start = Date()

    init(filter: String?) {
        self.filter = filter
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else {
            print("Bluetooth not powered on: \(central.state.rawValue)")
            exit(1)
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        print("Scanning for \(duration)s...")
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier.uuidString
        guard !seen.contains(id) else { return }
        seen.insert(id)
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? "<unnamed>"
        if let f = filter, !name.lowercased().contains(f) { return }
        let svcs = (advertisementData[CBAdvertisementDataServiceUUIDsKey] as? [CBUUID])?.map(\.uuidString) ?? []
        print("\(name) | \(id) | RSSI \(RSSI) | services: \(svcs.joined(separator: ", "))")
    }
}

let scanner = Scanner(filter: filter)
RunLoop.main.run(until: Date().addingTimeInterval(duration))
print("--- done, \(scanner.seen.count) devices seen ---")
