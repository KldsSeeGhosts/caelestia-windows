//@ pragma AppId org.caelestia.windows
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Window
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Caelestia.State
import Caelestia.Services
import Caelestia.Windows
import Quickshell.Windows as Native
import qs.services
import qs.daemons
import qs.modules.background
import qs.modules.drawers
import qs.modules.clipboard
import qs.modules.launcher.services
import qs.modules.nexus as Nexus
import qs.modules.tiling

// Original upstream drawer geometry and motion, with the combined Windows
// facades, per-monitor AppBar reservation and opt-in Windows controllers.
ShellRoot {
    id: root

    // Establish fresh-or-upgrade provenance before ThemeTokens (below) or any
    // other current-run writer can create state. This binding is evaluated
    // while the root object is created, ahead of its child objects.
    readonly property bool wallpaperProfileReady: WallpaperProvenance.ready
    // Changes on a successful QML reload, not on a watchdog/process restart alone.
    readonly property string generation: Date.now().toString(36) + Math.random().toString(36).slice(2)
    // A keybind's panel-off request waiting for the keyboard hook to see the
    // chord released. Kept off the IpcHandler so it exposes no IPC property.
    property bool displayOffPending: false
    readonly property bool externalWallpaperActive: WallpaperEngine.ownsDesktop
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    // Offscreen public smoke: skip the native monitor/panel schedule below and
    // exit after the drawers present two frames and readiness settles.
    readonly property bool smokeCi: Quickshell.env("CAELESTIA_SHELL_SMOKE_CI") === "1"
    // Isolated install validation may reserve only the secondary monitor.
    // Normal starts always retain the complete per-monitor shell.
    readonly property int smokeScreenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "-1")
    readonly property var shellScreens: smoke && smokeScreenIndex >= 0
        ? Quickshell.screens.filter((screen, index) => index === smokeScreenIndex)
        : Quickshell.screens
    settings.watchFiles: false
    ThemeTokens {}

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    WindowsBackground { id: desktopBackground }
    IdleInhibit { id: idleInhibitor }
    Shortcuts {}

    // Windows' own clipboard history behind the Caelestia picker. Gated by
    // windows.clipboard.enabled; smoke never opens it or reads the history.
    ClipboardOverlay {
        interactionEnabled: !root.smoke
    }

    // Where a dragged tiled window will land. Makes no window until the first
    // drag on a screen, and nothing at all while tiling is off.
    DragPreview {}

    Variants {
        id: drawers
        model: root.shellScreens

        Scope {
            id: scope
            required property ShellScreen modelData
            readonly property alias window: content
            property bool firstFrame: false
            property int smokeFrames: 0

            Connections {
                target: content.contentItem.Window.window
                function onFrameSwapped(): void {
                    scope.firstFrame = true;
                    if (root.smokeCi) {
                        scope.smokeFrames++;
                        if (scope.smokeFrames < 2)
                            content.contentItem.Window.window.update();
                        Qt.callLater(root.finishSmokeCi);
                    }
                }
            }

            Exclusions {
                screen: scope.modelData
                zone: content.bar.exclusiveZone
                active: !root.smoke
                fullscreen: content.hasFullscreen
            }
            ContentWindow {
                id: content
                screen: scope.modelData
                visible: true
                interactionEnabled: !root.smoke
                anchors { top: true; bottom: true; left: true; right: true }
            }

            WindowsFocusGuard {
                target: content.contentItem
                foregroundSource: Native.Foreground
                active: !root.smoke && ((content.screenState?.session ?? false)
                    || (content.screenState?.launcher ?? false))
                onDismissRequested: {
                    content.screenState.session = false;
                    content.screenState.launcher = false;
                }
            }
        }
    }

    Binding {
        target: Notifs
        property: "centerVisible"
        value: ShellState.anySidebarOpen()
    }

    // The native classifier recognises Windows' own shell UI by class and
    // host process. Taskbar eligibility (tool, no-activate and owned windows)
    // is a separate question: such a window is not a shell surface, and a
    // fullscreen one still counts as fullscreen. This list adds a positive
    // shell identity for third-party shell windows the classifier cannot tell
    // apart; it never changes the taskbar or fullscreen rules, is empty by
    // default and reloads live. Selectors use the tiling dialect: exe:,
    // class:, title:, or an unprefixed exe/class pattern (`screen:` is
    // rejected, and so is a title pattern that matches an empty title).
    Binding {
        target: Native.ShellSurfaces
        property: "extra"
        // The backend validates element types and rejects `screen:` rules;
        // never coerce unknown config entries into selector text here.
        value: GlobalConfig.windows?.shellSurfaces?.extra ?? []
    }

    // IPC selects this installation; tiling retains its separate opt-in.
    IpcHandler {
        target: "shell"
        function quit(): bool {
            // Acceptance is not completion; captureHostState reports refusal
            // or asynchronous close failure while the shell remains alive.
            return Glazier.requestQuit();
        }
        function restart(): string {
            const previous = root.generation;
            // Keep the generation-string acknowledgement compatible. Reload
            // after asynchronous registry handoff, including recording.
            // Refusal leaves this generation alive, so readiness cannot lie.
            Glazier.prepareReload(() => Quickshell.reload(false));
            return previous;
        }
        function captureHostState(): string { return JSON.stringify(Glazier.hostState); }
        function state(): string { return JSON.stringify(root.snapshot()); }
        // on-demand, content-free stage counts, separate from smoke readiness.
        function tilingState(): string {
            const status = Tiling.status;
            const fullscreen = GlobalConfig.utilities.toasts.fullscreen;
            let openToastCount = 0;
            for (const toast of Toaster.toasts) {
                if (!toast.closed)
                    openToastCount++;
            }
            return JSON.stringify({
                backendLoaded: Tiling.backendLoaded,
                supportsTelemetry: Tiling.backendLoaded && Tiling.backend?.supportsTelemetry === true,
                failedCount: Tiling.failedCount,
                recentFailureCount: Tiling.recentFailureCount,
                toastCount: Tiling.toastCount,
                openToastCount: openToastCount,
                hasFullscreen: Notifs.hasFullscreen(),
                fullscreenPolicy: ["off", "important", "all"].includes(fullscreen) ? fullscreen : "unknown",
                status: ["disabled", "observing", "refused", "tiling"].includes(status) ? status : "unknown"
            });
        }
        function settings(): bool {
            if (root.smoke)
                return false;
            Nexus.WindowFactory.openPage(4); // Existing System > Updates slot.
            return true;
        }
        function panel(screenName: string, name: string): bool {
            if (root.smoke || !["launcher", "dashboard", "session", "sidebar", "utilities"].includes(name))
                return false;
            const screen = Quickshell.screens.find(s => s.name === screenName);
            const state = screen ? ShellState.forScreen(screen) : null;
            if (!state)
                return false;
            state[name] = !state[name];
            return true;
        }
    }

    // Explicit panel-off through Windows display power. This is not
    // Displays::setEnabled: it changes no display path, topology or setting.
    // A keybind chord is still held when this runs, so the keyboard hook waits
    // for its keys to come up before the panels switch off. Other input first
    // cancels it, and a direct IPC request with no dispatched keybind sends at
    // once.
    IpcHandler {
        target: "displays"

        function off(): bool {
            // A direct IPC call has no dispatched keybind, so the backend
            // returns false for it even while a keybind wait is pending; it
            // also cancels that wait, and the send below happens at once.
            if (Native.Hotkeys.beginChordReleaseWait()) {
                root.displayOffPending = true;
                return true;
            }
            return WindowsDisplayPower.off();
        }
    }

    Connections {
        target: Native.Hotkeys
        function onChordReleaseSettled() {
            if (!root.displayOffPending)
                return;
            root.displayOffPending = false;
            WindowsDisplayPower.off();
        }
        function onChordReleaseCancelled() { root.displayOffPending = false; }
    }

    function snapshot(): var {
        return {
            lifecycle: {
                generation: root.generation,
                ready: root.shellScreens.length > 0
                    && drawers.instances.length === root.shellScreens.length
                    && drawers.instances.every(scope => scope.firstFrame && scope.window.backingWindowVisible
                        && scope.window.width > 0 && scope.window.height > 0)
            },
            smoke: root.smoke,
            smokeComplete: root.smoke && smokeCheck.step >= 5,
            screens: root.shellScreens.length,
            keyboard: { layout: Hypr.kbLayout, name: Hypr.kbLayoutFull,
                capsLock: Hypr.capsLock, numLock: Hypr.numLock },
            windows: drawers.instances.map(scope => ({
                screen: scope.modelData.name,
                width: scope.window.width, height: scope.window.height,
                screenWidth: scope.modelData.width, screenHeight: scope.modelData.height,
                barWidth: scope.window.bar.implicitWidth,
                barZone: scope.window.bar.exclusiveZone,
                borderZone: scope.window.borderLayoutThickness,
                dpr: scope.window.devicePixelRatio,
                appFullscreen: scope.window.hasFullscreen,
                // Content-free readback for drawer interaction diagnostics.
                panels: {
                    dashboard: scope.window.screenState.dashboard,
                    quota: scope.window.screenState.quota,
                    sidebar: scope.window.screenState.sidebar,
                    session: scope.window.screenState.session
                }
            })),
            backgroundScreens: desktopBackground.screens.map(s => s.name),
            backgroundWindows: desktopBackground.instances.map(w => ({
                screen: w.screen?.name ?? "", modelScreen: w.modelData.name,
                width: w.width, height: w.height
            })),
            tilingMode: Tiling.mode,
            statisticsActive: Native.SystemMonitor.active,
            networkStatisticsActive: Native.SystemStats.active,
            wallpaperEngine: {
                ready: WallpaperEngine.snapshotReady,
                running: WallpaperEngine.running,
                detected: WallpaperEngine.detected,
                count: WallpaperEngine.items.length,
                current: WallpaperEngine.current?.path ?? "",
                // True while the desktop host is embedded as a WorkerW
                // underlay, ready to sit beneath an external wallpaper.
                underlayActive: desktopBackground.underlayActive
            },
            scheme: {
                available: SchemeGenerator.available,
                status: SchemeGenerator.status,
                schemes: Schemes.list.length,
                variants: M3Variants.list.length,
                primary: Colours.palette.m3primary
            },
            controls: {
                audio: Audio.controlsEnabled,
                brightness: Brightness.controlsEnabled,
                media: Players.controlsEnabled,
                network: Nmcli.controlsEnabled,
                bluetooth: WindowsBluetooth.controlsEnabled,
                profiles: WindowsBattery.profiles.writesPermitted,
                apps: Apps.launchEnabled,
                tray: WindowsTray.activationEnabled,
                notifications: Notifs.mirrorOptIn,
                session: SessionManager.actionsEnabled,
                dispatch: Hypr.dispatchEnabled,
                tiling: Tiling.backendEnabled,
                keepAwake: idleInhibitor.inhibiting,
                recorder: Recorder.running
            },
            // Status only. Never serialize notification text, app IDs or history.
            notifications: {
                enabled: Notifs.enabled,
                status: Notifs.status,
                mirrorOptIn: Notifs.mirrorOptIn,
                access: Notifs.mirrorAccessState,
                mirrorStatus: Notifs.mirrorStatus,
                mirrorActive: Notifs.systemMirrorActive,
                doNotDisturb: Notifs.doNotDisturb,
                fullscreenPolicy: GlobalConfig.notifs.fullscreen === 0 ? "On" : "Off"
            }
        };
    }

    // Diagnostics only: the public snapshot keeps the current project path and
    // the screen names (friendly monitor names or device paths) for IPC and
    // property consumers, but neither may reach the log. Screens are logged by
    // index and count.
    function loggingSnapshot(): var {
        const state = root.snapshot();
        state.wallpaperEngine = Object.assign({}, state.wallpaperEngine, {
            current: state.wallpaperEngine.current ? "set" : ""
        });
        state.windows = state.windows.map((w, i) => Object.assign({}, w, { screen: i }));
        state.backgroundScreens = state.backgroundScreens.length;
        state.backgroundWindows = state.backgroundWindows.map((w, i) =>
            Object.assign({}, w, { screen: i, modelScreen: i }));
        return state;
    }

    Component.onCompleted: {
        ShellState.shellRoot = root;
        Hypr.logStartupStatus();
        Tiling.logStartupStatus();
        FocusFollowsMouse.logStartupStatus();
        SchemeGenerator.refresh();
        Native.SystemStats.networkEnabled = true;
        // One route query per screen. Without it every monitor stays "unknown"
        // and the service refuses all brightness writes. No-op while the
        // brightness opt-in is off.
        Brightness.beginObservation();
    }

    // Sample only while a dashboard is visible, including its close animation.
    readonly property bool statisticsVisible: drawers.instances.some(scope =>
        (scope.window.screenState?.dashboard ?? false)
        || (ShellState.componentsFor(scope.modelData)?.panels?.dashboard.visible ?? false))

    Binding {
        target: Native.SystemMonitor
        property: "active"
        value: root.statisticsVisible
    }
    Binding {
        target: Native.SystemStats
        property: "active"
        value: root.statisticsVisible
    }

    // Readiness/control bindings can settle after the last frame.
    // Observe their property changes too, without accepting an unrendered graph.
    readonly property bool smokeCiReady: {
        if (!root.smokeCi || !root.smoke)
            return false;
        const state = root.snapshot();
        return state.lifecycle.ready && drawers.instances.every(scope => scope.smokeFrames >= 2)
            && Object.values(state.controls).every(value => value === false)
            && !state.statisticsActive && !state.networkStatisticsActive;
    }
    onSmokeCiReadyChanged: {
        if (root.smokeCiReady)
            Qt.callLater(root.finishSmokeCi);
    }

    // The timer below is only a deadline. Recheck after the queued binding turn.
    function finishSmokeCi(): void {
        if (!root.smokeCiReady)
            return;
        console.log("CAELESTIA_SHELL_LIVE_STATE", JSON.stringify(root.loggingSnapshot()));
        console.log("CAELESTIA_SHELL_SMOKE_PASS");
        smokeCheck.stop();
        Qt.exit(0);
    }

    // Quick install smoke: load the session and dashboard on every monitor,
    // suppress input/native writes, verify monitor-sized windows, then await IPC quit.
    // CAELESTIA_SHELL_SMOKE_CI instead skips the native-only panel schedule and
    // exits by itself once every drawer has presented two frames and is ready.
    Timer {
        id: smokeCheck
        property int step: 0
        interval: root.smokeCi ? 15000 : 3000
        repeat: !root.smokeCi
        running: root.smoke
        onTriggered: {
            step++;
            if (root.smokeCi) {
                console.error("CAELESTIA_SHELL_SMOKE_FAIL not ready");
                stop();
                Qt.exit(1);
                return;
            }
            for (const screen of root.shellScreens) {
                const state = ShellState.forScreen(screen);
                if (state) {
                    state.session = step === 1;
                    state.dashboard = step === 2;
                }
            }
            if (step < 5)
                return;
            const state = root.snapshot();
            console.log("CAELESTIA_SHELL_LIVE_STATE", JSON.stringify(root.loggingSnapshot()));
            const valid = state.screens > 0 && state.windows.length === state.screens
                && state.windows.every(w => w.width === w.screenWidth
                    && w.height === w.screenHeight && w.barWidth > 0)
                && Object.values(state.controls).every(value => value === false)
                && !state.statisticsActive && !state.networkStatisticsActive
                && (!WallpaperEngine.python || state.wallpaperEngine.ready)
                && (!state.scheme.available || (state.scheme.status === "ready"
                    && state.scheme.schemes > 0 && state.scheme.variants > 0))
                && Quickshell.env("QS_WINDOWS_TRAY_HOOK") === "0"
                && state.keyboard.layout !== "??" && state.keyboard.layout.length > 0
                && state.backgroundWindows.length === (desktopBackground.yielded ? 0 : state.screens)
                && state.backgroundWindows.every(w => {
                    const screen = Quickshell.screens.find(s => s.name === w.modelScreen);
                    return screen && w.screen === w.modelScreen
                        && w.width === screen.width && w.height === screen.height;
                })
                && root.shellScreens.every(s => desktopBackground.checkReady(s));
            if (valid)
                console.log("CAELESTIA_SHELL_LIVE_PASS");
            else
                console.error("CAELESTIA_SHELL_LIVE_FAIL");
            stop();
            if (!valid)
                Qt.exit(1);
        }
    }
}
