# AhaKey Bridge

Mirrors the status of agents supervised by Orca to an AhaKey X1 light bar: blue while working, red when attention is needed, and a brief cyan animation when work finishes. The status bar item shows the aggregate state and, when available, the keyboard's battery level.

## Install and setup

1. On macOS, pair the AhaKey X1 in System Settings → Bluetooth. Install Orca
   1.4.248 or newer and Xcode Command Line Tools.
2. Clone this project, build and start `ahakey-daemon` on the same Mac, and
   allow Bluetooth access. The plugin talks to the daemon over localhost; it
   does not connect to the keyboard itself. Follow the complete
   [setup from scratch](https://github.com/jake-101/ahakey-x1#setup-from-scratch),
   including the foreground test and optional LaunchAgent.
3. Search Orca's plugin marketplace for **AhaKey Bridge** (`jake-101.ahakey`)
   and install it if listed. Alternatively, from the project's root directory:

   ```sh
   orca plugin install ./orca-ahakey
   ```

   This trusted worker requires approval for **Full Access**: it runs code on
   your Mac, reads agent and workspace status, and accesses its own settings.
   Review the requested access and source before approving in Orca. For CLI
   installation, Orca prints the exact command with an approval fingerprint to
   rerun. Changes in this checkout do not imply a published marketplace release.

## Configuration

Open **Orca Settings → AhaKey Bridge**:

- **Daemon port**: local daemon TCP port, default `8787`. Match the daemon's
  `AHAKEY_PORT` or port argument if changed.
- **Keyboard screen text**: up to 40 characters. Changing it uploads a new OLED
  image and temporarily shows the upload screen; empty leaves the screen unchanged.

The status bar item displays aggregate state and available battery information.
Click it or run **AhaKey: refresh agent status** to resend the tracked aggregate.

## Updates

Update through Orca's marketplace or run `orca plugin update jake-101.ahakey`.
Catalog installs move to the offered catalog release, which may lag this checkout;
folder installs re-copy the folder. Review and approve new access when prompted.
The daemon is updated separately: pull the checkout, rebuild from `daemon/` with
`swiftc -O -o ahakey-daemon daemon.swift`, and restart the LaunchAgent with
`launchctl kickstart -k gui/$(id -u)/com.ahakey.daemon`.

## Troubleshooting

- **Keyboard:** Check power and Bluetooth pairing if keys do not work; re-pair
  if a reset changed the device name suffix.
- **Daemon:** `curl http://127.0.0.1:8787/status` checks the default port (use
  the configured port if different). If it fails, check the running process,
  LaunchAgent path and `/tmp/ahakey-daemon.log`. If `connected` is false, check
  Bluetooth permission and power-cycle the keyboard. Test the lights independently
  of Orca using the `/state` commands in the
  [project guide](https://github.com/jake-101/ahakey-x1#setup-from-scratch).
  The custom light mapping requires work mode 0.
- **Plugin:** If the direct daemon test works but Orca events do not, check that
  plugins and AhaKey Bridge are enabled and approved, and the configured daemon
  port matches. Use `orca plugin list` and `orca plugin logs jake-101.ahakey`.
  Only agents supervised by Orca produce the events consumed by this bridge.

Orca cannot identify every closed pane. A last-terminal or nonfocused-pane
closure can leave a stale tracked state; refresh resends it rather than
reconstructing all workspaces. `orca plugin restart jake-101.ahakey` clears the
plugin's tracked states; later events repopulate them. The daemon's 75-second
watchdog expires unrefreshed working states only, and the running plugin can
keep reasserting a stale state. See the
[project troubleshooting guide](https://github.com/jake-101/ahakey-x1#troubleshooting)
for more detail.