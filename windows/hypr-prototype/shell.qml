//@ pragma AppId org.caelestia.windows-hypr-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.services

// A separate bounded M3 host for the original bar workspace and active-window
// components with the Windows Hypr facade. The original components are loaded
// by URL only after the observation backend reports ready, so disabled
// construction never resolves a type that imports Quickshell.Hyprland. No
// Tiling, WindowManager, Taskbar, keyboard shortcut, taskbar hook, tiling
// option or dispatch request is constructed by this host.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(620, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(700, (selectedScreen?.height ?? 780) - 160)
    property var initialHyprState: null
    property bool failed: false

    settings.watchFiles: false

    function hyprState(): var {
        const monitors = Hypr.monitors.values;
        const workspaces = Hypr.workspaces.values;
        const special = workspaces.filter(w => typeof w?.name === "string"
            && w.name.startsWith("special:"));
        return {
            status: Hypr.status,
            reason: Hypr.reason,
            enabled: Hypr.enabled,
            dispatchEnabled: Hypr.dispatchEnabled,
            backendRequested: Hypr.nativeRequested,
            backendLoaded: Hypr.backend !== null,
            initialized: Hypr.nativeInitialized,
            usingLua: Hypr.usingLua,
            monitorCount: monitors.length,
            workspaceCount: workspaces.length,
            toplevelCount: Hypr.toplevels.values.length,
            focusedMonitorId: Hypr.focusedMonitor?.id ?? -1,
            focusedMonitorName: Hypr.focusedMonitor?.name ?? "",
            focusedWorkspaceId: Hypr.focusedWorkspace?.id ?? -1,
            focusedWorkspaceName: Hypr.focusedWorkspace?.name ?? "",
            activeWsId: Hypr.activeWsId,
            activeToplevelTitle: Hypr.activeToplevel?.title ?? "",
            activeToplevelClass: Hypr.activeToplevel?.lastIpcObject?.class ?? "",
            specialWorkspaceName: Hypr.focusedMonitor?.lastIpcObject?.specialWorkspace?.name ?? "",
            specialCount: special.length,
            monitorActiveWorkspaceIds: monitors.map(m => m.activeWorkspace?.id ?? -1),
            globalFocusMatch: monitors.every(m => m.activeWorkspace?.id
                === Hypr.focusedWorkspace?.id),
            workspaceMonitorIds: workspaces.map(w => w.monitor?.id ?? -1),
            workspacesLoaded: workspacesHost.item !== null,
            workspacesMonitorId: workspacesHost.item?.monitor?.id ?? -1,
            workspaceIds: workspacesHost.item?.wsIds ?? [],
            specialLoaded: specialHost.item !== null,
            specialWsIds: specialHost.item?.wsIds ?? [],
            specialActiveId: specialHost.item?.activeSpecialId ?? -1,
            activeWindowLoaded: activeWindowHost.item !== null,
            activeWindowTitle: activeWindowHost.item?.activeWindowTitle ?? "",
            commandsSent: Hypr.commandsSent,
            refusals: Hypr.refusals,
            consumed: Hypr.consumed,
            lastRefusalReason: Hypr.lastRefusalReason,
            lastDispatch: Hypr.lastDispatch
        };
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_HYPR_FAIL: " + message);
        Qt.exit(1);
    }

    // Loaded by URL only when the observation backend is ready. setSource
    // applies the host screen before the component completes, so the original
    // Workspaces binding never sees a null screen.
    function loadOriginalComponents(): void {
        if (!Hypr.nativeInitialized)
            return;
        if (workspacesHost.item === null) {
            workspacesHost.setSource(Qt.resolvedUrl("components/WorkspacesHost.qml"), {
                hostScreen: win.screen
            });
        }
        if (specialHost.item === null)
            specialHost.setSource(Qt.resolvedUrl("components/SpecialWorkspacesHost.qml"));
        if (activeWindowHost.item === null)
            activeWindowHost.setSource(Qt.resolvedUrl("components/ActiveWindowHost.qml"));
    }

    function checkInitialState(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_HYPR") === "1")
                || state.dispatchEnabled !== (state.enabled
                    && Quickshell.env("CAELESTIA_WINDOWS_HYPR_DISPATCH") === "1")) {
            root.fail("UI, fonts, DPI or service opt-in policy");
            return;
        }
        // No path in this host dispatches at startup, and observation without
        // dispatch must not have reached the backend either.
        if (state.commandsSent !== 0 || state.refusals !== 0 || state.consumed !== 0
                || state.lastDispatch !== "") {
            root.fail("startup sent or refused a Hypr dispatch");
            return;
        }
        if (state.usingLua) {
            root.fail("Windows adapter claimed the Lua dispatch surface");
            return;
        }
        if (!state.enabled) {
            if (state.status !== "disabled" || state.backendRequested || state.backendLoaded
                    || state.initialized || state.monitorCount !== 0
                    || state.workspaceCount !== 0 || state.toplevelCount !== 0
                    || state.workspacesLoaded || state.specialLoaded
                    || state.activeWindowLoaded || state.focusedMonitorId !== -1
                    || state.focusedWorkspaceId !== -1) {
                root.fail("disabled mode loaded the Hyprland backend or original components");
                return;
            }
        } else {
            if (!state.backendRequested) {
                root.fail("enabled mode did not activate the native backend loader");
                return;
            }
            if (!state.backendLoaded || !state.initialized || state.status !== "ready") {
                root.fail("enabled mode did not settle the native backend: " + state.status);
                return;
            }
            if (state.monitorCount < 1 || state.focusedMonitorId < 0
                    || state.focusedMonitorName === "") {
                root.fail("enabled mode has no focused monitor");
                return;
            }
            if (state.workspaceCount < 1 || state.focusedWorkspaceId < 1
                    || state.activeWsId !== state.focusedWorkspaceId) {
                root.fail("enabled mode has no focused workspace");
                return;
            }
            // The facade exposes the global focused workspace for every monitor
            // and never claims per-monitor ownership.
            if (!state.globalFocusMatch
                    || state.workspaceMonitorIds.some(id => id !== state.focusedMonitorId)) {
                root.fail("per-monitor workspace ownership was implied");
                return;
            }
            if (!state.workspacesLoaded || state.workspacesMonitorId < 0) {
                root.fail("original Workspaces did not load with a native monitor");
                return;
            }
            if (state.workspaceIds.length !== 5) {
                root.fail("original Workspaces did not project the configured five slots");
                return;
            }
            if (!state.specialLoaded || state.specialWsIds.length !== 0
                    || state.specialActiveId !== -1 || state.specialCount !== 0
                    || state.specialWorkspaceName !== "") {
                root.fail("special workspace UI is active on Windows");
                return;
            }
            if (!state.activeWindowLoaded) {
                root.fail("original ActiveWindow did not load");
                return;
            }
            const expectedTitle = state.activeToplevelTitle.length > 0
                ? state.activeToplevelTitle : "Desktop";
            if (state.activeWindowTitle !== expectedTitle) {
                root.fail("original ActiveWindow title disagrees with the facade: "
                    + state.activeWindowTitle + " != " + expectedTitle);
                return;
            }
        }
        root.initialHyprState = state;
        console.log("CAELESTIA_HYPR_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_HYPR_INITIAL", JSON.stringify(state));
    }

    function checkSettledState(state): void {
        if (root.failed)
            return;
        if (state.commandsSent !== 0 || state.refusals !== 0 || state.consumed !== 0
                || state.lastDispatch !== "") {
            root.fail("settled run sent or refused a Hypr dispatch");
            return;
        }
        if (!state.enabled) {
            if (state.status !== "disabled" || state.backendLoaded) {
                root.fail("disabled service did not stay disabled");
                return;
            }
            return;
        }
        if (state.status !== "ready" || !state.initialized || !state.backendLoaded) {
            root.fail("enabled service did not stay ready: " + state.status);
            return;
        }
        if (!state.globalFocusMatch) {
            root.fail("global focus model changed during the smoke");
            return;
        }
        if (!state.workspacesLoaded || !state.specialLoaded || !state.activeWindowLoaded) {
            root.fail("an original component unloaded during the smoke");
            return;
        }
        if (state.specialWsIds.length !== 0 || state.specialCount !== 0
                || state.specialWorkspaceName !== "") {
            root.fail("special workspace UI became active");
            return;
        }
    }

    FontLoader {
        id: bodyFont
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader {
        id: iconFont
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }

    StyledWindow {
        id: win

        name: "hypr-prototype"
        screen: root.selectedScreen
        visible: root.selectedScreen !== null
        implicitWidth: root.previewWidth
        implicitHeight: root.previewHeight
        anchors.top: true
        anchors.left: true
        margins.top: 80
        margins.left: 80
        exclusionMode: ExclusionMode.Ignore
        WlrLayershell.layer: WlrLayer.Top
        WlrLayershell.keyboardFocus: root.smoke ? WlrKeyboardFocus.None : WlrKeyboardFocus.OnDemand
        mask: root.smoke ? noInput : null
        color: Colours.palette.m3surface

        StyledRect {
            anchors.fill: parent
            color: Colours.palette.m3surface
        }

        Region {
            id: noInput
        }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    text: "Caelestia Windows Hyprland"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                StyledText {
                    text: Hypr.status + "  hypr=" + (Hypr.enabled ? 1 : 0)
                        + " dispatch=" + (Hypr.dispatchEnabled ? 1 : 0)
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Hypr.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Hypr.enabled
                    ? ("monitor " + (Hypr.focusedMonitor?.name ?? "?")
                        + " id " + (Hypr.focusedMonitor?.id ?? -1)
                        + "  workspace " + (Hypr.focusedWorkspace?.name ?? "?")
                        + " id " + (Hypr.focusedWorkspace?.id ?? -1)
                        + "  monitors " + Hypr.monitors.values.length
                        + "  workspaces " + Hypr.workspaces.values.length
                        + "  toplevels " + Hypr.toplevels.values.length)
                    : "No Windows Hyprland observation is loaded."
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            RowLayout {
                Layout.fillWidth: true
                Layout.fillHeight: true
                spacing: 24

                ColumnLayout {
                    spacing: 8

                    StyledText {
                        text: "Bar workspaces"
                        font: Tokens.font.label.medium
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    Loader {
                        id: workspacesHost

                        asynchronous: false
                        Layout.preferredWidth: item ? item.implicitWidth : 0
                        Layout.preferredHeight: item ? item.implicitHeight : 0
                    }
                }

                ColumnLayout {
                    spacing: 8

                    StyledText {
                        text: "Special workspaces (inactive)"
                        font: Tokens.font.label.medium
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    Loader {
                        id: specialHost

                        asynchronous: false
                        Layout.preferredWidth: 72
                        Layout.preferredHeight: 240
                    }
                }

                ColumnLayout {
                    spacing: 8

                    StyledText {
                        text: "Active window"
                        font: Tokens.font.label.medium
                        color: Colours.palette.m3onSurfaceVariant
                    }

                    Loader {
                        id: activeWindowHost

                        asynchronous: false
                        Layout.preferredWidth: 120
                        Layout.preferredHeight: 240
                    }
                }

                Item {
                    Layout.fillWidth: true
                    Layout.fillHeight: true
                }
            }
        }

        Shortcut {
            sequence: "Escape"
            enabled: !root.smoke
            onActivated: Qt.quit()
        }
    }

    IpcHandler {
        target: "prototype"

        function state(): string {
            return JSON.stringify(root.hyprState());
        }
        function quit(): void {
            Qt.quit();
        }
    }

    Connections {
        target: Hypr

        function onNativeInitializedChanged(): void {
            root.loadOriginalComponents();
        }
    }

    Component.onCompleted: {
        Hypr.logStartupStatus();
        if (!selectedScreen)
            Qt.callLater(() => Qt.exit(1));
        root.loadOriginalComponents();
    }

    Timer {
        id: check

        property int step
        running: root.smoke && root.selectedScreen !== null
        repeat: true
        interval: 1000
        onTriggered: {
            if (root.failed)
                return;
            // Wait for the bounded backend load and the original components.
            if (Hypr.enabled && (!Hypr.nativeInitialized || workspacesHost.item === null
                    || specialHost.item === null || activeWindowHost.item === null))
                return;
            const state = root.hyprState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialHyprState === null)
                    return;
            } else if (step === 1) {
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 2) {
                console.log("CAELESTIA_HYPR_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_HYPR_CAPTURE", path);
                    console.log("CAELESTIA_HYPR_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_HYPR_FAIL: screenshot");
                    Qt.exit(1);
                });
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: 15000
        onTriggered: {
            console.error("CAELESTIA_HYPR_FAIL: timeout", Hypr.status, Hypr.reason);
            Qt.exit(1);
        }
    }
}
