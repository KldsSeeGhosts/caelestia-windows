import QtQuick
import Quickshell
import qs.services
import qs.modules.drawers

ShellRoot {
    id: root

    property var monitor: null
    // Run the complete production window, including the bar's visibility
    // consumer, with an injected Hypr backend and every native opt-in off.
    property ContentWindow content: ContentWindow {
        screen: Quickshell.screens[0]
        visible: false
        interactionEnabled: false
    }
    readonly property bool hasFullscreen: content.hasFullscreen
    readonly property bool hasFullscreenOnNormalWs: content.hasFullscreenOnNormalWs

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
        property bool initialized: true
        property bool capsLock: false
        property bool numLock: false
        property string kbLayout: "us"
        property string kbLayoutFull: "English (US)"
        property var monitors: ({values: [monitorA, monitorB]})
        property var toplevels: ({values: [window, specialWindow]})
        property var focusedWorkspace: normal
        property var focusedMonitor: monitorA
        property var workspaces: ({values: [special]})
        function monitorFor(screen): var { return root.monitor; }
    }
    property bool toastFullscreen: Notifs.hasFullscreen()
    property int assertions: 0

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            Hypr._nativeLoader.active = false;
            Hypr.backend = hypr;
            Hypr.enabled = true;
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
            monitor = monitorB;
            check(!hasFullscreen && !hasFullscreenOnNormalWs && content.bar.shouldBeVisible,
                "maximized window on the bar's own monitor does not hide the bar");
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
            // Drop the singleton's reference before the fixture-owned backend
            // is destroyed during engine teardown.
            Hypr.enabled = false;
            Hypr.backend = null;
            console.log("CAELESTIA_PER_MONITOR_FULLSCREEN_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_PER_MONITOR_FULLSCREEN_FAIL " + error);
            Qt.exit(1);
        }
    }
}
