import CoreBluetooth
import Foundation

// Connects to candidate peripherals and prints their services.
// The AhaKey X1 exposes custom service 0x7340.
// Usage: swift ble-identify.swift <uuid1> <uuid2> ...

let uuids = CommandLine.arguments.dropFirst().compactMap { UUID(uuidString: $0) }
guard !uuids.isEmpty else { print("pass peripheral UUIDs"); exit(1) }

final class Prober: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var found = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { print("BT off"); exit(1) }
        let peripherals = central.retrievePeripherals(withIdentifiers: uuids)
        for p in peripherals {
            print("connecting to \(p.identifier.uuidString) (name: \(p.name ?? "?"))")
            central.connect(p, options: nil)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 12) {
            print("--- done; AhaKey service found: \(self.found) ---")
            exit(0)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("connected: \(peripheral.name ?? peripheral.identifier.uuidString)")
        peripheral.delegate = self
        peripheral.discoverServices(nil)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        let svcs = peripheral.services?.map { $0.uuid.uuidString } ?? []
        print("  services: \(svcs.joined(separator: ", "))")
        if svcs.contains(where: { $0.lowercased().contains("7340") }) {
            print("  *** AHAKEY X1 FOUND (service 0x7340): \(peripheral.identifier.uuidString) ***")
            found = true
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("failed to connect \(peripheral.identifier.uuidString): \(error?.localizedDescription ?? "?")")
    }
}

let prober = Prober()
RunLoop.main.run(until: Date().addingTimeInterval(15))
