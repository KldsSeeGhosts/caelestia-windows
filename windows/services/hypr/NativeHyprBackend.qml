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

    // A plain line parser must not trust the child's stdout: a partial line
    // while the watcher restarts must keep the last good foreground state
    // instead of throwing out of the signal handler.
    function applyForeground(line): void {
        let update;
        try {
            update = JSON.parse(line);
        } catch (error) {
            // Never log the line itself: it can contain a window title.
            console.warn("Caelestia: ignored a malformed active-window update.");
            return;
        }
        if (!update || typeof update !== "object")
            return;
        root.foreground = {
            address: typeof update.address === "string" ? update.address : "",
            title: typeof update.title === "string" ? update.title : "",
            appId: typeof update.appId === "string" ? update.appId : ""
        };
    }

    // The watcher is a resident PowerShell process. If it exits while this
    // backend is loaded (the Hypr observation opt-in is still on), restart it
    // with bounded exponential backoff and reset the delay after a sustained
    // healthy run. Unloading the backend destroys these timers with it.
    property int watcherRestarts: 0
    readonly property int watcherRestartDelay: Math.min(
        500 * Math.pow(2, Math.max(0, root.watcherRestarts - 1)), 30000)
    property bool watcherRestartEnabled: true

    function scheduleWatcherRestart(): void {
        // onExited and onRunningChanged both report a stopped watcher; only the
        // first one schedules, so a single failure is not counted twice.
        if (!root.watcherRestartEnabled || watcherRestartTimer.running)
            return;
        root.watcherRestarts++;
        watcherHealthyTimer.stop();
        // Log the first few failures only; a permanently broken helper must not
        // flood the shell log every backoff interval.
        if (root.watcherRestarts <= 3)
            console.warn("Caelestia: active-window watcher stopped unexpectedly; restarting in "
                + root.watcherRestartDelay + " ms.");
        watcherRestartTimer.restart();
    }

    readonly property Process foregroundWatcher: Process {
        id: watcherProcess

        command: [Quickshell.env("SystemRoot") + "/System32/WindowsPowerShell/v1.0/powershell.exe",
            "-NoProfile", "-NonInteractive", "-File",
            Quickshell.shellPath("helpers/Watch-ActiveWindow.ps1")]
        running: true
        stdout: SplitParser {
            onRead: line => root.applyForeground(line)
        }
        onStarted: {
            watcherRestartTimer.stop();
            watcherHealthyTimer.restart();
        }
        onExited: {
            root.foreground = { address: "", title: "", appId: "" };
            root.scheduleWatcherRestart();
        }
        onRunningChanged: {
            // FailedToStart emits runningChanged without exited, so cover it
            // here as well; a deliberate stop after destruction is ignored.
            if (!watcherProcess.running)
                root.scheduleWatcherRestart();
        }
    }

    readonly property Timer _watcherRestartTimer: Timer {
        id: watcherRestartTimer

        interval: root.watcherRestartDelay
        onTriggered: {
            if (root.watcherRestartEnabled && !root.foregroundWatcher.running)
                root.foregroundWatcher.running = true;
        }
    }

    readonly property Timer _watcherHealthyTimer: Timer {
        id: watcherHealthyTimer

        // A minute without an exit proves the restart worked; start the next
        // failure from the short delay instead of the previous backoff.
        interval: 60000
        onTriggered: root.watcherRestarts = 0
    }

    // A teardown or opt-out destroys the Process and both timers; the flag also
    // stops a late exit signal from scheduling a restart in that window.
    Component.onDestruction: root.watcherRestartEnabled = false

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
