import QtQuick
import "RunningApps.js" as Logic

// Injected native observations keep the projection and control gate testable
// without constructing a tracker or touching any real application.
QtObject {
    id: root

    property var source: []
    property bool actionsEnabled: false
    property var groupIds: []
    property var windowIds: []
    property var groups: ({})
    property var windows: ({})

    readonly property var observations: source.filter(t => t
        && t.lastIpcObject?.mapped && t.lastIpcObject?.class && t.wayland).map(t => ({
        id: t.address,
        appId: t.lastIpcObject.class,
        title: t.title || t.lastIpcObject.class,
        native: t.wayland,
        minimized: t.wayland.minimized,
        active: t.activated,
        desktop: t.workspace?.id ?? 0
    }))

    onObservationsChanged: refresh()

    function refresh(): void {
        const next = Logic.project(observations, groupIds, windowIds);
        windows = next.byId;
        groups = next.groups;
        // Primitive keys preserve delegate identity through title/state updates.
        if (groupIds.join("\n") !== next.groupIds.join("\n"))
            groupIds = next.groupIds;
        if (windowIds.join("\n") !== next.windowIds.join("\n"))
            windowIds = next.windowIds;
    }

    function request(id: string, action: string): void {
        if (!actionsEnabled || !["activate", "minimize", "close"].includes(action))
            return;
        const expected = windows[id]?.native;
        if (!expected)
            return;
        // Popup dismissal completes before the target gets foreground focus.
        // Resolve again after queuing: the selected window may have closed.
        Qt.callLater(() => {
            const window = root.windows[id];
            if (!root.actionsEnabled || window?.native !== expected)
                return;
            if (action === "activate")
                window.native.activate();
            else if (action === "minimize")
                window.native.minimized = true;
            else {
                window.native.activate();
                Qt.callLater(() => {
                    if (root.actionsEnabled && root.windows[id]?.native === window.native)
                        window.native.close();
                });
            }
        });
    }
}
