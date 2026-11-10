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
    private var pendingDisplay = false
    var lastStateChangeAt = Date()       // watchdog: stale states expire
    private var generation = 0
    private var triedCached = false
    private var cancelled: Set<UUID> = []
    private var notifyReady = false
    private var dataNotifyReady = false

    var uploadReady: Bool {
        notifyReady && (dataChar?.properties.contains(.notify) != true || dataNotifyReady)
    }

    func recycleUploadConnection(_ p: CBPeripheral) {
        recycle(p)
    }


    func start() {
        setbuf(stdout, nil) // unbuffered logging — stdout goes to a file under launchd
        central = CBCentralManager(delegate: self, queue: nil)
        startHeartbeat()
        startStatusPolling()
    }

    // MARK: central

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        print("[ble] central state: \(central.state.rawValue)")
        if central.state == .poweredOn {
            triedCached = false
            connect()
        } else {
            generation += 1
            central.stopScan()
            peripheral = nil
            cmdChar = nil
            dataChar = nil
            notifyReady = false
            dataNotifyReady = false
            OledUploader.shared.failPending()
            deviceState = [:]
            cancelled.removeAll()
        }
    }

    func connect() {
        guard central.state == .poweredOn, peripheral == nil else { return }
        generation += 1
        let attempt = generation
        if !triedCached {
            triedCached = true
            if let id = cachedIdentifier(), !cancelled.contains(id),
               let p = central.retrievePeripherals(withIdentifiers: [id]).first {
                print("[ble] reconnecting to cached peripheral \(id)")
                attach(p)
                return
            }
        }
        let services = ["7340", "180A", "180F", "1812"].map { CBUUID(string: $0) }
        if let p = central.retrieveConnectedPeripherals(withServices: services).first(where: {
            !cancelled.contains($0.identifier) && ($0.name ?? "").hasPrefix(peripheralNamePrefix)
        }) {
            attach(p)
            return
        }
        central.scanForPeripherals(withServices: nil, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in
            guard let self, self.generation == attempt, self.peripheral == nil,
                  self.central.state == .poweredOn else { return }
            self.central.stopScan()
            self.connect()
        }
    }

    func attach(_ p: CBPeripheral) {
        guard peripheral == nil, !cancelled.contains(p.identifier) else { return }
        generation += 1
        let attempt = generation
        central.stopScan()
        peripheral = p
        cmdChar = nil
        dataChar = nil
        notifyReady = false
        dataNotifyReady = false
        p.delegate = self
        print("[ble] connecting to \(p.name ?? p.identifier.uuidString)")
        central.connect(p, options: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in
            guard let self, self.generation == attempt, self.peripheral === p,
                  self.cmdChar == nil else { return }
            print("[ble] connect timed out — recycling and re-scanning")
            self.recycle(p)
        }
    }

    private func recycle(_ p: CBPeripheral) {
        guard peripheral === p else { return }
        generation += 1
        peripheral = nil
        cmdChar = nil
        dataChar = nil
        notifyReady = false
        dataNotifyReady = false
        OledUploader.shared.failPending()
        deviceState = [:]
        if cachedIdentifier() == p.identifier {
            try? FileManager.default.removeItem(at: cacheURL)
        }
        cancelled.insert(p.identifier)
        central.cancelPeripheralConnection(p)
        connect()
    }

    private func reconnectLater() {
        generation += 1
        let attempt = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.generation == attempt, self.peripheral == nil else { return }
            self.connect()
        }
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


    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let name = peripheral.name ?? advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? ""
        guard self.peripheral == nil, !cancelled.contains(peripheral.identifier),
              name.hasPrefix(peripheralNamePrefix) else { return }
        attach(peripheral)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        guard self.peripheral === peripheral, peripheral.state == .connected else { return }
        cacheIdentifier(peripheral.identifier)
        print("[ble] connected")
        peripheral.discoverServices([CBUUID(string: "7340")])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        connectionEnded(peripheral, error: error)
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        connectionEnded(peripheral, error: error)
    }

    private func connectionEnded(_ p: CBPeripheral, error: Error?) {
        if cancelled.remove(p.identifier) != nil {
            if peripheral == nil { connect() }
            return
        }
        guard peripheral === p else { return }
        if cmdChar == nil, cachedIdentifier() == p.identifier {
            try? FileManager.default.removeItem(at: cacheURL)
        }
        print("[ble] connection ended (\(error?.localizedDescription ?? "no error")) — reconnecting")
        peripheral = nil
        cmdChar = nil
        dataChar = nil
        notifyReady = false
        dataNotifyReady = false
        OledUploader.shared.failPending()
        deviceState = [:]
        reconnectLater()
    }

    // MARK: peripheral

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard self.peripheral === peripheral, peripheral.state == .connected else { return }
        guard let svc = peripheral.services?.first else { print("[ble] no 7340 service"); return }
        peripheral.discoverCharacteristics([
            CBUUID(string: "7341"), CBUUID(string: "7343"), CBUUID(string: "7344"),
        ], for: svc)
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard self.peripheral === peripheral, peripheral.state == .connected else { return }
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
        if let cmd = cmdChar {
            print("[ble] ready — applying state \(lastState)")
            if lastState.hasPrefix("raw"), let value = UInt8(lastState.dropFirst(3)) {
                peripheral.writeValue(frame(0x90, [value]), for: cmd, type: .withResponse)
            } else if lastState.hasPrefix("preview"), let value = UInt8(lastState.dropFirst(7)) {
                peripheral.writeValue(frame(0x91, [value]), for: cmd, type: .withResponse)
            } else {
                peripheral.writeValue(frame(0x90, [ahaState(activeState)]), for: cmd, type: .withResponse)
            }
        }
    }

    func applyDeferredDisplay() {
        guard pendingDisplay, !suppressHeartbeat, !OledUploader.shared.isBusy,
              let per = peripheral, let cmd = cmdChar else { return }
        pendingDisplay = false
        if lastState.hasPrefix("raw"), let value = UInt8(lastState.dropFirst(3)) {
            per.writeValue(frame(0x90, [value]), for: cmd, type: .withResponse)
        } else if lastState.hasPrefix("preview"), let value = UInt8(lastState.dropFirst(7)) {
            per.writeValue(frame(0x91, [value]), for: cmd, type: .withResponse)
        } else {
            per.writeValue(frame(0x90, [ahaState(activeState)]), for: cmd, type: .withResponse)
        }
    }

    func send(state: String) {
        lastState = state
        activeState = state
        lastStateChangeAt = Date()
        if suppressHeartbeat || OledUploader.shared.isBusy { pendingDisplay = true; return }
        guard let cmd = cmdChar else { return }
        let f = frame(0x90, [ahaState(state)])
        peripheral?.writeValue(f, for: cmd, type: .withResponse)
        print("[ble] state -> \(state)")
    }

    /// Direct light-effect preview (cmd 0x91) — bypasses the per-state table.
    func preview(effect: UInt8) {
        lastState = "preview\(effect)"
        if suppressHeartbeat || OledUploader.shared.isBusy { pendingDisplay = true; return }
        guard let cmd = cmdChar else { return }
        let f = frame(0x91, [effect])
        peripheral?.writeValue(f, for: cmd, type: .withResponse)
        print("[ble] preview effect -> \(effect)")
    }

    /// Poll device status every 2 s (firmware never pushes mode/lever changes),
    /// skipped while an OLED upload is in flight.
    func startStatusPolling() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self else { return }
            if let cmd = self.cmdChar, let per = self.peripheral,
               !self.suppressHeartbeat, !OledUploader.shared.isBusy {
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
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
            guard let self else { return }
            let stale = Date().timeIntervalSince(self.lastStateChangeAt) > 75
            if self.activeState == "working" && stale {
                print("[watchdog] working state stale >75s -> idle")
                self.send(state: "idle")
            } else if !self.suppressHeartbeat && !OledUploader.shared.isBusy {
                if let cmd = self.cmdChar, let per = self.peripheral {
                    switch self.activeState {
                    case "working":
                        per.writeValue(frame(0x91, [1]), for: cmd, type: .withResponse)
                    case "waiting", "blocked":
                        per.writeValue(frame(0x90, [0]), for: cmd, type: .withResponse)
                    default:
                        break
                    }
                }
            }
            self.startHeartbeat()
        }
    }

    func send(raw: UInt8) {
        lastState = "raw\(raw)"
        if suppressHeartbeat || OledUploader.shared.isBusy { pendingDisplay = true; return }
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
        guard !suppressHeartbeat, !OledUploader.shared.isBusy else {
            completion("busy"); return
        }
        suppressHeartbeat = true
        print("[remap] key \(index) -> \(hid.map { String(format: "%02X", $0) }.joined())")

        DispatchQueue.global().async {
            func command(_ opcode: UInt8, _ payload: [UInt8]) -> Bool {
                OledUploader.shared.beginAck(opcode)
                let sent = DispatchQueue.main.sync { () -> Bool in
                    guard self.peripheral === per, self.cmdChar === cmd else { return false }
                    per.writeValue(frame(opcode, payload), for: cmd, type: .withResponse)
                    return true
                }
                guard sent else { OledUploader.shared.failPending(); return false }
                let result = OledUploader.shared.waitForAck(timeout: 5)
                if result == .timeout || result == .failed {
                    DispatchQueue.main.sync { self.recycleUploadConnection(per) }
                }
                return result == .success
            }
            let ok = command(0x73, [0x73, 0x00, index] + hid) && command(0x04, [])
            DispatchQueue.main.async {
                self.suppressHeartbeat = false
                self.applyDeferredDisplay()
                completion(ok ? "ok" : "device command failed")
            }
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, peripheral.state == .connected else { return }
        if characteristic.uuid == CBUUID(string: "7341") {
            OledUploader.shared.finishDataWrite(error: error)
        }
        if let e = error {
            OledUploader.shared.failPending()
            print("[ble] WRITE ERROR on \(characteristic.uuid): \(e.localizedDescription)")
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, peripheral.state == .connected else { return }
        if let e = error {
            print("[ble] notify-sub error \(characteristic.uuid): \(e.localizedDescription)")
        }
        if characteristic.uuid == CBUUID(string: "7344") {
            notifyReady = error == nil && characteristic.isNotifying
        } else if characteristic.uuid == CBUUID(string: "7341") {
            dataNotifyReady = error == nil && characteristic.isNotifying
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        guard self.peripheral === peripheral, peripheral.state == .connected else { return }
        if let e = error {
            print("[ble] notify error: \(e)")
            OledUploader.shared.failPending()
            return
        }
        let v = characteristic.value ?? Data()
        print("[ble] notify(\(characteristic.uuid)): \(v.map { String(format: "%02X", $0) }.joined(separator: " "))")
        // 0x00 device status response: AA BB 00 [battery][signal][fwM][fwm][mode][light][switch][brightness] CC DD
        if characteristic.uuid == CBUUID(string: "7344"), v.count >= 12, v[2] == 0x00 {
            deviceState = ["battery": Int(v[3]), "firmwareMajor": Int(v[5]),
                           "firmwareMinor": Int(v[6]), "workMode": Int(v[7]),
                           "lightMode": Int(v[8]), "switchState": Int(v[9]),
                           "brightness": Int(v[10])]
        }
        if v.count >= 6, v[0] == 0xAA, v[1] == 0xBB,
           v[v.count - 2] == 0xCC, v[v.count - 1] == 0xDD {
            OledUploader.shared.signalAck(echo: v[2], status: v[3])
        }
    }
}

// MARK: - OLED (project-name display)

final class OledUploader {
    static let shared = OledUploader()
    private let lock = NSLock()
    private var uploading = false
    var isBusy: Bool { lock.withLock { uploading } }
    enum AckResult: Equatable { case success, rejected(UInt8), failed, timeout }
    private let ackCondition = NSCondition()
    private var expectedAck: UInt8?
    private var ackResult: AckResult?
    private var dataWritePending = false
    private var dataWriteResult: Bool?

    private let width = 160
    private let height = 80
    private let slotSize = 28_672
    private let startIndex = 10        // first custom frame slot (10 factory-reserved)
    private let chunkSize = 4096

    func beginAck(_ opcode: UInt8) {
        ackCondition.lock()
        expectedAck = opcode
        ackResult = nil
        ackCondition.unlock()
    }

    func signalAck(echo: UInt8, status: UInt8) {
        ackCondition.lock()
        if expectedAck == echo, ackResult == nil {
            ackResult = status == 0 ? .success : .rejected(status)
            ackCondition.broadcast()
        }
        ackCondition.unlock()
    }

    func beginDataWrite() {
        ackCondition.lock()
        dataWritePending = true
        dataWriteResult = nil
        ackCondition.unlock()
    }

    func finishDataWrite(error: Error?) {
        ackCondition.lock()
        if dataWritePending {
            dataWriteResult = error == nil
            ackCondition.broadcast()
        }
        ackCondition.unlock()
    }

    func waitForDataWrite() -> Bool {
        ackCondition.lock()
        defer { ackCondition.unlock() }
        let deadline = Date().addingTimeInterval(5)
        while dataWriteResult == nil && ackResult != .failed {
            if !ackCondition.wait(until: deadline) { break }
        }
        let ok = dataWriteResult == true && ackResult != .failed
        dataWritePending = false
        dataWriteResult = nil
        return ok
    }

    func failPending() {
        ackCondition.lock()
        if dataWritePending { dataWriteResult = false }
        if expectedAck != nil {
            ackResult = .failed
            ackCondition.broadcast()
        }
        ackCondition.unlock()
    }

    func pendingFailed() -> Bool {
        ackCondition.lock()
        defer { ackCondition.unlock() }
        guard let result = ackResult else { return false }
        return result != .success
    }

    func waitForAck(timeout: TimeInterval) -> AckResult {
        ackCondition.lock()
        defer { ackCondition.unlock() }
        let deadline = Date().addingTimeInterval(timeout)
        while ackResult == nil {
            if !ackCondition.wait(until: deadline) { break }
        }
        let result = ackResult ?? .timeout
        expectedAck = nil
        ackResult = nil
        return result
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

    func uploadAndShow(text: String) -> Bool {
        lock.lock()
        if uploading { lock.unlock(); return false }
        uploading = true
        lock.unlock()
        defer {
            lock.lock(); uploading = false; lock.unlock()
            DispatchQueue.main.async { Ble.shared.applyDeferredDisplay() }
        }

        let connection: (CBPeripheral, CBCharacteristic, CBCharacteristic)? = DispatchQueue.main.sync {
            guard !Ble.shared.suppressHeartbeat, Ble.shared.uploadReady,
                  let ble = Ble.shared.peripheral, ble.state == .connected,
                  let cmd = Ble.shared.cmdChar, let data = Ble.shared.dataChar else { return nil }
            return (ble, cmd, data)
        }
        guard let (ble, cmd, dataChar) = connection else {
            print("[oled] connection not ready or busy")
            return false
        }
        func recycle() {
            DispatchQueue.main.sync { Ble.shared.recycleUploadConnection(ble) }
        }
        func write(_ data: Data, to characteristic: CBCharacteristic) -> Bool {
            DispatchQueue.main.sync {
                guard Ble.shared.peripheral === ble, ble.state == .connected,
                      Ble.shared.cmdChar === cmd, Ble.shared.dataChar === dataChar,
                      !self.pendingFailed() else { return false }
                ble.writeValue(data, for: characteristic, type: .withResponse)
                return true
            }
        }
        func finishAck(_ opcode: UInt8, timeout: TimeInterval) -> Bool {
            let result = waitForAck(timeout: timeout)
            guard result == .success else {
                print("[oled] command \(String(format: "%02X", opcode)) failed: \(result)")
                if result == .timeout || result == .failed { recycle() }
                return false
            }
            return true
        }
        func command(_ opcode: UInt8, _ data: Data) -> Bool {
            beginAck(opcode)
            guard write(data, to: cmd) else {
                failPending()
                _ = waitForAck(timeout: 0)
                recycle()
                return false
            }
            return finishAck(opcode, timeout: 5)
        }

        let image = makeTextFrame(text)
        print("[oled] uploading frame for \"\(text)\" (\(image.count) bytes)")
        var offset = 0
        while offset < image.count {
            let n = min(chunkSize, image.count - offset)
            let addr = UInt32(startIndex * slotSize + offset)
            let prep = Data([0xAA, 0xBB, 0x80, 0x00,
                             UInt8(n & 0xFF), UInt8((n >> 8) & 0xFF),
                             UInt8(addr & 0xFF), UInt8((addr >> 8) & 0xFF),
                             UInt8((addr >> 16) & 0xFF), UInt8((addr >> 24) & 0xFF),
                             0xCC, 0xDD])
            guard command(0x80, prep) else { return false }
            Thread.sleep(forTimeInterval: 0.05)

            // Install the waiter before sending data: the result can arrive immediately.
            beginAck(0x81)
            var packetOffset = 0
            while packetOffset < n {
                let count = min(180, n - packetOffset)
                let start = offset + packetOffset
                beginDataWrite()
                guard write(image.subdata(in: start..<(start + count)), to: dataChar) else {
                    failPending()
                    _ = waitForAck(timeout: 0)
                    recycle()
                    return false
                }
                let resultDeadline = Date().addingTimeInterval(10)
                guard waitForDataWrite() else {
                    failPending()
                    _ = waitForAck(timeout: 0)
                    recycle()
                    return false
                }
                packetOffset += count
                if packetOffset < n {
                    Thread.sleep(forTimeInterval: 0.012)
                } else {
                    // A late 0x81 ACK is unsafe to match after the timeout.
                    guard finishAck(0x81, timeout: max(0, resultDeadline.timeIntervalSinceNow)) else { return false }
                }
            }
            offset += n
            Thread.sleep(forTimeInterval: 0.05)
        }

        let commit = Data([0xAA, 0xBB, 0x82, 0x00,
                           UInt8(startIndex & 0xFF), UInt8((startIndex >> 8) & 0xFF),
                           0x01, 0x00, 0xE8, 0x03, 0xCC, 0xDD])
        guard command(0x82, commit) else { return false }
        Thread.sleep(forTimeInterval: 0.05)
        guard command(0x04, frame(0x04, [])) else { return false }
        print("[oled] done — showing \"\(text)\"")
        return true
    }
}

// MARK: - HTTP server

final class Server {
    let listener: NWListener
    var doneTimer: DispatchWorkItem?

    init() throws {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        listener = try NWListener(using: params)
    }

    func start() {
        listener.newConnectionHandler = { conn in
            conn.start(queue: .main)
            self.handle(conn)
        }
        listener.stateUpdateHandler = { state in
            if case .failed(let e) = state { print("[http] failed: \(e)"); exit(1) }
        }
        listener.start(queue: .main)
        print("[http] listening on 127.0.0.1:\(port)")
    }

    func handle(_ conn: NWConnection) {
        receive(conn, buffer: Data())
    }

    func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, isComplete, error in
            var buf = buffer
            if let d = data { buf.append(d) }
            guard buf.count <= 1_000_000 else {
                self.reply(conn, 413, "{\"ok\":false}")
                return
            }
            if let range = buf.range(of: Data("\r\n\r\n".utf8)) {
                guard let head = String(data: buf[..<range.lowerBound], encoding: .utf8) else {
                    self.reply(conn, 400, "{\"ok\":false}"); return
                }
                var length: Int?
                for line in head.components(separatedBy: "\r\n").dropFirst() {
                    let parts = line.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
                    guard parts.count == 2 else {
                        self.reply(conn, 400, "{\"ok\":false}"); return
                    }
                    let name = parts[0].trimmingCharacters(in: .whitespaces).lowercased()
                    let value = parts[1].trimmingCharacters(in: .whitespaces)
                    if name == "transfer-encoding" {
                        self.reply(conn, 400, "{\"ok\":false}"); return
                    }
                    if name == "content-length" {
                        guard length == nil, !value.isEmpty,
                              value.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
                              let n = Int(value), n <= 1_000_000 else {
                            self.reply(conn, 400, "{\"ok\":false}"); return
                        }
                        length = n
                    }
                }
                let bodyLength = length ?? 0
                let available = buf.distance(from: range.upperBound, to: buf.endIndex)
                if available >= bodyLength {
                    let end = buf.index(range.upperBound, offsetBy: bodyLength)
                    self.route(conn, head: head, body: Data(buf[range.upperBound..<end]))
                    return
                }
            }
            if isComplete || error != nil {
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
            if let json = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                if let raw = json["raw"] as? Int, (0...8).contains(raw) {
                    Ble.shared.send(raw: UInt8(raw))
                    reply(conn, 200, "{\"ok\":true,\"raw\":\(raw)}")
                } else if let eff = json["preview"] as? Int, (0...16).contains(eff) {
                    Ble.shared.preview(effect: UInt8(eff))
                    reply(conn, 200, "{\"ok\":true,\"preview\":\(eff)}")
                } else if let text = json["text"] as? String, !text.isEmpty {
                    DispatchQueue.global().async {
                        let ok = OledUploader.shared.uploadAndShow(text: String(text.prefix(40)))
                        DispatchQueue.main.async {
                            self.reply(conn, ok ? 200 : 500, "{\"ok\":\(ok)}")
                        }
                    }
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
