// AhaKey Bridge — mirrors Orca agent status onto the AhaKey X1 light bar.
//
// Subscribes to agent.status.changed across ALL harnesses Orca supervises
// (Claude Code, OMP, OpenCode, Codex, Grok, ...), aggregates them, and POSTs
// the highest-priority state to the local BLE daemon (daemon/daemon.swift).

import type { OrcaWorkerApi } from "orca/worker"

const DAEMON = "http://127.0.0.1:8787/state"

type AgentState = "working" | "blocked" | "waiting" | "done"
type AggregateState = AgentState | "idle"

const PRIORITY: Record<AgentState, number> = { blocked: 3, waiting: 3, working: 2, done: 1 }

export default function activate(orca: OrcaWorkerApi) {
  // paneKey -> "working" | "blocked" | "waiting" | "done"
  const states = new Map<string, AgentState>()
  let lastSent: AggregateState | null = null

  function aggregate(): AggregateState {
    const values = [...states.values()]
    if (values.length === 0) return "idle"
    let best: AgentState = "done"
    for (const s of values) {
      if ((PRIORITY[s] ?? 0) > (PRIORITY[best] ?? 0)) best = s
    }
    return best
  }

  const TONES: Record<AggregateState, "accent" | "danger" | "success" | "neutral"> = {
    working: "accent", waiting: "danger", blocked: "danger", done: "success", idle: "neutral",
  }
  let battery: number | null = null

  function updateStatusBar(state: AggregateState) {
    try {
      const batt = battery != null ? ` · ${battery}%` : ""
      void orca.host.call("statusBar.update", {
        id: "ahakey-status",
        text: state === "idle" ? `AhaKey${batt}` : `AhaKey: ${state}${batt}`,
        tone: TONES[state] ?? "neutral",
      })
    } catch { /* status bar is cosmetic */ }
  }

  async function push() {
    const state = aggregate()
    if (state === lastSent) return
    lastSent = state
    updateStatusBar(state)
    try {
      await fetch(DAEMON, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ state }),
      })
      orca.log(`ahakey: agents -> ${state} (${states.size} tracked)`)
    } catch (err) {
      // Daemon not running — don't spam; retry on next event.
      lastSent = null
      orca.log(`ahakey: daemon unreachable: ${err}`)
    }
  }

  orca.events.on("agent.status.changed", (event) => {
    if (event.state === "waiting" || event.state === "blocked" ||
        event.state === "working" || event.state === "done") {
      states.set(event.paneKey, event.state)
      void push()
    }
  })

  // Register the status bar item's command: pressing it (or running from the
  // palette) forces a state refresh.
  orca.commands.register("ahakey.refresh", () => {
    lastSent = null
    void push()
  })

  // Keep-alive: every 30 s read the daemon's device status (battery changes
  // slowly, so this cadence is plenty) and re-assert the aggregate so the
  // daemon's watchdog (expires "working" after 75 s of silence) doesn't kill
  // the lights during genuinely long-running agent tasks. "Done" is skipped:
  // it's a one-shot (daemon turns the lights off itself) and re-asserting it
  // would replay the siren forever.
  const keepAlive = setInterval(() => {
    fetch("http://127.0.0.1:8787/status")
      .then((r) => r.json())
      .then((s: { device?: { battery?: number } }) => {
        if (typeof s?.device?.battery === "number") battery = s.device.battery
        updateStatusBar(aggregate())
      })
      .catch(() => {})
    const agg = aggregate()
    if (agg === "done") return
    lastSent = null
    void push()
  }, 30_000)

  // Keyboard screen text: only uploads when the user edits the setting in
  // Orca's Settings — never automatically (the upload takes seconds and shows
  // an "Uploading pic" screen on the device, too ugly for every switch).
  let lastOledText: string | undefined
  try {
    orca.settings.onDidChange(async () => {
      const text = String((await orca.settings.get("oledText")) ?? "").trim()
      if (!text || text === lastOledText) return
      lastOledText = text
      fetch("http://127.0.0.1:8787/display", {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ text }),
      }).catch(() => {})
    })
  } catch { /* settings API unavailable — screen stays as-is */ }

  orca.log("ahakey: bridge active")
  return () => clearInterval(keepAlive)
}
