pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.components.effects
import qs.services

// The footer's "…" menu, drawn inside the drawer so it never needs a window
// of its own. Up and Down move (over separators), Return and Enter act,
// Escape closes and hands focus back to the button that opened it.
// OpenUsage's is a native NSMenu (Views/PopoverFooter.swift); the sizes follow
// the maintainer's capture of it: 203 wide, 24 dp items, 13 dp text with the
// shortcut hint muted on the right, 11 dp separators, a 12 dp radius and an
// accent highlight under the pointer or the keyboard.
FocusScope {
    id: root
    objectName: "quotaMenu"

    // [{ key, label, shortcut, shortcutIcon, enabled }] or { separator: true }.
    // `shortcutIcon` draws a Material symbol for a key the text font lacks (Return).
    property var entries: []
    property bool open: false
    property Item returnFocusTo
    property string family: ""

    signal chosen(string key)

    implicitWidth: 203
    implicitHeight: list.implicitHeight + 10
    visible: open

    function firstItem(): var {
        for (let i = 0; i < entries.length; i++) {
            const item = repeater.itemAt(i);
            if (item && !entries[i].separator && item.enabled)
                return item;
        }
        return null;
    }
    function show(): void {
        open = true;
        const first = root.firstItem();
        if (first)
            first.forceActiveFocus(Qt.TabFocusReason);
    }
    function hide(): void {
        open = false;
        if (returnFocusTo)
            returnFocusTo.forceActiveFocus(Qt.TabFocusReason);
    }
    // The next enabled item that way, over separators; stays put at the ends.
    function step(from: int, by: int): void {
        for (let i = from + by; i >= 0 && i < entries.length; i += by) {
            const next = repeater.itemAt(i);
            if (next && !entries[i].separator && next.enabled) {
                next.forceActiveFocus(Qt.TabFocusReason);
                return;
            }
        }
    }

    // Tabbing or clicking away closes it without stealing focus back.
    onActiveFocusChanged: if (!activeFocus && open)
        open = false

    Keys.onEscapePressed: root.hide()

    Elevation {
        anchors.fill: parent
        radius: Tokens.rounding.medium
        level: 2

        StyledRect {
            anchors.fill: parent
            radius: Tokens.rounding.medium
            color: Colours.palette.m3surfaceContainerHigh

            Column {
                id: list

                anchors.fill: parent
                anchors.margins: 5

                Repeater {
                    id: repeater

                    model: root.entries
                    delegate: AbstractButton {
                        id: item

                        required property var modelData
                        required property int index
                        readonly property bool separator: modelData.separator === true
                        readonly property bool lit: !separator && enabled && (hovered || activeFocus)

                        objectName: separator ? "quotaMenuSeparator" : "quotaMenuItem"
                        // Arrows move inside the menu; Tab leaves it, which closes it.
                        activeFocusOnTab: false
                        focusPolicy: separator ? Qt.NoFocus : Qt.StrongFocus
                        width: list.width
                        height: separator ? 11 : 24
                        enabled: !separator && modelData.enabled
                        hoverEnabled: !separator
                        Accessible.role: separator ? Accessible.Separator : Accessible.MenuItem
                        Accessible.name: separator ? "" : modelData.label
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
                        background: Rectangle {
                            radius: 6
                            color: item.lit ? Colours.palette.m3primary : "transparent"
                            Rectangle {
                                visible: item.separator
                                anchors.verticalCenter: parent.verticalCenter
                                x: 11
                                width: parent.width - 22
                                height: 1
                                color: Qt.alpha(Colours.palette.m3onSurface, 0.12)
                            }
                        }
                        contentItem: Item {
                            visible: !item.separator
                            opacity: item.enabled ? 1 : 0.38
                            // The highlight appears at once, so its foreground
                            // does too: a StyledText animates its colour, which
                            // briefly made the selected item look disabled.
                            Text {
                                objectName: "quotaMenuLabel"
                                anchors.left: parent.left
                                anchors.leftMargin: 11
                                anchors.verticalCenter: parent.verticalCenter
                                text: item.modelData.label ?? ""
                                color: item.lit ? Colours.palette.m3onPrimary : Colours.palette.m3onSurface
                                renderType: Text.NativeRendering
                                textFormat: Text.PlainText
                                font.family: root.family
                                font.pixelSize: 13
                            }
                            MaterialIcon {
                                objectName: "quotaMenuShortcutIcon"
                                anchors.right: parent.right
                                anchors.rightMargin: 11
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !!item.modelData.shortcutIcon
                                text: item.modelData.shortcutIcon ?? ""
                                color: item.lit ? Colours.palette.m3onPrimary : Colours.palette.m3onSurfaceVariant
                                fontStyle: Tokens.font.icon.builders.small.scale(0.75).build()
                            }
                            Text {
                                objectName: "quotaMenuShortcut"
                                anchors.right: parent.right
                                anchors.rightMargin: 11
                                anchors.verticalCenter: parent.verticalCenter
                                visible: !!item.modelData.shortcut
                                text: item.modelData.shortcut ?? ""
                                color: item.lit ? Colours.palette.m3onPrimary : Colours.palette.m3onSurfaceVariant
                                renderType: Text.NativeRendering
                                textFormat: Text.PlainText
                                font.family: root.family
                                font.pixelSize: 13
                            }
                        }
                    }
                }
            }
        }
    }
}
