import QtQuick
import QtQuick.Shapes
import qs.Commons

// A 270-degree circular arc dial based on the SpeedTestOverlay pattern.
// Used in the system panel for CPU, GPU, and RAM readouts.
Item {
  id: root

  property string label: ""
  property real value: 0
  property real max: 100
  property string valueText: ""
  property string subText: ""
  property color baseColor: Color.foreground
  property color valueColor: baseColor
  property color subTextColor: Qt.darker(baseColor, 1.4)
  property color trackColor: Qt.rgba(baseColor.r, baseColor.g, baseColor.b, 0.14)
  property real diameter: Style.space(108)
  property real arcWidth: Math.max(3, Style.space(4))

  readonly property real fraction: max > 0 ? Math.max(0, Math.min(1, value / max)) : 0
  readonly property bool arcVisible: fraction > 0.004

  // 0° is 3 o'clock, increasing clockwise
  readonly property real dialStart: 135
  readonly property real dialSweep: 270
  readonly property real arcRadius: Math.max(1, (diameter / 2) - arcWidth)

  width: diameter
  height: diameter
  implicitWidth: diameter
  implicitHeight: diameter

  Shape {
    anchors.fill: parent
    preferredRendererType: Shape.CurveRenderer

    // Track: the full scale background arc
    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: root.trackColor
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep
      }
    }

    // Under-glow for the active value arc
    ShapePath {
      strokeWidth: root.arcWidth * 2.5
      strokeColor: root.arcVisible ? Qt.rgba(root.valueColor.r, root.valueColor.g, root.valueColor.b, 0.18) : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep * root.fraction
      }
    }

    // Value Arc
    ShapePath {
      strokeWidth: root.arcWidth
      strokeColor: root.arcVisible ? root.valueColor : "transparent"
      fillColor: "transparent"
      capStyle: ShapePath.RoundCap

      PathAngleArc {
        centerX: root.width / 2
        centerY: root.height / 2
        radiusX: root.arcRadius
        radiusY: root.arcRadius
        startAngle: root.dialStart
        sweepAngle: root.dialSweep * root.fraction
      }
    }
  }

  Column {
    anchors.centerIn: parent
    spacing: Style.space(1)

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.label.toUpperCase()
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      font.letterSpacing: 1.1
      color: Qt.darker(root.baseColor, 1.4)
    }

    Text {
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.valueText !== "" ? root.valueText : (root.value >= 0 ? Math.round(root.value) + "%" : "–")
      font.family: Style.font.family
      font.pixelSize: Style.font.title
      font.bold: true
      color: root.valueColor
      Behavior on color { ColorAnimation { duration: 240 } }
    }

    Text {
      visible: root.subText !== ""
      textFormat: Text.PlainText
      anchors.horizontalCenter: parent.horizontalCenter
      text: root.subText
      font.family: Style.font.family
      font.pixelSize: Style.font.caption
      font.bold: true
      color: root.subTextColor
      Behavior on color { ColorAnimation { duration: 240 } }
    }
  }
}
