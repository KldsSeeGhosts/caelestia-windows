// Windows: the running-app strip previews the application it points at, one
// row per window of that application under upstream's single-window view.
// Without a strip preview this is the unchanged upstream popout, so Linux
// defaults are untouched.
import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.services as Services
import qs.utils as Utils

Item {
    id: root

    required property var popouts

    // Upstream's single-window view stays the default; the strip overrides it.
    property var toplevel: Services.Hypr.activeToplevel
    readonly property var windows: Services.RunningApps.windows
    readonly property var group: Services.RunningApps.previewGroup
    readonly property var selectedId: {
        const ids = root.group?.windowIds ?? [];
        const requested = Services.RunningApps.previewWindowId;
        if (ids.includes(requested))
            return requested;
        // Default to the application's remembered last-active window, not its
        // first-created window.
        const last = root.group ? Services.RunningApps.lastActiveWindow(root.group.id) : "";
        return ids.includes(last) ? last : (ids[0] ?? "");
    }
    readonly property var selectedWindow: root.group ? (root.windows[root.selectedId] ?? null) : null
    // Only the facade's own tracked toplevel can be captured. The service's
    // injected handle is a plain stand-in in fixtures, and the capture view
    // rejects anything that is not a real toplevel.
    readonly property var captureToplevel: {
        const id = root.selectedId;
        if (!root.group || !id)
            return null;
        return Services.Hypr.toplevels.values.find(t => t.address === id)?.wayland ?? null;
    }
    // The upstream content reads a toplevel; a group preview hands it the
    // selected window in that shape, with no capture source while minimized
    // (a minimized window must never be restored just to preview it).
    readonly property var preview: root.group ? ({
        title: root.selectedWindow?.title ?? "",
        lastIpcObject: { class: root.selectedWindow?.appId ?? "" },
        wayland: root.selectedWindow && !root.selectedWindow.minimized ? root.captureToplevel : null
    }) : root.toplevel
    readonly property bool previewUnavailable: root.group !== null
        && (root.selectedWindow === null || root.selectedWindow.minimized || !root.captureToplevel)
    readonly property int rowHeight: 40

    implicitWidth: root.group ? Math.max(content.implicitWidth, Tokens.sizes.bar.windowPreviewSize) : content.implicitWidth
    implicitHeight: content.implicitHeight + (list.visible ? Tokens.spacing.medium + list.height : 0)

    ActiveWindowContent {
        id: content

        anchors.top: parent.top
        anchors.horizontalCenter: parent.horizontalCenter

        popouts: root.popouts
        toplevel: root.preview
        reservePreviewGeometry: true
    }

    // Covers the reserved preview viewport. The upstream layout reserves that
    // area before the first frame, so its bottom edge is the preview block.
    StyledRect {
        objectName: "activeWindowPreviewUnavailable"
        anchors.horizontalCenter: content.horizontalCenter
        anchors.bottom: content.bottom
        width: Tokens.sizes.bar.windowPreviewSize
        height: width * 9 / 16
        radius: Tokens.rounding.medium
        color: Services.Colours.palette.m3surfaceContainerHigh
        visible: root.previewUnavailable

        Column {
            anchors.centerIn: parent
            spacing: Tokens.spacing.small

            IconImage {
                anchors.horizontalCenter: parent.horizontalCenter
                implicitSize: Tokens.padding.extraLarge * 2
                asynchronous: true
                source: Utils.Icons.getAppIcon(root.selectedWindow?.appId ?? "", "image-missing")
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                width: Math.min(implicitWidth, parent.parent.width - Tokens.padding.large * 2)
                horizontalAlignment: Text.AlignHCenter
                text: root.selectedWindow?.title ?? ""
                color: Services.Colours.palette.m3onSurface
                elide: Text.ElideRight
            }

            StyledText {
                anchors.horizontalCenter: parent.horizontalCenter
                text: root.selectedWindow?.minimized ? qsTr("Minimized") : qsTr("No preview")
                color: Services.Colours.palette.m3onSurfaceVariant
            }
        }
    }

    ListView {
        id: list
        objectName: "activeWindowWindowList"

        anchors.top: content.bottom
        anchors.topMargin: Tokens.spacing.medium
        anchors.horizontalCenter: parent.horizontalCenter

        visible: root.group !== null && root.group.windowIds.length > 0
        width: Tokens.sizes.bar.windowPreviewSize
        height: visible ? Math.min(contentHeight, root.rowHeight * 6) : 0
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: root.group ? root.group.windowIds : []
        activeFocusOnTab: true
        ScrollBar.vertical: ScrollBar {}

        Keys.onReturnPressed: {
            const ids = root.group?.windowIds ?? [];
            if (ids.length)
                root.activate(ids[Math.max(0, Math.min(ids.length - 1, list.currentIndex))]);
        }

        delegate: Item {
            id: row

            required property string modelData
            required property int index

            readonly property var window: root.windows[modelData] ?? null
            readonly property bool current: list.activeFocus && list.currentIndex === index

            width: list.width
            height: root.rowHeight
            opacity: row.window?.minimized ? 0.6 : 1

            HoverHandler {
                onHoveredChanged: {
                    if (hovered)
                        Services.RunningApps.previewWindowId = row.modelData;
                }
            }

            StyledRect {
                anchors.fill: parent
                radius: Tokens.rounding.medium
                color: row.current ? Services.Colours.layer(Services.Colours.palette.m3surfaceContainerHigh, 2) : "transparent"
            }

            StateLayer {
                id: activateLayer
                objectName: "activeWindowWindowActivate"

                anchors.fill: parent
                radius: Tokens.rounding.medium
                enabled: Services.RunningApps.actionsEnabled
                onClicked: root.activate(row.modelData)
                activeFocusOnTab: true
                Keys.onReturnPressed: root.activate(row.modelData)
                Keys.onSpacePressed: root.activate(row.modelData)
                Accessible.role: Accessible.Button
                Accessible.name: (row.window?.title ?? "") + (row.window?.minimized ? ", " + qsTr("Minimized") : "")
                Accessible.onPressAction: root.activate(row.modelData)
            }

            RowLayout {
                anchors.fill: parent
                anchors.leftMargin: Tokens.padding.small
                anchors.rightMargin: Tokens.padding.extraSmall
                spacing: Tokens.spacing.small

                IconImage {
                    implicitSize: 22
                    asynchronous: true
                    Layout.alignment: Qt.AlignVCenter
                    source: Utils.Icons.getAppIcon(row.window?.appId ?? "", "image-missing")
                }

                StyledText {
                    Layout.fillWidth: true
                    Layout.alignment: Qt.AlignVCenter
                    text: row.window?.title ?? ""
                    color: Services.Colours.palette.m3onSurface
                    elide: Text.ElideRight
                }

                StyledText {
                    Layout.alignment: Qt.AlignVCenter
                    visible: row.window?.minimized ?? false
                    text: qsTr("Minimized")
                    color: Services.Colours.palette.m3onSurfaceVariant
                }

                // Close stays inside the row, so a click never activates the
                // window it closes. It uses the existing guarded close path.
                Item {
                    Layout.alignment: Qt.AlignVCenter
                    implicitWidth: closeIcon.implicitHeight + Tokens.padding.small
                    implicitHeight: closeIcon.implicitHeight + Tokens.padding.small

                    MaterialIcon {
                        id: closeIcon
                        anchors.centerIn: parent
                        text: "close"
                        color: Services.Colours.palette.m3onSurfaceVariant
                    }

                    StateLayer {
                        objectName: "activeWindowWindowClose"
                        anchors.fill: parent
                        radius: Tokens.rounding.full
                        enabled: Services.RunningApps.actionsEnabled
                        onClicked: Services.RunningApps.request(row.modelData, "close")
                        activeFocusOnTab: true
                        Keys.onReturnPressed: Services.RunningApps.request(row.modelData, "close")
                        Keys.onSpacePressed: Services.RunningApps.request(row.modelData, "close")
                        Accessible.role: Accessible.Button
                        Accessible.name: qsTr("Close ") + (row.window?.title ?? "")
                        Accessible.onPressAction: Services.RunningApps.request(row.modelData, "close")
                    }
                }
            }
        }
    }

    // A pinned popout is opened for keyboard and touch. Taking focus here makes
    // Escape (handled by the wrapper) and the arrow keys work at once.
    function focusWindowList(): void {
        if (root.group)
            list.forceActiveFocus();
    }

    function activate(id: string): void {
        if (!Services.RunningApps.actionsEnabled || !id)
            return;
        root.popouts.hasCurrent = false;
        Services.RunningApps.request(id, "activate");
    }
}
