pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Services.Pipewire
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.modules.nexus.common

// Windows adaptation of modules/nexus/common/AudioDeviceList.qml.
//
// Upstream treats every listed node as selectable. On Windows a node can be
// observed while its volume/default interface is unavailable, and controls can
// be off for the whole run. The caller now passes the facade's direction-level
// capability and the row also checks the facade's per-node `canControl()`;
// unavailable devices are visibly dimmed and cannot be selected.
ItemList {
    id: root

    property var nodes: []
    property int currentId: -1
    property string iconName: "speaker"
    property bool controlsAvailable: true

    signal selected(node: PwNode)

    last: true
    showList: true

    model: ScriptModel {
        values: [...root.nodes].sort((a, b) => (a.description || a.name || "").localeCompare(b.description || b.name || ""))
    }

    delegate: Item {
        id: device

        required property PwNode modelData
        required property int index
        readonly property bool active: device.modelData?.id === root.currentId
        readonly property bool controllable: root.controlsAvailable && Audio.canControl(device.modelData)

        anchors.left: root.list.contentItem.left
        anchors.right: root.list.contentItem.right
        implicitHeight: deviceLayout.implicitHeight + deviceLayout.anchors.margins * 2
        opacity: controllable ? 1 : 0.5

        StateLayer {
            radius: Tokens.rounding.extraSmall
            bottomLeftRadius: device.index === root?.list.count - 1 ? Tokens.rounding.extraLarge : radius
            bottomRightRadius: device.index === root?.list.count - 1 ? Tokens.rounding.extraLarge : radius
            disabled: !device.controllable
            onClicked: root.selected(device.modelData)
        }

        RowLayout {
            id: deviceLayout

            anchors.fill: parent
            anchors.margins: Tokens.padding.medium
            anchors.leftMargin: Tokens.padding.largeIncreased
            anchors.rightMargin: Tokens.padding.largeIncreased
            spacing: Tokens.spacing.medium

            StyledRect {
                implicitWidth: implicitHeight
                implicitHeight: devIcon.implicitHeight + Tokens.padding.small * 2
                radius: Tokens.rounding.full
                color: device.active ? Colours.palette.m3primary : Colours.palette.m3secondaryContainer

                MaterialIcon {
                    id: devIcon

                    anchors.centerIn: parent
                    text: root.iconName
                    color: device.active ? Colours.palette.m3onPrimary : Colours.palette.m3onSecondaryContainer
                    fontStyle: Tokens.font.icon.medium
                    fill: device.active ? 1 : 0

                    Behavior on fill {
                        Anim {}
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                text: device.modelData?.description || device.modelData?.name || Tr.trCtx("Unknown", "unknown audio device")
                font: Tokens.font.body.small
                elide: Text.ElideRight
            }

            MaterialIcon {
                text: "check"
                color: Colours.palette.m3primary
                fontStyle: Tokens.font.icon.medium
                opacity: device.active ? 1 : 0

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }
        }
    }
}
