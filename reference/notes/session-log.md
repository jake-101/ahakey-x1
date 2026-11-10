# Session log

## 2026-11-10 (night, 3) — key bindings finalized, daemon /remap + status polling

- User feedback on real usage: the key-to-binding attribution was shifted — the actual
  layout is checkmark=Return, **X=Down** (which in OpenCode dialogs jumps into the
  sub-agent/session list — the "can't get out" complaint), **back arrow=Delete**.
- Remapped **X → Escape** (HID 0x29) — the universal "get out" key. Final bindings:
  **mic=F13, checkmark=Return, X=Escape, back arrow=Delete.**
- The standalone `remap-key.swift` tool can't reach a system-connected (non-advertising)
  device — moved remaps into the daemon: **`POST /remap {"keyIndex":0-3,"hid":[bytes]}`**
  (0x73 + SAVE_CONFIG on the daemon's always-on connection, echo-verified).
- Daemon now **polls device status (0x00) every 2 s** (per the vendor's poll-don't-push
  rule) and exposes it in `/status` → `device:{battery,workMode,lightMode,switchState,
  brightness,...}`. Heartbeat suppressible during config writes.
- Daemon is now the single tool for everything: state, preview, remap, status. Confirmed
  the device's stored config matches what we observed (mode 0, our bindings survive
  power cycles via SAVE_CONFIG).

## 2026-11-10 (night, 2) — Rust runtime trial: adopted for config, Swift daemon stays for live state

- Installed Rust (brew, 1.99.1); cloned + built `ahakey-runtime-rust` to
  `~/Projects/ahakey-runtime-rust` (btleplug + tokio, WebSocket/JSON-RPC on loopback,
  discovery file at `~/Library/Application Support/AhaKey/runtime/discovery.json`).
- **Works flawlessly on fw 1.0, first try**: found "AhaKey B11E", connected in ~3.7s,
  0x9F catalog query OK, reads battery/brightness/lever/workMode, polls status.
- **But the runtime has NO live AI-state (0x90) RPC** — it's a config/OLED tool. The
  vendor's own architecture splits the same way (Rust = Studio config; Swift agent =
  live state). So: **final architecture = two pieces** — Rust runtime for config/OLED
  (when used), our Swift daemon for live lights (kept, works).
- OLED upload through the runtime returned **UNSUPPORTED_CAPABILITY**: needs the CP2
  resource profile (`x1-cp2-resource-v1`) — firmware 1.1.x. Our device is fw 1.0.
  → OLED features require a firmware flash (official: Windows + WCHISPTool; Mac
  alternative: `ch58x-programmer`, official HEX, ISP mode = hold voice key + plug USB
  with a DATA cable). Deferred until we have Windows or a data-capable cable.
- Firmware releases: v1.1.0 = current factory/recommended (adds USB HID, AI state light
  protocol, brightness config, new OLED behavior); v1.0.0 = initial. Flashing resets BLE
  identity → re-pair dance again.
- Runtime ops: `cargo run --locked` (needs exclusive-ish BLE; fails with
  RUNTIME_ALREADY_RUNNING if another instance holds the lock). Stopped for now.

## 2026-11-10 (night) — systematic protocol research (vendor source)

- Two parallel research passes over the official client source produced
  `reference/research/protocol-deep-dive.md` — the real rules of the protocol:
  - 0x81 data-write timeouts **poison the connection by design** (no request IDs); the
    vendor app tears down and reconnects. Our OLED stall is explained; fix = connection
    recycling + proper waiter table.
  - Device stops advertising once the system HID link is up; the vendor finds it via
    **retrieveConnectedPeripherals including HID service 0x1812** ("Issue #34").
  - Status byte 7 of the 0x00 response is **brightness** (doc says "reserved" — wrong).
  - Must poll status every 1.5 s (firmware never pushes lever/mode changes).
  - Full OLED sequence includes a trailing SAVE_CONFIG (0x04) after 0x82.
  - 0x93/0x94 (per-AI-state OLED) exist only in the Windows client, gated behind a
    0x9F capability query — don't send blind.
- Conclusion: our daemon works but is hacky (no waiter table, no connection poisoning,
  no status poll, heartbeat never expires). A robust rewrite plan is in the deep-dive.

## 2026-11-10 (evening) — device identity, work modes, OLED paused

- **Work modes discovered**: a short press on the power button cycles work mode
  0 → 1 → 2 (factory presets branded as Claude Code / Codex / Cursor — the OLED logo
  animation changes per mode). Each mode has its own key mappings, OLED animation set,
  and light-state table. Our light-table rewrite (0x84) applied to **mode 0 only**;
  modes 1/2 keep factory behavior (including the blue-middle Stop look).
- **MAC rotation**: power-cycling normally keeps the address; it rotated **once**
  ("AhaKey AF1E" `D0:F8:AF:1E:7E:C3` → "AhaKey B11E") after a long button hold (likely a
  reset). The old macOS pairing and the old peripheral identifier die with the old
  address. The daemon now connects by advertised name (prefix "AhaKey") and caches the
  last-seen identifier in `~/.ahakey-daemon/peripheral-id`; it catches the device during
  its post-power-on advertising window (blue flashing).
