pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.components.containers
import qs.components.controls
import qs.services
import qs.utils

// Windows per-app mixer for the bar audio popout, loaded under the master
// volume through AudioPopoutContent's `mixer` hook. Upstream only offers app
// volumes in the settings page (nexus/pages/audio/AppVolumes.qml); this reuses
// that page's stream model, naming and icons in the popout's flat row style.
//
// Every write goes through the facade, which rejects nodes that are no longer
// listed, not ready or not controllable. Rows only write on direct pointer
// interaction: no slider or button writes on creation or model refresh, and
// the sliders ignore the wheel so scrolling the list never changes a volume.
ColumnLayout {
    id: root

    // Rows visible before the list scrolls. The extra half row shows that
    // more apps are below.
    property real maxVisibleRows: 3.5

    spacing: Tokens.spacing.small

    StyledText {
        text: Tr.tr("App volumes")
        font: Tokens.font.body.builders.medium.weight(Font.Medium).build()
    }

    StyledText {
        Layout.fillWidth: true
        visible: text.length > 0
        text: Audio.streamControlsReason
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
        wrapMode: Text.WordWrap
    }

    StyledText {
        Layout.fillWidth: true
        visible: Audio.ready && list.count === 0
        text: Tr.tr("No apps playing audio")
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.small
    }

    StyledListView {
        id: list

        Layout.fillWidth: true
        Layout.rightMargin: -Tokens.spacing.small
        visible: count > 0
        implicitHeight: count > root.maxVisibleRows ? (contentHeight + spacing) / count * root.maxVisibleRows - spacing : contentHeight
        clip: true
        interactive: contentHeight > height
        spacing: Tokens.spacing.small

        StyledScrollBar.vertical: StyledScrollBar {
            flickable: list
        }

        // ScriptModel keeps existing rows (and an in-progress drag) when other
        // sessions arrive or leave.
        model: ScriptModel {
            values: [...Audio.streams]
        }

        delegate: RowLayout {
            id: stream

            required property PwNode modelData

            readonly property bool controllable: Audio.canControl(modelData)
            readonly property real volume: Audio.getStreamVolume(modelData)
            readonly property bool muted: Audio.getStreamMuted(modelData)

            anchors.left: list.contentItem.left
            anchors.right: list.contentItem.right
            anchors.rightMargin: Tokens.spacing.small
            spacing: Tokens.spacing.small

            opacity: 0
            scale: 0.7

            Component.onCompleted: {
                opacity = 1;
                scale = 1;
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }

            Behavior on scale {
                Anim {}
            }

            IconButton {
                // Playback sessions are sinks; capture sessions (apps using a
                // microphone) get the mic icons.
                icon: stream.modelData.isSink ? Icons.getVolumeIcon(stream.volume, stream.muted) : stream.muted ? "mic_off" : "mic"
                type: IconButton.Text
                label.animate: true
                disabled: !stream.controllable
                onClicked: Audio.setStreamMuted(stream.modelData, !stream.muted)
            }

            ColumnLayout {
                Layout.fillWidth: true
                spacing: Tokens.spacing.extraSmall

                RowLayout {
                    Layout.fillWidth: true
                    spacing: Tokens.spacing.small

                    StyledText {
                        Layout.fillWidth: true
                        text: Audio.getStreamName(stream.modelData)
                        font: Tokens.font.body.small
                        elide: Text.ElideRight
                    }

                    StyledText {
                        text: stream.muted ? Tr.tr("Muted") : Strings.percentOne(stream.volume)
                        color: Colours.palette.m3outline
                        font: Tokens.font.body.small
                    }
                }

                StyledSlider {
                    Layout.fillWidth: true
                    implicitHeight: Tokens.padding.medium * 2
                    radius: Tokens.rounding.small
                    enabled: stream.controllable
                    value: stream.volume
                    onInteraction: v => Audio.setStreamVolume(stream.modelData, v)
                }
            }
        }
    }
}
