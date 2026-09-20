import QtQuick
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.taisau.location"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false
  readonly property bool popoutSwitchClosing: panelItem
    ? panelItem.popoutSwitchClosing === true
    : false
  readonly property bool fixFresh: {
    var min = (root.settings && root.settings.staleMinutes) ? root.settings.staleMinutes : 10
    return service.best && service.best.fix_time
      ? ((Date.now() / 1000) - service.best.fix_time) < (min * 60)
      : false
  }

  Service {
    id: service
    settings: root.settings
  }

  function open() { if (panelItem) panelItem.open() }
  function close() { if (panelItem) panelItem.close() }
  function toggle() { if (panelItem) panelItem.toggle() }
  function closeForPopoutSwitch() {
    if (panelItem) panelItem.closeForPopoutSwitch()
  }

  function injectPanel() {
    var target = panelItem
    if (!target) return
    if ("bar" in target) target.bar = root.bar
    if ("settings" in target) target.settings = root.settings
    if ("anchorItem" in target) target.anchorItem = button
    if ("hostWidget" in target) target.hostWidget = root
    if ("service" in target) target.service = service
  }

  onBarChanged: injectPanel()
  onSettingsChanged: injectPanel()
  Component.onCompleted: console.warn("[taisau.location] BarWidget instantiated")

  Loader {
    id: panelLoader
    active: true
    source: Qt.resolvedUrl("Panel.qml")
    visible: false
    onLoaded: {
      root.injectPanel()
      Qt.callLater(root.injectPanel)
    }
  }

  // Indicator-style chip: sizes/marks like omarchy.indicators entries
  // (stay-awake / DND / night light) but toggles the location panel on click.
  BarIndicator {
    id: button
    anchors.fill: parent
    bar: root.bar
    settings: root.settings || {}
    indicatorHost: null
    fontFamily: "Material Symbols Rounded"

    readonly property bool healthy: service.running && service.best && root.fixFresh
    readonly property bool broken: !service.running

    active: healthy
    activeText: "\ue1b7"          // Material Symbols: location_searching (crosshair)
    activeTooltipText: healthy ? "Location: " + service.fixText(service.best)
                               : "Location: no fix"
    inactiveText: "\ue1b7"
    inactiveTooltipText: broken ? "Location: daemon stopped"
                                : "Location: stale · " + (service.best ? service.fixText(service.best) : "no fix")

    function toggle() {
      root.toggle()
    }

    onPressed: function(buttonCode) {
      if (buttonCode === Qt.MiddleButton) {
        service.forceRefresh()
      } else if (buttonCode === Qt.RightButton) {
        service.showLogs()
      } else {
        root.toggle()
      }
    }
  }
}
