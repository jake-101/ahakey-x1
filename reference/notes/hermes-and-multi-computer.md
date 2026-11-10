# Hermes Agent + multi-computer use

*2026-11-10*

## What Hermes is

Nous Research's open-source AI agent (MIT). Desktop apps for macOS/Windows/Linux, CLI,
cloud option, reachable via Telegram/Discord/Slack/WhatsApp/Signal/Email. Chat-driven
with persistent memory, subagents, sandboxing.

- Site: https://hermes-agent.nousresearch.com/
- Source: https://github.com/NousResearch/hermes-agent
- Community: r/hermesagent — there's active demand there for hands-free voice workflows.

## Can the X1 work with Hermes on another computer?

**Yes, with one physical constraint:** the X1 is a Bluetooth LE device (~10 m range).
It pairs to and talks to *whatever computer it's physically near*. It cannot follow you
across the house, and it cannot be bridged over the network without extra work (the
AhaKey repo does ship a C# BLE↔TCP bridge for remote clients, and the Nexting stack
routes device traffic via its App/cloud — both are later options).

Per feature, on the second computer:

| Feature | Works? | How |
|---|---|---|
| 4 keys as shortcuts | ✅ trivially | Standard BLE HID — pair, then bind F13–F19 in the OS/Hermes |
| Voice → Hermes | ✅ | Companion client transcribes (Apple Speech on Mac) and types into the focused Hermes input — same as any text field |
| OLED / LED strip | ✅ | Open-source clients exist for macOS (Swift), Windows (Java), Linux (Java) |
| Lever = approval gate | ⚠️ not out of the box | AhaKey's daemon ships hook handlers for Claude/Cursor/Codex/Kimi only. Both codebases are open source — writing a Hermes hook handler is a realistic small project |

## Approach for the lever-gate with Hermes (later project)

Same pattern as the official Claude Code integration:
1. Find Hermes's tool-call/permission hook or event surface (it's MIT, source available).
2. Run AhaKey's `ahakeyconfig-agent` (or a thin custom client) on that machine.
3. On permission events: read lever state over BLE (frame `AA BB 00 CC DD`, byte 9 =
   switch state) → auto-allow if 0, else leave for manual confirm. Fail-safe default: ask.
4. Optionally push task state via `AA BB 90 [state] CC DD` so the LEDs mirror Hermes.

## Voice-key caveat for multi-computer

The X1's voice flow requires its companion app *on the paired machine*. For the second
computer that means building/installing the platform client there too (or just using
whatever dictation that machine has with the X1 keys as hotkey triggers).
