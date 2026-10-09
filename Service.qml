import QtQuick
import Quickshell.Io
import "Model.js" as Model

// Samples CPU, memory, and GPU telemetry straight out of /proc and /sys.
//
// Discovery runs `hw-probe` once to find out which sysfs files this machine
// exposes. Steady-state bar sampling is blocking reads of virtual files
// measured in microseconds — no fork on a timer, which is why a two-second
// interval is affordable inside the shell process instead of forking a script
// the way a Waybar module would. Two documented exceptions fork helpers:
// `nvidia-smi` on the sample interval (NVIDIA cards expose no sysfs telemetry)
// and `proc_top.py` up to every 3 s, only while the system panel is open.
//
// One instance exists per monitor, since the bar mounts a widget per screen.
// The reads are cheap enough that this is not worth coordinating.
Item {
  id: root

  property var settings: ({})

  // Set false on a screen this widget is not drawn on: the timers stop and the
  // probe never runs, so a hidden instance costs nothing.
  property bool active: true

  // Resolved from this file's own location rather than spelled out, so a fork
  // that renames the plugin id does not silently lose the helper.
  readonly property string pluginDir: {
    var dir = String(Qt.resolvedUrl("."))
    if (dir.indexOf("file://") === 0) dir = dir.substring(7)
    return dir.replace(/\/$/, "")
  }
  readonly property string probePath: pluginDir + "/hw-probe"

  readonly property int intervalSec: intSetting("refreshIntervalSec", 2, 1, 60)

  // ------------------------------------------------------------- discovery

  property var probe: Model.parseProbe("")
  readonly property var cpuInfo: probe.cpu
  readonly property var gpuInfo: Model.pickGpu(probe.gpus, setting("gpu", "auto"))
  readonly property bool hasGpu: gpuInfo !== null
  readonly property bool gpuIsNvidia: hasGpu && String(gpuInfo.kind) === "nvidia"

  // -------------------------------------------------------------- readings
  //
  // -1 means "this machine does not report it" or "not sampled yet". Every
  // formatter in Model.js renders that as a dash, so a missing sensor degrades
  // to a gap in the readout instead of a zero that looks like real data.

  property real cpuPercent: -1
  property real cpuTempC: -1
  property real cpuMhz: -1
  property var load: null

  property var memory: null
  readonly property real memPercent: memory ? memory.percent : -1

  property real gpuPercent: -1
  property real gpuTempC: -1
  property real gpuWatts: -1
  property real gpuRpm: -1
  property real gpuMhz: -1
  property real gpuVramUsedBytes: -1
  property real gpuVramTotalBytes: -1
  readonly property real gpuVramPercent: gpuVramTotalBytes > 0
    ? Model.clamp(100 * gpuVramUsedBytes / gpuVramTotalBytes, 0, 100) : -1

  // Top processi per RAM: campionati solo a pannello aperto, mai in background.
  // Lo stato vive qui (persiste con la shell); il worker è per-tick e non
  // sopravvive tra i poll. Guardia singola: procTopProcess.running.
  property var topProcs: []
  property bool procPanelOpen: false
  property string procTopTime: ""
  property bool procTopFailed: false
  property string procGroupedBy: "none"
  readonly property int topProcCount: intSetting("topProcCount", 6, 3, 12)
  readonly property string topProcSort: {
    var want = String(setting("topProcSort", "ram")).trim().toLowerCase()
    return want === "cpu" ? "cpu" : "ram"
  }
  readonly property bool topProcGroup: {
    var value = setting("topProcGroup", true)
    if (typeof value === "boolean") return value
    return String(value).trim().toLowerCase() !== "false"
  }
  readonly property string procTopPath: pluginDir + "/proc_top.py"
  property double _lastProcTopTry: 0
  property double _lastProcTopOk: 0

  // Cumulative jiffies from the previous tick. CPU usage is the ratio between
  // two samples, so there is nothing to show until the second one lands.
  property var _prevJiffies: null

  function setting(name, fallback) {
    var value = settings ? settings[name] : undefined
    return value === undefined || value === null ? fallback : value
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // hwmon reports temperatures in millidegrees, but a handful of drivers
  // report whole degrees. Anything under 200 is already in degrees.
  function readTemp(view) {
    var raw = Model.toNumber(view.text(), -1)
    if (!isFinite(raw) || raw <= 0) return -1
    return raw > 200 ? raw / 1000 : raw
  }

  function readNumber(view, divisor) {
    var raw = Model.toNumber(view.text(), -1)
    if (!isFinite(raw) || raw < 0) return -1
    return divisor ? raw / divisor : raw
  }

  function refreshProbe() {
    probeProcess.command = [probePath]
    probeProcess.running = true
  }

  function sample() {
    statFile.reload()
    var jiffies = Model.parseCpuJiffies(statFile.text())
    if (jiffies) {
      var usage = Model.cpuUsage(_prevJiffies, jiffies)
      if (usage >= 0) cpuPercent = usage
      _prevJiffies = jiffies
    }

    memFile.reload()
    var parsed = Model.parseMemory(memFile.text())
    if (parsed) memory = parsed

    cpuinfoFile.reload()
    var mhz = Model.averageMhz(cpuinfoFile.text())
    cpuMhz = mhz > 0 ? mhz : -1

    loadFile.reload()
    load = Model.parseLoadAverage(loadFile.text())

    if (cpuTempFile.path !== "") {
      cpuTempFile.reload()
      cpuTempC = readTemp(cpuTempFile)
    }

    if (gpuIsNvidia) {
      sampleNvidia()
      return
    }

    if (gpuBusyFile.path !== "") {
      gpuBusyFile.reload()
      gpuPercent = readNumber(gpuBusyFile, 0)
    }
    if (gpuTempFile.path !== "") {
      gpuTempFile.reload()
      gpuTempC = readTemp(gpuTempFile)
    }
    if (gpuPowerFile.path !== "") {
      gpuPowerFile.reload()
      gpuWatts = readNumber(gpuPowerFile, 1000000)
    }
    if (gpuFanFile.path !== "") {
      gpuFanFile.reload()
      gpuRpm = readNumber(gpuFanFile, 0)
    }
    if (gpuClockFile.path !== "") {
      gpuClockFile.reload()
      gpuMhz = readNumber(gpuClockFile, 1000000)
    }
    if (gpuVramUsedFile.path !== "") {
      gpuVramUsedFile.reload()
      gpuVramUsedBytes = readNumber(gpuVramUsedFile, 0)
    }
    if (gpuVramTotalFile.path !== "") {
      gpuVramTotalFile.reload()
      gpuVramTotalBytes = readNumber(gpuVramTotalFile, 0)
    }
  }

  function sampleNvidia() {
    if (nvidiaProcess.running) return
    nvidiaProcess.command = ["nvidia-smi",
                             "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw",
                             "--format=csv,noheader,nounits",
                             "--id=" + String(gpuInfo.index !== undefined ? gpuInfo.index : 0)]
    nvidiaProcess.running = true
  }

  function applyNvidia(raw) {
    var sample = Model.parseNvidia(raw)
    if (!sample) return
    gpuPercent = sample.busy
    gpuTempC = sample.tempC
    gpuWatts = sample.watts
    gpuVramUsedBytes = sample.vramUsedBytes
    gpuVramTotalBytes = sample.vramTotalBytes
  }

  // Lancia proc_top.py al massimo ogni 3 s. Solo valori allowlist in argv
  // (intero clampato, sort ram/cpu validato, flag --group per presenza):
  // la stringa grezza del setting non tocca mai argv. Niente PATH, niente shell.
  function refreshProcTop() {
    if (!active || !procPanelOpen || procTopProcess.running) return
    var now = Date.now()
    if (_lastProcTopTry > 0 && now - _lastProcTopTry < 3000) return
    _lastProcTopTry = now
    var cmd = ["/usr/bin/python3", procTopPath, "--top", String(topProcCount), "--sort", topProcSort]
    if (topProcGroup) cmd.push("--group")
    procTopProcess.command = cmd
    procTopProcess.running = true
    procTopWatchdog.restart()
  }

  // Cambio sort/raggruppamento → refresh immediato (throttle azzerato).
  // Le guardie in refreshProcTop restano valide: a pannello chiuso non parte.
  onTopProcSortChanged: {
    _lastProcTopTry = 0
    refreshProcTop()
  }
  onTopProcGroupChanged: {
    _lastProcTopTry = 0
    refreshProcTop()
  }

  // ----------------------------------------------------------------- files
  //
  // blockAllReads makes reload() synchronous: without it text() returns the
  // previous tick's contents and every readout lags a full interval. These are
  // kernel-generated files of a few KB, so a blocking read never stalls the UI.

  FileView { id: statFile; path: "/proc/stat"; blockAllReads: true; printErrors: false }
  FileView { id: memFile; path: "/proc/meminfo"; blockAllReads: true; printErrors: false }
  FileView { id: cpuinfoFile; path: "/proc/cpuinfo"; blockAllReads: true; printErrors: false }
  FileView { id: loadFile; path: "/proc/loadavg"; blockAllReads: true; printErrors: false }

  FileView {
    id: cpuTempFile
    path: root.cpuInfo && root.cpuInfo.tempPath ? String(root.cpuInfo.tempPath) : ""
    blockAllReads: true
    printErrors: false
  }

  // A GPU sensor the card does not expose leaves its path empty, and sample()
  // skips it — the widget then renders a dash rather than a fake zero.
  FileView {
    id: gpuBusyFile
    path: root.hasGpu && root.gpuInfo.busyPath ? String(root.gpuInfo.busyPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuTempFile
    path: root.hasGpu && root.gpuInfo.tempPath ? String(root.gpuInfo.tempPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuPowerFile
    path: root.hasGpu && root.gpuInfo.powerPath ? String(root.gpuInfo.powerPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuFanFile
    path: root.hasGpu && root.gpuInfo.fanPath ? String(root.gpuInfo.fanPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuClockFile
    path: root.hasGpu && root.gpuInfo.clockPath ? String(root.gpuInfo.clockPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuVramUsedFile
    path: root.hasGpu && root.gpuInfo.vramUsedPath ? String(root.gpuInfo.vramUsedPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuVramTotalFile
    path: root.hasGpu && root.gpuInfo.vramTotalPath ? String(root.gpuInfo.vramTotalPath) : ""
    blockAllReads: true
    printErrors: false
  }

  // ------------------------------------------------------------- processes

  Process {
    id: probeProcess
    stdout: StdioCollector {
      id: probeOut
      waitForEnd: true
      onStreamFinished: {
        root.probe = Model.parseProbe(text)
        // Sensor paths only become known here, so take the first real sample
        // once they land instead of waiting out a whole interval.
        root.sample()
      }
    }
    stderr: StdioCollector { waitForEnd: true }
  }

  Process {
    id: nvidiaProcess
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.applyNvidia(text) }
    stderr: StdioCollector { waitForEnd: true }
  }

  // Worker top-processi: esecuzione diretta (mai sh -c), stdout limitato a una
  // riga JSON <16 KB, validato da Model.parseProcTop. Fallimento soft: tiene
  // l'ultimo valore buono e alza procTopFailed invece di svuotare la sezione.
  Process {
    id: procTopProcess
    stdout: StdioCollector {
      id: procTopOut
      waitForEnd: true
      onStreamFinished: {
        procTopWatchdog.stop()
        var res = Model.parseProcTop(text, 12)
        var list = res.rows
        if (list.length > 0 || String(text).indexOf('"procs"') !== -1) {
          root.topProcs = list
          root.procGroupedBy = res.groupedBy
          root.procTopFailed = false
          root._lastProcTopOk = Date.now()
          var d = new Date(root._lastProcTopOk)
          var hh = d.getHours()
          var mm = d.getMinutes()
          var ss = d.getSeconds()
          root.procTopTime = (hh < 10 ? "0" + hh : "" + hh) + ":" + (mm < 10 ? "0" + mm : "" + mm) + ":" + (ss < 10 ? "0" + ss : "" + ss)
        } else {
          root.procTopFailed = true
        }
      }
    }
    stderr: StdioCollector { waitForEnd: true }
    onExited: procTopWatchdog.stop()
  }

  // Watchdog kill-before-next-tick: 0.4 s di lettura interna << 2 s << 3 s di
  // throttle. Uccide il runaway e marca lo stallo; il latch si pulisce anche
  // in onExited così non resta mai incastrato se lo spawn fallisce.
  Timer {
    id: procTopWatchdog
    interval: 2000
    repeat: false
    onTriggered: {
      if (procTopProcess.running) procTopProcess.running = false
      root.procTopFailed = true
    }
  }

  // -------------------------------------------------------------- lifetime

  Timer {
    interval: root.intervalSec * 1000
    running: root.active
    repeat: true
    onTriggered: root.sample()
  }

  // CPU usage needs two samples. Take the second one shortly after startup so
  // the widget shows a real number immediately rather than a dash.
  Timer {
    interval: 350
    running: root.active
    repeat: false
    onTriggered: root.sample()
  }

  function start() {
    if (!active || probeProcess.running) return
    sample()
    refreshProbe()
  }

  onActiveChanged: if (active) start()
  Component.onCompleted: start()
}
