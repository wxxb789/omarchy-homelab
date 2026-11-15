import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar toggle for HomeLab mode.
//
// The CLI and the systemd units own the actual state; this widget only reads
// the mode flag and calls `homelab toggle`. That keeps the bar honest when the
// mode is changed from a terminal, SSH, or a keybinding.
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
    }
  }

  Timer {
    id: busyTimeout
    interval: 5000
    onTriggered: root.busy = false
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
  }

  Component.onCompleted: probe.running = true

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
    dimmed: !root.modeOn || root.busy
    keepSpace: true
    interactive: true
    tooltipText: {
      if (!root.installed) return "HomeLab: CLI not installed — run install.sh"
      if (root.failed) return "HomeLab: toggle failed — check journalctl --user -u homelab-inhibit"
      if (root.busy) return "HomeLab: switching…"
      return root.modeOn
        ? "HomeLab mode: on — lid close keeps the machine running"
        : "HomeLab mode: off — click to keep running with the lid closed"
    }
    onPressed: function(button) {
      if (button === Qt.LeftButton) root.toggle()
    }
  }
}
