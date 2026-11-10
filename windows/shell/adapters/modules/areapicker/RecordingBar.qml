pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.components.effects
import qs.services
import "RecordingLogic.js" as Logic

StyledRect {
    id: root

    required property var recorder
    readonly property string primaryAction: Logic.action(recorder.state)
    readonly property string timerText: Logic.timer(recorder.elapsed)
    readonly property real dpr: (QsWindow.window as QsWindow)?.devicePixelRatio ?? 1
    implicitWidth: row.implicitWidth + Tokens.padding.small * 2
    implicitHeight: row.implicitHeight + Tokens.padding.small * 2
    radius: Tokens.rounding.large
    color: Colours.palette.m3surfaceContainer

    function perform(action): void {
        if (action === "pause" || action === "resume")
            recorder.togglePause();
        else if (action === "stop")
            recorder.stop();
        else if (action === "mic")
            recorder.toggleMic();
        else if (action === "sound")
            recorder.toggleSound();
        else if (action === "discard")
            recorder.discard();
    }

    Row {
        id: row
        anchors.centerIn: parent
        spacing: Tokens.spacing.extraSmall

        Rectangle {
            width: Tokens.spacing.small
            height: width
            anchors.verticalCenter: parent.verticalCenter
            radius: width / 2
            color: Colours.palette.m3error
            opacity: root.recorder.state === "paused" ? 0.5 : 1
            SequentialAnimation on opacity {
                running: root.recorder.state === "recording" && pulseOut.duration > 0
                loops: Animation.Infinite
                Anim { id: pulseOut; to: 0.3; type: Anim.StandardLarge }
                Anim { to: 1; type: Anim.StandardLarge }
            }
        }
        StyledText {
            id: clock
            anchors.verticalCenter: parent.verticalCenter
            text: root.timerText
            font.pointSize: Tokens.font.body.small
            transform: PixelSnap { target: clock; surface: root; dpr: root.dpr }
        }
        IconTextButton {
            id: primary
            disabled: ["recording", "paused"].indexOf(root.recorder.state) === -1
            icon: root.primaryAction === "pause" ? "pause" : root.primaryAction === "resume" ? "play_arrow" : "fiber_manual_record"
            text: root.primaryAction === "pause" ? Tr.tr("Pause") : root.primaryAction === "resume" ? Tr.tr("Resume") : Tr.tr("Record")
            onClicked: root.perform(root.primaryAction)
            ToolTip.visible: hovered
            ToolTip.delay: 500
            ToolTip.text: text
            Accessible.name: text
            label.transform: PixelSnap { target: primary.label; surface: root; dpr: root.dpr }
            iconLabel.transform: PixelSnap { target: primary.iconLabel; surface: root; dpr: root.dpr }
        }
        Repeater {
            model: [
                { action: "stop", icon: "stop", label: Tr.tr("Stop") },
                { action: "mic", icon: "mic", label: Tr.tr("Mic") },
                { action: "sound", icon: "volume_up", label: Tr.tr("Sound") },
                { action: "discard", icon: "delete", label: Tr.tr("Discard") }
            ]
            IconButton {
                id: button
                required property var modelData
                type: IconButton.Text
                icon: modelData.icon
                disabled: ["recording", "paused"].indexOf(root.recorder.state) === -1
                checked: modelData.action === "mic" ? root.recorder.mic : modelData.action === "sound" ? root.recorder.sound : false
                onClicked: root.perform(modelData.action)
                ToolTip.visible: hovered
                ToolTip.delay: 500
                ToolTip.text: modelData.label
                Accessible.name: modelData.label
                label.transform: PixelSnap { target: button.label; surface: root; dpr: root.dpr }
            }
        }
    }
}
