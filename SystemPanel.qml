import QtQuick
import QtQuick.Controls as Controls
import QtQuick.Shapes
import Quickshell
import Quickshell.Io
import qs.Ui
import qs.Commons
import "Model.js" as Model

// First-class Omarchy system popup panel displaying visual telemetry for CPU,
// GPU, Memory, and live CPU load history.
KeyboardPanel {
  id: root

  required property QtObject hw
  property bool fahrenheit: false
  property int warnPercent: 70
  property int criticalPercent: 90
  property int warnTempC: 75
  property int criticalTempC: 90

  signal fahrenheitToggled()

  function toggleFahrenheit() {
    if (root.owner && typeof root.owner.toggleFahrenheit === "function") {
      root.owner.toggleFahrenheit()
    } else {
      root.fahrenheit = !root.fahrenheit
    }
  }

  readonly property color baseColor: root.bar ? root.bar.foreground : Color.foreground
  readonly property color hotColor: root.bar ? root.bar.urgent : Color.urgent
  readonly property color dimColor: Qt.darker(baseColor, 1.45)
  readonly property string fontFamily: root.bar ? root.bar.fontFamily : Style.font.family

  function warm(from, amount) {
    if (!(amount > 0)) return from
    var t = Math.min(1, amount)
    return Qt.rgba(from.r + (hotColor.r - from.r) * t,
                   from.g + (hotColor.g - from.g) * t,
                   from.b + (hotColor.b - from.b) * t,
                   from.a)
  }

  function tempColor(tempC) {
    if (!isFinite(tempC) || tempC <= 0) return dimColor
    if (tempC < 50) return dimColor
    var t = Math.min(1, Math.max(0, (tempC - 50) / Math.max(1, criticalTempC - 50)))
    return Qt.rgba(baseColor.r + (hotColor.r - baseColor.r) * t,
                   baseColor.g + (hotColor.g - baseColor.g) * t,
                   baseColor.b + (hotColor.b - baseColor.b) * t,
                   baseColor.a)
  }

  // Ring buffer for the last 60 seconds of CPU samples.
  // Sampled while the panel is open; cleared when closed to avoid background overhead.
  property var cpuHistory: []

  readonly property var sparklinePoints: {
    var list = []
    var n = cpuHistory ? cpuHistory.length : 0
    if (n < 2) return list
    var w = sparklineBox.width - Style.space(8)
    var h = sparklineBox.height - Style.space(8)
    for (var i = 0; i < n; i++) {
      var px = Style.space(4) + (i / (n - 1)) * w
      var v = Math.max(0, Math.min(100, Number(cpuHistory[i]) || 0))
      var py = Style.space(4) + h - (v / 100) * h
      list.push(Qt.point(px, py))
    }
    return list
  }

  readonly property point sparklineFirst: sparklinePoints.length > 0 ? sparklinePoints[0] : Qt.point(0, sparklineBox.height)

  readonly property var sparklineFillPoints: {
    if (sparklinePoints.length < 2) return []
    var list = sparklinePoints.slice()
    var w = sparklineBox.width - Style.space(4)
    var h = sparklineBox.height - Style.space(4)
    list.push(Qt.point(w, h))
    list.push(Qt.point(Style.space(4), h))
    return list
  }

  onOpenChanged: {
    if (open) {
      hw.sample()
      var initial = hw.cpuPercent >= 0 ? hw.cpuPercent : 0
      root.cpuHistory = [initial, initial]
    } else {
      root.cpuHistory = []
    }
  }

  focusTarget: keyCatcher
  contentWidth: fittedContentWidth(Style.space(430))
  contentHeight: fittedContentHeight(panelColumn.implicitHeight + Style.space(16), Style.space(960))

  PanelKeyCatcher {
    id: keyCatcher
    anchors.fill: parent
    onCloseRequested: root.close()
    onTabRequested: function(direction) { root.switchPanel(direction) }
    onTextKey: function(t) {
      if (t === "r" || t === "R") {
        hw.sample()
      } else if (t === "c" || t === "C" || t === "f" || t === "F") {
        root.toggleFahrenheit()
      }
    }

    Timer {
      id: historyTimer
      interval: 1000
      repeat: true
      running: root.open
      onTriggered: {
        hw.sample()
        var cur = hw.cpuPercent >= 0 ? hw.cpuPercent : 0
        var arr = root.cpuHistory.slice()
        arr.push(cur)
        if (arr.length > 60) arr.shift()
        root.cpuHistory = arr
      }
    }

    Component.onDestruction: historyTimer.stop()

    Controls.ScrollView {
      id: scrollArea
      anchors.fill: parent
      clip: true
      Controls.ScrollBar.horizontal.policy: Controls.ScrollBar.AlwaysOff
      Controls.ScrollBar.vertical.policy: panelColumn.implicitHeight > scrollArea.height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff

      Binding {
        target: scrollArea.contentItem
        property: "interactive"
        value: panelColumn.implicitHeight > scrollArea.height
      }

      Column {
        id: panelColumn
        width: scrollArea.availableWidth
        spacing: Style.space(12)

        // 1. Header with Processor Name and °C/°F Unit Toggle
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: ""
            color: Color.accent
            font.family: root.fontFamily
            font.pixelSize: Style.font.display
            anchors.verticalCenter: parent.verticalCenter
          }

          Column {
            width: Math.max(0, parent.width - Style.font.display - Style.space(12) - unitToggleRow.implicitWidth - Style.space(12))
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(2)

            Text {
              textFormat: Text.PlainText
              text: "Hardware"
              color: root.baseColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.title
              font.bold: true
            }

            Text {
              textFormat: Text.PlainText
              width: parent.width
              wrapMode: Text.Wrap
              text: hw.cpuInfo && hw.cpuInfo.model ? hw.cpuInfo.model : "System Telemetry"
              color: root.dimColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: true
            }
          }

          Item {
            height: 1
            width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[1].width - unitToggleRow.implicitWidth - Style.space(24))
          }

          Row {
            id: unitToggleRow
            spacing: Style.space(6)
            anchors.verticalCenter: parent.verticalCenter

            Text {
              textFormat: Text.PlainText
              text: "°C"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: !root.fahrenheit
              color: !root.fahrenheit ? root.baseColor : Qt.darker(root.baseColor, 1.8)
              anchors.verticalCenter: parent.verticalCenter
            }

            ToggleSwitch {
              id: unitSwitch
              checked: root.fahrenheit
              anchors.verticalCenter: parent.verticalCenter
              onToggled: root.toggleFahrenheit()
            }

            Text {
              textFormat: Text.PlainText
              text: "°F"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              font.bold: root.fahrenheit
              color: root.fahrenheit ? root.baseColor : Qt.darker(root.baseColor, 1.8)
              anchors.verticalCenter: parent.verticalCenter
            }
          }
        }

        // 2. Primary Telemetry Dials (CPU, RAM, GPU)
        Row {
          width: parent.width
          spacing: Style.space(8)

          Dial {
            id: cpuDial
            width: (parent.width - parent.spacing * 2) / 3
            title: "CPU"
            valueText: hw.cpuPercent >= 0 ? Math.round(hw.cpuPercent) + "%" : "–"
            subText: hw.cpuTempC > 0 ? Model.formatTemp(hw.cpuTempC, root.fahrenheit) : ""
            subTextColor: root.tempColor(hw.cpuTempC)
            ratio: hw.cpuPercent >= 0 ? hw.cpuPercent / 100 : 0
            baseColor: root.baseColor
            hotColor: root.hotColor
            accentColor: Color.accent
            severity: Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent)
            fontFamily: root.fontFamily
          }

          Dial {
            id: memDial
            width: (parent.width - parent.spacing * 2) / 3
            title: "RAM"
            valueText: hw.memPercent >= 0 ? Math.round(hw.memPercent) + "%" : "–"
            subText: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.usedKib)) + "/" + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + "G") : ""
            subTextColor: root.dimColor
            ratio: hw.memPercent >= 0 ? hw.memPercent / 100 : 0
            baseColor: root.baseColor
            hotColor: root.hotColor
            accentColor: Color.accent
            severity: Model.severity(hw.memPercent, root.warnPercent, root.criticalPercent)
            fontFamily: root.fontFamily
          }

          Dial {
            id: gpuDial
            width: (parent.width - parent.spacing * 2) / 3
            title: "GPU"
            valueText: hw.hasGpu ? (hw.gpuPercent >= 0 ? Math.round(hw.gpuPercent) + "%" : (hw.gpuVramPercent >= 0 ? Math.round(hw.gpuVramPercent) + "%" : "–")) : "N/A"
            subText: hw.hasGpu && hw.gpuTempC > 0 ? Model.formatTemp(hw.gpuTempC, root.fahrenheit) : (hw.hasGpu && hw.gpuWatts >= 0 ? Model.formatWatts(hw.gpuWatts) : "")
            subTextColor: root.tempColor(hw.gpuTempC)
            ratio: hw.hasGpu ? (hw.gpuPercent >= 0 ? hw.gpuPercent / 100 : (hw.gpuVramPercent >= 0 ? hw.gpuVramPercent / 100 : 0)) : 0
            baseColor: root.baseColor
            hotColor: root.hotColor
            accentColor: Color.accent
            severity: hw.hasGpu ? Model.severity(hw.gpuPercent >= 0 ? hw.gpuPercent : hw.gpuVramPercent, root.warnPercent, root.criticalPercent) : 0
            fontFamily: root.fontFamily
          }
        }

        // 3. CPU Load History Sparkline (60s)
        Rectangle {
          width: parent.width
          implicitHeight: sparklineCol.implicitHeight + Style.space(24)
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
          border.width: 1
          radius: Style.cornerRadius

          Column {
            id: sparklineCol
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(8)

            Row {
              width: parent.width

              Text {
                textFormat: Text.PlainText
                text: "CPU Load History (60s)"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Item {
                width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                height: 1
              }

              Text {
                textFormat: Text.PlainText
                text: hw.cpuPercent >= 0 ? (Math.round(hw.cpuPercent) + "% current") : "–"
                color: root.warm(root.baseColor, Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent))
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }
            }

            Item {
              id: sparklineBox
              width: parent.width
              height: Style.space(55)

              // Background grid lines
              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                y: parent.height * 0.25
                height: 1
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.08)
              }
              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                y: parent.height * 0.50
                height: 1
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.08)
              }
              Rectangle {
                anchors.left: parent.left
                anchors.right: parent.right
                y: parent.height * 0.75
                height: 1
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.08)
              }

              // Sparkline fill area
              Shape {
                anchors.fill: parent
                visible: root.sparklinePoints.length >= 2
                layer.enabled: true
                layer.samples: 4

                ShapePath {
                  strokeWidth: 0
                  strokeColor: "transparent"
                  fillColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.18)

                  startX: root.sparklineFirst.x
                  startY: root.sparklineFirst.y

                  PathPolyline {
                    path: root.sparklineFillPoints
                  }
                }
              }

              // Sparkline stroke line
              Shape {
                anchors.fill: parent
                visible: root.sparklinePoints.length >= 2
                layer.enabled: true
                layer.samples: 4

                ShapePath {
                  strokeWidth: Style.space(2)
                  strokeColor: Color.accent
                  fillColor: "transparent"
                  capStyle: ShapePath.RoundCap
                  joinStyle: ShapePath.RoundJoin

                  startX: root.sparklineFirst.x
                  startY: root.sparklineFirst.y

                  PathPolyline {
                    path: root.sparklinePoints
                  }
                }
              }
            }
          }
        }

        // 4. Processor Topology & Load Average
        Rectangle {
          width: parent.width
          implicitHeight: procCol.implicitHeight + Style.space(24)
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
          border.width: 1
          radius: Style.cornerRadius

          Column {
            id: procCol
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Processor"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // Specs
            Row {
              width: parent.width
              spacing: Style.space(16)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair {
                  label: "Cores"
                  value: hw.cpuInfo ? (hw.cpuInfo.cores + "C / " + hw.cpuInfo.threads + "T") : "–"
                }
                InfoPair {
                  label: "Avg Clock"
                  value: hw.cpuMhz > 0 ? Model.formatGhz(hw.cpuMhz) : "–"
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair {
                  label: "Temperature"
                  value: hw.cpuTempC > 0 ? Model.formatTemp(hw.cpuTempC, root.fahrenheit) : "–"
                  valueColor: root.tempColor(hw.cpuTempC)
                }
                InfoPair {
                  label: "Cur Load"
                  value: hw.cpuPercent >= 0 ? Model.formatPercent(hw.cpuPercent) : "–"
                  valueColor: root.warm(root.baseColor, Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent))
                }
              }
            }

            // Load average 1m, 5m, 15m
            Column {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "Load Average (1m · 5m · 15m)"
                color: Qt.darker(root.baseColor, 1.4)
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
                font.bold: true
              }

              Row {
                width: parent.width
                spacing: Style.space(8)

                readonly property real maxCores: hw.cpuInfo && hw.cpuInfo.threads ? hw.cpuInfo.threads : 8

                LoadMeter {
                  id: lm1
                  width: (parent.width - parent.spacing * 2) / 3
                  period: "1 min"
                  value: hw.load ? hw.load.one : 0
                  maxVal: parent.maxCores
                  baseColor: root.baseColor
                  hotColor: root.hotColor
                  fontFamily: root.fontFamily
                }

                LoadMeter {
                  id: lm5
                  width: (parent.width - parent.spacing * 2) / 3
                  period: "5 min"
                  value: hw.load ? hw.load.five : 0
                  maxVal: parent.maxCores
                  baseColor: root.baseColor
                  hotColor: root.hotColor
                  fontFamily: root.fontFamily
                }

                LoadMeter {
                  id: lm15
                  width: (parent.width - parent.spacing * 2) / 3
                  period: "15 min"
                  value: hw.load ? hw.load.fifteen : 0
                  maxVal: parent.maxCores
                  baseColor: root.baseColor
                  hotColor: root.hotColor
                  fontFamily: root.fontFamily
                }
              }
            }
          }
        }

        // 5. Memory & Swap Breakdown
        Rectangle {
          width: parent.width
          implicitHeight: memCol.implicitHeight + Style.space(24)
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
          border.width: 1
          radius: Style.cornerRadius

          Column {
            id: memCol
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: ""
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: "Memory & Storage Cache"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // RAM horizontal split progress
            Column {
              width: parent.width
              spacing: Style.space(4)

              Row {
                width: parent.width

                Text {
                  textFormat: Text.PlainText
                  text: "RAM Usage"
                  color: Qt.darker(root.baseColor, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Item {
                  width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                  height: 1
                }

                Text {
                  textFormat: Text.PlainText
                  text: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.usedKib)) + " / " + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + " GiB (" + Math.round(hw.memPercent) + "%)") : "–"
                  color: root.warm(root.baseColor, Model.severity(hw.memPercent, root.warnPercent, root.criticalPercent))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  radius: parent.radius
                  color: root.warm(root.baseColor, Model.severity(hw.memPercent, root.warnPercent, root.criticalPercent))
                  width: hw.memPercent >= 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.memPercent / 100))) : 0
                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }
              }
            }

            // Details
            Row {
              width: parent.width
              spacing: Style.space(16)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair {
                  label: "Available"
                  value: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.availableKib)) + " GiB") : "–"
                }
                InfoPair {
                  label: "Page Cache"
                  value: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.cachedKib)) + " GiB") : "–"
                }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair {
                  label: "Swap Used"
                  value: hw.memory && hw.memory.swapTotalKib > 0 ? (Model.formatGib(Model.gibFromKib(hw.memory.swapUsedKib)) + " GiB") : "0 GiB"
                }
                InfoPair {
                  label: "Swap Total"
                  value: hw.memory && hw.memory.swapTotalKib > 0 ? (Model.formatGib(Model.gibFromKib(hw.memory.swapTotalKib)) + " GiB") : "None"
                }
              }
            }
          }
        }

        // 6. Graphics Telemetry Section (if GPU present)
        Rectangle {
          width: parent.width
          implicitHeight: gpuCol.implicitHeight + Style.space(24)
          color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
          border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.10)
          border.width: 1
          radius: Style.cornerRadius
          visible: hw.hasGpu

          Column {
            id: gpuCol
            anchors.fill: parent
            anchors.margins: Style.space(12)
            spacing: Style.space(10)

            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                textFormat: Text.PlainText
                text: "󰾲"
                color: Color.accent
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                anchors.verticalCenter: parent.verticalCenter
              }

              Text {
                textFormat: Text.PlainText
                text: hw.gpuInfo && hw.gpuInfo.name ? hw.gpuInfo.name : "Graphics Adapter"
                color: root.baseColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
                font.bold: true
                wrapMode: Text.Wrap
                anchors.verticalCenter: parent.verticalCenter
              }
            }

            // VRAM Meter
            Column {
              width: parent.width
              spacing: Style.space(4)
              visible: hw.gpuVramTotalBytes > 0

              Row {
                width: parent.width

                Text {
                  textFormat: Text.PlainText
                  text: "VRAM"
                  color: Qt.darker(root.baseColor, 1.4)
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Item {
                  width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
                  height: 1
                }

                Text {
                  textFormat: Text.PlainText
                  text: hw.gpuVramTotalBytes > 0 ? (Model.formatGib(Model.gibFromBytes(hw.gpuVramUsedBytes)) + " / " + Model.formatGib(Model.gibFromBytes(hw.gpuVramTotalBytes)) + " GiB (" + Math.round(hw.gpuVramPercent) + "%)") : "–"
                  color: root.warm(root.baseColor, Model.severity(hw.gpuVramPercent, root.warnPercent, root.criticalPercent))
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(6)
                radius: height / 2
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  radius: parent.radius
                  color: root.warm(root.baseColor, Model.severity(hw.gpuVramPercent, root.warnPercent, root.criticalPercent))
                  width: hw.gpuVramPercent >= 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.gpuVramPercent / 100))) : 0
                  Behavior on width { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                }
              }
            }

            Row {
              width: parent.width
              spacing: Style.space(16)

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "Load"; value: hw.gpuPercent >= 0 ? Model.formatPercent(hw.gpuPercent) : "–" }
                InfoPair {
                  label: "Temperature"
                  value: hw.gpuTempC > 0 ? Model.formatTemp(hw.gpuTempC, root.fahrenheit) : "–"
                  valueColor: root.tempColor(hw.gpuTempC)
                }
                InfoPair { label: "Power"; value: hw.gpuWatts >= 0 ? Model.formatWatts(hw.gpuWatts) : "–" }
              }

              Column {
                width: (parent.width - parent.spacing) / 2
                spacing: Style.spacing.labelGap

                InfoPair { label: "Clock"; value: hw.gpuMhz > 0 ? Model.formatGhz(hw.gpuMhz) : "–" }
                InfoPair { label: "Fan"; value: hw.gpuRpm >= 0 ? Model.formatRpm(hw.gpuRpm) : "–" }
                InfoPair { label: "Driver"; value: hw.gpuInfo && hw.gpuInfo.kind ? String(hw.gpuInfo.kind) : "–" }
              }
            }
          }
        }

        // Bottom breathing room spacer to guarantee zero clipping
        Item {
          width: parent.width
          height: Style.space(12)
        }
      }
    }
  }

  component InfoPair: Row {
    id: infoPairRoot
    property string label: ""
    property string value: ""
    property color valueColor: root.baseColor

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: infoPairRoot.label
      color: Qt.darker(root.baseColor, 1.4)
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      font.bold: true
    }

    Item {
      width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth - parent.spacing * 2)
      height: 1
    }

    Text {
      textFormat: Text.PlainText
      text: infoPairRoot.value
      color: infoPairRoot.valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }

  component LoadMeter: Column {
    id: meterRoot
    property string period: ""
    property real value: 0
    property real maxVal: 8
    property color baseColor: Color.foreground
    property color hotColor: Color.urgent
    property string fontFamily: Style.font.family

    spacing: Style.space(4)

    Row {
      width: parent.width

      Text {
        textFormat: Text.PlainText
        text: meterRoot.period
        color: Qt.darker(meterRoot.baseColor, 1.4)
        font.family: meterRoot.fontFamily
        font.pixelSize: Style.font.caption
      }

      Item {
        width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth)
        height: 1
      }

      Text {
        textFormat: Text.PlainText
        text: meterRoot.value.toFixed(2)
        color: meterRoot.baseColor
        font.family: meterRoot.fontFamily
        font.pixelSize: Style.font.caption
        font.bold: true
      }
    }

    Rectangle {
      width: parent.width
      height: Style.space(4)
      radius: height / 2
      color: Qt.rgba(meterRoot.baseColor.r, meterRoot.baseColor.g, meterRoot.baseColor.b, 0.12)

      Rectangle {
        anchors.left: parent.left
        anchors.top: parent.top
        anchors.bottom: parent.bottom
        radius: parent.radius
        color: {
          var ratio = meterRoot.maxVal > 0 ? Math.min(1, meterRoot.value / meterRoot.maxVal) : 0
          return Qt.rgba(meterRoot.baseColor.r + (meterRoot.hotColor.r - meterRoot.baseColor.r) * ratio,
                         meterRoot.baseColor.g + (meterRoot.hotColor.g - meterRoot.baseColor.g) * ratio,
                         meterRoot.baseColor.b + (meterRoot.hotColor.b - meterRoot.baseColor.b) * ratio,
                         meterRoot.baseColor.a)
        }
        width: meterRoot.maxVal > 0 ? Math.max(parent.height, Math.min(parent.width, parent.width * Math.min(1, meterRoot.value / meterRoot.maxVal))) : 0
        Behavior on width { NumberAnimation { duration: 240 } }
      }
    }
  }
}
