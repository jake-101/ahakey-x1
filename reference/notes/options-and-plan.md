# Options, plan, and status

*2026-11-10. Companion notes: `device-summary.md`, `ble-protocol-cheatsheet.md`, `hermes-and-multi-computer.md`*

## Goal

Use the AhaKey X1 without the Chinese factory app. Primary wants:
1. Voice/dictation into **Orca** and/or **Raycast dictation** (audio from a Mac-visible mic).
2. Later: usable with **Hermes Agent** on another computer.

## Options

| Option | What | Effort | Status |
|---|---|---|---|
| **A. Dumb-keyboard mode** | No app. Pair X1, bind F13–F16 to Raycast dictation / Orca push-to-talk hotkeys. Audio from Studio Display mic. | ~10 min | **Chosen starting point** |
| **B. Open-source Swift client** | Build `AhakeyAI/desktop` (Swift/SwiftUI, Apache-2.0). English UI. Real X1 mic + voice HUD (Apple Speech, types into focused app), key remap, OLED, LED, lever daemon. | ~30 min | Backup / next |
| **C. Fork B** | Add an Orca/Hermes relay route or trigger Raycast from the X1's real mic. TypeScript plugin SDK exists. | weekend | Later |
| **D. DIY thin client** | Own CoreBluetooth script per protocol docs (see cheatsheet). Commands 0xA0–0xEF reserved for us. | as needed | Later |

## Why Raycast can't use the X1's mic

The X1 mic is not a standard audio device — audio travels the custom BLE channel to a
companion app which transcribes and types. Raycast dictation *can* pick its input device,
but only among macOS-visible mics (Studio Display / Volt 276 / built-in). So the X1's
keys work great as *triggers*; its mic only works *with a companion client* (Option B/C).

## Known unknowns (test when device is on)

- [ ] Multi-host pairing: does it remember Mac + another machine, or need re-pairing?
- [ ] What does the dedicated voice key send by default (HID code? BLE event only?)
- [ ] Actual default key mappings (docs say F13–F19; verify with TextEdit)
- [ ] Which physical switch position = which work mode (0/1/2)

## Status / next steps

1. ✅ **Paired** — "AhaKey AF1E", BLE address `D0:F8:AF:1E:7E:C3`, VID 0x07D7, HID over BLE.
   Connects automatically when powered on. Battery read 95% (2026-11-10).
2. ✅ **Key test done** — physical layout (left→right): **mic, checkmark, X, back arrow**,
   factory defaults: F18, Return, Down, Delete. Work mode 0, lights off, switch 0.
3. ✅ **Mic key remapped to F13** — `swift remap-key.swift 0 68` (HID 0x68 = F13 →
   macOS kVK 105). ACK `AA BB 73 00 CC DD`, saved with SAVE_CONFIG, verified with
   keylogger. **Our own remapper works — no Chinese app needed.**
4. ⏭ Bind F13 → Raycast dictation (Settings → Extensions → Dictation → hotkey),
   input device = Studio Display Microphone.
5. ⏭ Optional: build open-source client (Option B) for X1's real mic + lever + LEDs.

### Tools (this folder)

- `ble-scan.swift` — `swift ble-scan.swift [seconds] [name-filter]` — list advertisers
- `ble-probe.swift` — `swift ble-probe.swift [minRSSI] [seconds]` — scan + connect strong
  devices, print services (flags AHAKEY/HID)
- `ble-identify.swift` — `swift ble-identify.swift <uuid>...` — service discovery by UUID

## Useful links

- Org: https://github.com/orgs/AhakeyAI/repositories
- Desktop releases (installers): https://github.com/AhakeyAI/desktop/releases
- Desktop build: `swift build` from repo root (SwiftPM, target `AhaKeyConfig`)
- Nexting SDK X1 case (experimental, BLE JSON protocol, device-audio profile):
  https://nexting.ai/doc/documentation/devices
- Raycast dictation manual (input device + hotkey): https://manual.raycast.com/ai/dictation
