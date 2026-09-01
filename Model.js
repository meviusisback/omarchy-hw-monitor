.pragma library

// Pure parsing and formatting for the hardware readouts. Everything here takes
// raw file text or numbers and returns plain values, so the sampling in
// Service.qml and the drawing in Widget.qml never have to agree on anything
// beyond these shapes.

var KIB_PER_GIB = 1048576
var BYTES_PER_GIB = 1073741824

function toNumber(value, fallback) {
  var n = Number(String(value).trim())
  return isFinite(n) ? n : (fallback === undefined ? 0 : fallback)
}

function clamp(value, min, max) {
  return Math.max(min, Math.min(max, value))
}

// ------------------------------------------------------------------- probe

function parseProbe(raw) {
  var empty = { ok: false, cpu: { model: "CPU", cores: 0, threads: 0 }, gpus: [] }
  var text = String(raw || "").trim()
  if (text === "") return empty
  try {
    var parsed = JSON.parse(text)
    if (!parsed || typeof parsed !== "object") return empty
    return {
      ok: true,
      cpu: parsed.cpu || empty.cpu,
      gpus: parsed.gpus instanceof Array ? parsed.gpus : []
    }
  } catch (e) {
    return empty
  }
}

// Pick which discovered card the widget reports on. `auto` means the first,
// which hw-probe has already sorted so a card with a load counter wins.
function pickGpu(gpus, preference) {
  if (!(gpus instanceof Array) || gpus.length === 0) return null
  var want = String(preference === undefined || preference === null ? "auto" : preference).trim().toLowerCase()
  if (want === "" || want === "auto") return gpus[0]

  var index = parseInt(want, 10)
  if (isFinite(index) && index >= 0 && index < gpus.length) return gpus[index]

  // Otherwise treat it as a substring match on card, kind, or name — so
  // "card1", "amdgpu", and "9070" all select the same GPU.
  for (var i = 0; i < gpus.length; i++) {
    var gpu = gpus[i]
    var haystack = [gpu.card, gpu.kind, gpu.name].join(" ").toLowerCase()
    if (haystack.indexOf(want) !== -1) return gpu
  }
  return gpus[0]
}

// --------------------------------------------------------------------- cpu

// The aggregate line of /proc/stat holds cumulative jiffies since boot:
// cpu user nice system idle iowait irq softirq steal guest guest_nice
function parseCpuJiffies(raw) {
  var text = String(raw || "")
  var end = text.indexOf("\n")
  var line = end === -1 ? text : text.substring(0, end)
  var parts = line.replace(/\s+/g, " ").split(" ")
  if (parts.length < 5 || parts[0] !== "cpu") return null

  var total = 0
  // Fields past `steal` are already counted inside user/nice, so stop at 8.
  for (var i = 1; i < parts.length && i <= 8; i++) total += toNumber(parts[i])
  // iowait is time with nothing to run, so it belongs with idle rather than
  // being charged to a process — this matches what top and btop report.
  var idle = toNumber(parts[4]) + toNumber(parts[5])
  return { total: total, idle: idle }
}

// Usage is a ratio of jiffie deltas, not of wall-clock time, so an uneven
// sampling interval cannot skew it.
function cpuUsage(previous, current) {
  if (!previous || !current) return -1
  var totalDelta = current.total - previous.total
  var idleDelta = current.idle - previous.idle
  if (totalDelta <= 0) return -1
  return clamp(100 * (1 - idleDelta / totalDelta), 0, 100)
}

// Average current clock across every thread. /proc/cpuinfo is the one place
// that reports it without globbing 32 cpufreq directories.
function averageMhz(raw) {
  var matches = String(raw || "").match(/^cpu MHz\s*:\s*([\d.]+)/gm)
  if (!matches || matches.length === 0) return 0
  var sum = 0
  for (var i = 0; i < matches.length; i++) sum += toNumber(matches[i].split(":")[1])
  return sum / matches.length
}

function parseLoadAverage(raw) {
  var parts = String(raw || "").trim().split(/\s+/)
  if (parts.length < 3) return null
  return { one: toNumber(parts[0]), five: toNumber(parts[1]), fifteen: toNumber(parts[2]) }
}

// ------------------------------------------------------------------ memory

