import QtQuick
import Quickshell
import Quickshell.Io

QtObject {
  id: root

  property var settings: null
  property bool installed: true
  property bool running: false
  property var sources: []
  property var best: null
  property var config: null
  property string lastUpdated: ""

  readonly property int maxStatusBytes: 1048576
  readonly property int maxConfigBytes: 262144
  readonly property string homeDir: Quickshell.env("HOME") || ""
  readonly property string stateFile: homeDir + "/.local/state/omarchy-location/status.json"
  readonly property string cliPath: homeDir + "/.config/omarchy/plugins/io.github.taisau.location/cmd/omarchy-location"
  readonly property string confFile: homeDir + "/.config/omarchy-location/config.json"

  function ageOf(ts) {
    if (ts === undefined || ts === null) return ""
    var d = (Date.now() / 1000) - ts
    if (d < 60) return Math.floor(d) + "s ago"
    if (d < 3600) return Math.floor(d / 60) + "m ago"
    if (d < 86400) return Math.floor(d / 3600) + "h ago"
    return Math.floor(d / 86400) + "d ago"
  }

  function shortSource(src) {
    return String(src || "?").replace("ha:", "").replace("wifi:", "wifi·")
  }

  function fixText(fx) {
    if (!fx || fx.lat === undefined) return "no fix"
    var acc = (fx.accuracy !== undefined && fx.accuracy !== null) ? " ±" + Math.round(fx.accuracy) + "m" : ""
    return fx.lat.toFixed(5) + ", " + fx.lon.toFixed(5) + acc + " · " + shortSource(fx.source)
  }

  // base64 of a UTF-16-safe ASCII-only (JSON) string; injection-safe shell arg
  function b64(obj) {
    var s = JSON.stringify(obj)
    var b64d = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
    var out = "", i, a, b, c, bits
    for (i = 0; i < s.length; i += 3) {
      a = s.charCodeAt(i)
      b = i + 1 < s.length ? s.charCodeAt(i + 1) : false
      c = i + 2 < s.length ? s.charCodeAt(i + 2) : false
      bits = (a << 16) | ((b || 0) << 8) | (c || 0)
      out += b64d.charAt((bits >> 18) & 63)
      out += b64d.charAt((bits >> 12) & 63)
      out += (b !== false) ? b64d.charAt((bits >> 6) & 63) : "="
      out += (c !== false) ? b64d.charAt(bits & 63) : "="
    }
    return out
  }

  function refresh() {
    statusProc.running = true
    whichProc.running = true
    configProc.running = true
  }

  function restartDaemon() {
    runCmd(["/usr/bin/systemctl", "--user", "restart", "omarchy-location-daemon"])
  }

  function toggleDaemon() {
    runCmd([root.running ? "/usr/bin/systemctl --user stop omarchy-location-daemon"
                         : "/usr/bin/systemctl --user start omarchy-location-daemon"])
  }

  function showLogs() {
    runCmd(["/usr/bin/omarchy-launch-floating-terminal", "journalctl --user -u omarchy-location-daemon -f -n 60"])
  }

  function openMap() {
    var fx = root.best
    if (!fx) return
    runCmd(["/usr/bin/xdg-open",
            "https://www.openstreetmap.org/?mlat=" + fx.lat + "&mlon=" + fx.lon + "&zoom=16"])
  }

  function forceRefresh() {
    runCmd(["/usr/bin/curl", "-fsS", "-X", "POST", "http://127.0.0.1:9438/refresh"])
  }

  function saveConfig(edited) {
    var enc = root.b64(edited)
    if (!enc)
      return
    saveProc.command = ["/cmd/sh", "-c",
      "printf %s '" + enc + "' | base64 -d | " + root.cliPath + " config-write"]
    saveProc.running = true
  }

  // run a one-shot command via a dynamic process so callers don't clobber cmdProc
  property var saveProc: Process {
    id: saveProc
    running: false
    onExited: function() { Qt.callLater(root.refresh) }
  }

  function runCmd(args) {
    if (Array.isArray(args) && args.length === 1) {
      args = ["/cmd/sh", "-c", args[0]]
    }
    var proc = cmdProc
    if (proc.running) {
      var dyn = Qt.createQmlObject('import Quickshell.Io; Process {}', root)
      dyn.command = args
      dyn.running = true
    } else {
      proc.command = args
      proc.running = true
    }
  }

  property var timer: Timer {
    id: pollTimer
    interval: root.settings && root.settings.pollIntervalSec ? root.settings.pollIntervalSec * 1000 : 10000
    running: true
    repeat: true
    onTriggered: root.refresh()
  }

  property var whichProc: Process {
    id: whichProc
    command: ["/cmd/sh", "-c",
      "exec timeout 2 " + (root.homeDir ? "/usr/bin/systemctl --user is-active omarchy-location-daemon 2>/dev/null" : "")]
    stdout: StdioCollector {
      id: runCollector
      onStreamFinished: {
        root.running = (runCollector.text.trim() === "active")
      }
    }
    running: false
  }

  property var statusProc: Process {
    id: statusProc
    command: ["/cmd/sh", "-c",
      "exec timeout 3 /usr/bin/head -c 1048576 " + root.stateFile + " 2>/dev/null"]
    stdout: StdioCollector {
      id: statusCollector
      onStreamFinished: {
        var txt = statusCollector.text.trim()
        if (txt.length === 0) return
        try {
          var st = JSON.parse(txt)
          root.sources = st.sources || []
          root.best = st.best || null
          root.lastUpdated = st.updated || ""
        } catch (e) {
          console.warn("[location-plugin] status parse:", e)
        }
      }
    }
    running: false
  }

  property var configProc: Process {
    id: configProc
    command: ["/cmd/sh", "-c",
      "exec timeout 3 /usr/bin/head -c 262144 " + root.homeDir + "/.config/omarchy-location/config.json 2>/dev/null"]
    stdout: StdioCollector {
      id: confCollector
      onStreamFinished: {
        var txt = confCollector.text.trim()
        if (txt.length === 0) { root.config = null; return }
        try { root.config = JSON.parse(txt) } catch (e) { console.warn("[location-plugin] config parse:", e) }
      }
    }
    running: false
  }

  property var cmdProc: Process { id: cmdProc; running: false }

  Component.onCompleted: refresh()
}
