# AhaKey X1 Reference

Research + working notes for using the AhaKey X1 on macOS without the Chinese factory
app. Research date: 2026-11-10.

## Layout

- `notes/` — my distilled notes (start here)
  - `device-summary.md` — what the device is, its three capability layers, verified-on-this-Mac facts
  - `ble-protocol-cheatsheet.md` — frame format, commands, key config, HID codes, LED states
  - `options-and-plan.md` — options A–D, why Raycast can't use the X1 mic, current plan + status
  - `hermes-and-multi-computer.md` — using the X1 with Hermes Agent on another machine
  - `orca-bridge.md` — **built & installed**: Orca plugin + BLE daemon driving the light bar
  - `session-log.md` — chronological log of everything done in the first session
- `source-docs/` — original docs downloaded from the AhakeyAI GitHub org (exact copies)
  - `protocol-*.md` — from [AhakeyAI/protocol](https://github.com/AhakeyAI/protocol) (BLE protocol, SDK, commands)
  - `desktop-*.md` — from [AhakeyAI/desktop](https://github.com/AhakeyAI/desktop) (official open-source desktop suite; `ble-protocol.md` is partly Chinese but is the most detailed protocol doc — reverse-engineered + packet-verified)
  - `awesome-ahakey-README.md` — community showcase index

## Tools (`tools/`)

- `ble-scan.swift` — list BLE devices advertising nearby
- `ble-probe.swift` — scan + connect, print services (flags AHAKEY/HID)
- `ble-identify.swift` — service discovery by peripheral UUID
- `keylogger.swift` — log keycodes of pressed keys (needs Accessibility for host app)
- `remap-key.swift` — **remap an X1 key over Bluetooth, no companion app**:
  `swift remap-key.swift <keyIndex 0-3> <HID byte hex, e.g. 68> [mode 0-2]`
  (key indices left→right: mic, checkmark, X, back arrow; HID F13=68, F14=69, F15=6A,
  F16=6B, F17=6C, F18=6D, F19=6E; writes + SAVE_CONFIG + prints device ACKs)

## TL;DR

- USB cable = charging only; the device is Bluetooth LE (HID keyboard + custom service 0x7340).
- The 4 keys work on any computer with **no software** (default F13–F19).
- The mic is **not** a standard audio device; voice needs a companion app that transcribes
  and types into the focused window.
- The open-source Swift client (`AhakeyAI/desktop`) replaces the Chinese app entirely.
- Lever = readable switch (approval-gate for agents); LEDs/OLED = host-driven status surfaces.
