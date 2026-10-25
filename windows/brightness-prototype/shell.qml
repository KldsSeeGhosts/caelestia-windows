//@ pragma AppId org.caelestia.windows-brightness-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QSG_RENDER_LOOP=threaded

import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.components
import qs.components.containers
import qs.components.controls
import qs.modules.osd as OsdModule
import qs.services

// A separate bounded M2 host for the original OSD brightness slider. Other
// services, global shortcuts, IPC mutations, the OSD wrapper, toasts and all
// shell controllers stay unloaded. The audio facade is staged only because the
// original content references it; it is disabled and its native loader stays
// inactive, and the host hides the audio rows.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(560, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - 160)
    readonly property var selectedMonitor: Brightness.getMonitorForScreen(root.selectedScreen)
    // Constructed only with the observation opt-in. The original content binds
    // this type directly; a disabled host creates no persistent screen state.
    readonly property var screenState: screenStates.instances.find(
        state => state.modelData === root.selectedScreen) ?? null
    property var initialBrightnessState: null
    property bool failed: false

    settings.watchFiles: false

    function monitorSnapshot(monitor): var {
        return {
            screen: monitor.screenName,
            capability: monitor.capability,
            stateLabel: monitor.stateLabel,
            route: monitor.route,
            routeLabel: monitor.routeLabel,
            available: monitor.record?.available ?? false,
            brightness: monitor.brightness,
            brightnessKnown: monitor.brightnessKnown,
            interactive: monitor.interactive,
            writeReady: monitor.writeReady,
            writable: monitor.writable,
            latched: monitor.latched,
            lastOutcome: monitor.lastOutcome,
            lastError: monitor.lastError,
            reason: monitor.stateReason
        };
    }

    function brightnessState(): var {
        const selected = root.selectedMonitor;
        return {
            status: Brightness.status, reason: Brightness.reason,
            enabled: Brightness.enabled, controlsEnabled: Brightness.controlsEnabled,
            softwareEnabled: Brightness.softwareEnabled,
            backendLoaded: Brightness.backend !== null,
            nativeRequested: Brightness.nativeRequested,
            nativeBackendId: Brightness.backend?.backendId ?? "",
            ready: Brightness.ready, lastError: Brightness.lastError,
            strictBackend: Brightness.strictBackend,
            writesAllowed: Brightness.writesAllowed,
            strictRoutesEnabled: Brightness.strictRoutesEnabled,
            policyError: Brightness.policyError,
            queryRequests: Brightness.queryRequests, writeRequests: Brightness.writeRequests,
            coalescedWrites: Brightness.coalescedWrites,
            clearedDimmingRequests: Brightness.clearedDimmingRequests,
            refusedWrites: Brightness.refusedWrites, everWrote: Brightness.everWrote,
            gammaTouched: Brightness.gammaTouched,
            autoObservationDone: Brightness.autoObservationDone,
            monitorCount: Brightness.monitorCount,
            monitors: Brightness.monitors.map(root.monitorSnapshot),
            selectedScreen: selected?.screenName ?? "",
            selectedCapability: selected?.capability ?? "unknown",
            selectedRoute: selected?.route ?? "",
            selectedInteractive: selected?.interactive ?? false,
            selectedWritable: selected?.writable ?? false,
            selectedBrightnessKnown: selected?.brightnessKnown ?? false,
            screenStatePresent: root.screenState !== null,
            osdLoaded: osdHost.item !== null,
            osdControlsEnabled: osdHost.item?.brightnessControlsEnabled ?? false,
            osdAudioControlsEnabled: osdHost.item?.audioControlsEnabled ?? true
        };
    }

    function anyQuerying(): bool {
        return Brightness.monitorStates.some(state => state.querying);
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_BRIGHTNESS_FAIL: " + message);
        Qt.exit(1);
    }

    function checkInitialState(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_BRIGHTNESS") === "1")
                || state.controlsEnabled !== (state.enabled
                    && Quickshell.env("CAELESTIA_WINDOWS_BRIGHTNESS_CONTROLS") === "1")
                || state.softwareEnabled !== (state.controlsEnabled
                    && Quickshell.env("CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE") === "1")) {
            root.fail("UI, fonts, DPI or service opt-in policy");
            return;
        }
        if (state.enabled) {
            if (!state.nativeRequested || !state.backendLoaded
                    || state.nativeBackendId !== "Quickshell.Windows.Brightness") {
                root.fail("enabled mode did not construct the native Brightness facade");
                return;
            }
            if (!state.screenStatePresent) {
                root.fail("no ScreenState for the selected screen");
                return;
            }
            if (!state.osdLoaded) {
                root.fail("original OSD content did not load");
                return;
            }
            if (state.osdAudioControlsEnabled !== false) {
                root.fail("staged audio rows were not disabled");
                return;
            }
            if (state.osdControlsEnabled !== state.selectedInteractive) {
                root.fail("original OSD control hook is not guarded by the service");
                return;
            }
        } else if (state.status !== "disabled" || state.nativeRequested
                || state.backendLoaded || state.osdLoaded
                || state.monitorCount !== state.monitors.length
                || state.writeRequests !== 0 || state.everWrote) {
            root.fail("disabled mode constructed the backend or original component");
            return;
        }
        if (state.writeRequests !== 0 || state.everWrote) {
            root.fail("prototype startup issued a brightness write");
            return;
        }
        root.initialBrightnessState = state;
        console.log("CAELESTIA_BRIGHTNESS_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_BRIGHTNESS_INITIAL", JSON.stringify(state));
    }

    function checkSettledState(state): void {
        if (!state.enabled) {
            if (state.status !== "disabled" || state.writeRequests !== 0 || state.everWrote) {
                root.fail("disabled service did not settle inertly: " + state.status);
                return;
            }
            for (const monitor of state.monitors) {
                if (monitor.capability !== "unknown" || monitor.route !== ""
                        || monitor.brightnessKnown || monitor.writable) {
                    root.fail("disabled monitor invented a route: " + monitor.screen);
                    return;
                }
            }
            return;
        }
        if (state.status !== "observing" || !state.ready) {
            root.fail("enabled service did not settle to observation: " + state.status);
            return;
        }
        // Smoke is always read-only: the launcher must never pass a write
        // opt-in, and this host must not have sent any write or gamma request.
        if (state.controlsEnabled || state.softwareEnabled) {
            root.fail("smoke run enabled brightness writes");
            return;
        }
        if (state.writeRequests !== 0 || state.everWrote || state.gammaTouched
                || state.refusedWrites !== 0) {
            root.fail("read-only observation attempted a write");
            return;
        }
        if (!state.osdLoaded || state.osdControlsEnabled !== false
                || state.osdAudioControlsEnabled !== false) {
            root.fail("original OSD content is not loaded read-only");
            return;
        }
        if (state.monitorCount !== state.monitors.length || state.monitorCount === 0) {
            root.fail("monitor states are inconsistent");
            return;
        }
        for (const monitor of state.monitors) {
            if (monitor.capability === "unknown" || monitor.capability === "querying") {
                root.fail("monitor route did not settle: " + monitor.screen + " " + monitor.capability);
                return;
            }
            if (monitor.capability === "hardware") {
                if (["wmi", "lcd", "ddc"].indexOf(monitor.route) < 0 || !monitor.available
                        || !monitor.brightnessKnown) {
                    root.fail("hardware route is inconsistent: " + monitor.screen);
                    return;
                }
            } else if (monitor.capability === "software-only") {
                if (monitor.route !== "software" || monitor.writable) {
                    root.fail("software route is inconsistent: " + monitor.screen);
                    return;
                }
            } else if (monitor.capability === "failed") {
                if (["wmi", "lcd", "ddc"].indexOf(monitor.route) < 0
                        || monitor.lastError.length === 0 || monitor.writable) {
                    root.fail("failed route is inconsistent: " + monitor.screen);
                    return;
                }
            } else if (monitor.route !== "" || monitor.writable) {
                root.fail("unsupported route is inconsistent: " + monitor.screen);
                return;
            }
            if (monitor.brightnessKnown
                    && (!Number.isFinite(monitor.brightness)
                        || monitor.brightness < 0 || monitor.brightness > 1)) {
                root.fail("brightness value is out of range: " + monitor.screen);
                return;
            }
        }
        console.log("CAELESTIA_BRIGHTNESS_ROUTES", JSON.stringify(
            state.monitors.map(monitor => ({
                screen: monitor.screen, capability: monitor.capability,
                route: monitor.route, routeLabel: monitor.routeLabel
            }))));
    }

    Variants {
        id: screenStates

        model: Brightness.enabled ? Quickshell.screens : []

        ScreenState {}
    }

    Component.onCompleted: {
        if (!root.selectedScreen) {
            Qt.callLater(() => Qt.exit(1));
            return;
        }
        // Read-only observation asks for one route query per screen. The
        // service only sends it when no software dimming was applied by this
        // process, and it never calls probe().
        Brightness.beginObservation();
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

        name: "brightness-prototype"
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

        Region { id: noInput }

        ColumnLayout {
            anchors.fill: parent
            anchors.margins: 24
            spacing: 12

            RowLayout {
                Layout.fillWidth: true

                StyledText {
                    text: "Caelestia Windows brightness"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                StyledText {
                    text: Brightness.status
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
                IconButton {
                    visible: !root.smoke
                    icon: "refresh"
                    onClicked: Brightness.refreshRoutes()
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Brightness.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            Repeater {
                model: Brightness.monitors

                StyledText {
                    required property var modelData

                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    font: Tokens.font.body.small
                    color: Colours.palette.m3onSurfaceVariant
                    text: modelData.screenName + " · " + modelData.stateLabel
                        + (modelData.route.length > 0 ? " · " + modelData.routeLabel : "")
                        + (modelData.latched ? " · route changed, waiting for a user refresh" : "")
                        + "\n" + modelData.stateReason
                }
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            // The original OSD content, including its brightness slider and
            // dimension/icon expressions. It is instantiated only with the
            // observation opt-in; the localized hooks hide the audio rows and
            // disable the brightness row when the service refuses the route.
            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true

                Loader {
                    id: osdHost

                    anchors.centerIn: parent
                    active: Brightness.enabled && root.selectedMonitor !== null
                        && root.screenState !== null
                    sourceComponent: OsdModule.Content {
                        objectName: "windowsOsdBrightness"
                        monitor: root.selectedMonitor
                        screenState: root.screenState
                        volume: 0
                        muted: false
                        sourceVolume: 0
                        sourceMuted: false
                        brightness: root.selectedMonitor ? root.selectedMonitor.brightness : 0
                        audioControlsEnabled: false
                        brightnessControlsEnabled: root.selectedMonitor
                            ? root.selectedMonitor.interactive : false
                    }
                }

                StyledText {
                    anchors.horizontalCenter: parent.horizontalCenter
                    anchors.top: osdHost.bottom
                    anchors.topMargin: 16
                    visible: root.selectedMonitor !== null
                    width: parent.width
                    horizontalAlignment: Text.AlignHCenter
                    wrapMode: Text.WordWrap
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                    text: root.selectedMonitor
                        ? root.selectedMonitor.stateLabel
                            + (root.selectedMonitor.route.length > 0
                                ? " · " + root.selectedMonitor.routeLabel : "")
                        : ""
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
            return JSON.stringify(root.brightnessState());
        }
        function quit(): void { Qt.quit(); }
    }

    Timer {
        id: check
        property int step
        property int waits
        running: root.smoke && root.selectedScreen !== null
        repeat: true
        interval: 1000
        onTriggered: {
            if (root.failed)
                return;
            if (Brightness.enabled && Brightness.status === "loading")
                return;
            // Bound the wait for the backend's deferred route queries.
            if (Brightness.enabled && root.anyQuerying() && waits < 10) {
                waits++;
                return;
            }
            const state = root.brightnessState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialBrightnessState === null)
                    return;
            } else if (step === 1) {
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 2) {
                console.log("CAELESTIA_BRIGHTNESS_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_BRIGHTNESS_CAPTURE", path);
                    console.log("CAELESTIA_BRIGHTNESS_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_BRIGHTNESS_FAIL: screenshot");
                    Qt.exit(1);
                });
            }
            step++;
        }
    }

    Timer {
        running: root.smoke
        interval: 20000
        onTriggered: {
            console.error("CAELESTIA_BRIGHTNESS_FAIL: timeout", Brightness.status, Brightness.reason);
            Qt.exit(1);
        }
    }
}
