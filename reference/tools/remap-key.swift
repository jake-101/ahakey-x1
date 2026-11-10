import CoreBluetooth
import Foundation

// AhaKey X1 key remapper — writes UPDATE_CUSTOM_KEY frames via BLE.
// Usage: swift remap-key.swift <keyIndex> <hidByte1,hidByte2,...> [mode]
// Example — set Key1 (mic key) to F13 (HID 0x68):
//   swift remap-key.swift 0 68

let args = CommandLine.arguments
guard args.count >= 3, let keyIndex = UInt8(args[1]) else {
    print("usage: swift remap-key.swift <keyIndex 0-3> <hid bytes hex, comma-sep> [mode 0-2]")
    exit(1)
}
let hidBytes = args[2].split(separator: ",").compactMap { UInt8($0, radix: 16) }
let mode = args.count > 3 ? UInt8(args[3]) ?? 0 : 0
guard !hidBytes.isEmpty else { print("no hid bytes"); exit(1) }

func frame(_ cmd: UInt8, _ data: [UInt8]) -> Data {
    Data([0xAA, 0xBB, cmd] + data + [0xCC, 0xDD])
}

final class Bot: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral!
    var cmdChar: CBCharacteristic!
    var step = 0
    let targetId = UUID(uuidString: "58A4FF66-FB55-B06E-F479-4BAB74FF3C33")!
    let keyIndex: UInt8
    let hidBytes: [UInt8]
    let mode: UInt8

    init(keyIndex: UInt8, hidBytes: [UInt8], mode: UInt8) {
        self.keyIndex = keyIndex
        self.hidBytes = hidBytes
        self.mode = mode
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { print("BT off"); exit(1) }
        central.scanForPeripherals(withServices: nil, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard name.lowercased().hasPrefix("ahakey") else { return }
        central.stopScan()
        self.peripheral = peripheral
        peripheral.delegate = self
        print("connecting to \(name)...")
        central.connect(peripheral, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("connected")
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "7340")])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first else { print("no 7340 service"); exit(1) }
        print("found service \(svc.uuid)")
        peripheral.discoverCharacteristics([CBUUID(string: "7343"), CBUUID(string: "7344")], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid.uuidString == "7343" { cmdChar = c }
            if c.uuid.uuidString == "7344" { peripheral.setNotifyValue(true, for: c) }
        }
        if cmdChar != nil {
            // Step 0: query state first
            print("querying device state...")
            peripheral.writeValue(frame(0x00, []), for: cmdChar, type: .withResponse)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error { print("notify error: \(e)"); exit(1) }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let bytes = (characteristic.value ?? Data()).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("notify: \(bytes)")

        if step == 0 {
            // Response to state query — now write the key config
            step = 1
            let data = [UInt8(0x73), mode, keyIndex] + hidBytes
            let f = frame(0x73, data)
            print("writing key config: \(f.map { String(format: "%02X", $0) }.joined(separator: " "))")
            peripheral.writeValue(f, for: cmdChar, type: .withResponse)
        } else if step == 1 {
            // ACK for key config — now SAVE_CONFIG
            step = 2
            print("saving config...")
            peripheral.writeValue(frame(0x04, []), for: cmdChar, type: .withResponse)
        } else if step == 2 {
            print("✅ done — key \(keyIndex) remapped and saved. Power-cycle the key to test.")
            exit(0)
        }
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        print("connect failed: \(error?.localizedDescription ?? "?")")
        exit(1)
    }
}

let bot = Bot(keyIndex: keyIndex, hidBytes: hidBytes, mode: mode)
RunLoop.main.run(until: Date().addingTimeInterval(20))
print("--- timed out ---")
