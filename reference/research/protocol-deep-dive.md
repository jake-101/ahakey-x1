# Protocol deep-dive: findings from the vendor source

*Source: systematic read of the official open-source client (`AhakeyAI/desktop`,
cloned to /tmp/ahakey-desktop), 2026-11-10. Two reports merged; file/line refs are to
`ahakeyconfig-mac/Sources/` unless noted.*

## The protocol rules we must follow (each one is a real failure the vendor hit)

1. **Frame envelope everywhere**: `AA BB [cmd] [payload] CC DD`. ACK = `AA BB [cmd echo]
   [status] CC DD`, minimum 6 bytes, **status 0 = success**, non-zero = device rejected
   (never retry those).
2. **One waiter slot per command byte.** Responses carry no request ID. Registering a new
   waiter supersedes the old one. After a 0x81 data-write timeout, **the connection is
   poisoned** (a late ACK can confirm the wrong write) — the vendor *cancels the BLE
   connection and reconnects* (`invalidateDataWriteConnection`, AhaKeyBLEManager.swift
   L1231-1236). This is very likely why our daemon's upload stalled in
   "Uploading pic 10,70": our first broken attempts left stale state, and we never recycle
   the connection on timeout.
3. **Serialize everything**: 50 ms between queued commands; 12 ms between data
   sub-packets; data packets capped at **180 bytes** (firmware frames at ~180 B; larger
   writes = CoreBluetooth "value's length is invalid" or silent firmware drop).
   Chunk = 4096 B (one flash sector — **each 0x80 prepare erases+writes exactly one
   sector**; addresses must be 4096-aligned). Wait for the 0x81 with a **10 s timeout that
   starts after the last packet is handed to CoreBluetooth**; max 3 timeout-only retries;
   resend of 0x80+data at the same address is idempotent.
4. **Command timeout default 5 s.** Fail all pending waiters immediately on disconnect.
5. **Poll device status (0x00) every 1.5 s while connected** — the firmware does NOT push
   lever/mode changes; polling is the only way to detect them. Skip polls during uploads
   or while waiters are pending. This also explains our device "going quiet": the vendor
   treats lack of status as staleness (agent: freshness < 5 s).
6. **Old firmware ACKs unknown commands with status 0** — capability detection must be
   write-then-read-back (e.g. set brightness 0x85, verify via 0x00 status byte 7).

## Connection lifecycle (the vendor's three-tier strategy)

```
1. retrievePeripherals(by remembered identifier)   — fast path, per-boot only
2. retrieveConnectedPeripherals([0x7340, 0x180A, 0x180F, 0x1812])
   — THE HID TRICK: once the system HID bond is up, the device STOPS ADVERTISING;
     a system-connected keyboard is findable through the HID service 0x1812
     (comment "Issue #34", L142-143)
3. scanForPeripherals(service 0x7340), filtered by name prefix
   — accepted names: "AhaKey", "vibe code" (case-insensitive); 10 s scan timeout
```

- **Name prefix is the durable identity** — the MAC/identifier rotates on power cycles
  (confirmed live: AF1E → B11E). The vendor does NOT persist the identifier across
  restarts.
- **No app-level pairing/bonding** — plain writes to 0x7340; the system HID bond is
  assumed to exist for keyboard function but is not enforced programmatically.
- Reconnect backoff: 4s → 8s → 15s → 30s (reset on sighting the device or connect).
- Our daemon's "device not advertising" problem has a documented fix: **tier 2** —
  retrieve by connected-peripherals lookup including 0x1812.

## Device status (0x00 response) — corrected layout

`AA BB 00 [battery][signal(Int8 SIGNED)][fwMain][fwSub][workMode][lightMode][switch]
[brightness?] CC DD` — byte 7 is **brightness (1-100, default 35)** in newer firmware,
not "reserved" (the vendor doc is wrong). Presence of a plausible brightness is the
lighting-firmware capability heuristic.

## OLED upload — complete sequence (single frame, mode 0)

```
subscribe 0x7344 (+0x7341) notifications FIRST
per 4096-byte chunk of the 25600-byte frame (7 chunks):
    AA BB 80 00 [len:2LE] [addr:4LE] CC DD  → 0x7343, wait echo 0x80 (≤5s)
    write chunk as ≤180-byte packets, 12 ms apart → 0x7341 (.write = withResponse)
    wait 0x81 write-result (10 s, from after last packet; timeout ⇒ RECONNECT)
    retry same address up to 3× on timeout (idempotent per-sector)
commit:  AA BB 82 [mode] [start:2LE] [count:2LE] [delayMs:2LE] CC DD, wait echo 0x82
then:    AA BB 04 CC DD (SAVE_CONFIG — sent by the app's write flow; win-java always
         sends it right after 0x82; treat as required for persistence)
```

- Frame N in mode M lives at address `(10 + min(3,M)*70 + N) * 28672`.
- Slot = 28672 B (7 sectors); payload 25600 B; trailing 3072 B never written.
- Max 70 frames per upload; delay = max(1, 1000/fps); single-frame static display =
  count=1 (win-java "clear slot" uses count=0, delay=0 — and is **USB-only** per their
  docs: "screen animations can only be modified via USB" on some units — unverified for
  BLE).
- **"Uploading pic 10,70"** (device screen) = firmware flash-write indicator:
  start slot 10, 70-slot mode-0 region. Not a string in the client source — device-side.
- No 0x83 handshake needed (the app sends it but discards the result — UI refresh only).
- **0x93/0x94 (per-AI-state OLED GIFs)**: implemented only in the Windows Java client —
  payload `mode:1, state:1, startIndex:2LE, frameCount:2LE, delayMs:2LE`; state 1-4 =
  idle/running/waiting/done; per mode, 4 profiles × 44 slots, asset offsets {0,8,20,32}.
  **Gated behind a 0x9F capability query on newer firmware** — do not send blind.

## 0x90 state sync (vendor's agent architecture worth copying)

- IDE hooks → Unix socket `/tmp/ahakey.sock` → agent → fire-and-forget `AA BB 90 [s]`.
- **Watchdog every 10 s**: transient states expire — permission/prompt states after 30 s,
  tool states after 60 s — resetting to Stop (5) **only if** the CLI processes exited.
- `state_with_reset` = send state + schedule auto-reset after delayMs.

## What "better" looks like for our daemon (the robust rewrite)

1. Three-tier connect (identifier cache → system-connected lookup incl. 0x1812 → name
   scan) — fixes our "device not advertising" dead-ends entirely.
2. Real waiter table keyed by command byte with 5 s/10 s timeouts, connection poisoning
   + reconnect on 0x81 timeout, single upload mutex.
3. 1.5 s status poll loop (gives us live battery/mode/lever for free, detects lever and
   mode changes — the firmware never pushes them).
4. Watchdog with state expiry (our current heartbeat never expires a stale "working").
5. 0x04 after 0x82 commits.

## Community repos to investigate (user's pointer: other GitHub repos document this)

- `awesome-ahakey` — **placeholder only, nothing to reference** (confirmed by Jake).
- The Windows Java client (`ahakeyconfig-win-java`) is the ONLY source for 0x93/0x94,
  0x99 task-slot, 0x9A heartbeat, and 0x9F capability-query commands.
- Nexting SDK (nexting.ai) has an AhaKey X1 case study with a JSON-over-BLE profile
  (device-audio/1) — alternative ecosystem, experimental.
