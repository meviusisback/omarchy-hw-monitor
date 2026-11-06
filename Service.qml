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
  readonly property var gpuInfo: Model.pickGpu(probe.gpus, setting("gpu", "auto"), busiestIndex)
  onGpuInfoChanged: {
    if (_destroyed) return
    // The idle baseline belongs to one GT's counter; a reselect to a different
    // card must not mix it into another card's delta. A re-probe resolving to
    // the same card keeps the baseline — the counter never changed identity.
    var card = gpuInfo && gpuInfo.card ? String(gpuInfo.card) : ""
    if (card !== _gpuCard) {
      _gpuCard = card
      _prevGpuIdle = null
      _gpuSuspended = false
      // Readouts reset too, so the old card's figures never render as the new
      // card's until the next sample repopulates them.
      gpuPercent = -1
      gpuTempC = -1
      gpuWatts = -1
      gpuRpm = -1
      gpuMhz = -1
      gpuVramUsedBytes = -1
      gpuVramTotalBytes = -1
    }
  }
  readonly property bool hasGpu: gpuInfo !== null
  readonly property var nvidiaGpus: (probe.gpus || []).filter(function (g) { return String(g.kind) === "nvidia" })
  property var nvidiaSamples: []
  property int busiestIndex: 0
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
  // nvidia-smi formats its CSV numbers with the session locale, so a
  // comma-decimal locale (de_DE, fr_FR, it_IT) turns "55.30" into "55,30" —
  // a sixth comma-separated field, after which every reading is one slot off.
  // Pinning C makes the parse locale-proof instead of making the parser
  // tolerate a shape it cannot detect. Held in a `var` because
  // Process.environment is a QVariantHash and an object literal infers
  // QVariantMap, which qmllint reports as a type mismatch; the runtime accepts
  // it either way (verified by probe: the child sees LC_ALL=C and keeps its
  // inherited PATH, so the locale is overridden and nothing else is lost).
  readonly property var cleanLocale: ({ "LC_ALL": "C", "LANG": "C" })
  property double _lastProcTopTry: 0
  property double _lastProcTopOk: 0
  // Stale-length baselines for the byte guards: StdioCollector.text still
  // holds the PREVIOUS run's output until this run's first byte arrives, so
  // each guard compares against the length recorded at spawn — without a
  // baseline a slow-first-byte run would be killed for the last run's size.
  // stderr needs the same treatment as stdout: a collector that is never
  // written to again keeps its old text forever, so a bare `err > cap` latches
  // true after one oversized run and kills every later run of that helper at
  // the first poll, for the rest of the session.
  property int _probeBase: 0
  property int _nvidiaBase: 0
  property int _procTopBase: 0
  property int _probeErrBase: 0
  property int _nvidiaErrBase: 0
  property int _procTopErrBase: 0
  // Veto anti-teardown: nessun handler tocca più lo stato dopo l'inizio
  // della distruzione (finestra di reload). Ogni callback che può mutare
  // stato — Process/StdioCollector, watchdog, kill timer, byte guard, sample
  // timer, start() — controlla questo flag. Vedi onDestruction in fondo.
  property bool _destroyed: false

  // Cumulative jiffies from the previous tick. CPU usage is the ratio between
  // two samples, so there is nothing to show until the second one lands.
  property var _prevJiffies: null

  // Previous Intel RC6 idle reading and when it was taken. GPU load on Intel
  // is derived the same way as CPU load, so it also needs two samples.
  property var _prevGpuIdle: null
  property bool _gpuSuspended: false
  // Card the current baseline and readouts belong to. onGpuInfoChanged fires
  // on every probe assignment (new object identity), so the reset keys on
  // this instead — otherwise a same-card re-probe needlessly dashes Intel load.
  property string _gpuCard: ""

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
    _probeBase = String(probeOut.text).length
    _probeErrBase = String(probeErr.text).length
    probeWatchdog.restart()
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

    if (gpuBusyFile.path === "" && gpuIdleFile.path !== "") sampleGpuIdle()
    else if (gpuIdleFile.path === "" && gpuPmStatusFile.path !== "") refreshGpuSuspended()
    if (gpuBusyFile.path !== "") {
      gpuBusyFile.reload()
      gpuPercent = readNumber(gpuBusyFile, 0)
    }
    if (gpuTempFile.path !== "" && !_gpuSuspended) {
      gpuTempFile.reload()
      gpuTempC = readTemp(gpuTempFile)
    }
    if (gpuPowerFile.path !== "" && !_gpuSuspended) {
      gpuPowerFile.reload()
      gpuWatts = readNumber(gpuPowerFile, 1000000)
    }
    if (gpuFanFile.path !== "" && !_gpuSuspended) {
      gpuFanFile.reload()
      gpuRpm = readNumber(gpuFanFile, 0)
    }
    if (gpuClockFile.path !== "" && !_gpuSuspended) {
      gpuClockFile.reload()
      gpuMhz = readNumber(gpuClockFile, 1000000)
    } else if (gpuClockMhzFile.path !== "" && !_gpuSuspended) {
      gpuClockMhzFile.reload()
      gpuMhz = readNumber(gpuClockMhzFile, 0)
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

  // Reading runtime_status never wakes the device, so this stays cheap to
  // call even when idle sampling is skipped (busyPath cards, clock-only cards).
  function refreshGpuSuspended() {
    _gpuSuspended = false
    if (gpuPmStatusFile.path !== "") {
      gpuPmStatusFile.reload()
      _gpuSuspended = String(gpuPmStatusFile.text()).trim() === "suspended"
    }
    // Clock-only cards never run sampleGpuIdle, so dash here too: the gated
    // reads below are skipped while suspended and would otherwise freeze.
    // (sampleGpuIdle also sets gpuPercent = 0 on its own suspended branch.)
    if (_gpuSuspended) {
      gpuMhz = 0
      gpuTempC = -1
      gpuWatts = -1
      gpuRpm = -1
    }
  }

  // A runtime-suspended GT is idle by definition, and reading its residency
  // counter or clock would wake it, so it reads as 0% without touching either.
  // The baseline is dropped too: the next delta must not span the suspension.
  function sampleGpuIdle() {
    refreshGpuSuspended()
    if (_gpuSuspended) {
      _prevGpuIdle = null
      gpuPercent = 0
      return
    }
    gpuIdleFile.reload()
    var idleMs = readNumber(gpuIdleFile, 0)
    if (idleMs < 0) return
    var current = { idleMs: idleMs, atMs: Date.now() }
    // Twice the sample interval plus headroom: a suspend or clock step makes
    // wall time jump while the counter sits frozen, and that delta would print
    // ~100%. Refusing it keeps the last good figure; the baseline still moves
    // to current, so the NEXT delta spans only the post-resume interval.
    var usage = Model.gpuBusyFromIdle(_prevGpuIdle, current, 2 * root.intervalSec * 1000 + 1000)
    if (usage >= 0) {
      gpuPercent = usage
    }
    _prevGpuIdle = current
  }

  function sampleNvidia() {
    if (_destroyed || nvidiaProcess.running) return
    // hw-probe reports the absolute path it resolved, so the bar never
    // re-resolves nvidia-smi from the session PATH at sample time.
    var bin = gpuInfo && gpuInfo.nvidiaPath ? String(gpuInfo.nvidiaPath) : "nvidia-smi"
    nvidiaProcess.command = [bin,
                             "--query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total,power.draw",
                             "--format=csv,noheader,nounits"]
    _nvidiaBase = String(nvidiaOut.text).length
    _nvidiaErrBase = String(nvidiaErr.text).length
    nvidiaWatchdog.restart()
    nvidiaProcess.running = true
  }

  function applyNvidia(raw) {
    var all = Model.parseNvidiaAll(raw)
    busiestIndex = Model.busiestNvidia(all, busiestIndex, 10)
    var sample = all[gpuInfo && gpuInfo.index !== undefined ? gpuInfo.index : 0]
    // Publish every card before the guard: a null or missing selected slot keeps
    // the bar readouts on their last good value, but must not freeze the panel.
    nvidiaSamples = all
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
    if (_destroyed || !active || !procPanelOpen || procTopProcess.running) return
    var now = Date.now()
    if (_lastProcTopTry > 0 && now - _lastProcTopTry < 3000) return
    _lastProcTopTry = now
    var cmd = ["/usr/bin/python3", procTopPath, "--top", String(topProcCount), "--sort", topProcSort]
    if (topProcGroup) cmd.push("--group")
    procTopProcess.command = cmd
    _procTopBase = String(procTopOut.text).length
    _procTopErrBase = String(procTopErr.text).length
    procTopProcess.running = true
    procTopWatchdog.restart()
  }

  // Cambio sort/raggruppamento → refresh immediato (throttle azzerato).
  // Le guardie in refreshProcTop restano valide: a pannello chiuso non parte.
  // Il veto è ripetuto qui perché questi due handler scrivono _lastProcTopTry
  // prima di chiamare: senza, muterebbero stato su un oggetto già distrutto.
  onTopProcSortChanged: {
    if (_destroyed) return
    _lastProcTopTry = 0
    refreshProcTop()
  }
  onTopProcGroupChanged: {
    if (_destroyed) return
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
    id: gpuIdleFile
    path: root.hasGpu && root.gpuInfo.idlePath ? String(root.gpuInfo.idlePath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuClockMhzFile
    path: root.hasGpu && root.gpuInfo.clockMhzPath ? String(root.gpuInfo.clockMhzPath) : ""
    blockAllReads: true
    printErrors: false
  }
  FileView {
    id: gpuPmStatusFile
    path: root.hasGpu && root.gpuInfo.pmStatusPath ? String(root.gpuInfo.pmStatusPath) : ""
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

  // Byte caps: StdioCollector never emits the parser's read signal, so the
  // cap is enforced by polling the collected text length from a short repeat
  // Timer (verified on Quickshell 0.3.1: a 64 MB spewer is stopped within one
  // polling interval). Untampered output is one JSON line of at most a few
  // KB, so a cap crossing always means a runaway or tampered helper.
  Process {
    id: probeProcess
    stdout: StdioCollector {
      id: probeOut
      waitForEnd: false
      onStreamFinished: {
        if (root._destroyed) return
        root.probe = Model.parseProbe(text)
        // Sensor paths only become known here, so take the first real sample
        // once they land instead of waiting out a whole interval. Re-base the
        // warmup on this sample: the 250 ms idle-delta floor would refuse a
        // second sample that lands inside the same window on a slow probe.
        root.sample()
        warmupSampleTimer.restart()
      }
    }
    stderr: StdioCollector { id: probeErr; waitForEnd: false }
    onExited: {
      if (root._destroyed) return
      probeWatchdog.stop()
      probeKillTimer.stop()
      // A killed or crashed probe leaves discovery empty for the whole
      // session otherwise: retry slowly until one run succeeds.
      if (!root.probe.ok) probeRetryTimer.restart()
    }
  }

  Process {
    id: nvidiaProcess
    environment: root.cleanLocale
    stdout: StdioCollector {
      id: nvidiaOut
      waitForEnd: false
      onStreamFinished: { if (!root._destroyed) root.applyNvidia(text) }
    }
    stderr: StdioCollector { id: nvidiaErr; waitForEnd: false }
    onExited: {
      if (root._destroyed) return
      nvidiaWatchdog.stop()
      nvidiaKillTimer.stop()
    }
  }

  // Worker top-processi: esecuzione diretta (mai sh -c), stdout limitato a una
  // riga JSON <16 KB, validato da Model.parseProcTop. Fallimento soft: tiene
  // l'ultimo valore buono e alza procTopFailed invece di svuotare la sezione.
  Process {
    id: procTopProcess
    stdout: StdioCollector {
      id: procTopOut
      waitForEnd: false
      onStreamFinished: {
        if (root._destroyed) return
        // parseProcTop degrades fail-soft on every shape it documents, but an
        // exotic value type can still throw: catch it so the section flags a
        // failure instead of freezing silently. The watchdog is stopped in
        // onExited, not here — a helper that closes stdout and then hangs
        // must still be killed.
        var res = null
        try { res = Model.parseProcTop(text, 12) } catch (e) { res = null }
        if (!res) {
          root.procTopFailed = true
          return
        }
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
    stderr: StdioCollector { id: procTopErr; waitForEnd: false }
    onExited: {
      if (root._destroyed) return
      procTopWatchdog.stop()
      procTopKillTimer.stop()
    }
  }

  // Watchdog kill-before-next-tick: 0.4 s di lettura interna << 2 s << 3 s di
  // throttle. The first trigger sends SIGTERM via running=false; the kill
  // timer escalates to SIGKILL for a helper that ignores it. Both stay armed
  // until onExited — a helper that finishes its output and then hangs must
  // still be killed. nvidia and probe get the same two-stage treatment: a
  // wedged nvidia-smi or a hung hw-probe used to latch running=true forever.
  Timer {
    id: procTopWatchdog
    interval: 2000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (procTopProcess.running) procTopProcess.running = false
      procTopKillTimer.restart()
      root.procTopFailed = true
    }
  }

  Timer {
    id: procTopKillTimer
    interval: 1000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (procTopProcess.running) procTopProcess.signal(9)
    }
  }

  Timer {
    id: nvidiaWatchdog
    interval: 10000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (nvidiaProcess.running) nvidiaProcess.running = false
      nvidiaKillTimer.restart()
    }
  }

  Timer {
    id: nvidiaKillTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (nvidiaProcess.running) nvidiaProcess.signal(9)
    }
  }

  Timer {
    id: probeWatchdog
    interval: 8000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (probeProcess.running) probeProcess.running = false
      probeKillTimer.restart()
    }
  }

  Timer {
    id: probeKillTimer
    interval: 2000
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      if (probeProcess.running) probeProcess.signal(9)
    }
  }

  // Byte-cap guards, one per helper: poll the collected text length while
  // the process runs and stop it past the cap, escalating through the same
  // kill timers the watchdogs use. Two rules keep the check honest, and both
  // apply to stderr exactly as to stdout: the baseline recorded at spawn
  // separates the previous run's stale text from this run's bytes (a collector
  // is only reset once THIS run writes its first byte, and one that is never
  // written to again keeps its old length forever), and stderr counts toward
  // the cap too. The running binding stops the guard when the process ends,
  // and the teardown veto stops it touching state during a reload.
  Timer {
    id: procTopByteGuard
    interval: 100
    repeat: true
    running: procTopProcess.running
    onTriggered: {
      if (root._destroyed) return
      var len = String(procTopOut.text).length
      var err = String(procTopErr.text).length
      if ((len !== root._procTopBase && len > 16384) ||
          (err !== root._procTopErrBase && err > 16384)) {
        procTopProcess.running = false
        procTopKillTimer.restart()
      }
    }
  }

  Timer {
    id: probeByteGuard
    interval: 100
    repeat: true
    running: probeProcess.running
    onTriggered: {
      if (root._destroyed) return
      var len = String(probeOut.text).length
      var err = String(probeErr.text).length
      if ((len !== root._probeBase && len > 65536) ||
          (err !== root._probeErrBase && err > 65536)) {
        probeProcess.running = false
        probeKillTimer.restart()
      }
    }
  }

  Timer {
    id: nvidiaByteGuard
    interval: 100
    repeat: true
    running: nvidiaProcess.running
    onTriggered: {
      if (root._destroyed) return
      var len = String(nvidiaOut.text).length
      var err = String(nvidiaErr.text).length
      if ((len !== root._nvidiaBase && len > 65536) ||
          (err !== root._nvidiaErrBase && err > 65536)) {
        nvidiaProcess.running = false
        nvidiaKillTimer.restart()
      }
    }
  }

  // Slow retry for discovery: armed only when a probe run ended without
  // producing a valid payload (killed, crashed, or malformed), restart() so
  // each failed exit resets the 30 s deadline, and never re-armed once a
  // run succeeds (onTriggered checks probe.ok).
  Timer {
    id: probeRetryTimer
    interval: 30000
    repeat: false
    onTriggered: {
      if (root._destroyed || root.probe.ok) return
      refreshProbe()
    }
  }

  // Cleanup anti-teardown: ferma worker, watchdog, byte guard e sample timer,
  // poi alza il veto, così nessun callback in volo tocca lo stato durante la
  // finalizzazione (reload). Il veto va alzato per primo: è l'unica cosa che
  // impedisce a un timer già accodato di rieseguire start() e rilanciare un
  // helper dopo che i watchdog sono stati spenti — un figlio che resterebbe
  // orfano perché nessuno lo ucciderebbe più.
  Component.onDestruction: {
    _destroyed = true
    procTopWatchdog.stop()
    procTopKillTimer.stop()
    nvidiaWatchdog.stop()
    nvidiaKillTimer.stop()
    probeWatchdog.stop()
    probeKillTimer.stop()
    probeRetryTimer.stop()
    // Fermati esplicitamente: il loro `running` è legato a quello dei Process,
    // e dipendere dalla ri-valutazione del binding significherebbe affidare lo
    // spegnimento all'ordine di valutazione invece che a una dichiarazione.
    procTopByteGuard.stop()
    probeByteGuard.stop()
    nvidiaByteGuard.stop()
    sampleTimer.stop()
    warmupSampleTimer.stop()
    if (procTopProcess.running) procTopProcess.running = false
    if (nvidiaProcess.running) nvidiaProcess.running = false
    if (probeProcess.running) probeProcess.running = false
  }

  // -------------------------------------------------------------- lifetime

  Timer {
    id: sampleTimer
    interval: root.intervalSec * 1000
    running: root.active
    repeat: true
    onTriggered: {
      if (root._destroyed) return
      root.sample()
    }
  }

  // CPU usage needs two samples. Take the second one shortly after startup so
  // the widget shows a real number immediately rather than a dash.
  Timer {
    id: warmupSampleTimer
    interval: 350
    running: root.active
    repeat: false
    onTriggered: {
      if (root._destroyed) return
      root.sample()
    }
  }

  function start() {
    if (_destroyed || !active || probeProcess.running) return
    sample()
    refreshProbe()
  }

  // `active` follows the widget's screen membership, which collapses to true
  // for a moment while the window/screen is being torn down or hotplugged —
  // exactly the window where start() must not run.
  onActiveChanged: if (!_destroyed && active) start()
  Component.onCompleted: start()
}
