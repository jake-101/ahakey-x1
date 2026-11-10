# BLE protocol cheatsheet (AhaKey X1)

*Condensed from `source-docs/desktop-ble-protocol.md` (reverse-engineered + packet-capture
verified) and `source-docs/protocol-*.md`. See those for full detail.*

## Transport

```
Service 0x7340 (custom)
  0x7341 DATA     — host→device bulk payloads (OLED images), max 4096 B/write
  0x7342 INFO     — unused (returns 200 empty bytes)
  0x7343 COMMAND  — host→device command writes
  0x7344 NOTIFY   — device→host responses/events (subscribe first)
Battery Service 0x180F (0x2A19), Device Info 0x180A (0x2A24 model, 0x2A26 fw rev)
```

## Frame format

```
[0xAA 0xBB] [Cmd:1] [Data:N] [0xCC 0xDD]
```
Min frame 5 bytes. Responses on 0x7344: `AA BB [cmd_echo] [status] [data...] CC DD`,
status 0 = success.

## Commands

| Cmd | Name | Purpose |
|-----|------|---------|
| 0x00 | state query | → battery %, signal, fw ver, work mode, light mode, switch state |
| 0x01 | CHANGE_NAME | rename BLE device (≤21 B UTF-8, ≤15 shown in adverts) + SAVE |
| 0x04 | SAVE_CONFIG | **required after any config write** or it's lost on power-off |
| 0x73 | UPDATE_CUSTOM_KEY | key config container (see below) |
| 0x80 | PREPARE_WRITE | bulk write init (4K-aligned address) for OLED frames |
| 0x82 | UPDATE_PIC | OLED animation params (mode, start idx, frame count, delay ms) |
| 0x83 | READ_PIC_STATE | query OLED animation state |
| 0x84 | AI state light config | mode + per-state light table |
| 0x85 | LED brightness | 1–100 |
| 0x90 | UPDATE_STATE | AI/agent state sync → LED effects |
| 0x91 | direct WS2812 effect | host-side preview / hooks |
| 0x92 | set work mode | host switches device mode 0/1/2 |
| 0x93/0x94 | AI OLED GIF metadata update/query | |
| 0xA0–0xEF | **reserved for user custom commands** | safe for our own clients |
| 0xF0–0xFF | system/debug/factory reserved | don't touch |

## Key config (0x73)

```
AA BB 73 [sub_type] [mode] [key_index] [data:N] CC DD
sub_type: 0x73 = shortcut, 0x74 = macro, 0x75 = description (OLED label, ≤20 ASCII)
mode:     0/1/2 (work mode)
key_index: 0–3 (Key1–Key4)
```
- Shortcut data = HID usage IDs, modifiers first (e.g. Cmd+C = `E3 06`), ≤98 B.
  Example — Key1 = F18: `AA BB 73 73 00 00 6D CC DD`
- Macro data = action pairs: 1=DOWN_KEY(hid), 2=UP_KEY(hid), 3=DELAY(~3ms units),
  4=UP_ALLKEY, 0=NO_OP.
- Always follow with SAVE_CONFIG `AA BB 04 CC DD`.

## HID codes worth remembering

- Modifiers: LCtrl E0, LShift E1, LAlt E2, LCmd E3, RCtrl E4, RShift E5, RAlt E6, RCmd E7
- F13–F19: 68 69 6A 6B 6C 6D 6E
- Letters A–Z: 04–1D; digits 1–9,0: 1E–27; Space 2C; Enter 28; Esc 29; arrows 4F–52

## Agent state sync (0x90) — drives LEDs

| State | Val | LED (inferred) |
|---|---|---|
| Notification | 0 | blink |
| PermissionRequest | 1 | yellow solid |
| PostToolUse | 2 | green flash |
| PreToolUse | 3 | blue breathing |
| SessionStart | 4 | green solid |
| Stop | 5 | off |
| TaskCompleted | 6 | green blink |
| UserPromptSubmit | 7 | white flash |
| SessionEnd | 8 | off |

Official Claude Code hook integration pattern: append a hook script that notifies the
companion daemon (Unix socket), daemon sends `AA BB 90 [state] CC DD`. The lever state is
queried at PermissionRequest time: switch==0 → auto-allow, else → ask.
