import QtQuick
import QtQuick.Controls
import Quickshell
import Caelestia.Config
import qs.services

// Retain the original tray styling and native app-owned context menus. Windows
// has no Qt semantic menu handle, so popouts.tray stays off; expand explicitly.
TrayContent {
    id: root

    // Pointer handlers are QObjects and cannot inherit screen-attached tokens.
    readonly property bool trayCompact: Config.bar.tray.compact
    readonly property real trayRowHeight: Tokens.font.body.small.pointSize * 2 + Tokens.spacing.small

    sourceItems: WindowsTray.list
    autoCollapse: false
    implicitHeight: items.count > 0 ? nonAnimHeight : 0
    // Whole rows only: a half-cut icon at the bottom reads as a rendering bug.
    maximumListHeight: (Tokens.font.body.small.pointSize * 2 + Tokens.spacing.small) * 5 - Tokens.spacing.small
    itemInteractionsEnabled: WindowsTray.activationEnabled && (expanded || !Config.bar.tray.compact)
    itemNativeMenuMode: WindowsTray.activationEnabled
    // The app opens its menu at the cursor, so ask the backend to place the
    // cursor just past the bar's outer edge; there the bar cannot cover the menu.
    function menuX(): real {
        let bar = root.parent;
        while (bar && bar.vPadding === undefined)
            bar = bar.parent;
        const edge = bar ?? root;
        return edge.mapToItem(null, edge.width, 0).x + Tokens.spacing.small;
    }

    // The native menu opens with its top-left at the cursor, while the tray
    // reports the icon's centre: lift the point by half an icon so the menu
    // aligns with the icon row instead of hanging half an icon below it.
    onItemMenuRequested: (item, x, y) => WindowsTray.openMenu(
        item, QsWindow.window, menuX(), y - Tokens.font.body.small.pointSize)

    // Mouse wheels must scroll even when the pointer is over an icon's
    // MouseArea, and must not fall through to the bar's volume/brightness.
    WheelHandler {
        parent: root.viewport
        target: null
        enabled: root.expanded || !root.trayCompact
        onWheel: event => {
            // One row per notch, so icons stay aligned to the capsule.
            const direction = (event.pixelDelta.y || event.angleDelta.y) > 0 ? -1 : 1;
            const row = root.trayRowHeight;
            const next = (Math.round(root.viewport.contentY / row) + direction) * row;
            root.viewport.contentY = Math.max(0, Math.min(root.viewport.contentHeight - root.viewport.height, next));
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
        // Right-click expands too: collapsed icons cannot be reached, so the
        // pill must not swallow the gesture.
        acceptedButtons: Qt.LeftButton | Qt.RightButton
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
