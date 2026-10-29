import QtQuick
import QtQuick.Controls
import Quickshell
import Caelestia.Config
import qs.services

// Retain the original tray styling and native app-owned context menus. Windows
// has no Qt semantic menu handle, so popouts.tray stays off; expand explicitly.
TrayContent {
    id: root

    sourceItems: WindowsTray.list
    implicitHeight: items.count > 0 ? nonAnimHeight : 0
    maximumListHeight: (Tokens.font.body.small.pointSize * 2 + Tokens.spacing.small) * 5.5 - Tokens.spacing.small
    itemInteractionsEnabled: WindowsTray.activationEnabled && (expanded || !Config.bar.tray.compact)
    itemNativeMenuMode: WindowsTray.activationEnabled
    onItemMenuRequested: (item, x, y) => WindowsTray.openMenu(item, QsWindow.window, x, y)

    // Mouse wheels must scroll even when the pointer is over an icon's
    // MouseArea, and must not fall through to the bar's volume/brightness.
    WheelHandler {
        parent: root.viewport
        target: null
        enabled: root.expanded || !Config.bar.tray.compact
        onWheel: event => {
            const rowHeight = Tokens.font.body.small.pointSize * 2 + Tokens.spacing.small;
            const delta = event.pixelDelta.y || event.angleDelta.y / 120 * rowHeight * 3;
            root.viewport.contentY = Math.max(0, Math.min(root.viewport.contentHeight - root.viewport.height, root.viewport.contentY - delta));
            event.accepted = true;
        }
    }

    MouseArea {
        objectName: "trayExpandButton"
        z: 1
        x: 0
        y: root.expanded ? root.expandIcon.y : 0
        width: root.width
        height: root.expanded ? root.expandIcon.height : root.height
        enabled: Config.bar.tray.compact && root.items.count > 0
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onClicked: root.expanded = !root.expanded

        ToolTip.visible: containsMouse
        ToolTip.delay: 500
        ToolTip.text: "Background apps"
        Accessible.role: Accessible.Button
        Accessible.name: "Background apps"
        Accessible.description: root.expanded ? "Collapse background apps" : "Expand background apps"
        Accessible.onPressAction: root.expanded = !root.expanded
    }
}
