import QtQuick
import Quickshell.Hyprland

// Loaded by URL only after CAELESTIA_WINDOWS_HYPR=1. Referencing Quickshell's
// Hyprland singleton constructs HyprlandIpc: WindowTracker, VirtualDesktops,
// the dispatcher, input-mask watchers, screen/model sync and one openwindow
// event per tracked window (connection.cpp:112-172). Every tracked window's
// HyprlandToplevel also constructs TilingManager::instance(), which runs
// rescueParked() and registers the quit handler even though tiling stays
// disabled (hyprland_toplevel.cpp:59-66; tiling.cpp:237-257). There is no
// dispatch at construction, but this is a process-wide side effect and must
// only happen behind the explicit observation opt-in.
//
// The pinned object has no initialization flag or error signal, so `initialized`
// is an adapter flag set once construction has populated the models. Bindings
// pass the backend's ObjectModel objects through unchanged: their identity is
// stable and consumers read `.values`, which keeps the original QML reactive.
QtObject {
    id: root

    readonly property bool initialized: true
    readonly property var monitors: Hyprland.monitors
    readonly property var workspaces: Hyprland.workspaces
    readonly property var toplevels: Hyprland.toplevels
    readonly property var activeToplevel: Hyprland.activeToplevel
    readonly property var focusedWorkspace: Hyprland.focusedWorkspace
    readonly property var focusedMonitor: Hyprland.focusedMonitor
    readonly property bool usingLua: Hyprland.usingLua

    // Feature-detected because the current backend pin does not expose the
    // property (a backend rebuild with the desktop-accessor capability does).
    // A missing property therefore reports false, and the facade refuses
    // workspace creation/switching instead of reaching a synthetic chord.
    readonly property bool desktopControlSupported:
        typeof Hyprland.desktopControlSupported === "boolean"
            ? Hyprland.desktopControlSupported : false

    function monitorFor(screen): var {
        return Hyprland.monitorFor(screen);
    }

    function dispatch(request): void {
        // The facade has already applied the Windows allowlist. This is the only
        // path that reaches the backend dispatcher.
        Hyprland.dispatch(request);
    }

    Component.onCompleted: {
        console.info("CAELESTIA_HYPR_BACKEND_READY usingLua=" + root.usingLua
            + " monitors=" + root.monitors.values.length
            + " workspaces=" + root.workspaces.values.length
            + " toplevels=" + root.toplevels.values.length);
    }
}
