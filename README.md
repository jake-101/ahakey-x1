# ahakey-x1

Use the [AhaKey X1](https://ahakey.com/) ("Vibecoding Keyboard") on macOS **without the
vendor's software** — as a programmable macro keyboard, a voice-input trigger, and a live
status display for AI coding agents.

Everything here was built by pairing the device with the protocol documentation from the
[vendor's open-source repos](https://github.com/orgs/AhakeyAI/repositories) and verifying
against the real hardware.

## Setup from scratch

Prerequisites: macOS with [Orca](https://orca.new), [Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install` — provides `swiftc`), an AhaKey X1, and optionally [Raycast](https://raycast.com) for voice input.

1. **Pair the keyboard** — System Settings → Bluetooth → connect the `AhaKey …` entry. This bonds the HID half (the key bindings). You'll know it's working when the keys act as shortcuts in any app.

2. **Build and start the daemon**:

   ```sh
   git clone https://github.com/jake-101/ahakey-x1
   cd ahakey-x1/daemon
   swiftc -O -o ahakey-daemon daemon.swift
   ./ahakey-daemon          # approve Bluetooth access when macOS asks
   ```

   Verify: `curl localhost:8787/status` should say `"connected":true` — then try
   `curl -X POST localhost:8787/state -d '{"state":"working"}'` and watch the light bar.

3. **Auto-start it** — install the launchd agent (edit the copied plist first, replacing
   the placeholder path with your checkout path):

   ```sh
   cp ../launchd/com.ahakey.daemon.plist ~/Library/LaunchAgents/
   # edit ~/Library/LaunchAgents/com.ahakey.daemon.plist → fix the binary path
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ahakey.daemon.plist
   ```

4. **Install the Orca plugin**:

   ```sh
   orca plugin install github.com/jake-101/ahakey-x1     # once listed in the directory
   # or, from a clone of this repo:
   orca plugin install ./orca-ahakey
   ```

   Approve it when Orca asks (it runs a Node worker and reads agent status). You should
   see an **AhaKey** item in Orca's status bar showing agent state + battery.

5. **Voice input (optional)** — in Raycast Settings → Extensions → Dictation:
   set the hotkey to **F13** (then the keyboard's mic key triggers it) and pick your
   input device (the X1's own mic is *not* a macOS audio device — use e.g. a display mic).

6. **Optional settings** — Orca → Settings → AhaKey Bridge:
   *Keyboard screen text* (shown on the X1's OLED, uploaded once on change) and
   *Daemon port* (only if you don't use the default 8787).

## Troubleshooting

| Symptom | Fix |
|---|---|
| Lights dead, keys work | `curl localhost:8787/status` — if `connected:false`, power-cycle the keyboard (the daemon catches it during its blue-flashing window) |
| Keys dead or wrong | Check System Settings → Bluetooth: if the device name suffix changed, the BLE identity rotated — remove the old entry and re-pair |
| Lights wrong in some modes | The custom light table applies to **work mode 0**; short-press the power button until the screen shows mode 0's logo |
| Bar stuck animating | Shouldn't happen (75 s watchdog expires zombie states); if it does, click the status bar item or `launchctl kickstart -k gui/$(id -u)/com.ahakey.daemon` |

## What it does


```
Any agent CLI (Claude Code, OMP, OpenCode, Codex, Grok, ...)
        │ supervised by Orca
        ▼
orca-ahakey plugin ──HTTP──> ahakey-daemon ──BLE──> AhaKey X1 light bar
```

- **Macro keyboard** — the 4 keys (mic / ✓ / ✗ / ←) are plain Bluetooth HID with
  bindings stored in the keyboard's flash. They work on any computer with zero software.
  Current bindings: **F13** (Raycast dictation hotkey), **Return**, **Escape**, **Delete**.
- **Voice input** — the mic key triggers Raycast AI dictation; the transcription is typed
  into whatever app is focused. (The X1's built-in microphone is *not* a standard macOS
  audio device — it only works through vendor software — so dictation uses another mic.)
- **Agent status light bar** — the daemon mirrors Orca's `agent.status.changed` events
  (for every harness Orca supervises) onto the LED strip:

  | Agents | Light bar |
  |---|---|
  | working | blue Knight Rider sweep, looping |
  | needs you (waiting/blocked) | red flash |
  | all done | cyan siren → dark after 2 s |
  | idle | dark |

- **Programmable over Bluetooth** — keys and the per-state light table can be remapped at
  runtime over BLE (`POST /remap`, `set-light-mapping`); no vendor app, no Windows tool.

## Components

| Components |
|---|
| `daemon/` | Swift + CoreBluetooth daemon: keeps the BLE connection, HTTP API on `127.0.0.1:8787` (`/state`, `/display`, `/remap`, `/status`), LED state sync + heartbeat, device status polling. Runs under launchd. |
| `launchd/` | LaunchAgent plist template for auto-starting the daemon at login. |
| `orca-ahakey/` | [Orca](https://orca.new) plugin: subscribes to `agent.status.changed`, aggregates across all workspaces, forwards to the daemon. Adds an Orca status bar item (state + battery). |
| `reference/` | The useful part for other owners: distilled protocol notes, a BLE cheatsheet, a deep-dive into the vendor client's source, one-shot Swift tools (BLE scan/probe/identify, keylogger, key remapper, light-mapping writer), and copies of the vendor's protocol docs. |

## Notes for reusing this

- The X1 is **Bluetooth LE only** — the USB-C cable is charging-only (on firmware 1.0).
- The device's BLE MAC/name suffix **can change** (observed once, after holding the
  power button down — likely a reset; it does *not* change on normal power cycles).
  So don't rely on the address — connect by advertised name (`AhaKey …`). Re-pair in
  System Settings only if the keys stop working and the suffix has changed.
- The keyboard must be paired once via System Settings → Bluetooth for the key bindings
  to work (standard HID).
- Paths (home dir, device ids, launchd labels) are hardcoded to this machine — treat the
  code as a working reference implementation, not a turnkey installer.
- Device was on **firmware 1.0** when this was written; the vendor's current release is
  1.1.x (adds USB HID and new OLED features — see `reference/research/`).

## Documentation

- [`reference/research/protocol-deep-dive.md`](reference/research/protocol-deep-dive.md) —
  how the device really behaves: connection lifecycle, ACK semantics, packetization rules,
  the full OLED upload sequence, and the LED effect vocabulary (extracted from the
  vendor's open-source client).
- [`reference/notes/`](reference/notes/) — device summary, BLE cheatsheet, the Orca bridge,
  and a full session log including what didn't work.
- [`reference/tools/`](reference/tools/) — standalone scripts (no daemon needed for
  one-shot operations, except that non-advertising devices require an existing connection).

## Related

- [AhakeyAI](https://github.com/orgs/AhakeyAI/repositories) — the vendor's open-source
  clients, protocol docs, and firmware releases (Apache-2.0). `source-docs/` contains
  copies; see [`reference/source-docs/README.md`](reference/source-docs/README.md).

## License

MIT — see [LICENSE](LICENSE). The vendored vendor documentation in `reference/source-docs/`
remains under its original Apache-2.0 license.
