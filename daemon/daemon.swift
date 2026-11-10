import CoreBluetooth
import Foundation
import Network

// ahakey-ble-daemon
// Keeps a BLE connection to the AhaKey X1 and runs a tiny HTTP server on
// 127.0.0.1:8787. POST /state {"state":"working|waiting|done|idle"} drives the
// X1 light bar via the firmware's AI-state command (0x90).
//
// Build:  swiftc -O -o ahakey-daemon daemon.swift
// Run:    ./ahakey-daemon
// Test:   curl -X POST localhost:8787/state -d '{"state":"working"}'

let peripheralId = UUID(uuidString: "58A4FF66-FB55-B06E-F479-4BAB74FF3C33")!
let port: UInt16 = 8787

// Orca aggregate state -> AhaKey 0x90 state byte (effects verified by LED sweep 2026-11-10)
func ahaState(_ orca: String) -> UInt8 {
    switch orca {
    case "working": return 3              // blue Knight Rider sweep
    case "waiting", "blocked": return 0   // red flash — needs attention
    case "done": return 7                 // cyan siren expanding from center
    default: return 5                     // off
    }
}

func frame(_ cmd: UInt8, _ data: [UInt8]) -> Data {
    Data([0xAA, 0xBB, cmd] + data + [0xCC, 0xDD])
}

final class Ble: NSObject, CBCentralManagerDelegate, CBPeripheralDelegate {
    static let shared = Ble()
    var central: CBCentralManager!
    var peripheral: CBPeripheral?
    var cmdChar: CBCharacteristic?
    var lastState: String = "idle"
    var doneTimer: DispatchWorkItem?

    func start() {
        central = CBCentralManager(delegate: self, queue: nil)
    }

    // MARK: central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        if central.state == .poweredOn { connect() }
    }

    func connect() {
        // Prefer the known identifier; fall back to scanning by name.
        if let p = central.retrievePeripherals(withIdentifiers: [peripheralId]).first {
            attach(p)
        } else {
            central.scanForPeripherals(withServices: nil, options: nil)
            scanFallback()
        }
    }

    func scanFallback() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.peripheral == nil else { return }
            if let p = self.central.retrievePeripherals(withIdentifiers: [peripheralId]).first {
                self.attach(p)
            } else {
                self.connect() // keep retrying
            }
        }
    }

    func attach(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        p.delegate = self
        print("[ble] connecting to \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        print("[ble] connected")
        peripheral.discoverServices([CBUUID(string: "7340")])
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        print("[ble] disconnected (\(error?.localizedDescription ?? "no error")) — reconnecting")
        cmdChar = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in self?.connect() }
    }

    // MARK: peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let svc = peripheral.services?.first else { print("[ble] no 7340 service"); return }
        peripheral.discoverCharacteristics([CBUUID(string: "7343"), CBUUID(string: "7344")], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            switch c.uuid.uuidString {
            case "7343": cmdChar = c
            case "7344": peripheral.setNotifyValue(true, for: c)
            default: break
            }
        }
        if cmdChar != nil {
            print("[ble] ready — applying state \(lastState)")
            send(state: lastState)
        }
    }

    func send(state: String) {
        lastState = state
        guard let cmd = cmdChar else { return }
        let f = frame(0x90, [ahaState(state)])
        peripheral?.writeValue(f, for: cmd, type: .withResponse)
        print("[ble] state -> \(state)")
    }

    func send(raw: UInt8) {
        lastState = "raw\(raw)"
        guard let cmd = cmdChar else { return }
        let f = frame(0x90, [raw])
        peripheral?.writeValue(f, for: cmd, type: .withResponse)
        print("[ble] raw state -> \(raw)")
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // notify responses; log unexpected errors only
        if let e = error { print("[ble] notify error: \(e)") }
    }
}

// MARK: - HTTP server

final class Server {
    let listener: NWListener
    var doneTimer: DispatchWorkItem?

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        listener = try NWListener(using: params, on: NWEndpoint.Port(rawValue: port)!)
    }

    func start() {
        listener.newConnectionHandler = { conn in
            conn.start(queue: .global())
            self.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { print("[http] failed: \(e)"); exit(1) }
        }
        listener.start(queue: .global())
        print("[http] listening on 127.0.0.1:\(port)")
    }

    func handle(_ conn: NWConnection) {
        receive(conn, buffer: Data())
    }

    func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buf = buffer
            if let d = data { buf.append(d) }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                let head = String(data: buf[..<range.lowerBound], encoding: .utf8) ?? ""
                let body = buf[range.upperBound...]
                self.route(conn, head: head, body: body)
            } else if isComplete || error != nil {
                conn.cancel()
            } else if buf.count > 1_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    func route(_ conn: NWConnection, head: String, body: Data) {
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first ?? ""
        let parts = first.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : "/"

        if method == "POST" && path == "/state" {
            // headers already complete but body may still be arriving; body received so far
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let raw = json["raw"] as? Int, (0...8).contains(raw) {
                    Ble.shared.send(raw: UInt8(raw))
                    reply(conn, 200, "{\"ok\":true,\"raw\":\(raw)}")
                } else if let s = json["state"] as? String {
                    if s == "done" {
                        Ble.shared.send(state: "done")
                        // green flash then off
                        doneTimer?.cancel()
                        let t = DispatchWorkItem { Ble.shared.send(state: "idle") }
                        doneTimer = t
                        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: t)
                    } else {
                        doneTimer?.cancel()
                        Ble.shared.send(state: s)
                    }
                    reply(conn, 200, "{\"ok\":true}")
                } else {
                    reply(conn, 400, "{\"ok\":false,\"error\":\"body must be {\\\"state\\\":\\\"working|waiting|blocked|done|idle\\\"} or {\\\"raw\\\":0-8}\"}")
                }
            } else {
                reply(conn, 400, "{\"ok\":false}")
            }
        } else if method == "GET" && (path == "/" || path == "/status") {
            let s = Ble.shared.lastState
            reply(conn, 200, "{\"state\":\"\(s)\",\"connected\":\(Ble.shared.cmdChar != nil)}")
        } else {
            reply(conn, 404, "{\"ok\":false}")
        }
    }

    func reply(_ conn: NWConnection, _ code: Int, _ json: String) {
        let body = json + "\n"
        let head = "HTTP/1.1 \(code) OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in
            conn.cancel()
        })
    }
}

let server = try! Server()
server.start()
Ble.shared.start()
dispatchMain()
