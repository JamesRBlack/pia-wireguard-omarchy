import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Fuzzy.js" as Fuzzy

// PIA VPN in the bar. Display and switch only: every action runs pia-toggle,
// which starts or stops pia-vpn.service and the killswitch together, so the
// widget can never bring up a stale key or leave the killswitch out of step.
// Status comes from `pia-toggle --status` (the same JSON a bar module reads).
Panel {
  id: root
  moduleName: "pia.vpn"
  ipcTarget: "pia.vpn"
  manageIpc: false

  readonly property string toggleCmd: "/usr/local/bin/pia-toggle"

  // "on" | "blocked" | "off" | "" (not read yet)
  property string vpnState: ""
  property string vpnText: ""
  property var detailLines: []
  property string lastError: ""
  // [{id, name, country}] from `pia-toggle --regions`, and the configured
  // region id.
  property var regions: []
  property string currentRegion: ""
  // Search: regions prepared once for Fuzzy.filter, the query, the matches
  // shown, and the keyboard-highlighted row among them.
  property var entries: []
  property string query: ""
  property var filtered: []
  property int pick: 0

  readonly property bool busy: toggleProcess.running
  readonly property int refreshIntervalSec: {
    var v = root.settings ? root.settings.refreshIntervalSec : undefined
    var n = parseInt(String(v === undefined || v === null ? 5 : v), 10)
    if (!isFinite(n)) n = 5
    return Math.max(2, Math.min(300, n))
  }

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  // Server rows read a step larger than the panel's small body text.
  readonly property int serverFontSize: Math.round(Style.font.bodySmall * 1.12)
  // Red while traffic is blocked (connecting, or the tunnel dropped), full
  // brightness while connected, dimmed while off.
  readonly property color barIconColor: vpnState === "blocked" || lastError !== ""
    ? urgent
    : (vpnState === "on" ? barForeground : Qt.darker(barForeground, 1.55))

  function refresh() {
    if (!statusProcess.running) statusProcess.running = true
  }

  // No argument flips it; "on"/"off" are explicit.
  function runToggle(mode) {
    if (busy) return false
    // --quiet: the icon is the feedback; a toast would cover it. Failures
    // still notify.
    toggleProcess.command = mode ? [toggleCmd, mode, "--quiet"] : [toggleCmd, "--quiet"]
    toggleProcess.running = true
    return true
  }

  function applyStatus(text) {
    try {
      var s = JSON.parse(String(text).trim())
      vpnState = s["class"] || ""
      vpnText = s.text || ""
      detailLines = String(s.tooltip || "").split("\n")
      currentRegion = s.region || ""
      lastError = ""
    } catch (e) {
      lastError = "Could not read pia-toggle --status"
    }
  }

  // Saves the region (root, via pia-region@<id>) and reconnects, or connects
  // if the VPN was off. The killswitch stays up across the switch.
  function runRegion(id) {
    if (busy || id === currentRegion && vpnState === "on") return false
    toggleProcess.command = [toggleCmd, "region", id, "--quiet"]
    toggleProcess.running = true
    currentRegion = id
    return true
  }

  function loadRegions() {
    if (!regionsProcess.running) regionsProcess.running = true
  }

  function applyRegions(text) {
    var out = []
    var lines = String(text).split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      if (f.length >= 2 && f[0] !== "") out.push({ id: f[0], name: f[1], country: f[2] || "" })
    }
    if (out.length === 0) return
    regions = out
    entries = Fuzzy.prepare(out)
    updateFilter()
  }

  function updateFilter() {
    filtered = Fuzzy.filter(entries, query)
    // Typing highlights the best match; with no query, the current server.
    pick = query.trim() === "" ? Math.max(0, currentIndex()) : 0
    Qt.callLater(function() {
      if (serverList && filtered.length > 0)
        serverList.positionViewAtIndex(pick, query.trim() === "" ? ListView.Center : ListView.Beginning)
    })
  }

  function movePick(step) {
    if (filtered.length === 0) return
    pick = Math.max(0, Math.min(filtered.length - 1, pick + step))
    serverList.positionViewAtIndex(pick, ListView.Contain)
  }

  function currentIndex() {
    for (var i = 0; i < filtered.length; i++) if (filtered[i].id === currentRegion) return i
    return -1
  }

  // With a flag showing, the name drops its two-letter prefix ("UK London"
  // -> "London"); search still matches the full name.
  function shortName(r) {
    return flag(r.country) !== "" ? String(r.name).replace(/^[A-Z]{2} (?=\S)/, "") : r.name
  }

  // "GB" -> the GB flag emoji: two regional-indicator symbols. Drawn by the
  // colour-emoji font (noto-fonts-emoji); without one it shows the letters.
  function flag(cc) {
    cc = String(cc || "").toUpperCase()
    if (!/^[A-Z]{2}$/.test(cc)) return ""
    return String.fromCodePoint(0x1F1E6 + cc.charCodeAt(0) - 65, 0x1F1E6 + cc.charCodeAt(1) - 65)
  }

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: {
    if (opened) {
      refresh()
      query = ""
      searchInput.text = ""
      loadRegions()
      Qt.callLater(function() { searchInput.forceActiveFocus() })
    }
  }

  Process {
    id: statusProcess
    running: false
    command: [root.toggleCmd, "--status"]
    stdout: StdioCollector {
      id: statusStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      // A failed poll must not read as "off": keep the last state, say why.
      if (exitCode === 0) root.applyStatus(statusStdout.text)
      else root.lastError = "pia-toggle --status failed (is it installed in /usr/local/bin?)"
    }
  }

  Process {
    id: regionsProcess
    running: false
    command: [root.toggleCmd, "--regions"]
    stdout: StdioCollector {
      id: regionsStdout
      waitForEnd: true
    }
    onExited: function(exitCode) {
      if (exitCode === 0) root.applyRegions(regionsStdout.text)
    }
  }

  // No stdout collector on purpose: pia-toggle leaves a background job
  // waiting for the connection, and collecting its output would hold this
  // process open until that job ends.
  Process {
    id: toggleProcess
    running: false
    onExited: function(exitCode) {
      if (exitCode !== 0) root.lastError = "pia-toggle failed (exit " + exitCode + ")"
      root.refresh()
      fastPoll.restart()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Connecting takes a few seconds; poll quickly for a while after a toggle
  // so the icon turns from red to connected without waiting a full interval.
  Timer {
    id: fastPoll
    interval: 1000
    repeat: true
    property int ticks: 0
    onRunningChanged: if (running) ticks = 0
    onTriggered: {
      root.refresh()
      if (++ticks >= 20 || root.vpnState === "on" || root.vpnState === "off") stop()
    }
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): string { return root.runToggle("") ? "ok" : "error: busy" }
    function on(): string { return root.runToggle("on") ? "ok" : "error: busy" }
    function off(): string { return root.runToggle("off") ? "ok" : "error: busy" }
    function status(): string { return root.vpnText }
    function region(id: string): string { return root.runRegion(id) ? "ok" : "error: busy or already connected there" }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰖂"
    foreground: root.barIconColor
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.runToggle("")
      else if (buttonCode === Qt.MiddleButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    // Typing goes straight into the server search.
    focusTarget: searchInput
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(560))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Column {
        id: column
        width: parent.width
        spacing: Style.space(12)

        // Inside PanelHero's components `root` is the hero, not this Panel
        // (Omawire works around the same thing), so they read the panel's
        // state through this item instead.
        Item {
          id: header
          width: parent.width
          implicitHeight: hero.implicitHeight
          readonly property string vpnState: root.vpnState
          readonly property bool busy: root.busy
          readonly property color iconColor: root.vpnState === "blocked" ? root.urgent : root.foreground
          readonly property string fontFamily: root.fontFamily
          function flip() { root.runToggle(root.vpnState === "off" ? "on" : "off") }

          PanelHero {
            id: hero
            width: parent.width
            title: "PIA VPN"
            meta: root.vpnState === "on" ? (root.detailLines[0] || "Connected").replace(/^PIA /, "")
              : (root.vpnState === "blocked" ? "Connecting: traffic blocked" : "Off")
            foreground: root.foreground
            fontFamily: root.fontFamily
            iconOpacity: root.vpnState === "on" ? 1.0 : 0.5
            iconComponent: Component {
              Text {
                text: "󰖂"
                color: header.iconColor
                font.family: header.fontFamily
                font.pixelSize: Style.font.display
              }
            }
            trailingControl: Component {
              ToggleSwitch {
                id: powerSwitch
                // On while the killswitch is: "blocked" still means the VPN is
                // wanted, and switching it off is how to get normal internet.
                checked: header.vpnState === "on" || header.vpnState === "blocked"
                busy: header.busy
                foreground: hero.foreground
                onToggled: header.flip()

                PanelToolTip {
                  visible: powerSwitch.containsMouse
                  text: header.vpnState === "off" ? "Connect with a fresh key" : "Turn off VPN and killswitch"
                  fontFamily: header.fontFamily
                }
              }
            }
          }
        }

        Text {
          visible: root.lastError !== ""
          width: parent.width
          text: root.lastError
          color: root.urgent
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        // Server, endpoint and since-when, from the status tooltip.
        Repeater {
          model: root.vpnState === "on" ? root.detailLines.slice(1) : []
          Text {
            required property string modelData
            width: column.width
            text: modelData
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            elide: Text.ElideRight
          }
        }

        Text {
          visible: root.vpnState === "blocked"
          width: parent.width
          text: "Nothing leaves this machine until the tunnel is up. The watchdog keeps retrying; switch off for normal internet."
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          wrapMode: Text.WordWrap
        }

        Text {
          width: parent.width
          text: root.regions.length === 0 ? "SERVERS (loading…)"
            : (root.query.trim() === "" ? "SERVERS" : "SERVERS · " + root.filtered.length + " of " + root.regions.length)
          color: root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          topPadding: Style.space(4)
        }

        // Fuzzy search: "lon", "uk lon" and "uklon" all find UK London.
        // Up/Down move, Enter connects, Esc clears and then closes.
        Rectangle {
          width: parent.width
          height: Style.space(32)
          radius: Style.space(4)
          color: "transparent"
          border.width: 1
          border.color: searchInput.activeFocus ? root.foreground : root.dim

          TextInput {
            id: searchInput
            anchors.fill: parent
            anchors.leftMargin: Style.space(10)
            anchors.rightMargin: Style.space(10)
            verticalAlignment: TextInput.AlignVCenter
            color: root.foreground
            selectionColor: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            clip: true
            onTextChanged: {
              root.query = text
              root.updateFilter()
            }
            Keys.onPressed: function(event) {
              if (event.key === Qt.Key_Down) { root.movePick(1); event.accepted = true }
              else if (event.key === Qt.Key_Up) { root.movePick(-1); event.accepted = true }
              else if (event.key === Qt.Key_PageDown) { root.movePick(8); event.accepted = true }
              else if (event.key === Qt.Key_PageUp) { root.movePick(-8); event.accepted = true }
              else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                if (root.filtered.length > 0) root.runRegion(root.filtered[root.pick].id)
                event.accepted = true
              } else if (event.key === Qt.Key_Escape) {
                if (text !== "") text = ""
                else root.close()
                event.accepted = true
              }
            }

            Text {
              anchors.fill: parent
              verticalAlignment: Text.AlignVCenter
              visible: searchInput.text === ""
              text: "Search servers…"
              color: root.dim
              font: searchInput.font
            }
          }
        }

        // Click (or Enter on the highlighted row) to switch to a server, or to
        // connect to it when off. The current one is in full white, the rest
        // dimmed. The flag has a fixed-width column, so every name starts at
        // the same x whatever the font, with or without a flag.
        ListView {
          id: serverList
          width: parent.width
          height: Style.space(260)
          clip: true
          boundsBehavior: Flickable.StopAtBounds
          model: root.filtered
          ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

          delegate: Rectangle {
            id: row
            required property var modelData
            required property int index
            readonly property bool current: modelData.id === root.currentRegion
            readonly property bool picked: index === root.pick && root.query.trim() !== ""
            width: serverList.width
            height: Style.space(30)
            radius: Style.space(4)
            color: rowMouse.containsMouse || picked
              ? Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.08) : "transparent"

            Row {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.leftMargin: Style.space(8)
              anchors.right: parent.right
              anchors.rightMargin: Style.space(8)
              spacing: Style.space(6)

              Text {
                width: Style.space(24)
                horizontalAlignment: Text.AlignHCenter
                text: root.flag(row.modelData.country)
                font.pixelSize: root.serverFontSize
              }

              Text {
                width: parent.width - Style.space(24) - parent.spacing
                text: root.shortName(row.modelData)
                color: row.current ? "white" : root.dim
                font.pixelSize: root.serverFontSize
                // Bold only widens the name to the right; it still starts
                // at the same x as every other row.
                font.bold: row.current
                font.family: root.fontFamily
                elide: Text.ElideRight
              }
            }

            MouseArea {
              id: rowMouse
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              enabled: !root.busy
              onEntered: root.pick = row.index
              onClicked: root.runRegion(row.modelData.id)
            }
          }

          Text {
            anchors.centerIn: parent
            visible: root.regions.length > 0 && root.filtered.length === 0
            text: "No server matches “" + root.query.trim() + "”"
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }
      }
    }
  }
}
