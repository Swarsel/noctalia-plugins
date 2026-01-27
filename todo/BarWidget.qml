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

  function getIntValue(value, defaultValue) {
    return (typeof value === 'number') ? Math.floor(value) : defaultValue;
  }

  readonly property int todoCount: getIntValue(pluginApi?.pluginSettings?.count, getIntValue(pluginApi?.manifest?.metadata?.defaultSettings?.count, 0))
  readonly property int completedCount: getIntValue(pluginApi?.pluginSettings?.completedCount, getIntValue(pluginApi?.manifest?.metadata?.defaultSettings?.completedCount, 0))
  readonly property int activeCount: todoCount - completedCount

  readonly property string barPosition: Settings.data.bar.position || "top"
  readonly property bool barIsVertical: barPosition === "left" || barPosition === "right"

  readonly property real contentWidth: barIsVertical ? Style.capsuleHeight : contentRow.implicitWidth + Style.marginM * 2
  readonly property real contentHeight: Style.capsuleHeight

  implicitWidth: contentWidth
  implicitHeight: contentHeight

  Connections {
    target: Color
    function onMOnHoverChanged() { }
    function onMOnSurfaceChanged() { }
  }

  // Visual capsule - pixel-perfect centered
  Rectangle {
    id: visualCapsule
    x: Style.pixelAlignCenter(parent.width, width)
    y: Style.pixelAlignCenter(parent.height, height)
    width: root.contentWidth
    height: root.contentHeight
    color: mouseArea.containsMouse ? Color.mHover : Style.capsuleColor
    radius: Style.radiusL

    RowLayout {
      id: contentRow
      anchors.centerIn: parent
      spacing: Style.marginS

      NIcon {
        icon: "checklist"
        applyUiScale: false
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
      }

      NText {
        visible: !barIsVertical
        text: {
          var count = activeCount;
          var key = count === 1 ? "bar_widget.todo_count_singular" : "bar_widget.todo_count_plural";
          var text = pluginApi?.tr(key) || (count + " todo" + (count !== 1 ? 's' : ''));
          return text.replace("{count}", count);
        }
        color: mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface
        pointSize: Style.barFontSize
        font.weight: Font.Medium
      }
    }
  }

  MouseArea {
    id: mouseArea
    anchors.fill: parent
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    onClicked: {
      if (pluginApi) {
        Logger.i("Todo", "Opening Todo panel");
        pluginApi.openPanel(root.screen);
      }
    }
  }
}
