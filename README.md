# ahakey-x1

Use the [AhaKey X1](https://ahakey.com/) ("Vibecoding Keyboard") on macOS **without the
vendor's software** — as a programmable macro keyboard, a voice-input trigger, and a live
status display for AI coding agents.

Everything here was built by pairing the device with the protocol documentation from the
[vendor's open-source repos](https://github.com/orgs/AhakeyAI/repositories) and verifying
against the real hardware.

## Setup from scratch

Prerequisites: macOS, [Orca](https://orca.new) 1.4.248 or newer, an AhaKey X1, and
[Xcode Command Line Tools](https://developer.apple.com/xcode/) (`xcode-select --install`
provides `swiftc`). [Raycast](https://raycast.com) is optional for voice input.

1. **Pair the keyboard** in System Settings → Bluetooth: connect the `AhaKey …` entry.
   This bonds the HID keyboard; check that its keys work. Power it on and leave Bluetooth enabled.

2. **Build and run the daemon in the foreground.** In Terminal:

   ```sh
   git clone https://github.com/jake-101/ahakey-x1.git
   cd ahakey-x1/daemon
   swiftc -O -o ahakey-daemon daemon.swift
   ./ahakey-daemon
   ```

   Allow Bluetooth access when macOS asks. Leave this terminal running and use a
   **second terminal** to check the daemon and test the lights:

   ```sh
   curl http://127.0.0.1:8787/status
   curl -X POST http://127.0.0.1:8787/state -H 'content-type: application/json' -d '{"state":"working"}'
   curl -X POST http://127.0.0.1:8787/state -H 'content-type: application/json' -d '{"state":"idle"}'
   ```

   Wait for `"connected":true` before testing. The first POST should show a blue
   sweep in work mode 0; the second clears it. Stop the foreground daemon with
   Ctrl-C before starting the LaunchAgent, so only one daemon owns the port and BLE connection.

3. **Start it automatically at login.** From the checkout's `daemon` directory:

   ```sh
   mkdir -p ~/Library/LaunchAgents
   cp ../launchd/com.ahakey.daemon.plist ~/Library/LaunchAgents/
   ```

   Edit `~/Library/LaunchAgents/com.ahakey.daemon.plist`: replace
   `/path/to/ahakey-x1/daemon/ahakey-daemon` with the **absolute** path to the
   binary you built (use `pwd` in the daemon directory to find it). Then:

   ```sh
   launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.ahakey.daemon.plist
   curl http://127.0.0.1:8787/status
   ```

   The agent runs at login and restarts if it exits. Its log is
   `/tmp/ahakey-daemon.log`. If macOS requests Bluetooth access for the launched
   process, allow it in System Settings → Privacy & Security → Bluetooth.

4. **Install AhaKey Bridge in Orca.** In Orca's plugin marketplace, search for
   **AhaKey Bridge** (`jake-101.ahakey`) and install it if listed. Alternatively,
   from the checkout's `daemon` directory install this local copy:

   ```sh
   orca plugin install ../orca-ahakey
   ```

   Orca requires approval for this trusted worker's **Full Access**: it executes
   code on your Mac, reads agent and workspace status, and accesses its own settings.
   Review the source and requested access before approving. The CLI prints an
   `approval_required` response with the exact fingerprint-bound command to rerun;
   approve in Orca if using the UI. No marketplace release is implied by changes in
   this checkout. The AhaKey status bar item shows aggregate agent state and, when
   available, battery.

5. **Optional settings** — Orca → Settings → AhaKey Bridge: *Keyboard screen text*
   uploads on change (empty leaves the screen unchanged); *Daemon port* must match
   the daemon's port, default 8787.

6. **Voice input (optional)** — in Raycast Settings → Extensions → Dictation:
   set the hotkey to **F13** and pick an input device. The X1 mic is not a macOS
   audio device; use another microphone.

## Updating

Pull updates in your checkout, rebuild from `daemon/` with
`swiftc -O -o ahakey-daemon daemon.swift`, then restart the installed agent:

```sh
launchctl kickstart -k gui/$(id -u)/com.ahakey.daemon
```

Update the plugin separately in Orca's marketplace or with
`orca plugin update jake-101.ahakey`. Catalog installs update to the catalog's
offered release, which may lag this checkout; folder installs re-copy that folder.
Review and approve any new access when prompted. Rebuild/restart does not publish
or update the marketplace plugin.

## Troubleshooting

Work through the layers in order:

1. **HID:** if keys do not work, check Bluetooth pairing and power. If the device
   name suffix changed, remove the old entry and re-pair. The suffix can change
   after a reset. Keys and custom lights are separate Bluetooth functions.
2. **Daemon:** if `curl http://127.0.0.1:8787/status` fails, check the foreground
   process or `/tmp/ahakey-daemon.log`, the plist's binary path, and Bluetooth
   permission. Ensure no other daemon occupies the port. For a different port,
   use that port in curl and the plugin settings. If the server responds but
   `"connected":false`, check Bluetooth and power-cycle the keyboard to advertise
   again. The direct `/state` test above isolates BLE/lights from Orca.
3. **Device lights:** if connected but the direct test does not light the bar,
   short-press the power button to select work mode 0. Check the daemon log.
4. **Orca:** if the direct test works but agent events do not, check that plugins
   are enabled and AhaKey Bridge is installed, approved and enabled; inspect
   `orca plugin list` and `orca plugin logs jake-101.ahakey`. Ensure the plugin's
   daemon port matches. Only agents supervised by Orca send these events.

Click the AhaKey status bar item or run **AhaKey: refresh agent status** to resend
the tracked aggregate. Orca cannot identify every closed pane: a last-terminal or
nonfocused-pane closure can leave a stale tracked state, and refresh does not
reconstruct all workspaces. Restarting the plugin with
`orca plugin restart jake-101.ahakey` clears its tracked states; subsequent events
repopulate them. The daemon's 75-second watchdog expires unrefreshed *working*
states only; a live plugin can keep reasserting a stale state.

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

| Component | Purpose |
|---|---|
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
