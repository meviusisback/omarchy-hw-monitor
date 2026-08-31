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
  contentWidth: fittedContentWidth(Style.space(420))
  contentHeight: fittedContentHeight(panelColumn.implicitHeight, Style.space(680))

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
      Controls.ScrollBar.vertical.policy: panelColumn.implicitHeight > height ? Controls.ScrollBar.AsNeeded : Controls.ScrollBar.AlwaysOff

      Column {
        id: panelColumn
        width: scrollArea.width
        spacing: Style.space(12)

        // 1. Header with Processor Name and °C/°F Unit Toggle
        Row {
          width: parent.width
          spacing: Style.space(12)

          Text {
            textFormat: Text.PlainText
            text: ""
            color: root.baseColor
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
              checked: root.fahrenheit
              trackHeight: Style.space(16)
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

        // 2. Three Dials
        Row {
          id: dialsRow
          anchors.horizontalCenter: parent.horizontalCenter
          spacing: Style.space(10)

          readonly property real dialSize: Math.floor((panelColumn.width - spacing * 2) / 3)

          Dial {
            label: "CPU"
            diameter: dialsRow.dialSize
            value: hw.cpuPercent >= 0 ? hw.cpuPercent : 0
            valueText: hw.cpuPercent >= 0 ? Math.round(hw.cpuPercent) + "%" : "–"
            subText: hw.cpuTempC > 0
              ? (Model.formatTemp(hw.cpuTempC, root.fahrenheit) + (root.fahrenheit ? "°F" : "°C"))
              : (hw.cpuMhz > 0 ? Model.formatGhzShort(hw.cpuMhz) + " GHz" : "")
            baseColor: root.baseColor
            valueColor: root.warm(root.baseColor, Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent))
            subTextColor: hw.cpuTempC > 0 ? root.tempColor(hw.cpuTempC) : Qt.darker(root.baseColor, 1.4)
          }

          Dial {
            label: "RAM"
            diameter: dialsRow.dialSize
            value: hw.memPercent >= 0 ? hw.memPercent : 0
            valueText: hw.memPercent >= 0 ? Math.round(hw.memPercent) + "%" : "–"
            subText: hw.memory
              ? (Model.formatGib(Model.gibFromKib(hw.memory.usedKib)) + "/" + Model.formatGib(Model.gibFromKib(hw.memory.totalKib)) + "G")
              : ""
            baseColor: root.baseColor
            valueColor: root.warm(root.baseColor, Model.severity(hw.memPercent, root.warnPercent, root.criticalPercent))
            subTextColor: Qt.darker(root.baseColor, 1.4)
          }

          Dial {
            label: "GPU"
            diameter: dialsRow.dialSize
            value: hw.hasGpu
              ? (hw.gpuPercent >= 0 ? hw.gpuPercent : (hw.gpuVramPercent >= 0 ? hw.gpuVramPercent : 0))
              : 0
            valueText: hw.hasGpu
              ? (hw.gpuPercent >= 0 ? Math.round(hw.gpuPercent) + "%" : (hw.gpuVramPercent >= 0 ? Math.round(hw.gpuVramPercent) + "%" : "–"))
              : "N/A"
            subText: hw.hasGpu && hw.gpuTempC > 0
              ? (Model.formatTemp(hw.gpuTempC, root.fahrenheit) + (root.fahrenheit ? "°F" : "°C"))
              : (hw.hasGpu && hw.gpuWatts >= 0 ? Model.formatWatts(hw.gpuWatts) : "")
            baseColor: root.baseColor
            valueColor: hw.hasGpu
              ? root.warm(root.baseColor, Math.max(Model.severity(hw.gpuPercent, root.warnPercent, root.criticalPercent),
                                                   Model.severity(hw.gpuTempC, root.warnTempC, root.criticalTempC)))
              : Qt.darker(root.baseColor, 1.4)
            subTextColor: (hw.hasGpu && hw.gpuTempC > 0) ? root.tempColor(hw.gpuTempC) : Qt.darker(root.baseColor, 1.4)
          }
        }

        // 3. History Sparkline
        PanelSeparator { foreground: root.baseColor }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "CPU LOAD (60s HISTORY)"
            foreground: root.baseColor
            fontFamily: root.fontFamily
          }

          Item {
            id: sparklineBox
            width: parent.width
            implicitHeight: Style.space(48)

            Rectangle {
              anchors.fill: parent
              radius: Style.cornerRadius
              color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.04)
              border.width: 1
              border.color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)
            }

            // 50% guideline
            Rectangle {
              anchors.verticalCenter: parent.verticalCenter
              anchors.left: parent.left
              anchors.right: parent.right
              anchors.margins: Style.space(4)
              height: 1
              color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.08)
            }

            Text {
              textFormat: Text.PlainText
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(3)
              text: "100%"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.baseColor, 1.6)
            }

            Text {
              textFormat: Text.PlainText
              anchors.verticalCenter: parent.verticalCenter
              anchors.right: parent.right
              anchors.rightMargin: Style.space(3)
              text: "50%"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.baseColor, 1.6)
            }

            Text {
              textFormat: Text.PlainText
              anchors.bottom: parent.bottom
              anchors.left: parent.left
              anchors.margins: Style.space(3)
              text: "60s"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.baseColor, 1.6)
            }

            Text {
              textFormat: Text.PlainText
              anchors.bottom: parent.bottom
              anchors.right: parent.right
              anchors.margins: Style.space(3)
              text: "now"
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              color: Qt.darker(root.baseColor, 1.6)
            }

            Shape {
              anchors.fill: parent
              preferredRendererType: Shape.CurveRenderer
              visible: root.sparklinePoints.length >= 2

              ShapePath {
                strokeColor: "transparent"
                fillColor: Qt.rgba(Color.accent.r, Color.accent.g, Color.accent.b, 0.12)
                startX: Style.space(4)
                startY: sparklineBox.height - Style.space(4)

                PathPolyline {
                  path: root.sparklineFillPoints
                }
              }

              ShapePath {
                strokeWidth: Math.max(1.5, Style.space(2))
                strokeColor: root.warm(Color.accent, Model.severity(hw.cpuPercent, root.warnPercent, root.criticalPercent))
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

        // 4. Processor Section
        PanelSeparator { foreground: root.baseColor }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "PROCESSOR"
            foreground: root.baseColor
            fontFamily: root.fontFamily
          }

          Row {
            width: parent.width
            spacing: Style.space(16)

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap

              InfoPair { label: "Load"; value: Model.formatPercent(hw.cpuPercent) }
              InfoPair { label: "Clock"; value: hw.cpuMhz > 0 ? Model.formatGhz(hw.cpuMhz) : "–" }
              InfoPair {
                label: "Cores";
                value: hw.cpuInfo ? (hw.cpuInfo.cores + "C / " + hw.cpuInfo.threads + "T") : "–"
              }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap

              InfoPair {
                label: "Temperature"
                value: hw.cpuTempC > 0 ? (Model.formatTemp(hw.cpuTempC, root.fahrenheit) + (root.fahrenheit ? "°F" : "°C")) : "–"
                valueColor: root.tempColor(hw.cpuTempC)
              }
              InfoPair {
                label: "Load Avg"
                value: hw.load ? (hw.load.one.toFixed(2) + "  " + hw.load.five.toFixed(2) + "  " + hw.load.fifteen.toFixed(2)) : "–"
              }
            }
          }

          // 1/5/15 Load Average Meters
          Row {
            visible: hw.load !== null
            width: parent.width
            spacing: Style.space(8)

            readonly property real threads: hw.cpuInfo && hw.cpuInfo.threads > 0 ? hw.cpuInfo.threads : 1
            readonly property real cellWidth: (width - spacing * 2) / 3

            Column {
              width: parent.cellWidth
              spacing: Style.space(2)

              Row {
                width: parent.width
                Text {
                  textFormat: Text.PlainText
                  text: "1m"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: Qt.darker(root.baseColor, 1.4)
                }
                Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth); height: 1 }
                Text {
                  textFormat: Text.PlainText
                  text: hw.load ? hw.load.one.toFixed(2) : "0.00"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.baseColor
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  radius: parent.radius
                  color: root.warm(root.baseColor, hw.load ? (hw.load.one / parent.parent.threads) - 0.7 : 0)
                  width: hw.load ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.load.one / parent.parent.threads))) : 0
                }
              }
            }

            Column {
              width: parent.cellWidth
              spacing: Style.space(2)

              Row {
                width: parent.width
                Text {
                  textFormat: Text.PlainText
                  text: "5m"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: Qt.darker(root.baseColor, 1.4)
                }
                Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth); height: 1 }
                Text {
                  textFormat: Text.PlainText
                  text: hw.load ? hw.load.five.toFixed(2) : "0.00"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.baseColor
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  radius: parent.radius
                  color: root.warm(root.baseColor, hw.load ? (hw.load.five / parent.parent.threads) - 0.7 : 0)
                  width: hw.load ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.load.five / parent.parent.threads))) : 0
                }
              }
            }

            Column {
              width: parent.cellWidth
              spacing: Style.space(2)

              Row {
                width: parent.width
                Text {
                  textFormat: Text.PlainText
                  text: "15m"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                  color: Qt.darker(root.baseColor, 1.4)
                }
                Item { width: Math.max(0, parent.width - parent.children[0].implicitWidth - parent.children[2].implicitWidth); height: 1 }
                Text {
                  textFormat: Text.PlainText
                  text: hw.load ? hw.load.fifteen.toFixed(2) : "0.00"
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  color: root.baseColor
                }
              }

              Rectangle {
                width: parent.width
                height: Style.space(4)
                radius: height / 2
                color: Qt.rgba(root.baseColor.r, root.baseColor.g, root.baseColor.b, 0.12)

                Rectangle {
                  anchors.left: parent.left
                  anchors.top: parent.top
                  anchors.bottom: parent.bottom
                  radius: parent.radius
                  color: root.warm(root.baseColor, hw.load ? (hw.load.fifteen / parent.parent.threads) - 0.7 : 0)
                  width: hw.load ? Math.max(parent.height, Math.min(parent.width, parent.width * (hw.load.fifteen / parent.parent.threads))) : 0
                }
              }
            }
          }
        }

        // 5. Memory Section
        PanelSeparator { foreground: root.baseColor }

        Column {
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "MEMORY"
            foreground: root.baseColor
            fontFamily: root.fontFamily
          }

          // Used / Total RAM progress bar
          Column {
            width: parent.width
            spacing: Style.space(3)

            InfoPair {
              label: "Used / Total"
              value: hw.memory
                ? (Model.formatGibPrecise(Model.gibFromKib(hw.memory.usedKib)) + " / " + Model.formatGibPrecise(Model.gibFromKib(hw.memory.totalKib)) + " GiB (" + Math.round(hw.memPercent) + "%)")
                : "–"
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
                label: "Cached"
                value: hw.memory ? (Model.formatGib(Model.gibFromKib(hw.memory.cachedKib)) + " GiB") : "–"
              }
            }

            Column {
              width: (parent.width - parent.spacing) / 2
              spacing: Style.spacing.labelGap

              InfoPair {
                label: "Swap Total"
                value: hw.memory && hw.memory.swapTotalKib > 0
                  ? (Model.formatGib(Model.gibFromKib(hw.memory.swapTotalKib)) + " GiB")
                  : "None"
              }
              InfoPair {
                label: "Swap Used"
                value: hw.memory && hw.memory.swapTotalKib > 0
                  ? (Model.formatGib(Model.gibFromKib(hw.memory.swapUsedKib)) + " GiB (" + Math.round(100 * hw.memory.swapUsedKib / hw.memory.swapTotalKib) + "%)")
                  : "–"
              }
            }
          }
        }

        // 6. GPU Section with Full Characteristics (only shown when GPU is present)
        PanelSeparator {
          visible: hw.hasGpu
          foreground: root.baseColor
        }

        Column {
          visible: hw.hasGpu
          width: parent.width
          spacing: Style.space(6)

          PanelSectionHeader {
            text: "GRAPHICS"
            foreground: root.baseColor
            fontFamily: root.fontFamily
          }

          // Full GPU model name (wrapped without cutoff)
          Text {
            visible: hw.gpuInfo && hw.gpuInfo.name !== ""
            width: parent.width
            wrapMode: Text.Wrap
            text: String(hw.gpuInfo ? hw.gpuInfo.name : "")
            color: root.baseColor
            font.family: root.fontFamily
            font.pixelSize: Style.font.bodySmall
            font.bold: true
          }

          // VRAM progress bar if total VRAM is known
          Column {
            visible: hw.gpuVramTotalBytes > 0
            width: parent.width
            spacing: Style.space(3)

            InfoPair {
              label: "VRAM Used / Total"
              value: hw.gpuVramTotalBytes > 0
                ? (Model.formatGibPrecise(Model.gibFromBytes(hw.gpuVramUsedBytes)) + " / " + Model.formatGibPrecise(Model.gibFromBytes(hw.gpuVramTotalBytes)) + " GiB (" + Math.round(hw.gpuVramPercent) + "%)")
                : "–"
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
                value: hw.gpuTempC > 0 ? (Model.formatTemp(hw.gpuTempC, root.fahrenheit) + (root.fahrenheit ? "°F" : "°C")) : "–"
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
    }
  }

  component InfoPair: Row {
    property string label: ""
    property string value: ""
    property color valueColor: root.baseColor

    width: parent.width
    spacing: Style.space(8)

    Text {
      textFormat: Text.PlainText
      text: label
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
      text: value
      color: valueColor
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }
}
