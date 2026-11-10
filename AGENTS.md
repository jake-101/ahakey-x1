# AGENTS.md

## What this project is

Software for the **AhaKey X1** ("Vibecoding Keyboard") — a Bluetooth LE macro keyboard with
an LED light bar, a 160×80 OLED, a lever, and a mic — used on macOS **without the vendor's
Chinese factory app**. Two things live here:

1. **`daemon/`** — `ahakey-daemon`, a Swift + CoreBluetooth background daemon. It keeps a BLE
   connection to the X1 and exposes a local HTTP API on `127.0.0.1:8787`. It is the only
   writer of LED/OLED state frames.
2. **`orca-ahakey/`** — an Orca plugin (`local.ahakey`, trusted-worker). It listens to
   `agent.status.changed` for **every harness Orca supervises** (Claude Code, OMP,
   OpenCode, Codex, Grok, …), aggregates agent states, and POSTs them to the daemon.

3. **`reference/`** — research archive: the vendor's protocol docs (`source-docs/`),
   distilled notes (`notes/`), and standalone Swift tools (`tools/`).

## Layout

```
daemon/daemon.swift        daemon source (single file)
daemon/ahakey-daemon       compiled binary (launchd runs this)
orca-ahakey/main.ts        plugin worker: aggregate agent states → daemon
orca-ahakey/orca-plugin.json
reference/README.md        index of all research
reference/notes/           device summary, BLE cheatsheet, Orca bridge, plans, session log
reference/tools/           ble-scan / ble-probe / ble-identify / keylogger / remap-key
reference/source-docs/     vendor docs (exact copies; ble-protocol.md is partly Chinese)
```

## The device

- BLE only; USB-C is charging-only. Advertises as "AhaKey AF1E", address `D0:F8:AF:1E:7E:C3`.
- Keys (left→right): mic, checkmark, X, back arrow. Plain BLE HID — work on any computer.
  Current bindings: mic=**F13**, checkmark=Return, X=Delete, back=Down.
- The mic is not a macOS audio device; the mic key is just an HID key (F13 → Raycast
  dictation, input = Studio Display Microphone).
- Custom service `0x7340`: write commands to char `0x7343`, responses on `0x7344` notify.
  Frame: `AA BB [cmd] [data] CC DD`. Save config with cmd 0x04 or writes are lost on
  power-off. User commands must stay in `0xA0–0xEF`.

## LED state table (verified by sweep, 2026-11-10)

`0x90` state byte: `0` red flash · `1` slow blue flash · `2/3/4` blue Knight Rider sweep ·
`5` off · `6` static blue middle · `7` cyan center-out siren · `8` off.

Bridge mapping: working→3, waiting/blocked→0, done→7 (auto-idle 5 s later), idle→5.

## Common commands

```sh
# daemon
cd daemon && swiftc -O -o ahakey-daemon daemon.swift        # rebuild
launchctl kickstart -k gui/$(id -u)/com.jake.ahakey-daemon  # restart
curl localhost:8787/status                                  # health
curl -X POST localhost:8787/state -d '{"state":"working"}'  # test
tail /tmp/ahakey-daemon.log                                 # logs

# plugin
orca plugin logs local.ahakey                               # plugin logs
orca plugin dev emit . agent.status.changed \
  --data '{"workspaceId":null,"paneKey":"t","state":"working","receivedAt":1}'  # test event

# keys
cd reference/tools && swift remap-key.swift <0-3> <HID hex>  # remap a key over BLE
swift keylogger.swift 30                                     # watch keycodes
```

## Conventions / gotchas

- Don't talk BLE from more than one place: the daemon owns the connection; plugins/scripts
  go through HTTP.
- HID byte for F-keys: F13=0x68 F14=0x69 F15=0x6A F16=0x6B F17=0x6C F18=0x6D F19=0x6E.
- `orca-plugin.json`: `capabilities` are objects (`{"kind":"agent:read"}`), `main` has no
  `./` prefix; validate with `orca plugin validate .`.
- The keylogger and any CGEventTap work only after Accessibility is granted to the host
  terminal app.
- Never flash vendor HEX files here; this project is app-side only.
