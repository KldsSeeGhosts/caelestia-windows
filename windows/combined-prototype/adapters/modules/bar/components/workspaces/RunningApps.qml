pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.effects
import qs.services as Services

StyledRect {
    id: root

    required property real maximumHeight
    required property real rowSize
    signal interactionStarted
    property string selectedApp: ""
    // The bar that hosts the pill; the chooser opens past its outer edge.
    property Item edgeItem: null
    readonly property real padding: Tokens.padding.small
    readonly property var selectedGroup: Services.RunningApps.groups[selectedApp] ?? null
    // The chooser is its own native popup. A click on the parent window must
    // still dismiss it where the platform does not deliver the native
    // outside-click close (the offscreen harness included).
    readonly property Item dismissHost: {
        let item = root;
        while (item.parent)
            item = item.parent;
        return item;
    }

    function appName(group): string {
        // Re-resolve friendly names when the existing catalog finishes scanning.
        DesktopEntries.applications.values;
        return group ? DesktopEntries.heuristicLookup(group.appId)?.name || group.appId : "";
    }

    function appIcon(group): string {
        const id = group?.appId ?? "";
        DesktopEntries.applications.values;
        return Quickshell.iconPath(DesktopEntries.heuristicLookup(id)?.icon || id, "image-missing");
    }

    function describe(group): string {
        if (!group)
            return "";
        return appName(group) + ", " + group.windowIds.length + " open"
            + (group.minimized ? ", " + group.minimized + " minimized" : "");
    }

    function activate(id: string): void {
        chooser.visible = false;
        Services.RunningApps.request(id, "activate");
    }

    function openChooser(key: string, item: Item): void {
        if (!Services.RunningApps.groups[key] || !Services.RunningApps.actionsEnabled)
            return;
        selectedApp = key;
        chooser.anchor.item = item;
        // Clear the rest of the bar so the card floats beside it, not over it.
        chooser.barOverhang = edgeItem ? Math.max(0, edgeItem.width - item.mapToItem(edgeItem, item.width, 0).x) : 0;
        // A chooser opened for a new gesture starts at the first window.
        windowList.currentIndex = 0;
        chooser.visible = true;
    }

    function selectApp(key: string, item: Item): void {
        const group = Services.RunningApps.groups[key];
        if (!group || !Services.RunningApps.actionsEnabled)
            return;
        if (group.windowIds.length === 1) {
            activate(group.windowIds[0]);
            return;
        }
        openChooser(key, item);
    }

    onSelectedGroupChanged: {
        if (!selectedGroup)
            chooser.visible = false;
    }
    onVisibleChanged: {
        if (!visible)
            chooser.visible = false;
    }

    objectName: "runningAppsPill"
    implicitWidth: Tokens.sizes.bar.innerWidth
    // Fit the open apps up to the row budget, then scroll. It disappears only
    // when there are no windows, including minimized ones.
    implicitHeight: {
        const count = Services.RunningApps.groupIds.length;
        return count ? Math.min(maximumHeight, count * rowSize + padding * 2) : 0;
    }
    visible: implicitHeight > 0
    radius: Tokens.rounding.full
    color: Services.Colours.tPalette.m3surfaceContainer
    clip: true

    ListView {
        id: apps
        anchors.fill: parent
        anchors.margins: root.padding
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: ScriptModel { values: Services.RunningApps.groupIds }
        ScrollBar.vertical: ScrollBar {
            width: 2
            policy: apps.contentHeight > apps.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        }

        delegate: Item {
            id: app
            required property string modelData
            readonly property var group: Services.RunningApps.groups[modelData] ?? null
            width: apps.width
            height: root.rowSize

            IconImage {
                id: appIcon
                anchors.centerIn: parent
                implicitSize: Math.round(root.rowSize * 0.62)
                asynchronous: true
                source: root.appIcon(app.group)
                opacity: app.group?.allMinimized ? 0.45 : 1

                Behavior on opacity { Anim {} }
            }
            MaterialIcon {
                anchors.centerIn: parent
                text: "apps"
                visible: appIcon.status === Image.Error || appIcon.status === Image.Null
                color: Services.Colours.palette.m3onSurfaceVariant
                opacity: appIcon.opacity
            }
            // Dock-style state on the bar's outer edge: a dot per running app,
            // a longer pill for several windows, an outline when all are
            // minimized. It sits beside the icon instead of colliding with it.
            StyledRect {
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                implicitWidth: 3
                implicitHeight: app.group?.windowIds.length > 1 ? Math.round(root.rowSize * 0.4) : 6
                radius: Tokens.rounding.full
                color: app.group?.allMinimized ? "transparent"
                    : app.group?.active ? Services.Colours.palette.m3primary
                    : Services.Colours.palette.m3onSurfaceVariant
                border.width: app.group?.allMinimized ? 1 : 0
                border.color: Services.Colours.palette.m3outline

                Behavior on implicitHeight { Anim {} }
            }
            StateLayer {
                id: appButton
                disabled: !Services.RunningApps.actionsEnabled
                radius: Tokens.rounding.full
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onEntered: root.interactionStarted()
                onClicked: event => {
                    if (event.button === Qt.RightButton)
                        root.openChooser(app.modelData, app);
                    else
                        root.selectApp(app.modelData, app);
                }
                activeFocusOnTab: true
                Keys.onReturnPressed: root.selectApp(app.modelData, app)
                Keys.onSpacePressed: root.selectApp(app.modelData, app)
                ToolTip.visible: containsMouse && !chooser.visible
                ToolTip.delay: 500
                ToolTip.text: root.describe(app.group)
                Accessible.role: Accessible.Button
                Accessible.name: root.describe(app.group)
                Accessible.onPressAction: root.selectApp(app.modelData, app)
            }
        }
    }

    // Consume even a non-overflowing list's wheel events. They must not fall
    // through to the enclosing workspace/volume/brightness scroll actions.
    WheelHandler {
        target: null
        onWheel: event => {
            const delta = event.pixelDelta.y || event.angleDelta.y / 120 * root.rowSize * 3;
            apps.contentY = Math.max(0, Math.min(Math.max(0, apps.contentHeight - apps.height), apps.contentY - delta));
            event.accepted = true;
        }
    }

    PopupWindow {
        id: chooser
        objectName: "runningAppsChooser"
        // Right edge only: the menu is centred vertically on the icon.
        anchor.edges: Edges.Right
        anchor.gravity: Edges.Right
        anchor.adjustment: PopupAdjustment.Slide
        grabFocus: true
        // The window is transparent margin around the card: a gap from the
        // bar on the left and room for the shadow on the other sides.
        property real barOverhang: 0
        readonly property real gap: barOverhang + root.Tokens.spacing.small
        readonly property real shadowRoom: root.Tokens.padding.large
        implicitWidth: 304 + gap + shadowRoom
        implicitHeight: Math.min(440, (screen?.height ?? 720) * 0.7, content.implicitHeight) + shadowRoom * 2
        color: "transparent"
        onVisibleChanged: {
            if (visible)
                windowList.forceActiveFocus();
        }

        Elevation {
            anchors.fill: content
            radius: content.radius
            level: 2
        }

        StyledRect {
            id: content
            anchors.fill: parent
            anchors.leftMargin: chooser.gap
            anchors.rightMargin: chooser.shadowRoom
            anchors.topMargin: chooser.shadowRoom
            anchors.bottomMargin: chooser.shadowRoom
            implicitHeight: windowList.contentHeight + Tokens.padding.small * 2
            radius: Tokens.rounding.large
            color: Services.Colours.palette.m3surfaceContainer

            ListView {
                id: windowList
                objectName: "runningAppsWindowList"
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.topMargin: Tokens.padding.small
                anchors.leftMargin: Tokens.padding.small
                anchors.rightMargin: Tokens.padding.small
                anchors.bottomMargin: Tokens.padding.small
                spacing: 0
                clip: true
                boundsBehavior: Flickable.StopAtBounds
                model: ScriptModel { values: root.selectedGroup?.windowIds ?? [] }
                ScrollBar.vertical: ScrollBar {}
                Keys.onEscapePressed: chooser.visible = false
                Keys.onDownPressed: incrementCurrentIndex()
                Keys.onUpPressed: decrementCurrentIndex()
                Keys.onReturnPressed: {
                    const ids = root.selectedGroup?.windowIds ?? [];
                    if (ids.length)
                        root.activate(ids[Math.max(0, Math.min(ids.length - 1, currentIndex))]);
                }

                delegate: RunningAppWindow {
                    required property string modelData
                    required property int index
                    width: windowList.width
                    window: Services.RunningApps.windows[modelData] ?? null
                    actionsEnabled: Services.RunningApps.actionsEnabled
                    keyboardSelected: windowList.activeFocus && windowList.currentIndex === index
                    onActivateRequested: root.activate(modelData)
                    onMinimizeRequested: Services.RunningApps.request(modelData, "minimize")
                    onCloseRequested: {
                        chooser.visible = false;
                        Services.RunningApps.request(modelData, "close");
                    }
                }
            }
        }
    }

    // Sits above the bar only for the chooser's lifetime, so an outside press
    // dismisses instead of acting on whatever was underneath.
    MouseArea {
        id: outsideDismiss
        objectName: "runningAppsOutsideDismiss"
        parent: root.dismissHost
        width: parent ? parent.width : 0
        height: parent ? parent.height : 0
        z: 1000000
        visible: chooser.visible
        enabled: visible
        acceptedButtons: Qt.LeftButton | Qt.RightButton
        onClicked: chooser.visible = false
    }

    Behavior on implicitHeight { Anim {} }
}
