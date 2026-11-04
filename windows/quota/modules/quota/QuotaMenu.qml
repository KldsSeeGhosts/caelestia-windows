pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.components.effects
import qs.services

// The footer's small menu, drawn inside the drawer so it never needs a window
// of its own. Up and Down move, Return and Enter act, Escape closes and hands
// focus back to the button that opened it.
FocusScope {
    id: root
    objectName: "quotaMenu"

    // [{ key, label, icon, enabled }]
    property var entries: []
    property bool open: false
    property Item returnFocusTo
    property string family: ""

    signal chosen(string key)

    implicitWidth: 208
    implicitHeight: list.implicitHeight + Tokens.padding.extraSmall * 2
    visible: open

    function show(): void {
        open = true;
        const first = repeater.itemAt(0);
        if (first)
            first.forceActiveFocus(Qt.TabFocusReason);
    }
    function hide(): void {
        open = false;
        if (returnFocusTo)
            returnFocusTo.forceActiveFocus(Qt.TabFocusReason);
    }
    function step(from: int, by: int): void {
        const next = repeater.itemAt(Math.max(0, Math.min(entries.length - 1, from + by)));
        if (next && next.enabled)
            next.forceActiveFocus(Qt.TabFocusReason);
    }

    // Tabbing or clicking away closes it without stealing focus back.
    onActiveFocusChanged: if (!activeFocus && open)
        open = false

    Keys.onEscapePressed: root.hide()

    Elevation {
        anchors.fill: parent
        radius: Tokens.rounding.large
        level: 2

        StyledRect {
            anchors.fill: parent
            radius: Tokens.rounding.large
            color: Colours.palette.m3surfaceContainerHigh

            Column {
                id: list

                anchors.fill: parent
                anchors.margins: Tokens.padding.extraSmall

                Repeater {
                    id: repeater

                    model: root.entries
                    delegate: AbstractButton {
                        id: item

                        required property var modelData
                        required property int index

                        objectName: "quotaMenuItem"
                        // Arrows move inside the menu; Tab leaves it, which closes it.
                        activeFocusOnTab: false
                        width: list.width
                        height: 40
                        enabled: modelData.enabled
                        hoverEnabled: true
                        onClicked: {
                            root.open = false;
                            root.chosen(modelData.key);
                            if (root.returnFocusTo)
                                root.returnFocusTo.forceActiveFocus(Qt.TabFocusReason);
                        }
                        Keys.onReturnPressed: item.click()
                        Keys.onEnterPressed: item.click()
                        Keys.onUpPressed: root.step(index, -1)
                        Keys.onDownPressed: root.step(index, 1)
                        Accessible.name: modelData.label
                        background: Rectangle {
                            radius: Tokens.rounding.medium
                            color: Qt.alpha(Colours.palette.m3onSurface, item.down ? 0.12 : item.hovered || item.activeFocus ? 0.08 : 0)
                            border.width: item.activeFocus ? 2 : 0
                            border.color: Colours.palette.m3primary
                        }
                        contentItem: Row {
                            spacing: Tokens.spacing.small
                            leftPadding: Tokens.padding.medium
                            opacity: item.enabled ? 1 : 0.38
                            MaterialIcon {
                                anchors.verticalCenter: parent.verticalCenter
                                text: item.modelData.icon
                                color: Colours.palette.m3onSurfaceVariant
                            }
                            StyledText {
                                anchors.verticalCenter: parent.verticalCenter
                                text: item.modelData.label
                                font.family: root.family
                                font.pixelSize: 14
                            }
                        }
                    }
                }
            }
        }
    }
}
