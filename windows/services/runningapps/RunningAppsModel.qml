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
    // A close waits for the backend to observe restore and activation. One
    // entry belongs to one target lifetime; a target that disappears, is
    // replaced or times out is dropped without a late WM_CLOSE.
    property var pendingCloses: []
    // A dispatched close stays associated with its target lifetime so duplicate
    // requests cannot post a second WM_CLOSE while the application is open.
    property var closedTargets: []
    readonly property int closeTimeoutMs: 2000

    readonly property var observations: Logic.observe(source)

    onObservationsChanged: refresh()
    onActionsEnabledChanged: {
        if (!actionsEnabled)
            pendingCloses = [];
    }

    function resolveTarget(id: string, native): var {
        try {
            if (!native)
                return null;
            const window = windows[id];
            return window && window.native === native ? window : null;
        } catch (error) {
            // A removed Toplevel can be deleted before the source refresh.
            return null;
        }
    }

    function tracksTarget(entry): bool {
        try {
            return !!entry.native && !!resolveTarget(entry.id, entry.native);
        } catch (error) {
            return false;
        }
    }

    function hasCloseState(id: string, native): bool {
        try {
            return pendingCloses.some(request => request.id === id && request.native === native)
                || closedTargets.some(request => request.id === id && request.native === native);
        } catch (error) {
            return false;
        }
    }

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
        if (pendingCloses.length)
            pendingCloses = pendingCloses.filter(tracksTarget);
        if (closedTargets.length)
            closedTargets = closedTargets.filter(tracksTarget);
        if (pendingCloses.length)
            Qt.callLater(() => root.flushCloses());
    }

    function flushCloses(): void {
        if (!actionsEnabled) {
            pendingCloses = [];
            return;
        }
        const waiting = [];
        for (const request of pendingCloses) {
            const window = resolveTarget(request.id, request.native);
            if (!window)
                continue;
            if (window.active && !window.minimized) {
                try {
                    request.native.close();
                } catch (error) {
                    console.warn("Caelestia: running-app close could not be dispatched.");
                }
                // One graceful close per target lifetime. A cancelled native
                // save prompt must not turn a retry into a second WM_CLOSE.
                closedTargets = closedTargets.concat({ id: request.id, native: request.native });
                continue;
            }
            if (Date.now() < request.deadline) {
                waiting.push(request);
                continue;
            }
            console.warn("Caelestia: running-app close cancelled because activation was not confirmed.");
        }
        if (waiting.length !== pendingCloses.length)
            pendingCloses = waiting;
    }

    // Activation can wait for a virtual-desktop switch in the backend. Observe
    // its completion before WM_CLOSE so a save prompt cannot open out of sight.
    // Never turn a focus denial into a delayed, unobserved close.
    readonly property Timer closeTimer: Timer {
        interval: 100
        repeat: true
        running: root.actionsEnabled && root.pendingCloses.length > 0
        onTriggered: root.flushCloses()
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
            const window = root.resolveTarget(id, expected);
            if (!root.actionsEnabled || !window)
                return;
            if (action === "activate") {
                try {
                    window.native.activate();
                } catch (error) {
                    console.warn("Caelestia: running-app activation could not be dispatched.");
                }
            } else if (action === "minimize") {
                try {
                    window.native.minimized = true;
                } catch (error) {
                    console.warn("Caelestia: running-app minimize could not be dispatched.");
                }
            } else {
                root.requestClose(id, expected);
            }
        });
    }

    function requestClose(id: string, native): void {
        if (!actionsEnabled || !native || !root.resolveTarget(id, native) || hasCloseState(id, native))
            return;
        pendingCloses = pendingCloses.concat({ id, native, deadline: Date.now() + closeTimeoutMs });
        try {
            native.activate();
        } catch (error) {
            pendingCloses = pendingCloses.filter(request => request.id !== id);
            console.warn("Caelestia: running-app close was cancelled before activation.");
            return;
        }
        Qt.callLater(() => root.flushCloses());
    }
}
