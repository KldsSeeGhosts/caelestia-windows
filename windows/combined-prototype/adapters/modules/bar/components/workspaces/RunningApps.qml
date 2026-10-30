pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.services as Services

StyledRect {
    id: root

    required property real maximumHeight
    required property real rowSize
    signal interactionStarted
    property string selectedApp: ""
    readonly property real padding: Tokens.padding.small
    readonly property var selectedGroup: Services.RunningApps.groups[selectedApp] ?? null

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

    function selectApp(key: string, item: Item): void {
        const group = Services.RunningApps.groups[key];
        if (!group || !Services.RunningApps.actionsEnabled)
            return;
        if (group.windowIds.length === 1) {
            activate(group.windowIds[0]);
            return;
        }
        selectedApp = key;
        chooser.anchor.item = item;
        chooser.visible = true;
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
    // Reserve the same viewport while applications open/close. It disappears
    // only when there are no windows, including minimized ones.
    implicitHeight: Services.RunningApps.groupIds.length ? maximumHeight : 0
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

            StyledRect {
                anchors.fill: parent
                anchors.margins: Tokens.padding.extraSmall
                radius: Tokens.rounding.full
                color: app.group?.active ? Services.Colours.palette.m3primaryContainer : "transparent"
            }
            IconImage {
                id: appIcon
                anchors.centerIn: parent
                implicitSize: Tokens.font.body.small.pointSize * 2
                asynchronous: true
                source: root.appIcon(app.group)
                opacity: app.group?.allMinimized ? 0.55 : 1
            }
            MaterialIcon {
                anchors.centerIn: parent
                text: "apps"
                visible: appIcon.status === Image.Error || appIcon.status === Image.Null
                color: Services.Colours.palette.m3onSurfaceVariant
                opacity: app.group?.allMinimized ? 0.55 : 1
            }
            StyledRect {
                anchors.bottom: parent.bottom
                anchors.horizontalCenter: parent.horizontalCenter
                anchors.bottomMargin: Tokens.padding.extraSmall
                implicitWidth: app.group?.windowIds.length > 1 ? 8 : 4
                implicitHeight: 4
                radius: Tokens.rounding.full
                color: app.group?.allMinimized ? "transparent" : Services.Colours.palette.m3primary
                border.width: app.group?.minimized ? 1 : 0
                border.color: Services.Colours.palette.m3onSurfaceVariant
            }
            StateLayer {
                id: appButton
                disabled: !Services.RunningApps.actionsEnabled
                radius: Tokens.rounding.full
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onEntered: root.interactionStarted()
                onClicked: event => {
                    if (event.button === Qt.RightButton) {
                        root.selectedApp = app.modelData;
                        chooser.anchor.item = app;
                        chooser.visible = true;
                    } else {
                        root.selectApp(app.modelData, app);
                    }
                }
                activeFocusOnTab: true
                Keys.onReturnPressed: root.selectApp(app.modelData, app)
                Keys.onSpacePressed: root.selectApp(app.modelData, app)
                ToolTip.visible: containsMouse
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
        anchor.edges: Edges.Right | Edges.Top
        anchor.gravity: Edges.Right | Edges.Bottom
        anchor.adjustment: PopupAdjustment.Slide
        grabFocus: true
        implicitWidth: root.Tokens.sizes.bar.windowPreviewSize
        implicitHeight: Math.min(420, (screen?.height ?? 720) * 0.7, content.implicitHeight)
        color: "transparent"
        onVisibleChanged: {
            if (visible)
                windowList.forceActiveFocus();
        }

        StyledRect {
            id: content
            anchors.fill: parent
            implicitHeight: heading.implicitHeight + windowList.contentHeight + Tokens.padding.large * 3
            radius: Tokens.rounding.large
            color: Services.Colours.palette.m3surfaceContainer

            StyledText {
                id: heading
                anchors.top: parent.top
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Tokens.padding.large
                text: root.appName(root.selectedGroup)
                elide: Text.ElideRight
                font: Tokens.font.body.medium
            }

            ListView {
                id: windowList
                objectName: "runningAppsWindowList"
                anchors.top: heading.bottom
                anchors.bottom: parent.bottom
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.margins: Tokens.padding.large
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
                        root.activate(ids[Math.max(0, currentIndex)]);
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

    Behavior on implicitHeight { Anim {} }
}
