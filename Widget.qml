import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Telemetry readouts for GPU, CPU, Temperatures, and Memory in the Omarchy bar
// with rich per-item data selection, ordering, and formatting controls.
//
// Left click opens the Omarchy system panel popup (or runs clickCommand if set).
// Right click walks the display modes and remembers the choice; middle click resamples.
Panel {
  id: root
  moduleName: "io.github.edgarsilva.hw-monitor"
  ipcTarget: "io.github.edgarsilva.hw-monitor"
  manageIpc: false

  readonly property bool vertical: bar ? bar.vertical : false

  function broadcast(method) {
    var items = bar && typeof bar.moduleWidgets === "function"
      ? bar.moduleWidgets(moduleName) : [root]
    for (var i = 0; i < items.length; i++) {
      if (items[i] && typeof items[i][method] === "function") items[i][method]()
    }
  }

  // Four states, cycled by right click:
  //   icons    Sleek component glyphs + live figures (Noctalia-style readout, default)
  //   compact  glyphs + gauges
  //   full     glyphs + gauges + temperatures
  //   labels   Waybar-style text readout — GPU 0% · CPU 34% · TEMP 46°C · RAM 11/23G
  readonly property var modes: ["icons", "compact", "full", "labels"]
  readonly property string mode: {
    var want = String(setting("mode", "icons")).trim().toLowerCase()
    return modes.indexOf(want) === -1 ? "icons" : want
  }

  readonly property string nextMode: modes[(modes.indexOf(mode) + 1) % modes.length]
  readonly property bool labelled: mode === "labels" && !vertical
  readonly property bool showTemps: mode !== "compact" && !vertical
  readonly property bool showValues: (labelled || mode === "icons" || boolSetting("showValues", false)) && !vertical
  readonly property bool showGauges: boolSetting("showGauges", mode !== "icons" && mode !== "labels")
  readonly property bool showClocks: boolSetting("showClocks", false) && !vertical

  readonly property var monitors: {
    var raw = setting("monitors", [])
    if (raw === undefined || raw === null) return []
    if (raw instanceof Array) return raw.map(String)
    var text = String(raw).trim()
    return text === "" ? [] : text.split(/[,\s]+/)
  }

  readonly property string screenName: {
    var window = root.QsWindow ? root.QsWindow.window : null
    return window && window.screen ? String(window.screen.name) : ""
  }

  readonly property bool onThisScreen: monitors.length === 0 || screenName === ""
    || monitors.indexOf(screenName) !== -1

  // -------------------------------------------------------- data selection

  readonly property bool showGpu: boolSetting("showGpu", true)
  readonly property bool showCpu: boolSetting("showCpu", true)
  readonly property bool showCpuTemp: boolSetting("showCpuTemp", true)
  readonly property bool showGpuTemp: boolSetting("showGpuTemp", false)
  readonly property bool showRam: boolSetting("showRam", true)

  readonly property var itemOrder: {
    var raw = setting("itemsOrder", ["gpu", "cpu", "cpu-temp", "ram"])
    if (raw instanceof Array) return raw.map(function(s) { return String(s).trim().toLowerCase() })
    var text = String(raw || "").trim().toLowerCase()
    return text === "" ? ["gpu", "cpu", "cpu-temp", "ram"] : text.split(/[,\s]+/)
  }

  // ------------------------------------------------------------ formatting

  readonly property bool fahrenheit: boolSetting("fahrenheit", false)
  readonly property string ramFormat: {
    var want = String(setting("ramFormat", "used/total")).trim().toLowerCase()
    return ["used/total", "used", "percent", "free", "available"].indexOf(want) === -1 ? "used/total" : want
  }

  readonly property string tempFormat: {
    var want = String(setting("tempFormat", "degree-unit")).trim().toLowerCase()
    return ["degree-unit", "degree", "unit", "unit-lower", "bare"].indexOf(want) === -1 ? "degree-unit" : want
  }

  readonly property string percentPad: {
    var want = String(setting("percentPad", mode === "icons" ? "none" : "zero")).trim().toLowerCase()
    if (want === "space") want = "trail"
    return ["lead", "zero", "trail", "none"].indexOf(want) === -1 ? (mode === "icons" ? "none" : "zero") : want
  }

  readonly property real padOpacity: {
    var n = Number(setting("padOpacity", 0.3))
    return isFinite(n) ? Math.max(0, Math.min(1, n)) : 0.3
  }

  readonly property int iconSizeSetting: intSetting("iconSize", 0, 0, 48)
  readonly property int iconSize: iconSizeSetting > 0 ? iconSizeSetting : Style.bar.iconFont
  readonly property int valueSize: Math.max(9, Math.round(iconSize * 0.92))

  readonly property int warnPercent: intSetting("warnPercent", 70, 1, 100)
  readonly property int criticalPercent: intSetting("criticalPercent", 90, 1, 100)
  readonly property int warnTempC: intSetting("warnTempC", 75, 1, 150)
  readonly property int criticalTempC: intSetting("criticalTempC", 90, 1, 150)

  readonly property string clickCommand: String(setting("clickCommand", ""))

  // ----------------------------------------------------------------- glyphs

  readonly property string gpuIcon: String(setting("gpuIcon", "󰾲"))
  readonly property string cpuIcon: String(setting("cpuIcon", ""))
  readonly property string tempIcon: String(setting("tempIcon", ""))
  readonly property string gpuTempIcon: String(setting("gpuTempIcon", "󰔏"))
  readonly property string ramIcon: String(setting("ramIcon", ""))
  readonly property string clockIcon: String(setting("clockIcon", "󰓅"))

  readonly property int gpuIconRotation: intSetting("gpuIconRotation", 0, -360, 360)
  readonly property int cpuIconRotation: intSetting("cpuIconRotation", 0, -360, 360)
  readonly property int tempIconRotation: intSetting("tempIconRotation", 0, -360, 360)
  readonly property int ramIconRotation: intSetting("ramIconRotation", 0, -360, 360)

  function boolSetting(name, fallback) {
    var value = setting(name, fallback)
    if (typeof value === "boolean") return value
    var text = String(value).trim().toLowerCase()
    if (["true", "1", "yes", "on"].indexOf(text) !== -1) return true
    if (["false", "0", "no", "off"].indexOf(text) !== -1) return false
    return fallback
  }

  function intSetting(name, fallback, min, max) {
    var n = parseInt(String(setting(name, fallback)), 10)
    if (!isFinite(n)) n = fallback
    return Math.max(min, Math.min(max, n))
  }

  // ------------------------------------------------------------------ color

  readonly property color base: bar ? bar.barForeground : Color.foreground
  readonly property color hot: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(base, 1.45)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  function warm(from, amount) {
    if (!(amount > 0)) return from
    var t = Math.min(1, amount)
    return Qt.rgba(from.r + (hot.r - from.r) * t,
                   from.g + (hot.g - from.g) * t,
                   from.b + (hot.b - from.b) * t,
                   from.a)
  }

  function tempColor(tempC) {
    if (!isFinite(tempC) || tempC <= 0) return dim
    if (tempC < 50) return dim
    var t = Math.min(1, Math.max(0, (tempC - 50) / Math.max(1, criticalTempC - 50)))
    return Qt.rgba(base.r + (hot.r - base.r) * t,
                   base.g + (hot.g - base.g) * t,
                   base.b + (hot.b - base.b) * t,
                   base.a)
  }

  readonly property int percentSlot: Math.ceil(percentMetrics.advanceWidth)

  TextMetrics {
    id: percentMetrics
    font.family: root.fontFamily
    font.pixelSize: root.valueSize
    text: "100%"
  }

  // --------------------------------------------------------------- readings

  Service {
    id: hw
    settings: root.settings
    active: root.onThisScreen
  }

  function percentPadFor(value) {
    if (percentPad !== "zero") return ""
    if (!isFinite(value) || value < 0) return ""
    return Math.round(value) < 10 ? "0" : ""
  }

  function percentText(value) {
    if (percentPad === "lead") return Model.padLeft(Model.formatPercent(value), 3)
    return Model.formatPercent(value)
  }

  function tempText(celsius) {
    var figure = Model.tempNumber(celsius, fahrenheit)
    if (figure === "–") return Model.padLeft(figure, 3)

    var unit = fahrenheit ? "F" : "C"
    var text = figure
    if (tempFormat === "degree-unit") text += "°" + unit
    else if (tempFormat === "degree") text += "°"
    else if (tempFormat === "unit") text += unit
    else if (tempFormat === "unit-lower") text += unit.toLowerCase()
    return (labelled || percentPad === "lead") ? Model.padLeft(text, 3) : text
  }

  function ramText() {
    if (ramFormat === "percent") return percentText(hw.memPercent)
    if (!hw.memory) return "–"

    var usedGib = Model.gibFromKib(hw.memory.usedKib)
    var totalGib = Model.gibFromKib(hw.memory.totalKib)
    var availGib = Model.gibFromKib(hw.memory.availableKib)

    if (ramFormat === "used") {
      return Model.formatGibPrecise(usedGib) + "G"
    }

    if (ramFormat === "free" || ramFormat === "available") {
      return Model.formatGibPrecise(availGib) + "G"
    }

    if (labelled) {
      return Model.formatGibPrecise(usedGib) + "/" + Model.formatGib(totalGib) + "G"
    }

    if (mode === "icons") {
      return Model.formatGib(usedGib) + "/" + Model.formatGib(totalGib) + "G"
    }

    var used = Model.formatGib(usedGib)
    var total = Model.formatGib(totalGib)
    return Model.padLeft(used, 3) + "/" + total
  }

  // ------------------------------------------------------------- cell output

  readonly property var cells: {
    var cellMap = {}

    // GPU Load
    if (showGpu && hw.hasGpu) {
      var busy = hw.gpuPercent
      var meterValue = busy >= 0 ? busy : hw.gpuVramPercent
      cellMap["gpu"] = {
        key: "gpu",
        label: "GPU",
        icon: gpuIcon,
        iconRotation: gpuIconRotation,
        value: percentText(meterValue),
        pad: percentPadFor(meterValue),
        slotted: percentPad === "trail",
        temp: (mode === "full" || mode === "labels") && hw.gpuTempC > 0 ? tempText(hw.gpuTempC) : "",
        tempC: hw.gpuTempC,
        clock: Model.formatGhzShort(hw.gpuMhz),
        ratio: meterValue >= 0 ? meterValue / 100 : 0,
        severity: Model.severity(busy, warnPercent, criticalPercent)
      }
    }

    // CPU Load
    if (showCpu) {
      cellMap["cpu"] = {
        key: "cpu",
        label: "CPU",
        icon: cpuIcon,
        iconRotation: cpuIconRotation,
        value: percentText(hw.cpuPercent),
        pad: percentPadFor(hw.cpuPercent),
        slotted: percentPad === "trail",
        temp: (mode === "full" || mode === "labels") && hw.cpuTempC > 0 ? tempText(hw.cpuTempC) : "",
        tempC: hw.cpuTempC,
        clock: Model.formatGhzShort(hw.cpuMhz),
        ratio: hw.cpuPercent >= 0 ? hw.cpuPercent / 100 : 0,
        severity: Model.severity(hw.cpuPercent, warnPercent, criticalPercent)
      }
    }

    // CPU Temperature (standalone cell used in 'icons' mode)
    if (showCpuTemp && hw.cpuTempC > 0 && showTemps && mode === "icons") {
      cellMap["cpu-temp"] = {
        key: "cpu-temp",
        label: "TEMP",
        icon: tempIcon,
        iconRotation: tempIconRotation,
        value: tempText(hw.cpuTempC),
        pad: "",
        slotted: false,
        temp: "",
        tempC: hw.cpuTempC,
        clock: "",
        ratio: Math.min(1, Math.max(0, (hw.cpuTempC - 30) / Math.max(1, criticalTempC - 30))),
        severity: Model.severity(hw.cpuTempC, warnTempC, criticalTempC)
      }
    }

    // GPU Temperature (standalone cell used in 'icons' mode)
    if (showGpuTemp && hw.hasGpu && hw.gpuTempC > 0 && showTemps && mode === "icons") {
      cellMap["gpu-temp"] = {
        key: "gpu-temp",
        label: "GPU°",
        icon: gpuTempIcon,
        iconRotation: gpuIconRotation,
        value: tempText(hw.gpuTempC),
        pad: "",
        slotted: false,
        temp: "",
        tempC: hw.gpuTempC,
        clock: "",
        ratio: Math.min(1, Math.max(0, (hw.gpuTempC - 30) / Math.max(1, criticalTempC - 30))),
        severity: Model.severity(hw.gpuTempC, warnTempC, criticalTempC)
      }
    }

    // RAM
    if (showRam) {
      cellMap["ram"] = {
        key: "ram",
        label: "RAM",
        icon: ramIcon,
        iconRotation: ramIconRotation,
        value: ramText(),
        pad: "",
        slotted: false,
        temp: "",
        tempC: -1,
        clock: "",
        ratio: hw.memPercent >= 0 ? hw.memPercent / 100 : 0,
        severity: Model.severity(hw.memPercent, warnPercent, criticalPercent)
      }
    }

    var out = []
    var added = {}
    for (var i = 0; i < itemOrder.length; i++) {
      var k = itemOrder[i]
      if (cellMap[k] && !added[k]) {
        out.push(cellMap[k])
        added[k] = true
      }
    }
    // Append any enabled items not in itemOrder
    var fallbackOrder = ["gpu", "cpu", "cpu-temp", "gpu-temp", "ram"]
    for (var j = 0; j < fallbackOrder.length; j++) {
      var fk = fallbackOrder[j]
      if (cellMap[fk] && !added[fk]) {
        out.push(cellMap[fk])
        added[fk] = true
      }
    }

    return out
  }

  // ---------------------------------------------------------------- tooltip

  readonly property string monitorName: {
    var parts = clickCommand.split(/\s+/)
    var last = String(parts[parts.length - 1] || "")
    return last.substring(last.lastIndexOf("/") + 1)
  }

  readonly property string hint: clickCommand === ""
    ? "Hardware · right click for " + nextMode
    : "Click for " + monitorName + " · right click for " + nextMode

  function detail() {
    var lines = []

    var cpu = "CPU  " + Model.formatPercent(hw.cpuPercent)
    if (hw.cpuTempC > 0) cpu += "  ·  " + Model.formatTemp(hw.cpuTempC, fahrenheit)
    if (hw.cpuMhz > 0) cpu += "  ·  " + Model.formatGhz(hw.cpuMhz)
    lines.push(cpu)
    if (hw.cpuInfo && hw.cpuInfo.model) {
      lines.push(hw.cpuInfo.model + " · " + hw.cpuInfo.cores + "C/" + hw.cpuInfo.threads + "T")
    }
    if (hw.load) {
      lines.push("Load " + hw.load.one.toFixed(2) + "  " + hw.load.five.toFixed(2) + "  " + hw.load.fifteen.toFixed(2))
    }

    if (hw.hasGpu) {
      lines.push("")
      var gpu = "GPU  " + Model.formatPercent(hw.gpuPercent)
      if (hw.gpuWatts >= 0) gpu += "  ·  " + Model.formatWatts(hw.gpuWatts)
      lines.push(gpu)
      lines.push(String(hw.gpuInfo.name))
      if (hw.gpuVramTotalBytes > 0) {
        lines.push("VRAM " + Model.formatGib(Model.gibFromBytes(hw.gpuVramUsedBytes)) + " / "
                   + Model.formatGib(Model.gibFromBytes(hw.gpuVramTotalBytes)) + " GiB  ·  "
                   + Model.formatPercent(hw.gpuVramPercent))
      }
      var extras = []
      if (hw.gpuRpm >= 0) extras.push("Fan " + Model.formatRpm(hw.gpuRpm))
      if (hw.gpuMhz > 0) extras.push(Model.formatGhz(hw.gpuMhz))
      if (extras.length > 0) lines.push(extras.join("  ·  "))
    }

    if (hw.memory) {
      lines.push("")
      lines.push("RAM  " + Model.formatGib(Model.gibFromKib(hw.memory.usedKib)) + " / "
                 + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + " GiB  ·  "
                 + Model.formatPercent(hw.memory.percent))
      lines.push("Cache " + Model.formatGib(Model.gibFromKib(hw.memory.cachedKib)) + " GiB"
                 + (hw.memory.swapTotalKib > 0
                    ? "  ·  Swap " + Model.formatGib(Model.gibFromKib(hw.memory.swapUsedKib)) + " / "
                      + Model.formatGib(Model.gibFromKib(hw.memory.swapTotalKib)) + " GiB"
                    : ""))
    }

    return lines.join("\n")
  }

  // ----------------------------------------------------------------- actions

  function refresh() {
    hw.sample()
  }

  function currentEntry() {
    var config = root.bar && root.bar.shell ? root.bar.shell.shellConfig : null
    var layout = config && config.bar ? config.bar.layout : null
    var sections = ["left", "center", "right"]
    for (var s = 0; layout && s < sections.length; s++) {
      var entries = layout[sections[s]] || []
      for (var i = 0; i < entries.length; i++) {
        if (entries[i] && String(entries[i].id) === root.moduleName) return entries[i]
      }
    }
    return root.settings || {}
  }

  function persistSetting(key, value) {
    var live = currentEntry()
    var entry = { id: root.moduleName }
    for (var k in live) if (k !== "id") entry[k] = live[k]
    entry[key] = value
    root.settings = entry
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
    }
  }

  function cycleMode() {
    var live = currentEntry()

    var from = String(live.mode === undefined || live.mode === null ? mode : live.mode).trim().toLowerCase()
    if (modes.indexOf(from) === -1) from = mode
    var next = modes[(modes.indexOf(from) + 1) % modes.length]

    persistSetting("mode", next)
  }

  function toggleFahrenheit() {
    persistSetting("fahrenheit", !fahrenheit)
  }

  function launchMonitor() {
    if (clickCommand === "") {
      root.toggle()
      return
    }
    if (root.bar) root.bar.run(clickCommand)
    else Quickshell.execDetached(["bash", "-lc", clickCommand])
  }

  IpcHandler {
    target: "io.github.edgarsilva.hw-monitor"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function show(): void { root.open() }
    function hide(): void { root.close() }
    function toggle(): void { root.toggle() }
    function toggleFahrenheit(): void { root.toggleFahrenheit() }
    function refresh(): void { root.broadcast("refresh") }
    function cycleMode(): void { root.cycleMode() }
    function status(): string { return root.detail() }
  }

  // ------------------------------------------------------------------ layout

  readonly property int glyphBox: Math.max(Style.bar.iconCanvas, iconSize + Style.space(2))
  readonly property int contentHeight: Math.max(glyphBox, Style.space(15))
  readonly property int gaugeWidth: Math.max(6, Math.round(iconSize * 0.45))
  readonly property int gaugeHeight: Math.max(11, Math.round(iconSize * 0.9))

  visible: onThisScreen
  implicitWidth: onThisScreen ? button.implicitWidth : 0
  implicitHeight: button.implicitHeight

  WidgetButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    labelVisible: false
    hasVisualContent: root.cells.length > 0
    tooltipText: root.hint
    horizontalMargin: 6
    fixedWidth: root.vertical ? -1 : Math.ceil(horizontalCells.implicitWidth + button.scaledHorizontalMargin * 2)
    fixedHeight: root.vertical ? Math.ceil(verticalCells.implicitHeight + Style.space(8)) : -1

    onPressed: function(pressedButton) {
      if (pressedButton === Qt.RightButton) root.cycleMode()
      else if (pressedButton === Qt.MiddleButton) root.refresh()
      else root.launchMonitor()
    }

    Row {
      id: horizontalCells
      visible: !root.vertical
      anchors.centerIn: parent
      spacing: Style.space(root.mode === "icons" ? 14 : 8)

      Repeater {
        model: root.cells
        delegate: cell
      }
    }

    Column {
      id: verticalCells
      visible: root.vertical
      anchors.centerIn: parent
      spacing: Style.space(5)

      Repeater {
        model: root.cells
        delegate: cell
      }
    }
  }

  SystemPanel {
    id: systemPanel
    anchorItem: button
    bar: root.bar
    owner: root
    open: root.opened
    hw: hw
    mode: root.mode
    showGpu: root.showGpu
    showCpu: root.showCpu
    showCpuTemp: root.showCpuTemp
    showGpuTemp: root.showGpuTemp
    showRam: root.showRam
    showClocks: root.showClocks
    showGauges: root.showGauges
    ramFormat: root.ramFormat
    tempFormat: root.tempFormat
    fahrenheit: root.fahrenheit
    warnPercent: root.warnPercent
    criticalPercent: root.criticalPercent
    warnTempC: root.warnTempC
    criticalTempC: root.criticalTempC
  }

  // A component group: glyph + figure (+ temp)
  Component {
    id: cell

    Row {
      id: group
      required property var modelData
      spacing: Style.space(4)

      readonly property real slack: root.showValues && modelData.slotted
        ? Math.max(0, root.percentSlot - valueText.implicitWidth - spacing)
        : 0

      readonly property bool isTempCell: modelData.key === "cpu-temp" || modelData.key === "gpu-temp"

      TextMetrics {
        id: glyphMetrics
        font.family: root.fontFamily
        font.pixelSize: root.iconSize
        text: modelData.icon
      }

      Item {
        readonly property bool turned: Math.abs(modelData.iconRotation % 180) === 90
        readonly property real inkWidth: turned
          ? glyphMetrics.tightBoundingRect.height
          : glyphMetrics.tightBoundingRect.width

        visible: !root.labelled
        width: visible ? Math.max(1, Math.ceil(inkWidth)) : 0
        height: root.contentHeight

        OpticalGlyph {
          anchors.fill: parent
          visible: modelData.iconRotation === 0
          text: modelData.icon
          fontFamily: root.fontFamily
          fontSize: root.iconSize
          color: group.isTempCell
            ? root.tempColor(modelData.tempC)
            : root.warm(Color.accent, modelData.severity)
          Behavior on color { ColorAnimation { duration: 240 } }
        }

        Text {
          anchors.centerIn: parent
          visible: modelData.iconRotation !== 0
          rotation: modelData.iconRotation
          text: modelData.icon
          color: group.isTempCell
            ? root.tempColor(modelData.tempC)
            : root.warm(Color.accent, modelData.severity)
          font.family: root.fontFamily
          font.pixelSize: root.iconSize
          renderType: Text.NativeRendering
          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }

      Gauge {
        visible: root.showGauges && !root.labelled
        height: root.contentHeight
        bodyWidth: root.gaugeWidth
        bodyHeight: root.gaugeHeight
        ratio: modelData.ratio
        fillColor: group.isTempCell ? root.tempColor(modelData.tempC) : root.warm(root.base, modelData.severity)
        trackColor: Qt.rgba(root.base.r, root.base.g, root.base.b, 0.14)
        borderColor: Qt.rgba(root.base.r, root.base.g, root.base.b, 0.4)
        glow: modelData.severity >= 1
      }

      Text {
        visible: root.labelled
        height: root.contentHeight
        text: modelData.label
        color: root.dim
        font.family: root.fontFamily
        font.pixelSize: root.valueSize
        font.bold: true
        verticalAlignment: Text.AlignVCenter
        renderType: Text.NativeRendering
      }

      Row {
        visible: root.showValues
        height: root.contentHeight
        spacing: 0

        Text {
          visible: modelData.pad !== ""
          height: root.contentHeight
          text: modelData.pad
          color: root.warm(root.base, modelData.severity)
          opacity: root.padOpacity
          font.family: root.fontFamily
          font.pixelSize: root.valueSize
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
        }

        Text {
          id: valueText
          height: root.contentHeight
          text: modelData.value
          color: group.isTempCell
            ? root.tempColor(modelData.tempC)
            : root.warm(root.base, modelData.severity)
          font.family: root.fontFamily
          font.pixelSize: root.valueSize
          font.bold: !group.isTempCell
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }

      Row {
        visible: root.showClocks && modelData.clock !== ""
        height: root.contentHeight
        spacing: Style.space(2)

        Text {
          visible: root.clockIcon !== ""
          height: root.contentHeight
          leftPadding: Style.space(2)
          text: root.clockIcon
          color: root.warm(root.dim, modelData.severity)
          font.family: root.fontFamily
          font.pixelSize: root.valueSize
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
          Behavior on color { ColorAnimation { duration: 240 } }
        }

        Text {
          height: root.contentHeight
          text: modelData.clock
          color: root.warm(root.dim, modelData.severity)
          font.family: root.fontFamily
          font.pixelSize: root.valueSize
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }

      Row {
        visible: root.showTemps && modelData.temp !== ""
        height: root.contentHeight
        spacing: Style.space(3)

        Text {
          textFormat: Text.PlainText
          height: root.contentHeight
          text: "·"
          color: Qt.darker(root.base, 1.8)
          font.family: root.fontFamily
          font.pixelSize: root.valueSize
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
        }

        Text {
          textFormat: Text.PlainText
          height: root.contentHeight
          text: modelData.temp
          color: root.tempColor(modelData.tempC)
          font.family: root.fontFamily
          font.pixelSize: root.valueSize
          font.bold: false
          verticalAlignment: Text.AlignVCenter
          renderType: Text.NativeRendering
          Behavior on color { ColorAnimation { duration: 240 } }
        }
      }

      Item {
        visible: group.slack > 0
        width: visible ? group.slack : 0
        height: 1
      }
    }
  }
}
