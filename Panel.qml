import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "io.github.taisau.location"
  manageIpc: false

  property var anchorItem: null
  property var hostWidget: null
  property var service: null
  readonly property var barIdentity: hostWidget || root

  property bool editMode: false
  property var editSources: []
  property bool editWifiOn: false
  property int editWifiInterval: 300
  property int editPort: 9438
  property string savedNotice: ""
  property bool noticeVisible: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color accent: Color.accent
  readonly property color dim: Qt.darker(foreground, 1.5)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function open() { root.controller.show() }
  function close() { root.controller.hide() }
  function switchPanel(direction) {
    if (root.bar && typeof root.bar.switchPanelFrom === "function")
      return root.bar.switchPanelFrom(root.hostWidget || root, direction)
    return false
  }

  // Defaults for a fresh config
  function newSource() {
    return { "type": "ha", "name": "", "url": "http://100.75.37.107", "token": "",
             "entity": "device_tracker.pixel_9_pro", "enabled": true,
             "interval": 300, "priority": 50 }
  }

  function composedConfig() {
    var srcs = []
    for (var i = 0; i < root.editSources.length; i++) {
      var s = root.editSources[i]
      if (!s || (String(s.entity || "").trim() === "")) continue   // skip empty rows
      srcs.push({
        "type": "ha",
        "name": String(s.name || "").trim() || ("source-" + (i + 1)),
        "label": String(s.name || "").trim() || ("source-" + (i + 1)),
        "url": String(s.url || "").trim(),
        "token": String(s.token || "").trim(),
        "entity": String(s.entity || "").trim(),
        "enabled": s.enabled !== false,
        "interval": Math.max(10, Math.floor(s.interval || 300)),
        "priority": Math.floor(s.priority || 50)
      })
    }
    if (root.editWifiOn)
      srcs.push({ "type": "wifi", "name": "wifi", "enabled": true,
                  "interval": Math.max(120, Math.floor(root.editWifiInterval || 300)),
                  "priority": 90 })
    var cfg = root.service && root.service.config ? JSON.parse(JSON.stringify(root.service.config)) : {}
    cfg.port = Math.max(1024, Math.floor(root.editPort || 9438))
    cfg.sources = srcs
    return cfg
  }

  function enterEditMode() {
    var cfg = root.service && root.service.config
      ? root.service.config : { "port": 9438, "sources": [] }
    root.editPort = cfg.port || 9438
    root.editSources = []
    root.editWifiOn = false
    root.editWifiInterval = 300
    var list = (cfg.sources || []).slice()
    for (var i = 0; i < list.length; i++) {
      var s = list[i]
      if (s.type === "wifi") {
        root.editWifiOn = s.enabled !== false
        root.editWifiInterval = s.interval || 300
        continue
      }
      root.editSources.push({
        "name": s.label || s.name || s.entity || "",
        "url": s.url || "", "token": s.token || "", "entity": s.entity || "",
        "enabled": s.enabled !== false,
        "interval": s.interval || 300, "priority": s.priority || 50
      })
    }
    root.editMode = true
  }

  function saveEdit() {
    if (!root.service) return
    root.service.saveConfig(root.composedConfig())
    root.editMode = false
    root.savedNotice = "Saved — daemon reloads on next cycle"
    root.noticeVisible = true
    noticeTimer.restart()
  }

  onOpenedChanged: {
    if (opened) {
      root.editMode = false
      root.noticeVisible = false
      if (root.service) root.service.refresh()
    }
  }

  Timer {
    id: noticeTimer
    interval: 2600
    onTriggered: root.noticeVisible = false
  }

  KeyboardPanel {
    id: panel
    anchorItem: root.anchorItem
    owner: root.barIdentity
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(680))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(10)

          // 1. Hero header
          Item {
            width: parent.width
            implicitHeight: hero.implicitHeight

            PanelHero {
              id: hero
              width: parent.width
              title: "Location"
              meta: {
                var s = root.service
                if (!s) return "loading…"
                if (!s.running) return "daemon stopped"
                var fx = s.best
                if (!fx) return "no fix yet"
                var acc = (fx.accuracy !== undefined && fx.accuracy !== null)
                  ? "±" + Math.round(fx.accuracy) + "m" : "accuracy?"
                return s.shortSource(fx.source) + " · " + acc + " · " + s.ageOf(fx.fix_time)
              }
              foreground: root.foreground
              fontFamily: root.fontFamily

              iconComponent: Component {
                Image {
                  width: hero.iconSize
                  height: hero.iconSize
                  source: (root.service && root.service.running)
                    ? Qt.resolvedUrl("assets/location.svg")
                    : Qt.resolvedUrl("assets/location-disabled.svg")
                  sourceSize.width: 48
                  sourceSize.height: 48
                  fillMode: Image.PreserveAspectFit
                  smooth: true
                }
              }

              trailingControl: Component {
                ToggleSwitch {
                  id: powerSwitch
                  checked: root.service ? root.service.running : false
                  foreground: hero.foreground
                  onToggled: if (root.service) root.service.toggleDaemon()

                  PanelToolTip {
                    visible: powerSwitch.containsMouse
                    text: root.service && root.service.running ? "Stop daemon" : "Start daemon"
                    fontFamily: hero.fontFamily
                  }
                }
              }
            }
          }

          // 2. Saved toast
          Text {
            visible: root.noticeVisible
            width: parent.width
            text: "✓  " + root.savedNotice
            textFormat: Text.PlainText
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
            horizontalAlignment: Text.AlignHCenter
          }

          // 3. Edit mode: config form
          ColumnLayout {
            visible: root.editMode
            width: parent.width
            spacing: Style.space(8)

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              PanelSectionHeader {
                text: "SETTINGS"
                foreground: root.foreground
                fontFamily: root.fontFamily
                Layout.fillWidth: true
              }

              PanelActionButton {
                iconText: "󰅖"   // close editor
                foreground: root.foreground
                onClicked: root.editMode = false
              }
            }

            TextField {
              width: parent.width
              text: String(root.editPort)
              onTextChanged: root.editPort = parseInt(text) || 9438
              placeholderText: "mirror port (restart daemon after change)"
              foreground: root.foreground
              accent: root.accent
            }

            Repeater {
              id: srcRepeater
              model: root.editSources

              delegate: Column {
                required property var modelData
                required property int index
                width: parent.width

                BorderSurface {
                  color: Style.selectedFillFor(root.foreground, root.accent)
                  radius: Style.cornerRadius
                  width: parent.width
                  implicitHeight: srcCol.implicitHeight + Style.space(10)

                  ColumnLayout {
                    id: srcCol
                    anchors.left: parent.left
                    anchors.right: parent.right
                    anchors.verticalCenter: parent.verticalCenter
                    anchors.leftMargin: Style.space(10)
                    anchors.rightMargin: Style.space(10)
                    spacing: Style.space(4)

                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)

                      TextField {
                        Layout.fillWidth: true
                        placeholderText: "label (e.g. Phone GPS)"
                        text: modelData.name
                        onTextChanged: {
                          if (index >= 0 && index < root.editSources.length)
                            root.editSources[index].name = text
                        }
                        foreground: root.foreground
                        accent: root.accent
                      }

                      ToggleSwitch {
                        checked: modelData.enabled
                        foreground: root.foreground
                        onToggled: {
                          if (index >= 0 && index < root.editSources.length)
                            root.editSources[index].enabled = !root.editSources[index].enabled
                        }
                        PanelToolTip {
                          visible: parent.containsMouse
                          text: "Enable/disable source"
                          fontFamily: hero.fontFamily
                        }
                      }

                      PanelActionButton {
                        iconText: "󰆴"
                        foreground: root.urgent
                        onClicked: {
                          root.editSources.splice(index, 1)
                          srcRepeater.model = root.editSources.slice()
                        }
                      }
                    }

                    TextField {
                      width: parent.width
                      placeholderText: "Home Assistant URL"
                      text: modelData.url
                      onTextChanged: {
                        if (index >= 0 && index < root.editSources.length)
                          root.editSources[index].url = text
                      }
                      foreground: root.foreground
                      accent: root.accent
                    }

                    TextField {
                      width: parent.width
                      placeholderText: "long-lived access token (stored 0600)"
                      text: modelData.token
                      onTextChanged: {
                        if (index >= 0 && index < root.editSources.length)
                          root.editSources[index].token = text
                      }
                      foreground: root.foreground
                      accent: root.accent
                    }

                    TextField {
                      width: parent.width
                      placeholderText: "entity_id (device_tracker.…)"
                      text: modelData.entity
                      onTextChanged: {
                        if (index >= 0 && index < root.editSources.length)
                          root.editSources[index].entity = text
                      }
                      foreground: root.foreground
                      accent: root.accent
                    }

                    RowLayout {
                      width: parent.width
                      spacing: Style.space(6)

                      Text {
                        text: "every"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      TextField {
                        text: String(modelData.interval)
                        onTextChanged: {
                          if (index >= 0 && index < root.editSources.length)
                            root.editSources[index].interval = parseInt(text) || 300
                        }
                        Layout.preferredWidth: Style.space(70)
                        foreground: root.foreground
                        accent: root.accent
                      }
                      Text {
                        text: "sec · priority"
                        color: root.dim
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                      }
                      TextField {
                        text: String(modelData.priority)
                        onTextChanged: {
                          if (index >= 0 && index < root.editSources.length)
                            root.editSources[index].priority = parseInt(text) || 50
                        }
                        Layout.preferredWidth: Style.space(70)
                        foreground: root.foreground
                        accent: root.accent
                      }
                    }
                  }
                }
              }
            }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              ToggleSwitch {
                checked: root.editWifiOn
                foreground: root.foreground
                onToggled: root.editWifiOn = !root.editWifiOn
              }
              Text {
                text: "WiFi positioning (nmcli scan + beaconDB)"
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                Layout.fillWidth: true
              }
              TextField {
                text: String(root.editWifiInterval || 300)
                onTextChanged: root.editWifiInterval = parseInt(text) || 300
                enabled: root.editWifiOn
                Layout.preferredWidth: Style.space(70)
                foreground: root.foreground
                accent: root.accent
              }
            }

            Button {
              text: "Add source"
              iconText: "󰐕"
              bordered: true
              foreground: root.foreground
              accent: root.accent
              onClicked: {
                root.editSources.push(root.newSource())
                srcRepeater.model = root.editSources.slice()
              }
            }

            Button {
              text: "Save"
              iconText: "󰄬"
              bordered: true
              foreground: root.accent
              accent: root.accent
              onClicked: root.saveEdit()
            }

          // 4. View mode: current fix + per-source table + actions
          ColumnLayout {
            visible: !root.editMode
            width: parent.width
            spacing: Style.space(6)

            Text {
              text: root.service && root.service.best
                ? root.service.fixText(root.service.best)
                : "no fix"
              textFormat: Text.PlainText
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              font.bold: true
            }

            Text {
              text: root.service && root.service.lastUpdated
                ? "last resolver write " + root.service.ageOf(root.service.lastUpdated)
                : ""
              textFormat: Text.PlainText
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            PanelSectionHeader {
              text: "SOURCES"
              foreground: root.foreground
              fontFamily: root.fontFamily
              Layout.fillWidth: true
            }

            Repeater {
              id: viewRepeater
              model: root.service ? root.service.sources : []

              delegate: BorderSurface {
                required property var modelData
                required property int index
                width: parent.width
                color: Style.selectedFillFor(root.foreground, root.accent)
                radius: Style.cornerRadius
                implicitHeight: vRow.implicitHeight + Style.space(8)

                RowLayout {
                  id: vRow
                  anchors.left: parent.left
                  anchors.right: parent.right
                  anchors.verticalCenter: parent.verticalCenter
                  anchors.leftMargin: Style.space(10)
                  anchors.rightMargin: Style.space(10)
                  spacing: Style.space(8)

                  Text {
                    text: String(modelData.label || modelData.key)
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.bodySmall
                    font.bold: true
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                  }

                  ColumnLayout {
                    spacing: 0
                    Text {
                      text: {
                        var fx = (root.service && root.service.sources[index] && root.service.sources[index].fix) ? root.service.sources[index].fix : null
                        if (modelData.enabled === false) return "disabled"
                        return fx ? (root.service.ageOf(root.service.sources[index].fix.fix_time)) : "—"
                      }
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      horizontalAlignment: Text.AlignRight
                    }
                    Text {
                      visible: root.service && root.service.sources[index]
                               && root.service.sources[index].last_error
                      text: root.service && root.service.sources[index]
                        ? String(root.service.sources[index].last_error || "").slice(0, 48)
                        : ""
                      color: root.urgent
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                      horizontalAlignment: Text.AlignRight
                    }
                  }
                }
              }
            }

            PanelSeparator { width: parent.width; foreground: root.foreground }

            RowLayout {
              width: parent.width
              spacing: Style.space(6)

              Button {
                text: "Settings"
                iconText: "󰒓"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: root.enterEditMode()
              }

              Button {
                text: "Refresh"
                iconText: "󰁞"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: if (root.service) { root.service.forceRefresh() }
              }

              Button {
                text: "Map"
                iconText: "󰍳"
                bordered: true
                enabled: root.service && root.service.best !== null
                foreground: root.foreground
                accent: root.accent
                onClicked: if (root.service) root.service.openMap()
              }

              Button {
                text: "Logs"
                iconText: "󰌚"
                bordered: true
                foreground: root.foreground
                accent: root.accent
                onClicked: if (root.service) root.service.showLogs()
              }
            }
          }
        }
      }
    }
  }

}
