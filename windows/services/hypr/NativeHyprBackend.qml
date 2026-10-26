import QtQuick
import Quickshell
import Quickshell.Io
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
    property var foreground: ({ address: "", title: "", appId: "" })
    readonly property bool foregroundValidated: true
    readonly property var activeToplevel: {
        if (!foreground.address)
            return null;
        const tracked = toplevels.values.find(t =>
            t.address.toLowerCase().replace(/^0x/, "") === foreground.address);
        // Some application windows are omitted by the backend's task-switcher
        // eligibility rules. Their observed title remains usable, but no
        // screencopy/wayland handle is invented.
        return tracked ?? {
            address: foreground.address, title: foreground.title,
            workspace: focusedWorkspace, wayland: null,
            lastIpcObject: { class: foreground.appId, mapped: true, tags: [] }
        };
    }
    // The backend tracks windows on other desktops too. Independently observe
    // the real foreground HWND before projecting one as the active application.
    readonly property Process foregroundWatcher: Process {
        command: [Quickshell.env("SystemRoot") + "/System32/WindowsPowerShell/v1.0/powershell.exe",
            "-NoProfile", "-NonInteractive", "-File",
            Quickshell.shellPath("helpers/Watch-ActiveWindow.ps1")]
        running: true
        stdout: SplitParser {
            onRead: line => root.foreground = JSON.parse(line)
        }
        onExited: root.foreground = { address: "", title: "", appId: "" }
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
