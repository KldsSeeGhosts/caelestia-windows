import QtQuick

Item {
    id: root

    property var monitor: null
    // The runner inserts the real ContentWindow bindings here.
    // CONTENT_BINDINGS

    property QtObject monitorA: QtObject {
        property var activeWorkspace: normal
        property var lastIpcObject: ({specialWorkspace: {name: ""}})
    }
    property QtObject monitorB: QtObject {
        property var activeWorkspace: normal
        property var lastIpcObject: ({specialWorkspace: {name: ""}})
    }
    property QtObject normal: QtObject {
        property var toplevels: ({values: [window]})
    }
    property QtObject special: QtObject {
        property string name: "special:test"
        property var toplevels: ({values: [specialWindow]})
    }
    property QtObject window: QtObject {
        property var monitor: monitorA
        property var lastIpcObject: ({fullscreen: 2})
    }
    property QtObject specialWindow: QtObject {
        property var monitor: monitorB
        property var lastIpcObject: ({fullscreen: 2})
    }
    property QtObject switcherOverlay: QtObject {
        property var monitor: monitorA
        property var lastIpcObject: ({fullscreen: 2})
    }
    property QtObject hypr: QtObject {
        property var focusedMonitor: monitorA
        property var workspaces: ({values: [special]})
    }
    property QtObject toast: QtObject {
        // The runner inserts the real Windows Notifs function here.
        // TOAST_FUNCTION
    }
    property bool toastFullscreen: toast.hasFullscreen()
    property int assertions: 0

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Component.onCompleted: {
        try {
            check(!hasFullscreen && !hasFullscreenOnNormalWs, "missing monitor");
            monitor = monitorA;
            check(hasFullscreen && hasFullscreenOnNormalWs && toastFullscreen, "fullscreen on A");
            monitor = monitorB;
            check(!hasFullscreen && !hasFullscreenOnNormalWs, "A does not hide B");
            // The installed tracker accepted the explorer-owned Task Switching
            // overlay on the primary display, so only DP-1's binding flipped.
            // The backend classifier now rejects it before this model exists.
            monitor = monitorA;
            const savedWindow = window.lastIpcObject;
            window.lastIpcObject = {fullscreen: 0};
            normal.toplevels = {values: [window, switcherOverlay]};
            check(hasFullscreenOnNormalWs, "tracked switcher overlay hides DP-1");
            normal.toplevels = {values: [window]};
            check(!hasFullscreenOnNormalWs, "rejected switcher overlay leaves DP-1 visible");
            window.lastIpcObject = savedWindow;
            monitor = monitorB;
            hypr.focusedMonitor = monitorB;
            check(!toastFullscreen, "A does not suppress B's focused toast");
            window.monitor = monitorB;
            check(hasFullscreen && toastFullscreen, "move fullscreen to B");
            monitor = monitorA;
            check(!hasFullscreen, "move restores A");
            window.lastIpcObject = {fullscreen: 1};
            check(!toastFullscreen, "maximized is not fullscreen");
            window.lastIpcObject = {fullscreen: 2};
            monitorB.lastIpcObject = {specialWorkspace: {name: "special:test"}};
            monitor = monitorB;
            check(hasFullscreenOnNormalWs && hasFullscreen && toastFullscreen, "special fullscreen on B");
            specialWindow.monitor = monitorA;
            check(hasFullscreenOnNormalWs && !hasFullscreen && !toastFullscreen, "special on another monitor");
            monitorB.lastIpcObject = {specialWorkspace: {name: "special:missing"}};
            check(!hasFullscreen && !toastFullscreen, "missing special workspace");
            hypr.focusedMonitor = null;
            check(!toastFullscreen, "missing focused monitor");

            // A fullscreen window hidden from the task list (a tool window such
            // as mpv without a taskbar button) is not a toplevel, but the
            // backend's AppBar verdict still reports the screen as covered.
            window.lastIpcObject = {fullscreen: 0};
            monitorB.lastIpcObject = {specialWorkspace: {name: ""}};
            monitor = monitorB;
            hypr.focusedMonitor = monitorB;
            check(!hasFullscreen && !toastFullscreen, "no occluder, no toplevel fullscreen");
            monitorB.lastIpcObject = {specialWorkspace: {name: ""}, fullscreenOccluder: true};
            check(hasFullscreen && hasFullscreenOnNormalWs && toastFullscreen, "occluder alone is fullscreen on B");
            monitor = monitorA;
            check(!hasFullscreen, "B's occluder does not hide A");
            monitorB.lastIpcObject = {specialWorkspace: {name: ""}, fullscreenOccluder: false};
            monitor = monitorB;
            check(!hasFullscreen && !toastFullscreen, "occluder gone");
            console.log("CAELESTIA_PER_MONITOR_FULLSCREEN_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_PER_MONITOR_FULLSCREEN_FAIL " + error);
            Qt.exit(1);
        }
    }
}
