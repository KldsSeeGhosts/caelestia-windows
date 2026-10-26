//@ pragma AppId org.caelestia.windows
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

pragma ComponentBehavior: Bound

import QtQuick
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
import qs.modules.launcher.services

// Original upstream drawer geometry and motion, with the combined Windows
// facades, per-monitor AppBar reservation and opt-in Windows controllers.
ShellRoot {
    id: root

    readonly property bool externalWallpaperActive: WallpaperEngine.ownsDesktop
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    settings.watchFiles: false

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    WindowsBackground { id: desktopBackground }
    IdleInhibit { id: idleInhibitor }
    Shortcuts {}

    Variants {
        id: drawers
        model: Quickshell.screens

        Scope {
            id: scope
            required property ShellScreen modelData
            readonly property alias window: content

            Exclusions {
                screen: scope.modelData
                zone: content.bar.exclusiveZone
                active: !root.smoke
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
                active: !root.smoke && ((content.screenState?.session ?? false)
                    || (content.screenState?.launcher ?? false))
                onDismissRequested: {
                    content.screenState.session = false;
                    content.screenState.launcher = false;
                    SessionManager.cancelConfirmation();
                }
            }
        }
    }

    Binding {
        target: Notifs
        property: "centerVisible"
        value: ShellState.anySidebarOpen()
    }

    // IPC selects this installation; tiling retains its separate opt-in.
    IpcHandler {
        target: "shell"
        function quit(): void { Qt.quit(); }
        function restart(): void { Quickshell.reload(true); }
        function state(): string { return JSON.stringify(root.snapshot()); }
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

    function snapshot(): var {
        return {
            smoke: root.smoke,
            screens: Quickshell.screens.length,
            windows: drawers.instances.map(scope => ({
                screen: scope.modelData.name,
                width: scope.window.width, height: scope.window.height,
                screenWidth: scope.modelData.width, screenHeight: scope.modelData.height,
                barWidth: scope.window.bar.implicitWidth
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
                current: WallpaperEngine.current?.path ?? ""
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
            }
        };
    }

    Component.onCompleted: {
        ShellState.shellRoot = root;
        Hypr.logStartupStatus();
        Tiling.logStartupStatus();
        SchemeGenerator.refresh();
        Native.SystemStats.networkEnabled = true;
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

    // Quick install smoke: load the session and dashboard on every monitor,
    // suppress input/native writes, verify monitor-sized windows, then await IPC quit.
    Timer {
        property int step: 0
        interval: 3000
        repeat: true
        running: root.smoke
        onTriggered: {
            step++;
            for (const screen of Quickshell.screens) {
                const state = ShellState.forScreen(screen);
                if (state) {
                    state.session = step === 1;
                    state.dashboard = step === 2;
                }
            }
            if (step < 5)
                return;
            const state = root.snapshot();
            console.log("CAELESTIA_SHELL_LIVE_STATE", JSON.stringify(state));
            const valid = state.screens > 0 && state.windows.length === state.screens
                && state.windows.every(w => w.width === w.screenWidth
                    && w.height === w.screenHeight && w.barWidth > 0)
                && Object.values(state.controls).every(value => value === false)
                && !state.statisticsActive && !state.networkStatisticsActive
                && (!WallpaperEngine.python || state.wallpaperEngine.ready)
                && (!state.scheme.available || (state.scheme.status === "ready"
                    && state.scheme.schemes > 0 && state.scheme.variants > 0))
                && Quickshell.env("QS_WINDOWS_TRAY_HOOK") === "0"
                && state.backgroundWindows.length === (root.externalWallpaperActive ? 0 : state.screens)
                && state.backgroundWindows.every(w => {
                    const screen = Quickshell.screens.find(s => s.name === w.modelScreen);
                    return screen && w.screen === w.modelScreen
                        && w.width === screen.width && w.height === screen.height;
                })
                && Quickshell.screens.every(s => desktopBackground.checkReady(s));
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
