# ahakey-x1

Use the [AhaKey X1](https://ahakey.com/) ("Vibecoding Keyboard") on macOS **without the
vendor's software** — as a programmable macro keyboard, a voice-input trigger, and a live
status display for AI coding agents.

Everything here was built by pairing the device with the protocol documentation from the
[vendor's open-source repos](https://github.com/orgs/AhakeyAI/repositories) and verifying
against the real hardware.

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

| Path | What |
|---|---|
| `daemon/` | Swift + CoreBluetooth daemon: keeps the BLE connection, HTTP API on `127.0.0.1:8787` (`/state`, `/display`, `/remap`, `/status`), LED state sync + heartbeat, device status polling. Runs under launchd. |
| `orca-ahakey/` | [Orca](https://orca.new) plugin: subscribes to `agent.status.changed`, aggregates across all workspaces, forwards to the daemon. |
| `reference/` | The useful part for other owners: distilled protocol notes, a BLE cheatsheet, a deep-dive into the vendor client's source, one-shot Swift tools (BLE scan/probe/identify, keylogger, key remapper, light-mapping writer), and copies of the vendor's protocol docs. |

## Notes for reusing this

- The X1 is **Bluetooth LE only** — the USB-C cable is charging-only (on firmware 1.0).
- The device **rotates its BLE MAC on every power cycle**; connect by advertised name
  (`AhaKey …`), not by address. Re-pair in System Settings when the suffix changes.
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
