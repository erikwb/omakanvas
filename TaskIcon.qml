pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes

Item {
  id: root

  property real iconSize: 24
  property color color: "white"
  property bool busy: false

  implicitWidth: iconSize
  implicitHeight: iconSize

  // One coordinate system for the checks, bullet, and animated bars.
  // Scale the whole drawing together; no font metrics or glyph clipping.
  Item {
    id: drawing
    anchors.centerIn: parent
    width: 924
    height: 780
    scale: Math.min(root.iconSize / 1000, root.width / width, root.height / height)

    Shape {
      anchors.fill: parent
      antialiasing: true

      ShapePath {
        strokeColor: root.color
        strokeWidth: 88
        fillColor: "transparent"
        capStyle: ShapePath.RoundCap
        joinStyle: ShapePath.RoundJoin
        startX: 44
        startY: 116
        PathLine { x: 117; y: 188 }
        PathLine { x: 244; y: 44 }
        PathMove { x: 44; y: 404 }
        PathLine { x: 117; y: 476 }
        PathLine { x: 244; y: 332 }
      }
    }

    Rectangle {
      x: 0
      y: 606
      width: 174
      height: 174
      radius: 87
      color: root.color
      antialiasing: true
    }

    Repeater {
      model: 3

      Rectangle {
        id: stroke
        required property int index
        property real progress: 0
        readonly property color dimColor: Qt.rgba(root.color.r, root.color.g,
          root.color.b, root.color.a * 0.3)

        x: index === 2 ? 288 : 404
        y: 58 + index * 288
        width: drawing.width - x
        height: 116
        radius: height / 2
        color: root.busy ? dimColor : root.color
        antialiasing: true

        Item {
          visible: root.busy
          width: stroke.width * stroke.progress
          height: stroke.height
          clip: true

          Rectangle {
            width: stroke.width
            height: stroke.height
            radius: stroke.radius
            color: root.color
            antialiasing: true
          }
        }

        SequentialAnimation on progress {
          running: root.busy && root.visible
          loops: Animation.Infinite
          NumberAnimation { to: 0; duration: 0 }
          PauseAnimation { duration: stroke.index * 180 }
          NumberAnimation { from: 0; to: 1; duration: 450; easing.type: Easing.InOutQuad }
          PauseAnimation { duration: (2 - stroke.index) * 180 + 250 }
        }
      }
    }
  }
}
