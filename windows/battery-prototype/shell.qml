//@ pragma AppId org.caelestia.windows-battery-prototype
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
import qs.services
import qs.modules.bar.popouts as BarPopouts
import qs.modules.bar.components.status as BarStatus

// A separate bounded M2 host for the original read-only battery status. Other
// services, profile selection, power-plan writes and all shell controllers
// stay unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(640, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(620, (selectedScreen?.height ?? 780) - 160)
    property var initialBatteryState

    settings.watchFiles: false

    function batteryState(): var {
        return {
            status: Battery.status, reason: Battery.reason, enabled: Battery.enabled,
            backendLoaded: Battery.backend !== null,
            present: Battery.present, laptopBattery: Battery.laptopBattery,
            hasBattery: Battery.hasBattery, onBattery: Battery.onBattery,
            charging: Battery.charging, state: Battery.state,
            percentage: Battery.percentage, timeToEmpty: Battery.timeToEmpty,
            iconName: Battery.iconName
        };
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

        name: "battery-prototype"
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
                    text: "Caelestia Windows battery"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                // The original bar status icon. Instantiated only with the
                // read-only opt-in: it binds UPower directly, like upstream.
                Loader {
                    id: statusLoader
                    active: Battery.enabled
                    sourceComponent: BarStatus.BatteryStatus {
                        colour: Colours.palette.m3onSurfaceVariant
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Battery.reason
                    + (Battery.enabled
                    ? "\nRead-only preview. Profile selection and power-plan writes stay unavailable."
                    : "")
                color: Colours.palette.m3onSurfaceVariant
            }

            Flickable {
                id: viewport
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: batteryHost.item ? batteryHost.item.implicitHeight : 0
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                // The original popout content. Instantiated only with the
                // read-only opt-in: it binds UPower directly, like upstream.
                Loader {
                    id: batteryHost
                    active: Battery.enabled
                    width: viewport.width
                    sourceComponent: BarPopouts.Battery {
                        id: batteryContent
                        objectName: "windowsBatteryPopout"
                        profileStatusEnabled: false
                        profileControlsEnabled: false
                    }
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
            return JSON.stringify(root.batteryState());
        }
        function quit(): void { Qt.quit(); }
    }

    Component.onCompleted: {
        if (!selectedScreen)
            Qt.callLater(() => Qt.exit(1));
    }

    Timer {
        id: check
        property int step
        running: root.smoke && root.selectedScreen !== null
        repeat: true
        interval: 1000
        onTriggered: {
            if (Battery.status === "initializing")
                return;
            const state = root.batteryState();
            if (step === 0) {
                const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
                if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                        || win.width !== root.previewWidth || win.height !== root.previewHeight
                        || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                        || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_BATTERY") === "1")
                        || batteryHost.active !== Battery.enabled || statusLoader.active !== Battery.enabled) {
                    console.error("CAELESTIA_BATTERY_FAIL: UI, fonts, DPI or service policy");
                    Qt.exit(1);
                    return;
                }
                if (state.enabled && (batteryHost.item?.profileControlsEnabled !== false
                        || batteryHost.item?.profileStatusEnabled !== false)) {
                    console.error("CAELESTIA_BATTERY_FAIL: write-capable profile controls are bounded off");
                    Qt.exit(1);
                    return;
                }
                root.initialBatteryState = state;
                console.log("CAELESTIA_BATTERY_SCREEN", JSON.stringify({
                    index: root.screenIndex, name: win.screen.name,
                    x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
                    width: win.width, height: win.height
                }));
                console.log("CAELESTIA_BATTERY_INITIAL", JSON.stringify(state));
            } else if (step === 1) {
                if (!Number.isFinite(state.percentage) || state.percentage < 0 || state.percentage > 1) {
                    console.error("CAELESTIA_BATTERY_FAIL: percentage guard");
                    Qt.exit(1);
                    return;
                }
                // Truthful absence: no battery means no fake level, estimate,
                // charging state or icon. Adapter constants mirror
                // UPowerDeviceState; Charging/FullyCharged/PendingCharge are
                // the upstream "charging" set.
                if (!state.hasBattery && (state.percentage !== 0 || state.timeToEmpty !== 0
                        || state.charging || state.iconName !== "" || state.state !== Battery.stateUnknown)) {
                    console.error("CAELESTIA_BATTERY_FAIL: absent battery invented state");
                    Qt.exit(1);
                    return;
                }
                if (state.charging !== [Battery.stateCharging, Battery.stateFullyCharged, Battery.statePendingCharge].includes(state.state)) {
                    console.error("CAELESTIA_BATTERY_FAIL: charging gate");
                    Qt.exit(1);
                    return;
                }
                if (state.enabled) {
                    if (state.status !== "ready" && state.status !== "unavailable") {
                        console.error("CAELESTIA_BATTERY_FAIL: read-only status did not settle: " + state.status);
                        Qt.exit(1);
                        return;
                    }
                    if (state.hasBattery !== (state.present && state.laptopBattery)) {
                        console.error("CAELESTIA_BATTERY_FAIL: battery gating");
                        Qt.exit(1);
                        return;
                    }
                    if (state.onBattery && !state.hasBattery) {
                        console.error("CAELESTIA_BATTERY_FAIL: battery power without a battery");
                        Qt.exit(1);
                        return;
                    }
                } else if (state.status !== "disabled" || state.backendLoaded
                        || batteryHost.item !== null || statusLoader.item !== null) {
                    console.error("CAELESTIA_BATTERY_FAIL: disabled mode constructed the backend or original components");
                    Qt.exit(1);
                    return;
                }
            } else if (step === 2) {
                console.log("CAELESTIA_BATTERY_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_BATTERY_CAPTURE", path);
                    console.log("CAELESTIA_BATTERY_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_BATTERY_FAIL: screenshot");
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
            console.error("CAELESTIA_BATTERY_FAIL: timeout", Battery.status, Battery.reason);
            Qt.exit(1);
        }
    }
}
