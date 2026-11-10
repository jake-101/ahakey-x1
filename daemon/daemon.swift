import CoreBluetooth
import CoreGraphics
import CoreText
import Foundation
import Network

// ahakey-ble-daemon
// Keeps a BLE connection to the AhaKey X1 and runs a tiny HTTP server on
// 127.0.0.1 (default port 8787, override with AHAKEY_PORT env or first arg).
// POST /state {"state":"working|waiting|blocked|done|idle"} drives the
// X1 light bar via the firmware's AI-state command (0x90).
//
// Build:  swiftc -O -o ahakey-daemon daemon.swift
// Run:    ./ahakey-daemon
// Test:   curl -X POST localhost:8787/state -d '{"state":"working"}'

let peripheralNamePrefix = "AhaKey"
let port: UInt16 = {
  if let a = CommandLine.arguments.dropFirst().first, let p = UInt16(a) { return p }
  if let e = ProcessInfo.processInfo.environment["AHAKEY_PORT"], let p = UInt16(e) { return p }
  return 8787
}()

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
    var dataChar: CBCharacteristic?
    var lastState: String = "idle"       // what was last displayed (for /status)
    var activeState: String = "idle"     // semantic Orca state (drives heartbeat)
    var doneTimer: DispatchWorkItem?
    var workingBeat = 0
    var deviceState: [String: Int] = [:] // from periodic 0x00 queries
    var suppressHeartbeat = false
    var lastStateChangeAt = Date()       // watchdog: stale states expire

    func start() {
        setbuf(stdout, nil) // unbuffered logging — stdout goes to a file under launchd
        central = CBCentralManager(delegate: self, queue: nil)
        startHeartbeat()
        startStatusPolling()
    }

    // MARK: central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[ble] central state: \(central.state.rawValue)")
        if central.state == .poweredOn { connect() }
    }

    func connect() {
        // Fast path: identifier cached from a previous discovery...
        if let id = cachedIdentifier(), let p = central.retrievePeripherals(withIdentifiers: [id]).first {
            print("[ble] reconnecting to cached peripheral \(id)")
            attach(p)
            return
        }
        // The device rotates its MAC on power cycles, so scan by advertised name.
        central.scanForPeripherals(withServices: nil, options: nil)
        scanFallback()
    }

    func attach(_ p: CBPeripheral) {
        central.stopScan()
        peripheral = p
        cacheIdentifier(p.identifier)
        p.delegate = self
        print("[ble] connecting to \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
    }

    private var cacheURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".ahakey-daemon/peripheral-id")
    }

    private func cachedIdentifier() -> UUID? {
        guard let s = try? String(contentsOf: cacheURL, encoding: .utf8) else { return nil }
        return UUID(uuidString: s)
    }

    private func cacheIdentifier(_ id: UUID) {
        try? FileManager.default.createDirectory(at: cacheURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try? id.uuidString.write(to: cacheURL, atomically: true, encoding: .utf8)
    }

    func scanFallback() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.peripheral == nil else { return }
            if let id = self.cachedIdentifier(),
               let p = self.central.retrievePeripherals(withIdentifiers: [id]).first {
                self.attach(p)
            } else {
                self.connect() // keep retrying
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard self.peripheral == nil, name.hasPrefix(peripheralNamePrefix) else { return }
        attach(peripheral)
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
        peripheral.discoverCharacteristics([
            CBUUID(string: "7341"), CBUUID(string: "7343"), CBUUID(string: "7344"),
        ], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        for c in service.characteristics ?? [] {
            print("[ble] char \(c.uuid): props=\(c.properties.rawValue) (write=\(c.properties.contains(.write)), writeNR=\(c.properties.contains(.writeWithoutResponse)), notify=\(c.properties.contains(.notify)))")
            switch c.uuid.uuidString {
            case "7343": cmdChar = c
            case "7341":
                dataChar = c
                if c.properties.contains(.notify) { peripheral.setNotifyValue(true, for: c) }
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
        activeState = state
        lastStateChangeAt = Date()
        guard let cmd = cmdChar else { return }
        let f = frame(0x90, [ahaState(state)])
        peripheral?.writeValue(f, for: cmd, type: .withResponse)
        print("[ble] state -> \(state)")
    }

    /// Direct light-effect preview (cmd 0x91) — bypasses the per-state table.
    func preview(effect: UInt8) {
        lastState = "preview\(effect)"
        guard let cmd = cmdChar else { return }
        let f = frame(0x91, [effect])
        peripheral?.writeValue(f, for: cmd, type: .withResponse)
        print("[ble] preview effect -> \(effect)")
    }

    /// Poll device status every 2 s (firmware never pushes mode/lever changes),
    /// skipped while an OLED upload is in flight.
    func startStatusPolling() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if let cmd = self.cmdChar, let per = self.peripheral,
               !OledUploader.shared.isBusy {
                per.writeValue(Data([0xAA, 0xBB, 0x00, 0xCC, 0xDD]), for: cmd, type: .withResponse)
            }
            self.startStatusPolling()
        }
    }

    /// Animated effects settle quickly and same-state re-sends are ignored, so:
    /// - while agents are genuinely working, re-trigger the Knight Rider via the
    ///   0x91 preview (restarts the effect each time);
    /// - if "working" hasn't been re-asserted for 75 s, it's stale (agent pane
    ///   zombied) — expire to idle, like the vendor's watchdog (60 s tool expiry).
    /// The Orca plugin re-asserts the aggregate every 30 s, so real long tasks
    /// stay lit.
    func startHeartbeat() {
        DispatchQueue.global().asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            let stale = Date().timeIntervalSince(self.lastStateChangeAt) > 75
            if self.activeState == "working" && stale {
                print("[watchdog] working state stale >75s -> idle")
                self.send(state: "idle")
            } else if !self.suppressHeartbeat {
                switch self.activeState {
                case "working":
                    self.preview(effect: 1) // singleMove — blue Knight Rider flow
                case "waiting", "blocked":
                    self.send(raw: 0)       // warningBlink — red flash
                default:
                    break
                }
            }
            self.startHeartbeat()
        }
    }

    func send(raw: UInt8) {
        lastState = "raw\(raw)"
        guard let cmd = cmdChar else { return }
        let f = frame(0x90, [raw])
        peripheral?.writeValue(f, for: cmd, type: .withResponse)
        print("[ble] raw state -> \(raw)")
    }

    // MARK: key remap (0x73) — runs on the daemon's existing connection

    func remapKey(index: UInt8, hid: [UInt8], completion: @escaping (String) -> Void) {
        guard let cmd = cmdChar, let per = peripheral else {
            completion("not connected"); return
        }
        suppressHeartbeat = true
        print("[remap] key \(index) -> \(hid.map { String(format: "%02X", $0) }.joined())")

        // wait for a command echo (0x73 config, then 0x04 save); other echoes ignored
        func waitForEcho(_ expect: UInt8, timeout: Double) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if OledUploader.shared.lastGenericEcho == expect { return true }
                Thread.sleep(forTimeInterval: 0.02)
            }
            return OledUploader.shared.lastGenericEcho == expect
        }

        DispatchQueue.global().async {
            var ok = true
            OledUploader.shared.beginGenericWait()
            let f = frame(0x73, [0x73, 0x00, index] + hid)
            per.writeValue(f, for: cmd, type: .withResponse)
            ok = waitForEcho(0x73, timeout: 3)
            print("[remap] key write ack: \(ok)")
            if ok {
                OledUploader.shared.beginGenericWait()
                per.writeValue(frame(0x04, []), for: cmd, type: .withResponse)
                ok = waitForEcho(0x04, timeout: 3)
                print("[remap] save ack: \(ok)")
            }
            self.suppressHeartbeat = false
            completion(ok ? "ok" : "no device ack — retry or power-cycle")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            print("[ble] WRITE ERROR on \(characteristic.uuid): \(e.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        if let e = error {
            print("[ble] notify-sub error \(characteristic.uuid): \(e.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        // notify responses; log unexpected errors only
        if let e = error { print("[ble] notify error: \(e)") }
        let v = characteristic.value ?? Data()
        print("[ble] notify(\(characteristic.uuid)): \(v.map { String(format: "%02X", $0) }.joined(separator: " "))")
        // 0x00 device status response: AA BB 00 [battery][signal][fwM][fwm][mode][light][switch][brightness] CC DD
        if characteristic.uuid == CBUUID(string: "7344"), v.count >= 12, v[2] == 0x00 {
            deviceState = ["battery": Int(v[3]), "firmwareMajor": Int(v[5]),
                           "firmwareMinor": Int(v[6]), "workMode": Int(v[7]),
                           "lightMode": Int(v[8]), "switchState": Int(v[9]),
                           "brightness": Int(v[10])]
        }
        // bulk-write flow: device echoes the command byte (0x80 prepare / 0x81 write-result)
        if v.count >= 3, v[2] == 0x80 || v[2] == 0x81 {
            OledUploader.shared.signalAck(echo: v[2])
        }
        // other command echoes (0x73 key config, 0x04 save, ...) for one-shot writes
        if v.count >= 3, v[2] != 0x00, v[2] != 0x80, v[2] != 0x81 {
            OledUploader.shared.signalGeneric(echo: v[2])
        }
    }
}

// MARK: - OLED (project-name display)

final class OledUploader {
    static let shared = OledUploader()
    private let lock = NSLock()
    private var uploading = false
    var isBusy: Bool { lock.withLock { uploading } }
    private let ack80 = DispatchSemaphore(value: 0)  // prepare-write echo
    private let ack81 = DispatchSemaphore(value: 0)  // write-result echo
    private let ackLock = NSLock()

    private let width = 160
    private let height = 80
    private let slotSize = 28_672
    private let startIndex = 10        // first custom frame slot (10 factory-reserved)
    private let chunkSize = 4096

    func signalAck(echo: UInt8) {
        switch echo {
        case 0x80: ack80.signal()
        case 0x81: ack81.signal()
        default: break
        }
    }

    // generic command echo (for one-shot config writes like 0x73/0x04)
    private let genericLock = NSLock()
    private var genericEcho: UInt8 = 0
    var lastGenericEcho: UInt8 { genericLock.lock(); defer { genericLock.unlock() }; return genericEcho }
    func beginGenericWait() { genericLock.lock(); genericEcho = 0; genericLock.unlock() }
    func signalGeneric(echo: UInt8) { genericLock.lock(); genericEcho = echo; genericLock.unlock() }

    private func drain() {
        while ack80.wait(timeout: .now()) == .success {}
        while ack81.wait(timeout: .now()) == .success {}
    }

    // Render text centered on a 160x80 canvas; returns RGB565 big-endian frame data.
    func makeTextFrame(_ text: String) -> Data {
        let w = width, h = height
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                            bytesPerRow: w * 4, space: cs,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(gray: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))

        var fontSize: CGFloat = 44
        var line: CTLine!
        var bounds = CGRect.zero
        repeat {
            let font = CTFontCreateWithName("Helvetica-Bold" as CFString, fontSize, nil)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: CGColor(gray: 1, alpha: 1),
            ]
            let attributed = NSAttributedString(string: text, attributes: attrs as [NSAttributedString.Key: Any])
            line = CTLineCreateWithAttributedString(attributed)
            bounds = CTLineGetBoundsWithOptions(line, .useOpticalBounds)
            if bounds.width <= CGFloat(w - 12) { break }
            fontSize -= 3
        } while fontSize > 9

        let tx = (CGFloat(w) - bounds.width) / 2 - bounds.minX
        let ty = (CGFloat(h) - bounds.height) / 2 - bounds.minY
        ctx.textPosition = CGPoint(x: tx, y: ty)
        CTLineDraw(line, ctx)

        var out = Data(capacity: w * h * 2)
        let buf = ctx.data!
        for i in 0..<(w * h) {
            let px = buf.load(fromByteOffset: i * 4, as: UInt32.self) // little-endian RGBA
            let r = UInt8(px & 0xFF), g = UInt8((px >> 8) & 0xFF), b = UInt8((px >> 16) & 0xFF)
            let rgb565 = UInt16((UInt16(r >> 3) << 11) | (UInt16(g >> 2) << 5) | UInt16(b >> 3))
            out.append(UInt8(rgb565 >> 8))
            out.append(UInt8(rgb565 & 0xFF))
        }
        return out
    }

    func uploadAndShow(text: String) {
        lock.lock()
        if uploading { lock.unlock(); return }
        uploading = true
        lock.unlock()
        defer {
            lock.lock(); uploading = false; lock.unlock()
        }

        guard let ble = Ble.shared.peripheral, let cmd = Ble.shared.cmdChar,
              let dataChar = Ble.shared.dataChar else {
            print("[oled] not connected — skipped")
            return
        }

        let frame = makeTextFrame(text)
        print("[oled] uploading frame for \"\(text)\" (\(frame.count) bytes)")

        var offset = 0
        while offset < frame.count {
            let n = min(chunkSize, frame.count - offset)
            let addr = UInt32(startIndex * slotSize + offset)
            let chunk = frame.subdata(in: offset..<(offset + n))

            drain()
            let prep = Data([0xAA, 0xBB, 0x80, 0x00,
                             UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
                             UInt8(addr & 0xFF), UInt8((addr >> 8) & 0xFF),
                             UInt8((addr >> 16) & 0xFF), UInt8((addr >> 24) & 0xFF),
                             0xCC, 0xDD])
            ble.writeValue(prep, for: cmd, type: .withResponse)
            if ack80.wait(timeout: .now() + 2) == .timedOut {
                print("[oled] no ACK for prepare @0x\(String(addr, radix: 16)) — continuing")
            }

            // firmware frames data in ~180-byte packets; larger writes are dropped
            var packetOffset = 0
            while packetOffset < chunk.count {
                let n2 = min(180, chunk.count - packetOffset)
                ble.writeValue(chunk.subdata(in: packetOffset..<(packetOffset + n2)),
                               for: dataChar, type: .withResponse)
                Thread.sleep(forTimeInterval: 0.012)
                packetOffset += n2
            }
            if ack81.wait(timeout: .now() + 3) == .timedOut {
                print("[oled] no write-result @0x\(String(addr, radix: 16)) — continuing")
            }
            offset += n
        }

        // commit: mode 0, startIndex 10, 1 frame, 1000 ms
        let commit = Data([0xAA, 0xBB, 0x82, 0x00,
                           UInt8(startIndex & 0xFF), UInt8((startIndex >> 8) & 0xFF),
                           0x01, 0x00,
                           0xE8, 0x03, 0xCC, 0xDD])
        ble.writeValue(commit, for: cmd, type: .withResponse)
        print("[oled] done — showing \"\(text)\"")
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
                let body = Data(buf[range.upperBound...]) // copy: zero-based indices
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
        print("[http] \(head.components(separatedBy: "\r\n").first ?? "?") body(\(body.count)): \(String(data: body, encoding: .utf8) ?? "<binary>")")
        let lines = head.components(separatedBy: "\r\n")
        let first = lines.first ?? ""
        let parts = first.split(separator: " ")
        let method = parts.count > 0 ? String(parts[0]) : ""
        let path = parts.count > 1 ? String(parts[1]) : "/"

        if method == "POST" && (path == "/state" || path == "/display") {
            // headers already complete but body may still be arriving; body received so far
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let raw = json["raw"] as? Int, (0...8).contains(raw) {
                    Ble.shared.send(raw: UInt8(raw))
                    reply(conn, 200, "{\"ok\":true,\"raw\":\(raw)}")
                } else if let eff = json["preview"] as? Int, (0...16).contains(eff) {
                    Ble.shared.preview(effect: UInt8(eff))
                    reply(conn, 200, "{\"ok\":true,\"preview\":\(eff)}")
                } else if let text = json["text"] as? String, !text.isEmpty {
                    DispatchQueue.global().async {
                        OledUploader.shared.uploadAndShow(text: String(text.prefix(40)))
                    }
                    reply(conn, 200, "{\"ok\":true}")
                } else if let s = json["state"] as? String {
                    if s == "done" {
                        Ble.shared.send(state: "done")
                        // cyan siren briefly, then off
                        doneTimer?.cancel()
                        let t = DispatchWorkItem { Ble.shared.send(state: "idle") }
                        doneTimer = t
                        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: t)
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
        } else if method == "POST" && path == "/remap" {
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
               let idx = json["keyIndex"] as? Int, (0...3).contains(idx),
               let hidArr = json["hid"] as? [Int], !hidArr.isEmpty,
               hidArr.allSatisfy({ (0...255).contains($0) }) {
                Ble.shared.remapKey(index: UInt8(idx), hid: hidArr.map { UInt8($0) }) { result in
                    self.reply(conn, result == "ok" ? 200 : 500, "{\"ok\":\(result == "ok"),\"result\":\"\(result)\"}")
                }
            } else {
                reply(conn, 400, "{\"ok\":false,\"error\":\"need keyIndex 0-3 and hid byte array\"}")
            }
        } else if method == "GET" && (path == "/" || path == "/status") {
            let s = Ble.shared.lastState
            let dev = Ble.shared.deviceState.map { "\"\($0.key)\":\($0.value)" }.sorted().joined(separator: ",")
            reply(conn, 200, "{\"state\":\"\(s)\",\"connected\":\(Ble.shared.cmdChar != nil),\"device\":{\(dev)}}")
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
