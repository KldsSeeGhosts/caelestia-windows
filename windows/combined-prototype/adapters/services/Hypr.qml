pragma Singleton

import QtQuick
import Quickshell

// Contract only. Never import or call the backend Hyprland singleton.
// The combined prototype merges the M1 unavailable contract with the
// capsLock/numLock/kbLayout members that the original StatusIcons,
// status LockStatus and KbLayout popout types reference. Windows has no
// Hyprland IPC, so the keyboard state stays unknown and the layouts list is
// empty; the original components keep those entries collapsed or inert.
QtObject {
    readonly property bool available: false
    readonly property bool usingLua: false
    readonly property var focusedMonitor: null
    readonly property var activeToplevel: null
    readonly property bool capsLock: false
    readonly property bool numLock: false
    readonly property string kbLayout: ""
    readonly property QtObject workspaces: QtObject {
        readonly property var values: []
    }

    function monitorFor(screen: ShellScreen): var {
        return null;
    }

    function dispatch(command: string): void {
        console.error("Windows combined prototype: Hypr dispatch is unavailable; operation consumed.");
    }
}
