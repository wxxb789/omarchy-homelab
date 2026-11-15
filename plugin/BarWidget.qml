import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Commons as Commons
import qs.Ui

// Bar toggle and control panel for HomeLab mode.
//
// The CLI and the systemd units own the state. The icon reads the mode flag
// for an instant toggle and polls `homelab status --json` while the mode or
// panel is open so the tooltip and panel can show the verified lock, deadline,
// power, and temperature.
BarWidget {
  id: root
  moduleName: "io.github.wxxb789.homelab"

  readonly property string homelabBin: Quickshell.env("HOME") + "/.local/bin/homelab"
  readonly property string stateHome: {
    var xdg = Quickshell.env("XDG_STATE_HOME")
    return xdg && xdg.length > 0 ? xdg : Quickshell.env("HOME") + "/.local/state"
  }
  readonly property string flagPath: stateHome + "/homelab/enabled"
  readonly property color foreground: root.bar ? root.bar.foreground : Commons.Color.foreground
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  property bool modeOn: false
  property bool busy: false
  property bool failed: false
  property bool installed: true
  property bool popupOpen: false
  property var health: null
  property bool healthWarning: false

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  function close() {
    popupOpen = false
  }

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
      if (root.popupOpen) Qt.callLater(root.refreshStatus)
    }
  }

  onPopupOpenChanged: {
    if (root.popupOpen) {
      probe.running = true
      modeFlag.reload()
      Qt.callLater(root.refreshStatus)
    }
  }

  Process {
    id: probe
    command: ["/usr/bin/test", "-x", root.homelabBin]
    onExited: function(exitCode) { root.installed = exitCode === 0 }
  }

  Process {
    id: actionProc
    command: [root.homelabBin, "status"]
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
    interval: 20000
    onTriggered: {
      root.busy = false
      if (actionProc.running) {
        actionProc.running = false
        root.failed = true
      }
    }
  }

  Timer {
    id: healthTimer
    interval: 15000
    repeat: true
    running: (root.modeOn || root.popupOpen) && root.installed
    onTriggered: root.refreshStatus()
  }

  function toggle() {
    runAction(["toggle"])
  }

  function runAction(args) {
    if (actionProc.running || !root.installed) return
    root.busy = true
    root.failed = false
    busyTimeout.restart()
    actionProc.command = [root.homelabBin].concat(args)
    actionProc.running = true
    root.popupOpen = false
  }

  function refresh() {
    modeFlag.reload()
    probe.running = true
    refreshStatus()
  }

  function refreshStatus() {
    if (!root.installed || (!root.modeOn && !root.popupOpen) || statusProc.running) return
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
        const battery = power.batteryPercent === null || power.batteryPercent === undefined
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

  function panelStatusText() {
    if (!root.health) return root.modeOn ? "Fetching status…" : "Choose a timed hold or enable open-ended."
    var parts = []
    parts.push(root.health.inhibitor && root.health.inhibitor.lockHeld ? "lock verified" : "lock not held")
    parts.push(root.health.watcher && root.health.watcher.active ? "watcher active" : "watcher inactive")
    if (root.health.deadline) parts.push("until " + root.health.deadline.iso)
    if (root.health.power) {
      if (root.health.power.ac === false) parts.push("on battery")
      if (root.health.power.temperatureC !== null && root.health.power.temperatureC !== undefined)
        parts.push(root.health.power.temperatureC + "°C")
    }
    if (root.health.consistent === false) parts.push("STATE INCONSISTENT")
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
    function openPanel(): void { root.popupOpen = true }
    function closePanel(): void { root.popupOpen = false }
  }

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: root.modeOn ? "󰒋" : "󰌢"
    active: root.modeOn
    activeColor: root.healthWarning ? Commons.Color.urgent : (root.bar ? root.bar.urgent : Commons.Color.accent)
    dimmed: !root.modeOn || root.busy
    keepSpace: true
    interactive: true
    tooltipText: {
      if (!root.installed) return "HomeLab: CLI not installed — run install.sh"
      if (root.failed) return "HomeLab: action failed — run homelab status"
      if (root.busy) return "HomeLab: switching…"
      if (!root.modeOn) return "HomeLab mode: off — click for controls, right-click to toggle"
      var extra = root.healthText()
      return "HomeLab mode: on — click for controls, right-click to toggle" +
        (extra ? " · " + extra : "")
    }
    onPressed: function(button) {
      if (button === Qt.RightButton) root.toggle()
      else if (button === Qt.LeftButton) root.popupOpen = !root.popupOpen
    }
  }

  PopupCard {
    id: popup
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.popupOpen
    contentWidth: popup.fittedContentWidth(Style.space(360))
    contentHeight: popup.fittedContentHeight(column.implicitHeight)

    Column {
      id: column
      anchors.fill: parent
      spacing: Style.space(10)

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.modeOn ? "HomeLab ON" : "HomeLab OFF"
        color: root.foreground
        font.family: root.fontFamily
        font.pixelSize: Style.font.title
        font.bold: true
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: root.panelStatusText()
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.bodySmall
        wrapMode: Text.WordWrap
      }

      PanelSeparator {
        width: parent.width
        foreground: root.foreground
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Timed hold"
        color: Qt.darker(root.foreground, 1.4)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
        font.letterSpacing: 1.0
      }

      Row {
        id: presets
        width: parent.width
        spacing: Style.space(6)

        readonly property real cellWidth: (width - spacing * 2) / 3

        Button {
          width: presets.cellWidth
          text: "1h"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction(["on", "--for", "1h"])
        }
        Button {
          width: presets.cellWidth
          text: "3h"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction(["on", "--for", "3h"])
        }
        Button {
          width: presets.cellWidth
          text: "8h"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction(["on", "--for", "8h"])
        }
      }

      Row {
        width: parent.width
        spacing: Style.space(6)

        Button {
          width: (parent.width - parent.spacing) / 2
          text: "Open-ended"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction(["on"])
        }
        Button {
          width: (parent.width - parent.spacing) / 2
          text: root.modeOn ? "Turn off" : "Turn on"
          bordered: true
          fontSize: Style.font.bodySmall
          foreground: root.foreground
          fontFamily: root.fontFamily
          onClicked: root.runAction([root.modeOn ? "off" : "on"])
        }
      }

      Text {
        width: parent.width
        textFormat: Text.PlainText
        text: "Right-click the icon to toggle quickly"
        color: Qt.darker(root.foreground, 1.6)
        font.family: root.fontFamily
        font.pixelSize: Style.font.caption
      }
    }
  }
}
