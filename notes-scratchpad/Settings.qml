import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import qs.Commons
import qs.Widgets

ColumnLayout {
  id: root
  property var pluginApi: null

  // Local state
  property int panelWidth: pluginApi?.pluginSettings?.panelWidth ?? 600
  property int panelHeight: pluginApi?.pluginSettings?.panelHeight ?? 400
  property int fontSize: pluginApi?.pluginSettings?.fontSize ?? 14

  spacing: Style.marginM

  NLabel {
    label: pluginApi?.tr("settings.panel_dimensions.title") || "Panel Dimensions"
    description: pluginApi?.tr("settings.panel_dimensions.description") || "Configure the size of the scratchpad panel when it opens."
  }

  RowLayout {
    Layout.fillWidth: true
    spacing: Style.marginL

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      NText {
        text: (pluginApi?.tr("settings.panel_dimensions.width") || "Width") + ": " + root.panelWidth + "px"
        pointSize: Style.fontSizeM
      }

      NSlider {
        id: widthSlider
        Layout.fillWidth: true
        from: 400
        to: 1200
        value: root.panelWidth
        stepSize: 50
        onMoved: {
          root.panelWidth = Math.round(value);
        }
      }
    }

    ColumnLayout {
      Layout.fillWidth: true
      spacing: Style.marginS

      NText {
        text: (pluginApi?.tr("settings.panel_dimensions.height") || "Height") + ": " + root.panelHeight + "px"
        pointSize: Style.fontSizeM
      }

      NSlider {
        id: heightSlider
        Layout.fillWidth: true
        from: 300
        to: 900
        value: root.panelHeight
        stepSize: 50
        onMoved: {
          root.panelHeight = Math.round(value);
        }
      }
    }
  }

  ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.marginS
    Layout.topMargin: Style.marginM

    NText {
      text: pluginApi?.tr("settings.text_appearance.title") || "Text Appearance"
      pointSize: Style.fontSizeL
      font.weight: Font.Bold
    }

    NText {
      text: (pluginApi?.tr("settings.text_appearance.font_size") || "Font Size") + ": " + root.fontSize + "px"
      pointSize: Style.fontSizeM
    }

    NSlider {
      id: fontSizeSlider
      Layout.fillWidth: true
      from: 10
      to: 24
      value: root.fontSize
      stepSize: 1
      onMoved: {
        root.fontSize = Math.round(value)
      }
    }
  }

  ColumnLayout {
    Layout.fillWidth: true
    spacing: Style.marginS
    Layout.topMargin: Style.marginL

    NLabel {
      label: pluginApi?.tr("settings.keyboard_shortcut.title") || "Keyboard Shortcut"
      description: pluginApi?.tr("settings.keyboard_shortcut.description") || "Toggle the scratchpad panel with this command:"
    }

    Rectangle {
      Layout.fillWidth: true
      Layout.preferredHeight: commandText.implicitHeight + Style.marginM * 2
      color: Color.mSurfaceVariant
      radius: Style.radiusM

      TextEdit {
        id: commandText
        anchors.fill: parent
        anchors.margins: Style.marginM
        text: "qs -c noctalia-shell ipc call plugin togglePanel notes-scratchpad"
        font.pointSize: Style.fontSizeS
        font.family: Settings.data.ui.fontFixed
        color: Color.mPrimary
        wrapMode: TextEdit.WrapAnywhere
        readOnly: true
        selectByMouse: true
        selectionColor: Color.mPrimary
        selectedTextColor: Color.mOnPrimary
      }
    }
  }

  function saveSettings() {
    if (pluginApi) {
      pluginApi.pluginSettings.panelWidth = root.panelWidth
      pluginApi.pluginSettings.panelHeight = root.panelHeight
      pluginApi.pluginSettings.fontSize = root.fontSize
      pluginApi.saveSettings()
    }
  }
}