- Note: re-pair in System Settings → Bluetooth whenever the name suffix changes.
- **OLED project-name display: paused.** Architecture is proven and coded (daemon renders
  text → RGB565 frame → chunked upload via 0x80/0x7341 → 0x82 commit; plugin posts
  `workspace.changed` names) but the device stalls in "Uploading pic 10,70" after the
  first chunk ACK: only the first `0x80` gets acknowledged (`AA BB 80 00`), no `0x81`
  write-results, no further ACKs — even with 180-byte packetization. Suspicion: upload
  session was corrupted by the early malformed attempts, or an undocumented handshake
  step is missing (the vendor app subscribes to 0x7341 notifications; that char has no
  notify property on this firmware). Needs a clean device + fresh investigation.
- Daemon unbuffered logging fixed (launchd log now works).

## 2026-11-10 (later) — LED polish: ending state + continuous working animation

- Real-world use showed two flaws: the bar *settled* into static blue middle (1) at the
  end of turns, and (2) mid-task after ~30 s of "working".
- Root causes found in the vendor app source (cloned AhakeyAI/desktop): the firmware has
  **17 named light effects**; the **0x84 state table** mapped state 5 (Stop) → middleLight
  (static blue middle); animated effects settle after a while; same-state re-sends are
  ignored; the **0x91 preview command restarts an effect every time**.
- Fixes:
  - New tool `reference/tools/set-light-mapping.swift` (0x84 + SAVE_CONFIG): state 0 →
    warningBlink (11, red flash), state 5 (Stop) → off (0). Ending is now fully dark.
  - Daemon heartbeat: while agents are working, re-trigger the Knight Rider via `0x91`
    preview effect 1 every 8 s → continuous animation while working.
  - Daemon: unbuffered stdout (launchd logs now work), `POST /state {"preview":N}`
    endpoint, `activeState` vs `lastState` split.
- Verified live with the user: continuous Knight Rider while working, red flash on
  waiting, cyan siren on done, fully dark at rest. It also works in real Orca sessions —
  the bar mirrors the assistant's own activity.

## 2026-11-10 — initial research, bring-up, and Orca bridge

### Research
- Surveyed github.com/AhakeyAI (9 repos): `desktop` (official open-source suite),
  `protocol` (BLE docs + SDK), `firmware`, `awesome-ahakey`, others.
- Read the reverse-engineered BLE protocol (desktop repo `ble-protocol.md`, packet-verified):
  frame format `AA BB [cmd] [data] CC DD`, service 0x7340, commands 0x00–0x94, HID keymap,
  OLED image pipeline, AI-state sync.
- Researched Raycast dictation (can pick any macOS-visible input device + hotkey) and
  Hermes Agent (Nous Research) for the second-computer question.
- Saved all source docs to `reference/source-docs/`; distilled notes in `reference/notes/`.

### Key discoveries
- USB cable is charging-only; the X1 is Bluetooth LE (HID keyboard + custom service 0x7340).
- The X1 mic is NOT a macOS audio device — voice needs a companion app (transcribes, types
  into the focused window). Raycast dictation therefore uses another mic (Studio Display).
- The 4 keys are plain BLE HID, work on any computer with zero software.

### Device bring-up (this Mac)
- Powered on, discovered advertising as **"AhaKey AF1E"** (`D0:F8:AF:1E:7E:C3`, VID 0x07D7),
  paired via System Settings. Connects automatically when powered on.
- Key layout (left→right): **mic, checkmark, X, back arrow**.
- Factory key bindings read via key logger: mic=F18, checkmark=Return, X=Delete, back=Down.
- Wrote Swift CoreBluetooth tools in `reference/tools/`: ble-scan, ble-probe, ble-identify,
  keylogger (needs Accessibility for the host terminal), and **remap-key.swift** — remaps any
  key over BLE with command 0x73 + SAVE_CONFIG. Remapped mic key F18 → **F13** (verified).
- Battery read 95%; firmware 1.0.

### Voice workflow
- Raycast AI Dictation bound to **F13** (the X1 mic key), input device = Studio Display
  Microphone. Press mic key → dictation → text into focused app (Orca, Hermes, anything).

### LED state sweep (corrects the docs' guesses)
| 0x90 byte | effect |
|---|---|
| 0 | red flash |
| 1 | slow blue flash → static blue middle |
| 2/3/4 | blue Knight Rider sweep |
| 5 | off |
| 6 | static blue middle |
| 7 | cyan siren expanding outward from center |
| 8 | off |
No yellow/green on this unit (docs inferred them wrong); colors likely customizable via 0x84.

### Built the Orca ↔ X1 bridge
- `daemon/daemon.swift` → `ahakey-daemon`: Swift + CoreBluetooth daemon; keeps BLE connection
  to the X1, serves HTTP on 127.0.0.1:8787 (`GET /status`, `POST /state`, `raw` for testing).
- `orca-ahakey/`: Orca plugin (`local.ahakey`, trusted-worker) subscribing to
  `agent.status.changed` — works for every harness Orca supervises (Claude Code, OMP,
  OpenCode, Codex, Grok, ...). Aggregates states: waiting/blocked > working > done > idle.
- Mapping: working → blue sweep (3); waiting/blocked → red flash (0); done → cyan siren (7)
  then idle after 5 s; idle → off (5).
- Installed: plugin via `orca plugin install` (approved), daemon via launchd
  (`~/Library/LaunchAgents/com.jake.ahakey-daemon.plist`, RunAtLoad + KeepAlive).
- Verified end to end with test events and a live light show.

### Not done yet (backlog)
- OLED animations per state (upload RGB565 frames once; 0x93 switches them per AI state).
- Custom per-state colors via command 0x84.
- Hermes integration on the second computer (see `hermes-and-multi-computer.md`).
- Multi-host pairing behavior (Mac + second machine) unverified.
