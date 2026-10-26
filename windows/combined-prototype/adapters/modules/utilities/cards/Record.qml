pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.controls
import qs.services

// Original upstream screen-recorder card, adapted to the Windows recorder.
//
// The original SplitButton chose between fullscreen/region and sound/no-sound,
// all of which were flags for gpu-screen-recorder. The Windows recorder supports
// fullscreen gdigrab only, so the header keeps the original icon/title/state row
// and a single start/stop button; the unsupported modes are not offered. The
// recordings list is omitted because it depends on the Linux `caelestia record`
// directory layout; the card names the Windows folder instead.
StyledRect {
    id: root

    required property var props
    required property ScreenState screenState
    readonly property real nonAnimHeight: layout.implicitHeight + layout.anchors.margins * 2

    implicitHeight: nonAnimHeight

    radius: Tokens.rounding.large
    color: Colours.tPalette.m3surfaceContainer

    ColumnLayout {
        id: layout

        anchors.fill: parent
        anchors.margins: Tokens.padding.large
        spacing: Tokens.spacing.medium

        RowLayout {
            id: btnLayout

            spacing: Tokens.spacing.medium

            StyledRect {
                implicitWidth: implicitHeight
                implicitHeight: {
                    const h = icon.implicitHeight + Tokens.padding.small * 2;
                    return h - (h % 2);
                }

                radius: Tokens.rounding.full
                color: Recorder.running ? Colours.palette.m3secondary : Colours.palette.m3secondaryContainer

                MaterialIcon {
                    id: icon

                    anchors.centerIn: parent
                    anchors.verticalCenterOffset: 1
                    text: "screen_record"
                    color: Recorder.running ? Colours.palette.m3onSecondary : Colours.palette.m3onSecondaryContainer
                    fontStyle: Tokens.font.icon.large
                }
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: 0

                StyledText {
                    Layout.fillWidth: true
                    text: Tr.tr("Screen recorder")
                    font: Tokens.font.body.medium
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.fillWidth: true
                    text: Recorder.status
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                    elide: Text.ElideRight
                    animate: true
                }
            }

            IconButton {
                id: actionButton

                type: IconButton.Filled
                icon: Recorder.running ? "stop" : "screen_record"
                disabled: !Recorder.running && !Recorder.canStart
                onClicked: {
                    if (Recorder.running)
                        Recorder.stop();
                    else
                        Recorder.start();
                }
            }
        }

        StyledText {
            Layout.fillWidth: true
            visible: !Recorder.running
            text: {
                if (Recorder.lastError !== "")
                    return Recorder.lastError;
                if (!Recorder.permitted)
                    return Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1" ? Tr.tr("Recording is suppressed during smoke.") : Tr.tr("Turn on Live controls to record.");
                return Tr.tr("Saves to %1").arg(Recorder.outputDir);
            }
            color: Recorder.lastError !== "" ? Colours.palette.m3error : Colours.palette.m3onSurfaceVariant
            font: Tokens.font.body.small
            elide: Text.ElideMiddle
            animate: true
        }

        RowLayout {
            id: recordingControls

            visible: Recorder.running
            spacing: Tokens.spacing.medium

            StyledRect {
                radius: Tokens.rounding.full
                color: Colours.palette.m3error

                implicitWidth: recText.implicitWidth + Tokens.padding.medium * 2
                implicitHeight: recText.implicitHeight + Tokens.padding.large

                StyledText {
                    id: recText

                    anchors.centerIn: parent
                    animate: true
                    text: Tr.trCtx("REC", "recording status")
                    color: Colours.palette.m3onError
                    font: Tokens.font.mono.small
                }

                SequentialAnimation on opacity {
                    running: Recorder.running
                    loops: Animation.Infinite
                    alwaysRunToEnd: true

                    Anim {
                        from: 1
                        to: 0
                        duration: Tokens.anim.durations.large
                        easing: Tokens.anim.emphasizedAccel
                    }
                    Anim {
                        from: 0
                        to: 1
                        duration: Tokens.anim.durations.extraLarge
                        easing: Tokens.anim.emphasizedDecel
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: {
                    const elapsed = Recorder.elapsed;

                    const hours = Math.floor(elapsed / 3600);
                    const mins = Math.floor((elapsed % 3600) / 60);
                    const secs = Math.floor(elapsed % 60).toString().padStart(2, "0");

                    let time;
                    if (hours > 0)
                        time = `${hours}:${mins.toString().padStart(2, "0")}:${secs}`;
                    else
                        time = `${mins}:${secs}`;

                    // TRANSLATORS: %1 = elapsed recording duration, e.g. 01:23
                    return Tr.tr("Recording for %1").arg(time);
                }
                font: Tokens.font.body.medium
                elide: Text.ElideMiddle
            }

            IconButton {
                shapeMorph: true
                isRound: true
                icon: "stop"
                inactiveColour: Colours.palette.m3error
                inactiveOnColour: Colours.palette.m3onError
                font: Tokens.font.icon.medium
                onClicked: Recorder.stop()
            }
        }
    }
}
