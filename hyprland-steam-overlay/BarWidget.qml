import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
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

  property bool hasNewMessages: pluginApi?.pluginSettings?.hasNewMessages || false
  property bool steamRunning: false

  readonly property real contentWidth: barIsVertical ? Style.getCapsuleHeightForScreen(screen.name) : contentRow.implicitWidth + Style.marginM * 2
  readonly property real contentHeight: Style.getCapsuleHeightForScreen(screen.name)

  implicitWidth: contentWidth
  implicitHeight: contentHeight

  // Process to check Steam status
  Process {
    id: checkSteamProcess
    command: ["pidof", "steam"]
    running: false

    onExited: (exitCode, exitStatus) => {
      steamRunning = (exitCode === 0);
    }
  }

  // Update steam status periodically
  Timer {
    interval: 5000
    repeat: true
    running: true
    onTriggered: {
      checkSteamProcess.running = true;
    }
  }

  Component.onCompleted: {
    checkSteamProcess.running = true;
  }

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

      Item {
        implicitWidth: 24
        implicitHeight: 24

        // Steam icon - using stacked rectangles to create Steam-like logo
        Item {
          id: steamIcon
          anchors.centerIn: parent
          width: 20
          height: 20

          // Simple Steam-inspired icon using rectangles
          Rectangle {
            anchors.centerIn: parent
            width: 20
            height: 20
            color: "transparent"
            border.color: steamRunning ? Color.mPrimary : (mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface)
            border.width: 2
            radius: 10

            // Inner circles for Steam logo effect
            Rectangle {
              anchors.centerIn: parent
              anchors.horizontalCenterOffset: -4
              anchors.verticalCenterOffset: 2
              width: 6
              height: 6
              radius: 3
              color: steamRunning ? Color.mPrimary : (mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface)
            }

            Rectangle {
              anchors.centerIn: parent
              anchors.horizontalCenterOffset: 4
              anchors.verticalCenterOffset: 2
              width: 4
              height: 4
              radius: 2
              color: steamRunning ? Color.mPrimary : (mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface)
            }

            Rectangle {
              anchors.top: parent.top
              anchors.horizontalCenter: parent.horizontalCenter
              anchors.topMargin: 4
              width: 8
              height: 8
              radius: 4
              color: steamRunning ? Color.mPrimary : (mouseArea.containsMouse ? Color.mOnHover : Color.mOnSurface)
            }
          }

          // Notification dot
          Rectangle {
            visible: hasNewMessages
            anchors.top: parent.top
            anchors.right: parent.right
            width: 8
            height: 8
            radius: 4
            color: "#F44336"
            border.color: Color.mSurface
            border.width: 1

            SequentialAnimation on opacity {
              loops: Animation.Infinite
              running: hasNewMessages

              NumberAnimation {
                from: 1.0
                to: 0.3
                duration: 800
                easing.type: Easing.InOutQuad
              }
              NumberAnimation {
                from: 0.3
                to: 1.0
                duration: 800
                easing.type: Easing.InOutQuad
              }
            }
          }
        }
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
        Logger.i("SteamOverlay.BarWidget: Calling Steam overlay toggle");
        // Call toggle via IPC
        toggleProcess.running = true;
      }
    }
  }
}
