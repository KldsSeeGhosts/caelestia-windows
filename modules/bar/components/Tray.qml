pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Services.SystemTray
import Caelestia.Config
import qs.components
import qs.services

StyledRect {
    id: root

    readonly property alias layout: layout
    readonly property alias items: items
    readonly property alias expandIcon: expandIcon
    readonly property alias viewport: viewport

    // Windows staging hooks. Defaults preserve upstream Linux behavior: the
    // native SystemTray model is used and interactions keep their original
    // meaning. A bounded Windows host may inject an observed item list, disable
    // interactions for read-only observation, or route a menu request to the
    // native context menu that the backend opens through display().
    property var sourceItems: null
    property bool itemInteractionsEnabled: true
    property bool itemNativeMenuMode: false
    // Windows can bound the expanded tray without changing upstream sizing.
    property real maximumListHeight: Infinity
    readonly property real visibleListHeight: Math.min(layout.implicitHeight, maximumListHeight)

    signal itemMenuRequested(var item, real x, real y)

    readonly property int padding: Config.bar.tray.background ? Tokens.padding.medium : Tokens.padding.extraSmall
    readonly property int spacing: Config.bar.tray.background ? Tokens.spacing.medium : Tokens.spacing.extraSmall

    property bool expanded

    readonly property real nonAnimHeight: {
        if (!Config.bar.tray.compact)
            return visibleListHeight + padding * 2;
        const pad = (Config.bar.tray.background ? Tokens.padding.extraSmall : 0) + padding;
        if (expanded)
            return expandIcon.implicitHeight + visibleListHeight + spacing + pad;
        return Math.max(Config.bar.tray.background ? width : 0, expandIcon.implicitHeight + pad);
    }

    clip: true
    visible: height > 0

    implicitWidth: Tokens.sizes.bar.innerWidth
    implicitHeight: nonAnimHeight

    color: Qt.alpha(Colours.tPalette.m3surfaceContainer, (Config.bar.tray.background && items.count > 0) ? Colours.tPalette.m3surfaceContainer.a : 0)
    radius: Tokens.rounding.full

    // Windows caps this viewport; Infinity preserves the original Linux list.
    Flickable {
        id: viewport
        x: 0
        y: root.padding
        width: root.width
        height: root.visibleListHeight
        contentWidth: width
        contentHeight: layout.implicitHeight
        clip: true
        interactive: (root.expanded || !Config.bar.tray.compact) && contentHeight > height
        boundsBehavior: Flickable.StopAtBounds
        opacity: root.expanded || !Config.bar.tray.compact ? 1 : 0

        Column {
            id: layout

            anchors.horizontalCenter: parent.horizontalCenter
            spacing: Tokens.spacing.small

            add: Transition {
                Anim {
                    properties: "scale"
                    from: 0
                    to: 1
                    easing: Tokens.anim.standardDecel
                }
            }

            move: Transition {
                Anim {
                    properties: "scale"
                    to: 1
                    easing: Tokens.anim.standardDecel
                }
                Anim {
                    properties: "x,y"
                }
            }

            Repeater {
                id: items

                model: ScriptModel {
                    values: (root.sourceItems ?? SystemTray.items.values).filter(i => i.status !== Status.Passive && !GlobalConfig.bar.tray.hiddenIcons.includes(i.id))
                }

                TrayItem {
                    id: trayItem

                    interactionsEnabled: root.itemInteractionsEnabled
                    nativeMenuMode: root.itemNativeMenuMode
                    onNativeMenuRequested: (x, y) => root.itemMenuRequested(trayItem.modelData, x, y)
                }
            }
        }

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }

    Loader {
        id: expandIcon

        asynchronous: true

        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom

        active: Config.bar.tray.compact && items.count > 0

        sourceComponent: Item {
            implicitWidth: expandIconInner.implicitWidth
            implicitHeight: expandIconInner.implicitHeight - Tokens.padding.small

            MaterialIcon {
                id: expandIconInner

                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Config.bar.tray.background ? Tokens.padding.extraSmall : -Tokens.padding.small
                text: "expand_less"
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.medium
                rotation: root.expanded ? 180 : 0

                Behavior on rotation {
                    Anim {}
                }

                Behavior on anchors.bottomMargin {
                    Anim {}
                }
            }
        }
    }

    Behavior on implicitHeight {
        Anim {}
    }
}
