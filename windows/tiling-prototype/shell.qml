//@ pragma AppId org.caelestia.windows-tiling-prototype
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

// A separate bounded M3 host for the tiling opt-in slice: the pure Tiling
// service state, the original toast surface that explains fitting failures,
// and (only for observe/interactive) the backend `Tiling` wrapper loaded by
// the service facade. This host itself imports no Quickshell.Windows type
// and never constructs `Tiling`, `WindowManager` or `Taskbar`; `off` runs
// keep the facade's wrapper Loader inactive end to end. Native harness runs
// use Disabled mode only.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(620, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(700, (selectedScreen?.height ?? 780) - 160)
    property var initialTilingState: null
    property bool failed: false

    settings.watchFiles: false

    function tilingState(): var {
        return {
            requestedMode: Tiling.requestedMode,
            mode: Tiling.mode,
            smoke: Tiling.smoke,
            status: Tiling.status,
            reason: Tiling.reason,
            backendRequested: Tiling.nativeRequested,
            backendLoaded: Tiling.backendLoaded,
            backendEnabled: Tiling.backendEnabled,
            includedSupported: Tiling.backendIncludedSupported,
            managedCount: Tiling.managedCount,
            failedCount: Tiling.failedCount,
            lastError: Tiling.lastError,
            includedCount: Tiling.includedPatterns.length,
            excludedCount: Tiling.excludedPatterns.length,
            recentFailureCount: Tiling.recentFailureCount,
            toastCount: Tiling.toastCount,
            toastsLoaded: toastsHost.item !== null,
            toastSurfaceWidth: toastsHost.item?.implicitWidth ?? 0
        };
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_TILING_FAIL: " + message);
        Qt.exit(1);
    }

    // Loaded by URL in every mode: the original toast surface is plain
    // Caelestia QML (plus the Notifs adapter) and carries no native import.
    // The host wrapper imports it as a qs module so sibling types resolve.
    function loadOriginalComponents(): void {
        if (toastsHost.item === null)
            toastsHost.setSource(Qt.resolvedUrl("components/ToastsHost.qml"));
    }

    function checkInitialState(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        // Interactive is never allowed during smoke: the service must have
        // forced it down to observe whatever the environment said.
        const envMode = Quickshell.env("CAELESTIA_WINDOWS_TILING");
        const expectedMode = root.smoke && envMode === "interactive" ? "observe" : envMode;
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.mode !== expectedMode
                || state.smoke !== root.smoke) {
            root.fail("UI, fonts, DPI or tiling opt-in policy");
            return;
        }
        if (state.mode !== "off" && !state.backendRequested) {
            root.fail("non-off mode did not activate the native wrapper loader");
            return;
        }
        // The disabled path is the only one this harness runs natively: the
        // facade must never have requested the wrapper, nothing may be
        // enabled, counted or failed, and no toast decision may exist.
        if (state.mode === "off") {
            if (state.status !== "disabled" || state.requestedMode !== "off"
                    || state.backendRequested || state.backendLoaded
                    || state.backendEnabled || state.includedSupported
                    || state.managedCount !== 0 || state.failedCount !== 0
                    || state.lastError !== "" || state.recentFailureCount !== 0
                    || state.toastCount !== 0) {
                root.fail("disabled mode constructed tiling state");
                return;
            }
        }
        if (!state.toastsLoaded) {
            root.fail("original toast surface did not load");
            return;
        }
        root.initialTilingState = state;
        console.log("CAELESTIA_TILING_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_TILING_INITIAL", JSON.stringify(state));
    }

    function checkSettledState(state): void {
        if (root.failed)
            return;
        if (state.mode === "off") {
            if (state.status !== "disabled" || state.backendLoaded
                    || state.toastCount !== 0 || state.recentFailureCount !== 0
                    || !state.toastsLoaded) {
                root.fail("disabled service did not stay disabled");
                return;
            }
            return;
        }
        // Non-off modes are orchestrator-owned live runs; the smoke harness
        // only proves the slice never regressed the stage.
        if (!state.toastsLoaded) {
            root.fail("an original component unloaded during the smoke");
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

        name: "tiling-prototype"
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
                    text: "Caelestia Windows Tiling"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                StyledText {
                    text: Tiling.status + "  tiling=" + Tiling.mode
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Tiling.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Tiling.mode !== "off"
                    ? ("backend loaded=" + (Tiling.backendLoaded ? 1 : 0)
                        + " enabled=" + (Tiling.backendEnabled ? 1 : 0)
                        + " included supported=" + (Tiling.backendIncludedSupported ? 1 : 0)
                        + "  managed " + Tiling.managedCount
                        + "  failed " + Tiling.failedCount
                        + "  recent " + Tiling.recentFailureCount
                        + "  toasts " + Tiling.toastCount)
                    : "No Windows tiling controller is constructed."
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            ColumnLayout {
                spacing: 8

                StyledText {
                    text: "Original toast surface"
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }

                StyledText {
                    Layout.fillWidth: true
                    wrapMode: Text.WordWrap
                    text: "Fitting failures and enable refusals are explained here through Toaster.toast; nothing is synthesised in Disabled runs."
                    color: Colours.palette.m3onSurfaceVariant
                    font: Tokens.font.body.small
                }

                Loader {
                    id: toastsHost

                    asynchronous: false
                    Layout.preferredWidth: item ? item.implicitWidth : 0
                    Layout.preferredHeight: item ? item.implicitHeight : 0
                    Layout.fillHeight: true
                }
            }

            Item {
                Layout.fillWidth: true
                Layout.fillHeight: true
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
            return JSON.stringify(root.tilingState());
        }
        function quit(): void {
            Qt.quit();
        }
    }

    Component.onCompleted: {
        Tiling.logStartupStatus();
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
            // Wait for the bounded backend load in non-off modes.
            if (Tiling.mode !== "off" && !Tiling.backendLoaded)
                return;
            const state = root.tilingState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialTilingState === null)
                    return;
            } else if (step === 1) {
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 2) {
                console.log("CAELESTIA_TILING_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_TILING_CAPTURE", path);
                    console.log("CAELESTIA_TILING_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_TILING_FAIL: screenshot");
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
            console.error("CAELESTIA_TILING_FAIL: timeout", Tiling.status, Tiling.reason);
            Qt.exit(1);
        }
    }
}
