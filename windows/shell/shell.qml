//@ pragma AppId org.caelestia.windows
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Services
import Caelestia.Windows
import Quickshell.Windows as Native
import qs.services
import qs.modules.drawers
import qs.modules.launcher.services

// Original upstream drawer geometry and motion, with the combined Windows
// facades. No preview window, taskbar controller, tiler or AppBar is created.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    settings.watchFiles: false

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    Variants {
        id: drawers
        model: Quickshell.screens

        Scope {
            id: scope
            required property ShellScreen modelData
            readonly property alias window: content

            // Integration seam: attach the future per-screen AppBar exclusion
            // here using modelData and content.bar. Keep ContentWindow's own
            // exclusionMode=Ignore and full-monitor anchors intact.
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

    // Integration seam: global shortcuts can route to panel(screenName, name).
    // Tiling remains a separate explicit opt-in owned by its controller.
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
                session: SessionManager.actionsEnabled
            }
        };
    }

    Component.onCompleted: {
        ShellState.shellRoot = root;
        Native.SystemMonitor.active = true;
        Native.SystemStats.networkEnabled = true;
    }

    // Quick install smoke: load the session and dashboard on every monitor,
    // suppress input/native writes, verify monitor-sized windows, then exit.
    Timer {
        property int step: 0
        interval: 2000
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
                && Quickshell.env("QS_WINDOWS_TRAY_HOOK") === "0";
            if (valid)
                console.log("CAELESTIA_SHELL_LIVE_PASS");
            else
                console.error("CAELESTIA_SHELL_LIVE_FAIL");
            Qt.exit(valid ? 0 : 1);
        }
    }
}
