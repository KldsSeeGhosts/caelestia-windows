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
    // Insertion history survives temporary app cloaks. groupIds/windowIds are
    // the visible projection; these sequences restore an uncloaked slot.
    property var groupOrder: []
    property var windowOrder: []

    readonly property var observations: Logic.observe(source)

    onObservationsChanged: refresh()

    function refresh(): void {
        const next = Logic.project(observations, groupOrder, windowOrder);
        windows = next.byId;
        groups = next.groups;
        groupOrder = next.groupOrder;
        windowOrder = next.windowOrder;
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
