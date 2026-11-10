import CoreBluetooth
import Foundation

// One-shot device state query: prints battery, fw, workMode, light, switch, brightness.
// Usage: swift query-state.swift

final class Bot: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral!
    var cmdChar: CBCharacteristic?
    var done = false

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { print("BT state: \(central.state.rawValue)"); exit(1) }
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) {
            if !self.done { print("device not found/advertising"); exit(1) }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().hasPrefix("ahakey") else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "7340")])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first else { exit(1) }
        peripheral.discoverCharacteristics([CBUUID(string: "7343"), CBUUID(string: "7344")], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid.uuidString == "7343" { cmdChar = c }
            if c.uuid.uuidString == "7344" { peripheral.setNotifyValue(true, for: c) }
        }
        if let cmd = cmdChar {
            peripheral.writeValue(Data([0xAA, 0xBB, 0x00, 0xCC, 0xDD]), for: cmd, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let v = characteristic.value ?? Data()
        guard v.count >= 12, v[0] == 0xAA else { return }
        let b = v.map { String(format: "%02X", $0) }.joined(separator: " ")
        print("raw: \(b)")
        print("battery: \(v[3])%  fw: \(v[5]).\(v[6])  workMode: \(v[7])  lightMode: \(v[8])  switch: \(v[9])  brightness?: \(v[10])")
        done = true
        exit(0)
    }
}

let bot = Bot()
RunLoop.main.run(until: Date().addingTimeInterval(12))
