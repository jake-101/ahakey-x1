# Vendored vendor documentation

These files are **exact copies** of documentation from the AhaKey vendor's official
open-source repositories, kept here for offline reference. All of them are published by
the vendor under the **Apache License 2.0**.

| File | Source |
|---|---|
| `protocol-*.md` | [AhakeyAI/protocol](https://github.com/AhakeyAI/protocol) — BLE protocol, developer kit, commands, status sync, compatibility |
| `desktop-*.md` | [AhakeyAI/desktop](https://github.com/AhakeyAI/desktop) — official desktop suite overview, architecture, and the reverse-engineered `ble-protocol.md` (partly in Chinese) |
| `awesome-ahakey-README.md` | [AhakeyAI/awesome-ahakey](https://github.com/AhakeyAI/awesome-ahakey) — community showcase index |

Nothing in this folder is authored by this repository; see the upstream repos for the
license files and the full, current versions of these documents.

Note: some claims in these docs did not match the real hardware we tested —
`reference/research/protocol-deep-dive.md` and `reference/notes/` record the corrections
(verified LED effect table, the brightness byte in the 0x00 status response, the
poll-don't-push firmware behavior, and the connection-poisoning rule).
