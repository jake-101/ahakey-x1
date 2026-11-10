// AhaKey Bridge — mirrors Orca agent status onto the AhaKey X1 light bar.
//
// Subscribes to agent.status.changed across ALL harnesses Orca supervises
// (Claude Code, OMP, OpenCode, Codex, Grok, ...), aggregates them, and POSTs
// the highest-priority state to the local BLE daemon (daemon/daemon.swift).

const DAEMON = "http://127.0.0.1:8787/state"

const PRIORITY = { blocked: 3, waiting: 3, working: 2, done: 1 }

/** @param {import('orca/worker').OrcaWorkerApi} orca */
export default function activate(orca) {
  // paneKey -> "working" | "blocked" | "waiting" | "done"
  const states = new Map()
  let lastSent = null

  function aggregate() {
    const values = [...states.values()]
    if (values.length === 0) return "idle"
    let best = "done"
    for (const s of values) {
      if ((PRIORITY[s] ?? 0) > (PRIORITY[best] ?? 0)) best = s
    }
    return best
  }

  async function push() {
    const state = aggregate()
    if (state === lastSent) return
    lastSent = state
    try {
      await fetch(DAEMON, {
        method: "POST",
        headers: { "content-type": "application/json" },
        body: JSON.stringify({ state }),
      })
      orca.log?.(`ahakey: agents -> ${state} (${states.size} tracked)`)
    } catch (err) {
      // Daemon not running — don't spam; retry on next event.
      lastSent = null
      orca.log?.(`ahakey: daemon unreachable: ${err}`)
    }
  }

  orca.events.on("agent.status.changed", (event) => {
    if (event.state === "waiting" || event.state === "blocked" ||
        event.state === "working" || event.state === "done") {
      states.set(event.paneKey, event.state)
      void push()
    }
  })

  orca.log?.("ahakey: bridge active")
}
