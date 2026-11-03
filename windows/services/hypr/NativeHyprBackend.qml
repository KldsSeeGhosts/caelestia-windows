import QtQuick
import Quickshell
import Quickshell.Hyprland
import Quickshell.Windows
import Caelestia.Config

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
// The pinned Quickshell.Hyprland object has no init flag or error signal, so
// `initialized` is an adapter flag. Bindings pass the backend's ObjectModel
// objects through unchanged: their identity is stable and consumers read
// `.values`, which keeps the original QML reactive.
QtObject {
    id: root

    readonly property bool initialized: true
    readonly property var monitors: Hyprland.monitors
    readonly property var workspaces: Hyprland.workspaces
    readonly property var toplevels: Hyprland.toplevels
    readonly property bool foregroundValidated: true
    // One native observer over WindowTracker's existing WinEvent hook, exposed
    // by the backend. It keeps the last application while Windows shell
    // overlays or the shell's own panels own focus, and updates on title
    // changes; neither a helper process nor a QML timer samples the foreground.
    readonly property var activeToplevel: {
        if (!Foreground.address)
            return null;
        const tracked = toplevels.values.find(t =>
            t.address.toLowerCase().replace(/^0x/, "") === Foreground.address);
        // Some application windows are omitted by the backend's task-switcher
        // eligibility rules. Their observed title remains usable, but no
        // screencopy/wayland handle is invented.
        return tracked ?? {
            address: Foreground.address, title: Foreground.title,
            workspace: focusedWorkspace, wayland: null,
            lastIpcObject: { class: Foreground.appId, mapped: true, tags: [] }
        };
    }

    readonly property var focusedWorkspace: Hyprland.focusedWorkspace
    readonly property var focusedMonitor: Hyprland.focusedMonitor
    readonly property bool usingLua: Hyprland.usingLua
    // Native foreground-thread layout, refreshed on foreground changes and
    // a 500 ms read-only poll for language switches within the same app.
    readonly property string kbLayout: Keyboard.currentLayoutCode.split("-")[0].toLowerCase()
    readonly property string kbLayoutFull: Keyboard.currentLayoutName
    readonly property bool capsLock: Keyboard.capsLock
    readonly property bool numLock: Keyboard.numLock

    // Feature-detected for older backends. A missing or refused native
    // provider reports false; the facade then refuses workspace actions.
    readonly property bool desktopControlSupported:
        typeof Hyprland.desktopControlSupported === "boolean"
            ? Hyprland.desktopControlSupported : false
    readonly property var desktopControl:
        typeof Hyprland.desktopControl === "object" ? Hyprland.desktopControl : null

    function monitorFor(screen): var {
        return Hyprland.monitorFor(screen);
    }

    function dispatch(request): void {
        // The facade has already applied the Windows allowlist. This is the only
        // path that reaches the backend dispatcher.
        // Bound creation to the original bar's configured workspace count.
        // Existing Windows desktops are never removed by this limit.
        if (typeof Hyprland.workspaceLimit === "number") {
            const monitor = Hyprland.focusedMonitor;
            const config = monitor ? Config.forScreen(monitor.name) : GlobalConfig;
            Hyprland.workspaceLimit = config.bar.workspaces.shown;
        }
        Hyprland.dispatch(request);
    }

    Component.onCompleted: {
        console.info("CAELESTIA_HYPR_BACKEND_READY usingLua=" + root.usingLua
            + " monitors=" + root.monitors.values.length
            + " workspaces=" + root.workspaces.values.length
            + " toplevels=" + root.toplevels.values.length);
    }
}
