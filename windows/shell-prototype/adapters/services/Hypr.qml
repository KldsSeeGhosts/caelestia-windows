pragma Singleton

import QtQuick
import Quickshell

// Contract only. Never import or call the backend Hyprland singleton.
QtObject {
    readonly property bool available: false
    readonly property bool usingLua: false
    readonly property var focusedMonitor: null
    readonly property QtObject workspaces: QtObject {
        readonly property var values: []
    }

    function monitorFor(screen: ShellScreen): var {
        return null;
    }

    function dispatch(command: string): void {
        console.error("M1: Hypr dispatch is unavailable; operation consumed.");
    }
}
