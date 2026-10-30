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
    // replaced or times out is dropped without a late WM_CLOSE. Only the head
    // may activate the foreground; later requests wait their turn so two close
    // activations cannot compete and make the earlier request time out.
    property var pendingCloses: []
    // A dispatched close coalesces duplicate requests for a bounded window.
    // This suppresses a double-click's second WM_CLOSE without blacklisting the
    // target forever: if the user cancels the native save prompt, a deliberate
    // retry works once the window expires.
    property var recentCloses: []
    readonly property int closeTimeoutMs: 2000
    readonly property int closeCoalesceMs: 1000

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

    function pruneRecentCloses(): void {
        if (!recentCloses.length)
            return;
        const now = Date.now();
        const next = recentCloses.filter(entry => entry.expiresAt > now && tracksTarget(entry));
        if (next.length !== recentCloses.length)
            recentCloses = next;
    }

    function hasCloseState(id: string, native): bool {
        try {
            pruneRecentCloses();
            return pendingCloses.some(request => request.id === id && request.native === native)
                || recentCloses.some(request => request.id === id && request.native === native);
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
        if (recentCloses.length)
            pruneRecentCloses();
        if (pendingCloses.length)
            Qt.callLater(() => root.flushCloses());
    }

    // Start the head request only. A queued request gets its full timeout after
    // it reaches the head, not while an earlier activation is still pending.
    function promoteClose(): void {
        if (!actionsEnabled)
            return;
        while (pendingCloses.length) {
            const request = pendingCloses[0];
            if (request.deadline)
                return;
            if (!tracksTarget(request)) {
                pendingCloses = pendingCloses.slice(1);
                continue;
            }
            const next = pendingCloses.slice();
            next[0] = Object.assign({}, request, { deadline: Date.now() + closeTimeoutMs });
            pendingCloses = next;
            try {
                request.native.activate();
            } catch (error) {
                pendingCloses = pendingCloses.slice(1);
                console.warn("Caelestia: running-app close was cancelled before activation.");
                continue;
            }
            return;
        }
    }

    function flushCloses(): void {
        if (!actionsEnabled) {
            pendingCloses = [];
            return;
        }
        promoteClose();
        if (!pendingCloses.length)
            return;
        const request = pendingCloses[0];
        if (!request.deadline)
            return;
        const window = resolveTarget(request.id, request.native);
        if (!window) {
            pendingCloses = pendingCloses.slice(1);
            promoteClose();
            return;
        }
        if (window.active && !window.minimized) {
            // Remove the request before dispatching so a synchronous
            // observation cannot post a second WM_CLOSE. Record the coalescing
            // window first, then roll it back if the native call did not post.
            pendingCloses = pendingCloses.slice(1);
            const recent = { id: request.id, native: request.native, expiresAt: Date.now() + closeCoalesceMs };
            recentCloses = recentCloses.concat(recent);
            try {
                request.native.close();
            } catch (error) {
                recentCloses = recentCloses.filter(entry => entry !== recent);
                console.warn("Caelestia: running-app close could not be dispatched.");
            }
            promoteClose();
            return;
        }
        if (Date.now() >= request.deadline) {
            pendingCloses = pendingCloses.slice(1);
            console.warn("Caelestia: running-app close cancelled because activation was not confirmed.");
            promoteClose();
        }
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
        // The deadline starts only when promoteClose() reaches this request.
        pendingCloses = pendingCloses.concat({ id, native, deadline: 0 });
        promoteClose();
        Qt.callLater(() => root.flushCloses());
    }
}
