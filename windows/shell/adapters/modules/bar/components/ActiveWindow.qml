pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Widgets
import Caelestia.Config
import qs.components
import qs.components.effects
import qs.services as Services

// Windows: the bar's activeWindow entry is the running-application strip. One
// icon per application replaces upstream's rotated title; the title and the
// live preview live in the shared hover popout. Linux keeps the upstream
// modules/bar/components/ActiveWindow.qml.
StyledRect {
    id: root

    required property var bar
    required property var monitor
    signal interactionStarted

    // Bar.qml names this entry "taskbarActiveWindow"; the strip is that item.
    // The indicator circle needs the full row width, so the capsule keeps only
    // a hairline of side padding.
    readonly property real padding: Tokens.padding.extraSmall
    // 32 px rows: the bar's inner width minus its standard small padding.
    readonly property real rowSize: Tokens.sizes.bar.innerWidth - Tokens.padding.small
    readonly property var groups: Services.RunningApps.groups
    readonly property var windows: Services.RunningApps.windows
    readonly property var groupIds: Services.RunningApps.groupIds
    // Native foreground only: this is empty while the shell itself (a panel or
    // the bar just clicked) holds the foreground.
    readonly property string focusedGroupId: Services.RunningApps.focusedGroupId
    readonly property int focusedIndex: focusedGroupId ? groupIds.indexOf(focusedGroupId) : -1
    // Upstream ActiveWindow's available-height budget: whatever the other bar
    // entries leave, in whole rows. There is no fixed row cap.
    readonly property real maxHeight: {
        const otherModules = bar.children.filter(c => c.entryId && c.item !== this && c.entryId !== "spacer");
        const otherHeight = otherModules.reduce((acc, curr) => acc + (curr.item.nonAnimHeight ?? curr.height), 0);
        // Length - 2 because the repeater counts as a child (upstream note).
        return bar.height - otherHeight - bar.spacing * (bar.children.length - 1) - bar.vPadding * 2;
    }
    readonly property int rows: Math.max(1, Math.floor((maxHeight - padding * 2) / rowSize))
    // Where the shared popout anchors while a row is pointed at, in this
    // item's coordinates. Bar.qml prefers it over the entry's centre.
    property real hoverCenter: implicitHeight / 2
    // A right-click opens the popout deliberately, so a hover must not
    // retarget it until it closes again.
    property bool pinned: false

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

    // The app's last-active window, restoring it if it is minimized. The
    // service remembers the native foreground per app, because the facade's
    // `active` bit follows only the current activation.
    function lastActive(group): string {
        return group ? Services.RunningApps.lastActiveWindow(group.id) : "";
    }

    // Hovering a row previews that application in the shared popout. The
    // popout itself stays open until the pointer leaves it, as upstream's does.
    function preview(key: string, item: Item): void {
        if (pinned)
            return;
        Services.RunningApps.previewGroupId = key;
        Services.RunningApps.previewWindowId = lastActive(groups[key]);
        hoverCenter = item.mapToItem(root, 0, root.rowSize / 2).y;
        interactionStarted();
    }

    // A pinned popout is keyboard-driven: move focus into its window list so
    // Escape and the arrow keys work immediately, without a click.
    function focusPinnedPopout(): void {
        if (!pinned)
            return;
        const current = bar?.popouts?.current ?? null;
        if (current && typeof current.focusWindowList === "function")
            current.focusWindowList();
    }

    // Right-click pins the same popout for keyboard and touch: it opens without
    // waiting for a hover and stops following the pointer.
    function pin(key: string, item: Item): void {
        const group = groups[key];
        if (!group || !Services.RunningApps.actionsEnabled)
            return;
        const popouts = bar?.popouts ?? null;
        if (!popouts)
            return;
        pinned = true;
        Services.RunningApps.previewGroupId = key;
        Services.RunningApps.previewWindowId = lastActive(group);
        hoverCenter = item.mapToItem(root, 0, root.rowSize / 2).y;
        popouts.currentName = "activewindow";
        popouts.currentCenter = mapToItem(bar, 0, hoverCenter).y;
        popouts.hasCurrent = true;
        focusPinnedPopout();
        interactionStarted();
    }

    // Windows 11 taskbar click: an unfocused (or minimized) app focuses its
    // last-active window, a focused single-window app minimizes, and a focused
    // multi-window app cycles, all against native foreground, never the
    // retained facade.
    function activate(key: string): void {
        if (!Services.RunningApps.actionsEnabled)
            return;
        Services.RunningApps.click(key);
    }

    implicitWidth: Tokens.sizes.bar.innerWidth
    // Fit the running apps in whole rows, then scroll. The strip disappears
    // only when no application is running, minimized ones included.
    implicitHeight: groupIds.length ? Math.min(groupIds.length, rows) * rowSize + padding * 2 : 0
    visible: implicitHeight > 0
    radius: Tokens.rounding.full
    color: Services.Colours.palette.m3surfaceContainer
    clip: true

    ListView {
        id: apps
        anchors.fill: parent
        anchors.margins: root.padding
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        model: ScriptModel { values: root.groupIds }
        ScrollBar.vertical: ScrollBar {
            width: 2
            policy: apps.contentHeight > apps.height ? ScrollBar.AlwaysOn : ScrollBar.AlwaysOff
        }

        // One circle behind the foreground application's row. It slides with
        // the expressive spatial curve and fades out when no listed app owns
        // the native foreground.
        StyledRect {
            id: indicator
            z: -1
            width: apps.width
            height: root.rowSize
            radius: Tokens.rounding.full
            color: Services.Colours.palette.m3secondaryContainer
            visible: opacity > 0
            opacity: root.focusedIndex >= 0 ? 1 : 0
            y: Math.max(0, root.focusedIndex) * root.rowSize - apps.contentY

            // A scroll moves the rows, not the focus: do not animate that.
            Behavior on y {
                enabled: !apps.moving

                Anim {}
            }

            Behavior on opacity {
                Anim {
                    type: Anim.DefaultEffects
                }
            }
        }

        delegate: Item {
            id: app
            required property string modelData
            required property int index
            readonly property var group: root.groups[modelData] ?? null
            width: apps.width
            height: root.rowSize

            IconImage {
                id: appIcon
                anchors.centerIn: parent
                implicitSize: Math.round(root.rowSize * 0.7)
                asynchronous: true
                source: root.appIcon(app.group)
            }

            MaterialIcon {
                anchors.centerIn: parent
                text: "apps"
                visible: appIcon.status === Image.Error || appIcon.status === Image.Null
                color: Services.Colours.palette.m3onSurfaceVariant
            }

            StateLayer {
                id: appButton
                disabled: !Services.RunningApps.actionsEnabled
                radius: Tokens.rounding.full
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                onEntered: root.preview(app.modelData, app)
                onClicked: event => {
                    if (event.button === Qt.RightButton)
                        root.pin(app.modelData, app);
                    else
                        root.activate(app.modelData);
                }
                activeFocusOnTab: true
                // Focus lands on this child, not the delegate Item, so Tab
                // must scroll the row from here.
                onActiveFocusChanged: {
                    if (activeFocus)
                        apps.positionViewAtIndex(app.index, ListView.Contain);
                }
                Keys.onReturnPressed: root.activate(app.modelData)
                Keys.onSpacePressed: root.activate(app.modelData)
                Accessible.role: Accessible.Button
                Accessible.name: root.describe(app.group)
                Accessible.onPressAction: root.activate(app.modelData)
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

    // A hover-opened popout closes by itself; a pinned one stops following the
    // pointer only for as long as it is open.
    Connections {
        target: root.bar?.popouts ?? null

        function onHasCurrentChanged(): void {
            if (!target.hasCurrent)
                root.pinned = false;
        }

        function onCurrentNameChanged(): void {
            if (target.currentName !== "activewindow")
                root.pinned = false;
        }

        // The pinned popout content loads after the open request; take focus
        // when it appears.
        function onCurrentChanged(): void {
            root.focusPinnedPopout();
        }
    }

    Behavior on implicitHeight {
        Anim {}
    }
}
