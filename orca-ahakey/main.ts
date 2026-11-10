// AhaKey Bridge — aggregate Orca agent status and deliver it to the BLE daemon.
import type { OrcaWorkerApi } from "orca/worker"

type AgentState = "working" | "blocked" | "waiting" | "done"
type AggregateState = AgentState | "idle"
type TrackedAgent = { state: AgentState; workspaceId: string | null; terminalId?: string; receivedAt: number }

const PRIORITY: Record<AgentState, number> = { blocked: 3, waiting: 3, working: 2, done: 1 }
const TONES: Record<AggregateState, "accent" | "danger" | "success" | "neutral"> = {
  working: "accent", waiting: "danger", blocked: "danger", done: "success", idle: "neutral",
}

let stop: (() => void) | undefined

export default function activate(orca: OrcaWorkerApi) {
  const states = new Map<string, TrackedAgent>()
  const abort = new AbortController()
  let stopped = false
  let daemonPort = 8787
  let settingsReady = false
  let settingsLoading = false
  let settingsRevision = 0
  let oledChanged = false
  let oledText: string | null = null
  let oledRevision = 0
  let oledDelivered = 0
  let oledSending = false
  let desired: AggregateState = "idle"
  let revision = 1 // Initial idle must be delivered too.
  let delivered = 0
  let sending = false
  let battery: number | null = null

  const daemon = (port: number, path: string) => `http://127.0.0.1:${port}${path}`

  function updateStatusBar() {
    if (stopped) return
    const batt = battery != null ? ` · ${battery}%` : ""
    void orca.host.call("statusBar.update", {
      id: "ahakey-status",
      text: desired === "idle" ? `AhaKey${batt}` : `AhaKey: ${desired}${batt}`,
      tone: TONES[desired],
      tooltip: `Agent status — click to re-sync (daemon port ${daemonPort})`,
    }).catch(() => {})
  }

  function aggregate(): AggregateState {
    let best: AggregateState = "idle"
    for (const { state } of states.values()) {
      if (best === "idle" || PRIORITY[state] > PRIORITY[best]) best = state
    }
    return best
  }

  // Only one POST may be in flight: older responses cannot overwrite newer state.
  // A failed revision stays pending until another event, refresh, or keep-alive.
  async function deliver() {
    if (stopped || !settingsReady || sending || delivered === revision) return
    sending = true
    while (!stopped && settingsReady && delivered !== revision) {
      const sendingRevision = revision
      const state = desired
      const port = daemonPort
      try {
        const response = await fetch(daemon(port, "/state"), {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ state }),
          signal: abort.signal,
        })
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        if (stopped) break
        delivered = sendingRevision
        orca.log(`ahakey: agents -> ${state} (${states.size} tracked)`)
      } catch (err) {
        if (!stopped) orca.log(`ahakey: state delivery failed: ${err}`)
        if (sendingRevision === revision || stopped) break
      }
    }
    sending = false
  }

  function updateAggregate(force = false) {
    const next = aggregate()
    if (next !== desired || force) {
      desired = next
      revision++
    }
    updateStatusBar()
    void deliver()
  }

  // OLED uploads are also serialized; only edits request an upload, never startup.
  async function deliverOled() {
    if (stopped || !settingsReady || oledSending || oledDelivered === oledRevision || !oledText) return
    oledSending = true
    while (!stopped && settingsReady && oledDelivered !== oledRevision && oledText) {
      const sendingRevision = oledRevision
      const text = oledText
      try {
        const response = await fetch(daemon(daemonPort, "/display"), {
          method: "POST",
          headers: { "content-type": "application/json" },
          body: JSON.stringify({ text }),
          signal: abort.signal,
        })
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        if (stopped) break
        oledDelivered = sendingRevision
      } catch (err) {
        if (!stopped) orca.log(`ahakey: display delivery failed: ${err}`)
        if (sendingRevision === oledRevision || stopped) break
      }
    }
    oledSending = false
  }

  // Serialize settings reads, including changes that arrive during an earlier read.
  async function loadSettings() {
    if (stopped || settingsLoading) return
    settingsLoading = true
    while (!stopped) {
      const loadingRevision = settingsRevision
      try {
        const settings = await orca.settings.get()
        if (stopped) break
        if (loadingRevision !== settingsRevision) continue
        const port = Number(settings.daemonPort)
        const nextPort = Number.isInteger(port) && port >= 1 && port <= 65535 ? port : 8787
        const portChanged = daemonPort !== nextPort
        daemonPort = nextPort
        settingsReady = true
        if (portChanged) {
          revision++
          if (oledDelivered !== oledRevision) oledRevision++
        }
        if (oledChanged) {
          oledChanged = false
          const text = String(settings.oledText ?? "").trim()
          if (text !== oledText) {
            oledText = text
            oledRevision++
            // Empty text means leave the screen alone and cancels pending uploads.
            if (!text) oledDelivered = oledRevision
          }
        }
        updateStatusBar()
        void deliver()
        void deliverOled()
        break
      } catch (err) {
        if (!stopped) orca.log(`ahakey: settings read failed: ${err}`)
        if (loadingRevision === settingsRevision || stopped) break
      }
    }
    settingsLoading = false
  }

  const subscriptions = [
    orca.events.on("agent.status.changed", (event) => {
      const key = JSON.stringify([event.workspaceId, event.paneKey])
      const previous = states.get(key)
      if (previous && event.receivedAt < previous.receivedAt) return
      states.set(key, {
        state: event.state,
        workspaceId: event.workspaceId,
        terminalId: event.terminalId ?? previous?.terminalId,
        receivedAt: event.receivedAt,
      })
      updateAggregate()
    }),
    orca.events.on("workspace.removed", (event) => {
      for (const [key, agent] of states) {
        if (agent.workspaceId === event.workspaceId) states.delete(key)
      }
      updateAggregate()
    }),
    orca.events.on("workspace.changed", ({ context }) => {
      if (!context) return
      const terminals = new Set(context.terminals.map((terminal) => terminal.id))
      // The event has no workspace ID. An agent whose terminal appears in this
      // context identifies its workspace; never prune a different workspace.
      const presentWorkspaces = new Set<string>()
      for (const agent of states.values()) {
        if (agent.workspaceId && agent.terminalId && terminals.has(agent.terminalId)) {
          presentWorkspaces.add(agent.workspaceId)
        }
      }
      if (presentWorkspaces.size !== 1) return
      const workspaceId = presentWorkspaces.values().next().value
      let changed = false
      for (const [key, agent] of states) {
        if (agent.workspaceId === workspaceId && agent.terminalId && !terminals.has(agent.terminalId)) {
          states.delete(key)
          changed = true
        }
      }
      if (changed) updateAggregate()
    }),
    orca.commands.register("ahakey.refresh", () => {
      if (!settingsReady) void loadSettings()
      updateAggregate(true)
      void deliverOled()
    }),
    orca.settings.onDidChange(({ key }) => {
      if (key !== "daemonPort" && key !== "oledText") return
      settingsRevision++
      // Pause new sends until this change has been read. Invalidate any
      // in-flight OLED upload before it can acknowledge the old port.
      settingsReady = false
      if (key === "daemonPort" && oledDelivered !== oledRevision) oledRevision++
      if (key === "oledText") oledChanged = true
      void loadSettings()
    }),
  ]

  const keepAlive = setInterval(() => {
    if (!settingsReady) {
      void loadSettings()
      return
    }
    const port = daemonPort
    void fetch(daemon(port, "/status"), { signal: abort.signal })
      .then((response) => {
        if (!response.ok) throw new Error(`HTTP ${response.status}`)
        return response.json() as Promise<{ device?: { battery?: number } }>
      })
      .then((status) => {
        if (stopped || !settingsReady || port !== daemonPort) return
        battery = typeof status.device?.battery === "number" ? status.device.battery : null
        updateStatusBar()
      })
      .catch(() => {})
    // A successfully delivered done is one-shot, but a failed one is retried.
    if (desired !== "done") updateAggregate(true)
    else void deliver()
    void deliverOled()
  }, 30_000)

  void loadSettings()
  orca.log("ahakey: bridge active")
  stop = () => {
    stopped = true
    clearInterval(keepAlive)
    abort.abort()
    for (const subscription of subscriptions) subscription.dispose()
  }
}

export function deactivate() {
  stop?.()
  stop = undefined
}