// MemAvailable is the kernel's own estimate of what a new allocation can get
// without swapping, which is what "used" should be measured against — total
// minus free counts reclaimable page cache as used and always reads ~90%.
function parseMemory(raw) {
  var text = String(raw || "")
  function field(key) {
    var match = text.match(new RegExp("^" + key + ":\\s+(\\d+)", "m"))
    return match ? toNumber(match[1]) : 0
  }

  var total = field("MemTotal")
  var available = field("MemAvailable")
  if (total <= 0) return null
  if (available <= 0) available = field("MemFree") + field("Buffers") + field("Cached")

  var swapTotal = field("SwapTotal")
  return {
    totalKib: total,
    availableKib: available,
    usedKib: Math.max(0, total - available),
    cachedKib: field("Cached") + field("SReclaimable"),
    swapTotalKib: swapTotal,
    swapUsedKib: Math.max(0, swapTotal - field("SwapFree")),
    percent: clamp(100 * (total - available) / total, 0, 100)
  }
}

// ------------------------------------------------------------------ nvidia
//
// nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,
// memory.total,power.draw --format=csv,noheader,nounits
// Unsupported fields come back as "[N/A]".

function parseNvidia(raw) {
  var line = String(raw || "").trim().split("\n")[0]
  if (!line) return null
  var parts = line.split(",")
  if (parts.length < 4) return null

  function value(index) {
    var text = String(parts[index] || "").trim()
    if (text === "" || text.indexOf("N/A") !== -1) return -1
    return toNumber(text, -1)
  }

  return {
    busy: value(0),
    tempC: value(1),
    vramUsedBytes: value(2) >= 0 ? value(2) * 1048576 : -1,
    vramTotalBytes: value(3) >= 0 ? value(3) * 1048576 : -1,
    watts: parts.length > 4 ? value(4) : -1
  }
}

// -------------------------------------------------------------- formatting

function gibFromKib(kib) {
  return kib / KIB_PER_GIB
}

function gibFromBytes(bytes) {
  return bytes / BYTES_PER_GIB
}

// One decimal below 10 GiB, none above: "9.4G" and "62G" both stay narrow,
// and the bar never reflows as memory crosses a rounding boundary.
function formatGib(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  if (gib === 0) return "0"
  if (gib < 10) return gib.toFixed(1)
  return String(Math.round(gib))
}

// One decimal always, for the label mode where the figure is the whole point
// and the column is wide enough to carry it.
function formatGibPrecise(gib) {
  if (!isFinite(gib) || gib < 0) return "–"
  return gib.toFixed(1)
}

function formatPercent(value) {
  if (!isFinite(value) || value < 0) return "–"
  return Math.round(value) + "%"
}

// A leading zero rather than a leading space: same constant width, but the
// figure still starts where the eye expects it to, hard against its label.
function formatPercentPadded(value) {
  if (!isFinite(value) || value < 0) return "–"
  var n = Math.round(value)
  return (n < 10 ? "0" + n : String(n)) + "%"
}

// Just the figure, for callers that want to choose their own unit marker.
function tempNumber(celsius, fahrenheit) {
  if (!isFinite(celsius) || celsius <= 0) return "–"
  return String(Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius))
}

function formatTemp(celsius, fahrenheit) {
  if (!isFinite(celsius) || celsius <= 0) return "–"
  var deg = Math.round(fahrenheit ? celsius * 9 / 5 + 32 : celsius)
  return deg + "°" + (fahrenheit ? "F" : "C")
}

function formatGhz(mhz) {
  if (!isFinite(mhz) || mhz <= 0) return "–"
  return (mhz / 1000).toFixed(1) + " GHz"
}

// Just the number, for a bar row where an icon already says what it measures.
function formatGhzShort(mhz) {
  if (!isFinite(mhz) || mhz <= 0) return "–"
  return (mhz / 1000).toFixed(1)
}

function formatWatts(watts) {
  if (!isFinite(watts) || watts < 0) return "–"
  return Math.round(watts) + " W"
}

function formatRpm(rpm) {
  if (!isFinite(rpm) || rpm < 0) return "–"
  return rpm === 0 ? "idle" : Math.round(rpm) + " rpm"
}

// ------------------------------------------------------------------ severity
//
// 0 while a reading is unremarkable, ramping to 1 as it crosses from `warn` to
// `critical`. Widget.qml mixes the theme foreground toward urgent by this
// amount, so a busy machine warms up gradually instead of flipping to red.

function severity(value, warn, critical) {
  if (!isFinite(value) || value < 0) return 0
  if (value <= warn) return 0
  return clamp((value - warn) / Math.max(1, critical - warn), 0, 1)
}

// Monospace digits are all the same width, so left-padding a reading to the
// width of its widest realistic value keeps the bar from reflowing every time
// a number gains or loses a digit. Values past that width still render — they
// just push the widget wider, which for 100% or 100°C is rare enough to accept.
function padLeft(text, width) {
  var out = String(text)
  while (out.length < width) out = " " + out
  return out
}
