import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

BarIconButton {
  id: root
  property string moduleName: "muness.battery-charge"
  property var settings: ({})
  property var reading: ({})
  property var appActivity: null
  readonly property string limit: reading.limit || ""
  readonly property string executable: Quickshell.env("HOME") + "/.local/bin/battery-charge"

  // Follow the native indicator drawer's peek, including its hold while the
  // pointer moves across the bar. Travel stays visible like other active toggles.
  readonly property bool indicatorPeek: {
    if (!bar) return false
    var groups = bar.moduleWidgets("omarchy.indicators")
    for (var i = 0; i < groups.length; i++) {
      if (groups[i].revealInactiveIndicators) return true
    }
    return bar.centerSectionRevealHeld === true
  }
  readonly property bool revealed: settings.alwaysShow === true || limit !== "80" || indicatorPeek || panel.open
  readonly property bool discharging: reading.state === "Discharging"
  readonly property bool waitingForThreshold: reading.state === "Not charging" && reading.acOnline === true
    && limit !== "" && reading.resumeBelow != null && reading.capacity != null && reading.capacity >= reading.resumeBelow
  readonly property string chargeState: {
    if (reading.state === "Charging") return limit ? qsTr("Charging to %1%").arg(limit) : qsTr("Charging battery")
    if (reading.acOnline === false) return qsTr("Running on battery")
    if (discharging && reading.acOnline === true) return qsTr("Charger and battery are powering the Mac")
    if (waitingForThreshold) return reading.capacity >= Number(limit)
      ? qsTr("Charging paused at the %1% limit").arg(limit) : qsTr("Charging paused")
    if (reading.state === "Not charging" && reading.acOnline === true) return qsTr("Plugged in · battery idle")
    if (reading.state === "Full") return qsTr("Battery full")
    return reading.state || "Battery status unavailable"
  }

  text: "󱈏"
  implicitWidth: revealed ? (vertical ? barSize : slotSize) : 0
  implicitHeight: vertical ? (revealed ? slotSize : 0) : barSize
  clip: true
  concealed: !revealed
  interactive: revealed
  dimmed: limit === "80" && settings.alwaysShow !== true

  tooltipText: panel.open ? "" : "Power Flow"
  onPressed: function(button) {
    if (button === Qt.LeftButton && bar) panel.open = !panel.open
  }

  Process {
    id: change
    command: [root.executable, root.limit === "80" ? "100" : "80"]
    onExited: probe.running = true
  }

  Process {
    id: probe
    command: [root.executable, "status"]
    running: true
    stdout: StdioCollector {
      onStreamFinished: {
        try {
          root.reading = JSON.parse(text)
        } catch (error) {
          root.reading = ({})
        }
      }
    }
  }

  Process {
    command: [root.executable, "apps"]
    running: panel.open
    stdout: SplitParser {
      onRead: function(line) {
        try {
          root.appActivity = JSON.parse(line)
        } catch (error) {
          root.appActivity = null
        }
      }
    }
  }

  Timer {
    interval: panel.open ? 2000 : 5000
    running: true
    repeat: true
    onTriggered: probe.running = true
  }

  component PanelText: Text {
    color: ThemeColor.popups.text
    font.family: Qt.application.font.family
    font.pixelSize: Style.font.body
    textFormat: Text.PlainText
  }

  component PowerMetric: Column {
    property string label
    property var watts
    property string detail: ""
    property string valueOverride: ""
    spacing: Style.space(2)

    PanelText { text: parent.label }
    PanelText {
      text: parent.valueOverride !== "" ? parent.valueOverride
        : parent.watts == null ? "Unavailable" : parent.watts.toFixed(1) + " W"
      font.bold: true
    }
    PanelText {
      visible: parent.detail !== ""
      text: parent.detail
    }
  }

  PopupCard {
    id: panel
    anchorItem: root
    bar: root.bar
    contentWidth: fittedContentWidth(Style.space(354))
    contentHeight: fittedContentHeight(details.implicitHeight)
    onOpenChanged: {
      root.appActivity = null
      if (open) probe.running = true
    }

    ColumnLayout {
      id: details
      anchors.fill: parent
      spacing: Style.space(10)

      RowLayout {
        Layout.fillWidth: true

        PanelText {
          text: "Power Flow"
          font.bold: true
          Layout.fillWidth: true
        }

        PanelText {
          text: root.reading.capacity == null ? "Battery unavailable"
            : "Battery " + root.reading.capacity + "%"
              + (root.reading.energyWh == null ? "" : " · " + root.reading.energyWh.toFixed(1) + " Wh")
        }
      }

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(5)
        radius: height / 2
        color: Qt.alpha(ThemeColor.popups.text, 0.17)

        Rectangle {
          width: parent.width * (root.reading.capacity || 0) / 100
          height: parent.height
          radius: height / 2
          color: ThemeColor.accent
        }

        Rectangle {
          visible: root.limit !== ""
          width: Style.space(2)
          height: parent.height + Style.space(4)
          x: Math.min(parent.width - width, parent.width * Number(root.limit) / 100 - width / 2)
          anchors.verticalCenter: parent.verticalCenter
          radius: width / 2
          color: ThemeColor.popups.text
        }
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(2)
        PanelText {
          Layout.fillWidth: true
          text: root.chargeState
          font.bold: true
          wrapMode: Text.WordWrap
        }
        PanelText {
          Layout.fillWidth: true
          visible: root.waitingForThreshold
          text: root.waitingForThreshold ? qsTr("Charging resumes below %1%.").arg(root.reading.resumeBelow) : ""
          wrapMode: Text.WordWrap
        }
      }

      Item {
        id: flow
        Layout.fillWidth: true
        Layout.preferredHeight: Style.space(105)

        PowerMetric {
          id: charger
          label: root.reading.acOnline === false ? qsTr("Charger unplugged") : qsTr("Charger draw")
          watts: root.reading.chargerWatts
          detail: root.reading.chargerLimitWatts > 0
            ? qsTr("%1 W input limit").arg(Number(root.reading.chargerLimitWatts.toFixed(1))) : ""
          y: root.discharging ? 0 : (flow.height - height) / 2
        }

        PowerMetric {
          id: system
          x: flow.width - (root.discharging ? width : Math.max(width, battery.width))
          label: qsTr("System draw")
          watts: root.reading.systemWatts
          y: root.discharging || root.waitingForThreshold ? (flow.height - height) / 2 : flow.height - height
        }

        PowerMetric {
          id: battery
          y: root.discharging ? flow.height - height : 0
          x: root.discharging ? 0 : system.x
          label: root.discharging ? qsTr("Battery output")
            : root.waitingForThreshold ? qsTr("Battery") : qsTr("Into battery")
          watts: root.reading.batteryWatts
          valueOverride: root.waitingForThreshold && watts === 0 ? qsTr("Paused") : ""
        }

        Canvas {
          id: ribbons
          property var reading: root.reading
          x: Math.max(charger.width, root.discharging ? battery.width : 0) + Style.space(10)
          width: Math.max(0, system.x - x - Style.space(10))
          height: parent.height
          onReadingChanged: requestPaint()
          onWidthChanged: requestPaint()
          onHeightChanged: requestPaint()
          property color systemColor: Qt.alpha(ThemeColor.popups.text, 0.28)
          property color batteryColor: Qt.alpha(ThemeColor.accent, 0.65)
          onSystemColorChanged: requestPaint()
          onBatteryColorChanged: requestPaint()

          function center(metric) {
            return metric.y + metric.height / 2
          }

          function ribbon(ctx, left, right, thickness, color) {
            if (thickness <= 0) return
            const half = thickness / 2
            ctx.fillStyle = color
            ctx.beginPath()
            ctx.moveTo(0, left - half)
            ctx.bezierCurveTo(width * 0.5, left - half, width * 0.5, right - half, width, right - half)
            ctx.lineTo(width, right + half)
            ctx.bezierCurveTo(width * 0.5, right + half, width * 0.5, left + half, 0, left + half)
            ctx.closePath()
            ctx.fill()
          }

          onPaint: {
            const ctx = getContext("2d")
            ctx.clearRect(0, 0, width, height)
            const main = (root.discharging ? reading.chargerWatts : reading.systemWatts) || 0
            const batteryPower = reading.batteryWatts || 0
            const scale = Style.space(32) / Math.max(1, main + batteryPower)
            const mainWidth = main * scale
            const batteryWidth = batteryPower * scale

            if (root.discharging) {
              ribbon(ctx, center(charger), center(system) - batteryWidth / 2, mainWidth, systemColor)
              ribbon(ctx, center(battery), center(system) + mainWidth / 2, batteryWidth, batteryColor)
            } else if (root.waitingForThreshold && batteryPower === 0) {
              ribbon(ctx, center(charger), center(system), mainWidth, systemColor)
              // A dotted branch and pause mark show the inactive battery path.
              ctx.strokeStyle = systemColor
              ctx.lineWidth = 1
              ctx.setLineDash([3, 4])
              ctx.beginPath()
              ctx.moveTo(width * 0.55, center(system))
              ctx.bezierCurveTo(width * 0.75, center(system), width * 0.7, center(battery), width - 8, center(battery))
              ctx.stroke()
              ctx.setLineDash([])
              ctx.fillStyle = batteryColor
              ctx.fillRect(width - 6, center(battery) - 5, 2, 10)
              ctx.fillRect(width - 2, center(battery) - 5, 2, 10)
            } else if (reading.chargerWatts > 0) {
              ribbon(ctx, center(charger) - mainWidth / 2, center(battery), batteryWidth, batteryColor)
              ribbon(ctx, center(charger) + batteryWidth / 2, center(system), mainWidth, systemColor)
            }
          }
        }

      }

      Rectangle {
        Layout.fillWidth: true
        Layout.preferredHeight: 1
        color: Qt.alpha(ThemeColor.popups.text, 0.17)
      }

      ColumnLayout {
        Layout.fillWidth: true
        spacing: Style.space(5)

        RowLayout {
          Layout.fillWidth: true

          PanelText { text: "Top apps"; font.bold: true; Layout.fillWidth: true }
          PanelText {
            text: "CPU"
            Layout.preferredWidth: Style.space(55)
            horizontalAlignment: Text.AlignRight
          }
          PanelText {
            text: "GPU"
            Layout.preferredWidth: Style.space(55)
            horizontalAlignment: Text.AlignRight
          }
        }

        PanelText {
          visible: root.appActivity === null || root.appActivity.length === 0
          Layout.fillWidth: true
          text: root.appActivity === null ? "Sampling activity…" : "No significant app activity"
        }

        Repeater {
          model: root.appActivity || []

          RowLayout {
            required property var modelData
            Layout.fillWidth: true

            PanelText {
              text: parent.modelData.name
              Layout.fillWidth: true
              elide: Text.ElideRight
            }
            PanelText {
              text: parent.modelData.cpu + "%"
              Layout.preferredWidth: Style.space(55)
              horizontalAlignment: Text.AlignRight
            }
            PanelText {
              text: parent.modelData.gpu == null ? "—" : parent.modelData.gpu + "%"
              Layout.preferredWidth: Style.space(55)
              horizontalAlignment: Text.AlignRight
            }
          }
        }

      }

      RowLayout {
        Layout.fillWidth: true

        PanelText {
          Layout.fillWidth: true
          text: root.limit === "80" ? "Home cap 80%" : root.limit === "100" ? "Travel cap 100%" : "Cap unavailable"
        }

        Button {
          bordered: true
          focusable: true
          enabled: root.limit !== "" && !change.running
          text: change.running ? "Changing…" : root.limit === "80" ? "Switch to Travel" : "Switch to Home"
          onClicked: change.running = true
        }
      }
    }
  }
}
