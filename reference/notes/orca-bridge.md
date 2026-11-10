# AhaKey ↔ Orca bridge (built 2026-11-10)

Mirrors agent status from Orca onto the AhaKey X1 light bar, across ALL harnesses
Orca supervises (Claude Code, OMP, OpenCode, Codex, Grok, Pi, ...).

## Architecture

```
Claude Code ─┐
OMP ─────────┤  Orca supervises all of them
OpenCode ────┤
Codex/Grok ──┘
   ▼ agent.status.changed events
orca-ahakey plugin  (Orca trusted-worker, TypeScript)
   │ POST http://127.0.0.1:8787/state {"state":"working|waiting|blocked|done|idle"}
   ▼
ahakey-daemon  (Swift + CoreBluetooth, launchd agent)
   │ 0x90 AI-state frames over BLE (service 0x7340, char 0x7343)
   ▼
AhaKey X1 light bar
```

## Components (this repo)

- `orca-ahakey/` — the Orca plugin (installed as `local.ahakey`)
  - `orca-plugin.json` — trusted-worker, event `agent.status.changed`, capability `agent:read`
  - `main.ts` — aggregates agent states (priority: waiting/blocked > working > done > idle)
- `daemon/daemon.swift` → `daemon/ahakey-daemon` — BLE connection + HTTP server on 127.0.0.1:8787
- `~/Library/LaunchAgents/com.jake.ahakey-daemon.plist` — auto-start (RunAtLoad + KeepAlive)

The bridge serializes state delivery and retries failed HTTP responses; it removes
agents when Orca reports their workspace removed and prunes missing terminals when
the focused-workspace event can be matched to a tracked workspace. Orca's event
does not identify that workspace directly, and agent events may omit terminal IDs:
last-terminal and nonfocused-pane closures cannot always be detected. Existing
agent state across all workspaces also cannot be reconstructed at plugin startup.
The plugin requests workspace-read permission for this reconciliation.

The daemon binds HTTP to IPv4 loopback and waits for the declared HTTP body before
routing. BLE connection attempts use generation guards, a timeout, and a fallback
from the cached identifier to connected-device lookup and name scanning. BLE state,
HTTP routing, polling, and heartbeat coordination run on the main queue. OLED
uploads still lack safe 0x81 timeout recovery; see the protocol deep-dive.

## Verified LED effect table (0x90 state byte → effect, swept on device 2026-11-10)

| Byte | Effect |
|---|---|
| 0 | red flash |
| 1 | slow blue flash → settles static blue middle |
| 2 | blue Knight Rider sweep (fast) |
| 3 | blue Knight Rider sweep |
| 4 | blue Knight Rider sweep |
| 5 | off |
| 6 | static blue middle |
| 7 | cyan siren expanding outward from center |
| 8 | off |

NOTE: the GitHub docs' inferred colors (yellow on permission, green on done) do NOT match
this unit. The device's actual per-state table is configurable via command 0x84.

## Firmware effects vocabulary (from vendor app source, `LightEffectStyle`)

0=off · 1=singleMove (blue Knight Rider flow) · 2=rainbowMove · 3=rainbowWave ·
4=rainbowWaveSlow · 5=breathing · 6=middleLight (static blue middle) · 7=typingRipple ·
8=comet · 9=scanBar · 10=pulseCenter · 11=warningBlink (red flash) · 12=successSweep ·
13=blueThinking · 14=lowBattery · 15=chargingFlow · 16=approvalWait.

## State table rewrite (2026-11-10, via `reference/tools/set-light-mapping.swift`)

`0x84` frame: `AA BB 84 [mode] [eff0..eff8] CC DD` + SAVE_CONFIG. Factory table mapped
state 5 (Stop) → middleLight (6) — that was the unwanted blue-middle *ending* state.
Our table = factory defaults except: state 0 → warningBlink (11, red flash, "needs
attention") and state 5 → off (0). Ending is now fully dark.

## Firmware animation behavior (learned by experiment)

- Effects animate briefly, then **settle into a static rest look**.
- Re-sending the **same state byte is ignored** (no animation restart).
- The **0x91 preview command restarts an effect every time** — used for the heartbeat.
  Frame: `AA BB 91 [effectIndex] CC DD`; daemon endpoint `POST /state {"preview":N}`.
- Continuous "working" animation = daemon heartbeat re-sending `0x91` effect 1 every 8 s.

## Active mapping (in daemon's `ahaState()`)

| Orca state | X1 |
|---|---|
| any agent working | blue Knight Rider, loops (heartbeat via 0x91 preview) |
| any waiting/blocked | 0 — red flash (warningBlink) |
| all done | 7 — cyan siren, then off after 2 s |
| idle / no agents | 5 — off (dark) |

## API

```
curl localhost:8787/status                                # {"state":...,"connected":...}
curl -X POST localhost:8787/state -d '{"state":"working"}' # named states
curl -X POST localhost:8787/state -d '{"raw":7}'           # raw 0x90 byte 0-8 (testing)
```

## Ops

```
launchctl kickstart -k gui/$(id -u)/com.jake.ahakey-daemon   # restart daemon
tail /tmp/ahakey-daemon.log                                  # daemon log
orca plugin logs local.ahakey                                # plugin log
orca plugin list                                             # status
```

Rebuild daemon after editing daemon.swift: `cd daemon && swiftc -O -o ahakey-daemon daemon.swift`
then `launchctl kickstart -k gui/$(id -u)/com.jake.ahakey-daemon`.
