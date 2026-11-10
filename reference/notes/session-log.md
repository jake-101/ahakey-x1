# Session log

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
