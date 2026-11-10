import CoreBluetooth
import Foundation

// Sets the X1's per-state LED effect table for one work mode (cmd 0x84) and saves.
// Usage: swift set-light-mapping.swift [mode]
// Effects: 0=off 1=singleMove(KnightRider) 2=rainbowMove 3=rainbowWave 4=rainbowWaveSlow
//          5=breathing 6=middleLight 7=typingRipple 8=comet 9=scanBar 10=pulseCenter
//          11=warningBlink 12=successSweep 13=blueThinking 14=lowBattery 15=chargingFlow
//          16=approvalWait

let mode = CommandLine.arguments.count > 1 ? UInt8(CommandLine.arguments[1]) ?? 0 : 0

// factory defaults except state 5 (Stop): middleLight(6) -> off(0)
let effects: [UInt8] = [
    11, // 0 notification      warningBlink (red flash — "needs attention")
    16, // 1 permissionRequest approvalWait
    12, // 2 postToolUse       successSweep
    1,  // 3 preToolUse        singleMove (Knight Rider)
    3,  // 4 sessionStart      rainbowWave
    0,  // 5 stop              OFF  <-- was middleLight (6), the blue-middle ending
    12, // 6 taskCompleted     successSweep
    5,  // 7 userPromptSubmit  breathing
    0,  // 8 sessionEnd        off
]

final class Bot: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    var central: CBCentralManager!
    var peripheral: CBPeripheral!
    var cmdChar: CBCharacteristic?
    var step = 0
    let targetId = UUID(uuidString: "58A4FF66-FB55-B06E-F479-4BAB74FF3C33")!

    override init() {
        super.init()
        central = CBCentralManager(delegate: self, queue: nil)
    }

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { print("BT off"); exit(1) }
        guard let p = central.retrievePeripherals(withIdentifiers: [targetId]).first else {
            print("AhaKey not found"); exit(1)
        }
        peripheral = p
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.delegate = self
        peripheral.discoverServices([CBUUID(string: "7340")])
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first else { print("no 7340"); exit(1) }
        peripheral.discoverCharacteristics([CBUUID(string: "7343"), CBUUID(string: "7344")], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid.uuidString == "7343" { cmdChar = c }
            if c.uuid.uuidString == "7344" { peripheral.setNotifyValue(true, for: c) }
        }
        guard let cmd = cmdChar else { print("no cmd char"); exit(1) }
        let f = Data([0xAA, 0xBB, 0x84, mode] + effects + [0xCC, 0xDD])
        print("writing light mapping: \(f.map { String(format: "%02X", $0) }.joined(separator: " "))")
        peripheral.writeValue(f, for: cmd, type: .withResponse)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let bytes = (characteristic.value ?? Data()).map { String(format: "%02X", $0) }.joined(separator: " ")
        print("notify: \(bytes)")
        if step == 0 {
            step = 1
            peripheral.writeValue(Data([0xAA, 0xBB, 0x04, 0xCC, 0xDD]), for: characteristic.uuid == CBUUID(string: "7343") ? characteristic : cmdChar!, type: .withResponse)
        } else {
            print("✅ light mapping saved — Stop state is now fully off")
            exit(0)
        }
    }
}

let bot = Bot()
RunLoop.main.run(until: Date().addingTimeInterval(15))
print("--- timed out ---")
