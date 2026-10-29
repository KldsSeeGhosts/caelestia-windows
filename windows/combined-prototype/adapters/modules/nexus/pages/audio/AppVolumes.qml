pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.utils
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/pages/audio/AppVolumes.qml.
//
// Upstream enables each per-app slider unless that stream is muted. The Windows
// facade reports per-stream control availability separately, so a listed stream
// can be observable without a writable volume interface. Each slider now uses
// the facade's `canControl(node)`, and the page states the facade's reason when
// stream control is unavailable instead of offering an interactive dead slider.
PageBase {
    id: root

    title: Tr.tr("App volumes")
    isSubPage: true

    readonly property string controlsReason: Audio.streamControlsReason

    ColumnLayout {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.top: parent.top
        width: root.cappedWidth
        spacing: Tokens.spacing.extraSmall / 2

        ConnectedRect {
            readonly property bool shown: root.controlsReason.length > 0

            Layout.fillWidth: true
            visible: shown
            implicitHeight: shown ? controlsNote.implicitHeight + Tokens.padding.large * 2 : 0
            first: true
            last: true

            StyledText {
                id: controlsNote

                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.margins: Tokens.padding.large
                visible: parent.shown

                text: root.controlsReason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
                wrapMode: Text.WordWrap
            }
        }

        ItemList {
            id: streamList

            first: true
            last: true
            showList: true
            placeholderIcon: "music_off"
            placeholderText: Tr.tr("No apps playing audio")
            color: list.count === 0 ? Colours.tPalette.m3surfaceContainer : "transparent"
            list.spacing: Tokens.spacing.extraSmall / 2

            model: ScriptModel {
                values: [...Audio.streams]
            }

            delegate: SliderRow {
                id: stream

                required property PwNode modelData
                required property int index

                readonly property bool controllable: Audio.canControl(stream.modelData)

                anchors.left: streamList.list.contentItem.left
                anchors.right: streamList.list.contentItem.right
                first: index === 0
                last: index === streamList.list.count - 1

                icon: Icons.getVolumeIcon(stream.modelData?.audio?.volume ?? 0, stream.modelData?.audio?.muted ?? false)
                label: Audio.getStreamName(stream.modelData)
                valueLabel: Strings.percentOne(value)
                value: stream.modelData?.audio?.volume ?? 0
                enabled: stream.controllable && !stream.modelData?.audio?.muted
                onMoved: v => Audio.setStreamVolume(stream.modelData, v)
            }
        }
    }
}
