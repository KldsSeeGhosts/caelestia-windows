import QtQuick
import "RunningApps.js" as Logic

// Injected native observations keep the projection and control gate testable
// without constructing a tracker or touching any real application.
QtObject {
    id: root

    property var source: []
    property bool actionsEnabled: false
    // Raw native foreground HWND, lowercase hex without a prefix, from the
    // backend's WinEvent stream. Empty while a shell surface or another
    // non-application window owns the foreground. The facade's `activated`
    // value is retained while the bar itself has focus, so it must never decide
    // whether an application is focused.
    property string foregroundAddress: ""
    readonly property var foregroundWindow: foregroundAddress ? (windows[foregroundAddress] ?? null) : null
    readonly property string focusedGroupId: foregroundWindow ? foregroundWindow.appId.toLowerCase() : ""
    // Hover preview shared by the running-app strip and the bar popout. The
    // popout keeps one row per window of this application.
    property string previewGroupId: ""
    property string previewWindowId: ""
    readonly property var previewGroup: previewGroupId ? (groups[previewGroupId] ?? null) : null
    property var groupIds: []
    property var windowIds: []
    property var groups: ({})
    property var windows: ({})
    // Last window the native foreground reported for each application, keyed
    // by group id. Unlike the facade's `active` bit, this survives the user
    // switching to another application. Entries are dropped when the window
    // closes; the visible window order is never changed.
    property var lastActive: ({})
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
    // Monotonic elapsed time in ms. Advances by at least 100 ms per timer
    // callback and by the actual positive wall-clock delta when the event loop
    // stalls, while never moving backward or jumping forward excessively if
    // the system clock is adjusted.
    property double monotonicMs: 0
    property double lastWallMs: 0
    readonly property int closeTimeoutMs: 2000
    readonly property int closeCoalesceMs: 1000

    function nowMs(minStepMs: int): double {
        const wall = Date.now();
        if (lastWallMs <= 0) {
            lastWallMs = wall;
            monotonicMs += Math.max(0, minStepMs);
            return monotonicMs;
        }
        const delta = wall - lastWallMs;
        lastWallMs = wall;
        // A positive delta up to 60s reflects real elapsed time (including
        // event-loop stalls); negative or huge jumps (clock sync) fall back to
        // the minimum step so deadlines stay bounded in both directions.
        const step = (delta >= 0 && delta <= 60000)
            ? Math.max(minStepMs, delta)
            : Math.max(minStepMs, 100);
        monotonicMs += step;
        return monotonicMs;
    }

    readonly property var observations: Logic.observe(source)

    onObservationsChanged: refresh()
    onForegroundAddressChanged: recordForeground()
    onActionsEnabledChanged: {
        if (!actionsEnabled)
            pendingCloses = [];
    }

    // The native foreground is the only source for "last used": the facade's
    // `active` bit moves away with the current activation.
    function recordForeground(): void {
        // Resolve the handle directly: the foregroundWindow binding may still
        // hold the previous address while this change signal is being handled.
        const address = foregroundAddress;
        const window = address ? windows[address] : null;
        if (!window)
            return;
        const key = window.appId.toLowerCase();
        if (lastActive[key] === address)
            return;
        const next = Object.assign({}, lastActive);
        next[key] = address;
        lastActive = next;
    }

    function lastActiveWindow(id: string): string {
        return Logic.lastActiveWindow(groups[id] ?? null, windows, lastActive);
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

    function pruneRecentCloses(now: double): void {
        if (!recentCloses.length)
            return;
        const current = now > 0 ? now : nowMs(0);
        const next = recentCloses.filter(entry => entry.expiresAt > current && tracksTarget(entry));
        if (next.length !== recentCloses.length)
            recentCloses = next;
    }

    function hasCloseState(id: string, native): bool {
        try {
            pruneRecentCloses(nowMs(0));
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
        const retained = Logic.retainLastActive(next.groups, lastActive);
        if (Object.keys(retained).length !== Object.keys(lastActive).length)
            lastActive = retained;
        // A window can gain the foreground before the projection observes it.
        recordForeground();
        if (pendingCloses.length)
            pendingCloses = pendingCloses.filter(tracksTarget);
        if (recentCloses.length)
            pruneRecentCloses(nowMs(0));
        if (previewGroupId && !next.groups[previewGroupId]) {
            previewGroupId = "";
            previewWindowId = "";
        }
        if (pendingCloses.length)
            Qt.callLater(() => root.flushCloses(0));
    }

    // Start the head request only. A queued request gets its full timeout after
    // it reaches the head, not while an earlier activation is still pending.
    function promoteClose(now: double): void {
        if (!actionsEnabled)
            return;
        const current = now > 0 ? now : nowMs(0);
        while (pendingCloses.length) {
            const request = pendingCloses[0];
            if (request.deadline)
                return;
            if (!tracksTarget(request)) {
                pendingCloses = pendingCloses.slice(1);
                continue;
            }
            const next = pendingCloses.slice();
            next[0] = Object.assign({}, request, { deadline: current + closeTimeoutMs });
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

    function flushCloses(minStepMs: int): void {
        if (!actionsEnabled) {
            pendingCloses = [];
            return;
        }
        const now = nowMs(minStepMs);
        if (recentCloses.length)
            pruneRecentCloses(now);
        promoteClose(now);
        if (!pendingCloses.length)
            return;
        const request = pendingCloses[0];
        if (!request.deadline)
            return;
        const window = resolveTarget(request.id, request.native);
        if (!window) {
            pendingCloses = pendingCloses.slice(1);
            promoteClose(now);
            return;
        }
        // Check deadline expiry BEFORE dispatching close so an activation that
        // lands after the timeout (e.g. during an event-loop stall) is rejected.
        if (now >= request.deadline) {
            pendingCloses = pendingCloses.slice(1);
            console.warn("Caelestia: running-app close cancelled because activation was not confirmed.");
            promoteClose(now);
            return;
        }
        if (window.active && !window.minimized) {
            // Remove the request before dispatching so a synchronous
            // observation cannot post a second WM_CLOSE. Record the coalescing
            // window first, then roll it back if the native call did not post.
            pendingCloses = pendingCloses.slice(1);
            const recent = { id: request.id, native: request.native, expiresAt: now + closeCoalesceMs };
            recentCloses = recentCloses.concat(recent);
            try {
                request.native.close();
            } catch (error) {
                recentCloses = recentCloses.filter(entry => entry !== recent);
                console.warn("Caelestia: running-app close could not be dispatched.");
            }
            promoteClose(now);
        }
    }

    // Activation can wait for a virtual-desktop switch in the backend. Observe
    // its completion before WM_CLOSE so a save prompt cannot open out of sight.
    // Never turn a focus denial into a delayed, unobserved close.
    readonly property Timer closeTimer: Timer {
        interval: 100
        repeat: true
        running: root.actionsEnabled && (root.pendingCloses.length > 0 || root.recentCloses.length > 0)
        onTriggered: root.flushCloses(100)
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
        promoteClose(nowMs(0));
        Qt.callLater(() => root.flushCloses(0));
    }

    // Windows 11 taskbar click, decided from the native foreground window and
    // the app's remembered last-active window.
    function clickAction(id: string): var {
        return Logic.clickAction(groups[id] ?? null, windows, foregroundAddress, lastActive);
    }

    function click(id: string): void {
        const result = clickAction(id);
        if (result.action !== "none")
            request(result.id, result.action);
    }
}
