# AhaKey X1 — What it is and how it works

*Research date: 2026-11-10. Sources in `../source-docs/`.*

## The device

A BLE "vibecoding keyboard": 4 keys, an approval lever, WS2812 LED strip, 160×80 OLED,
microphone + voice key, battery. Connects over **Bluetooth LE only — the USB-C cable is
charging only** (verified: it does not enumerate as a USB device at all).

It exposes two communication surfaces:

1. **Standard BLE HID keyboard** — the 4 keys send normal shortcuts/macros. Works on any
   computer with zero companion software.
2. **Custom BLE service `0x7340`** — for configuration, state sync, OLED/LED control, and
   voice. This is what companion apps speak.

## The three capability layers

### Layer 1 — zero software (plain HID)
- **4 keys**: each sends a shortcut (list of HID keycodes) or a macro (key down/up/delay
  sequences). 3 work modes × 4 keys = 12 slots. Stored in flash on the device, survives
  reboots and re-pairing.
- Default mappings are **F13–F19** (HID 0x68–0x6E) — keys nothing else uses, ideal for
  global hotkey binding (Raycast, Orca, etc.).

### Layer 2 — needs a companion client (custom BLE service)
- **Lever (toggle)**: just a switch state the host reads (0/1). Meaning comes entirely
  from the client. Official use: **hardware approval gate** — flip to auto and the
  desktop daemon answers agent permission hooks with "allow"; flip back = manual confirm.
  Fail-safe: unreadable lever defaults to *ask*. Judged once per request at hook time.
- **LED strip**: host pushes agent states → light effects. Working=blue breathing,
  permission=yellow, done=green flash, etc. Brightness 1–100 configurable.
- **OLED 160×80**: host-uploaded RGB565 images/animations (up to 74 frames) + 20-char
  key labels. Not a live-text display except via the host client.
- **3 work modes**: host can switch key-mapping modes (command 0x92).

### Layer 3 — voice
- The mic has **no on-device transcription** and is **not a standard macOS audio device**
  (never appears in a mic picker — verified on Jake's Mac).
- Flow: device mic → audio over custom BLE → companion app runs ASR locally (legacy
  factory app: CapsWriter/SenseVoice; new open-source Swift client: Apple Speech) →
  **types text into the focused window**. Works with any app that has a text field.

## Key repos (github.com/AhakeyAI)

| Repo | What | Notes |
|---|---|---|
| `desktop` | Official open-source desktop suite (Apache-2.0) | macOS client is native Swift/SwiftUI + CoreBluetooth; includes voice HUD (push-to-talk, Apple Speech, "relay routes for IDEs"), lever-gate daemon, hook handlers for Claude/Cursor/Codex/Kimi. **Replaces the Chinese app.** Updated daily. |
| `protocol` | Developer kit: BLE protocol docs + hardware SDK + examples | Frame format, commands, HID codes. Invites third-party macOS clients. |
| `firmware` | Official firmware release notes | |
| `awesome-ahakey` | Community project showcase | |
| `AhaKey-Studio-mac` | Older Swift macOS client | Superseded by `desktop` monorepo |

The legacy Chinese app was PyInstaller/PySide6 + a .NET BLE↔TCP bridge — the open-source
Swift client eliminates all of that.

## Facts verified on this Mac (Nov 10 2026)

- No AhaKey USB device, no AhaKey audio device. Cable = charging only.
- Bluetooth shows a paired "**Bluetooth Keyboard**" (`10:12:89:AE:00:02`), *Not Connected* —
  likely the X1; device was powered off at time of check.
- Available mics for dictation: **Studio Display Microphone** (default), Volt 276,
  MacBook Pro built-in.
- Tooling available: Swift 6.4.2 (can compile CoreBluetooth scan/test scripts), python3.
