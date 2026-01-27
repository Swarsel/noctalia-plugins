import QtQuick
import QtQuick.Layouts
import Quickshell
import qs.Commons
import qs.Widgets

Item {
  id: root

  property var pluginApi: null
  property ShellScreen screen
  property string widgetId: ""
  property string section: ""

  readonly property string barPosition: Settings.getBarPositionForScreen(screen.name)
  readonly property bool barIsVertical: barPosition === "left" || barPosition === "right"

  readonly property real contentWidth: Style.getCapsuleHeightForScreen(screen.name)
  readonly property real contentHeight: Style.getCapsuleHeightForScreen(screen.name)

  implicitWidth: contentWidth
  implicitHeight: contentHeight

  Connections {
    target: Color
    function onMOnHoverChanged() { }
    function onMOnSurfaceChanged() { }
  }

  Rectangle {
    id: visualCapsule
    x: Style.pixelAlignCenter(parent.width, width)
    y: Style.pixelAlignCenter(parent.height, height)
    width: root.contentWidth
    height: root.contentHeight
    color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
    radius: Style.radiusL

    NIcon {
      id: contentIcon
      anchors.centerIn: parent
      icon: "keyboard"
      applyUiScale: false
      color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onClicked: {
      if (pluginApi) {
        // Set flag to trigger parser in Main.qml
        pluginApi.pluginSettings.triggerToggle = Date.now();
        pluginApi.saveSettings();
      }
    }
  }
}
