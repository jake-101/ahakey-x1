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
this unit. Per-state colors may be customizable via command 0x84 (experimental) — untried.

## Active mapping (in daemon's `ahaState()`)

| Orca state | X1 |
|---|---|
| any agent working | 3 — blue sweep |
| any waiting/blocked | 0 — red flash |
| all done | 7 — cyan siren, then idle after 5 s |
| idle / no agents | 5 — off |

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
