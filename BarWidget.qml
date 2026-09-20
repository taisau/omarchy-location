import QtQuick
import QtQuick.Effects
import Quickshell
import qs.Commons
import qs.Ui

BarWidget {
  id: root
  moduleName: "io.github.taisau.location"

  readonly property var panelItem: panelLoader.item
  readonly property bool opened: panelItem ? panelItem.opened === true : false

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
  console.warn("[taisau.location] BarWidget instantiated")
  onSettingsChanged: injectPanel()

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

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: !service.running
      ? "Location: daemon stopped"
      : (!service.best
          ? "Location: no fix yet"
          : (root.fixFresh ? "Location: " + service.fixText(service.best)
                           : "Location: stale · " + service.fixText(service.best)))

    readonly property bool fixHealthy: service.running && service.best && root.fixFresh

    iconComponent: Component {
      Item {
        id: iconWrapper
        anchors.fill: parent

        readonly property color iconColor: testRed !== undefined ? Color.urgent : button.fixHealthy
          ? (root.bar ? root.bar.foreground : Color.foreground)
          : (!service.running
              ? (root.bar ? root.bar.urgent : Color.urgent)
              : (root.bar ? Qt.darker(root.bar.foreground, 1.6) : Qt.darker(Color.foreground, 1.6)))

        Image {
          id: iconImg
          anchors.centerIn: parent
          width: Style.space(11)
          height: Style.space(11)
          source: !service.running
            ? Qt.resolvedUrl("assets/location-disabled.svg")
            : Qt.resolvedUrl("assets/location.svg")
          sourceSize.width: 32
          sourceSize.height: 32
          fillMode: Image.PreserveAspectFit
          smooth: true
          visible: false
          layer.enabled: true
        }

        MultiEffect {
          anchors.fill: iconImg
          source: iconImg
          colorization: 1.0
          colorizationColor: iconWrapper.iconColor
        }
      }
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

  readonly property bool fixFresh: {
    var min = (root.settings && root.settings.staleMinutes) ? root.settings.staleMinutes : 10
    return service.best && service.best.fix_time
      ? ((Date.now() / 1000) - service.best.fix_time) < (min * 60)
      : false
  }
}
