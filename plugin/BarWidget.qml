import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar toggle for HomeLab mode.
//
// The CLI and the systemd units own the actual state; this widget reads the
// mode flag for an instant toggle and polls `homelab status --json` while the
// mode is on so the tooltip can report the verified lock, deadline, power, and
// temperature instead of only the user's intent.
BarWidget {
  id: root
  moduleName: "io.github.wxxb789.homelab"

  readonly property string homelabBin: Quickshell.env("HOME") + "/.local/bin/homelab"
  readonly property string stateHome: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    return xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.local/state"
  }
  readonly property string flagPath: stateHome + "/homelab/enabled"

  property bool modeOn: false
  property bool busy: false
  property bool failed: false
  property bool installed: true
  property var health: null
  property bool healthWarning: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // The flag is the mode's single source of truth. Watching it means a
  // `homelab on/off` from anywhere updates the bar without polling.
  FileView {
    id: modeFlag
    path: root.flagPath
    watchChanges: true
    printErrors: false
    blockLoading: true
    onLoaded: root.modeOn = true
    onLoadFailed: root.modeOn = false
    onFileChanged: reload()
  }

  onModeOnChanged: {
    if (root.modeOn) {
      Qt.callLater(root.refreshStatus)
    } else {
      root.health = null
      root.healthWarning = false
    }
  }

  Process {
    id: probe
    command: ["/usr/bin/test", "-x", root.homelabBin]
    onExited: function(exitCode) { root.installed = exitCode === 0 }
  }

  Process {
    id: toggleProc
    command: [root.homelabBin, "toggle"]
    onExited: function(exitCode) {
      root.busy = false
      root.failed = exitCode !== 0
      busyTimeout.stop()
      modeFlag.reload()
      probe.running = true
      Qt.callLater(root.refreshStatus)
    }
  }

  Process {
    id: statusProc
    command: [root.homelabBin, "status", "--json"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.applyStatus(text)
    }
    onExited: function(exitCode) {
      if (exitCode !== 0) {
        root.health = null
        root.healthWarning = false
      }
    }
  }

  Timer {
    id: busyTimeout
    // A mode change can wait on a 20-second systemd call. Do not declare
    // failure while the CLI is still inside that window.
    interval: 20000
    onTriggered: {
      root.busy = false
      if (toggleProc.running) {
        toggleProc.running = false
        root.failed = true
      }
    }
  }

  Timer {
    id: healthTimer
    interval: 15000
    repeat: true
    running: root.modeOn && root.installed
    onTriggered: root.refreshStatus()
  }

  function toggle() {
    if (toggleProc.running || !root.installed) return
    root.busy = true
    root.failed = false
    busyTimeout.restart()
    toggleProc.running = true
  }

  function refresh() {
    modeFlag.reload()
    probe.running = true
    refreshStatus()
  }

  function refreshStatus() {
    if (!root.installed || !root.modeOn || statusProc.running) return
    statusProc.running = true
  }

  function applyStatus(text) {
    try {
      root.health = JSON.parse(String(text || ""))
      root.healthWarning = root.health && root.health.consistent === false
    } catch (e) {
      root.health = null
      root.healthWarning = false
      console.warn("homelab: could not parse status JSON", e)
    }
  }

  function formatDuration(seconds) {
    var value = Math.max(0, Number(seconds) || 0)
    if (value >= 3600) return Math.floor(value / 3600) + "h " + Math.floor((value % 3600) / 60) + "m"
    if (value >= 60) return Math.floor(value / 60) + "m"
    return Math.floor(value) + "s"
  }

  function healthText() {
    if (!root.health) return ""
    var parts = []
    if (root.health.deadline) {
      parts.push("until " + root.health.deadline.iso + " (" +
        formatDuration(root.health.deadline.remainingSeconds) + " left)")
    }
    var power = root.health.power
    if (power) {
      if (power.ac === false) {
        var battery = power.batteryPercent === null || power.batteryPercent === undefined
          ? "" : " " + power.batteryPercent + "%"
        parts.push("on battery" + battery)
      }
      if (power.temperatureC !== null && power.temperatureC !== undefined)
        parts.push(power.temperatureC + "°C")
    }
    if (root.health.consistent === false) {
      parts.push("STATE INCONSISTENT")
    } else if (root.health.warnings && root.health.warnings.length > 0) {
      parts.push(root.health.warnings[0])
    }
    return parts.join(" · ")
  }

  Component.onCompleted: {
    probe.running = true
    if (root.modeOn) Qt.callLater(root.refreshStatus)
  }

  // Lets a keybinding or script drive the same action:
  //   omarchy-shell io.github.wxxb789.homelab toggle
  ShellIpc {
    target: root.moduleName
    function toggle(): void { root.toggle() }
    function refresh(): void { root.refresh() }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    // A server while HomeLab is on, the laptop it becomes when off.
    text: root.modeOn ? "󰒋" : "󰌢"
    active: root.modeOn
    activeColor: root.healthWarning ? Commons.Color.urgent : (root.bar ? root.bar.urgent : Commons.Color.accent)
    dimmed: !root.modeOn || root.busy
    keepSpace: true
    interactive: true
    tooltipText: {
      if (!root.installed) return "HomeLab: CLI not installed — run install.sh"
      if (root.failed) return "HomeLab: toggle failed — run homelab status"
      if (root.busy) return "HomeLab: switching…"
      if (!root.modeOn) return "HomeLab mode: off — click to keep running with the lid closed"
      var extra = root.healthText()
      return "HomeLab mode: on — lid close keeps the machine running" +
        (extra ? " · " + extra : "")
    }
    onPressed: function(button) {
      if (button === Qt.LeftButton) root.toggle()
    }
  }
}
