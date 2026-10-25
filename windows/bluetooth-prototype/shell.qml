//@ pragma AppId org.caelestia.windows-bluetooth-prototype
//@ pragma DefaultEnv QS_NO_RELOAD_POPUP=1
//@ pragma DefaultEnv QS_RENDER_LOOP=threaded

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

// A separate bounded M2 host for the original Bluetooth status and popout. The
// original components bind Quickshell.Bluetooth directly, so they are
// instantiated only after the observation opt-in. Other services, global
// shortcuts, IPC mutations, credential UI and all shell controllers stay
// unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(560, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(700, (selectedScreen?.height ?? 780) - 160)
    property var initialBluetoothState: null
    property bool failed: false

    settings.watchFiles: false

    function bluetoothState(): var {
        const values = Bluetooth.devices;
        return {
            status: Bluetooth.status, reason: Bluetooth.reason,
            enabled: Bluetooth.enabled,
            controlsEnabled: Bluetooth.controlsEnabled,
            backendLoaded: Bluetooth.backend !== null,
            nativeRequested: Bluetooth.nativeRequested,
            initializationExpired: Bluetooth.initializationExpired,
            hasAdapter: Bluetooth.hasAdapter, adapterName: Bluetooth.adapterName,
            adapterState: Bluetooth.adapterState,
            radioEnabled: Bluetooth.radioEnabled,
            radioBlocked: Bluetooth.radioBlocked,
            radioPending: Bluetooth.radioPending, radioOff: Bluetooth.radioOff,
            radioUnknown: Bluetooth.radioUnknown,
            discovering: Bluetooth.discovering,
            discoveryTimedOut: Bluetooth.discoveryTimedOut,
            deviceCount: Bluetooth.deviceCount,
            devices: values.map(device => Bluetooth.deviceKey(device)),
            connectedCount: Bluetooth.connectedCount,
            pendingCount: Bluetooth.pendingCount, hasPending: Bluetooth.hasPending,
            pairing: Bluetooth.pairing,
            pairingNeedsWindowsSettings: Bluetooth.pairingNeedsWindowsSettings,
            canToggleRadio: Bluetooth.canToggleRadio,
            canSetDiscovering: Bluetooth.canSetDiscovering,
            canControlDevices: Bluetooth.canControlDevices,
            canConnect: values.map(device => Bluetooth.canConnect(device)),
            canDisconnect: values.map(device => Bluetooth.canDisconnect(device)),
            canPair: values.map(device => Bluetooth.canPair(device)),
            canForget: values.map(device => Bluetooth.canForget(device)),
            discoverableSupported: Bluetooth.discoverableSupported,
            renameSupported: Bluetooth.renameSupported,
            trustedSupported: Bluetooth.trustedSupported,
            blockedSupported: Bluetooth.blockedSupported,
            wakeSupported: Bluetooth.wakeSupported,
            settingsUri: Bluetooth.settingsUri,
            statusLoaded: statusLoader.item !== null,
            popoutLoaded: popoutHost.item !== null,
            popoutControlsEnabled: popoutHost.item?.controlsEnabled ?? false,
            popoutSettingsDelegated: popoutHost.item?.settingsDelegatesToWindows ?? false,
            popoutSettlingTimedOut: popoutHost.item?.settlingTimedOut ?? ({})
        };
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_BLUETOOTH_FAIL: " + message);
        Qt.exit(1);
    }

    function checkInitialState(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_BLUETOOTH") === "1")
                || state.controlsEnabled !== (state.enabled
                    && Quickshell.env("CAELESTIA_WINDOWS_BLUETOOTH_CONTROLS") === "1")) {
            root.fail("UI, fonts, DPI or service opt-in policy");
            return;
        }
        if (state.enabled) {
            if (!state.nativeRequested) {
                root.fail("enabled mode did not activate the native backend loader");
                return;
            }
            if (!state.statusLoaded || !state.popoutLoaded) {
                root.fail("original Bluetooth status or popout did not load");
                return;
            }
            if (state.popoutControlsEnabled !== state.controlsEnabled
                    || state.popoutSettingsDelegated !== true) {
                root.fail("original popout hooks do not match the service policy");
                return;
            }
        } else {
            // Disabled construction: no native loader, facade, status or popout.
            if (state.status !== "disabled" || state.nativeRequested
                    || state.backendLoaded || state.statusLoaded || state.popoutLoaded
                    || statusLoader.item !== null || popoutHost.item !== null) {
                root.fail("disabled mode constructed the backend or original components");
                return;
            }
        }
        root.initialBluetoothState = state;
        console.log("CAELESTIA_BLUETOOTH_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_BLUETOOTH_INITIAL", JSON.stringify(state));
    }

    function checkSettledState(state): void {
        if (!state.enabled) {
            if (state.status !== "disabled") {
                root.fail("disabled service did not settle: " + state.status);
                return;
            }
            return;
        }
        if (["no-adapter", "blocked", "off", "radio-pending", "on",
            "unknown-radio"].indexOf(state.status) < 0) {
            root.fail("enabled service did not settle: " + state.status);
            return;
        }
        // Smoke is always read-only: the launcher must never pass the control
        // opt-in, and no request may be advertised as available.
        if (state.controlsEnabled || state.popoutControlsEnabled) {
            root.fail("smoke run enabled Bluetooth controls");
            return;
        }
        for (const gate of ["canToggleRadio", "canSetDiscovering", "canControlDevices"]) {
            if (state[gate] !== false) {
                root.fail("read-only capability gate is true: " + gate);
                return;
            }
        }
        for (const gates of [state.canConnect, state.canDisconnect, state.canPair,
            state.canForget]) {
            if (gates.some(value => value !== false)) {
                root.fail("read-only device capability gate is true");
                return;
            }
        }
        for (const gate of ["discoverableSupported", "renameSupported",
            "trustedSupported", "blockedSupported", "wakeSupported"]) {
            if (state[gate] !== false) {
                root.fail("unsupported control is advertised as supported: " + gate);
                return;
            }
        }
        // Nothing in construction or observation may start discovery. The
        // bounded stop can only expire a discovery this process started.
        if (state.discovering || state.discoveryTimedOut) {
            root.fail("read-only observation started or timed out discovery");
            return;
        }
        if (state.settingsUri !== "ms-settings:bluetooth") {
            root.fail("Windows Settings delegation target changed");
            return;
        }
        if (state.status === "no-adapter") {
            if (state.hasAdapter || state.deviceCount !== 0
                    || state.radioEnabled || state.deviceCount !== state.devices.length) {
                root.fail("null-adapter state exposed stale devices or radio");
                return;
            }
        } else {
            if (!state.hasAdapter) {
                root.fail("adapter state without an adapter");
                return;
            }
            if (state.status === "blocked" && (!state.radioBlocked || state.radioEnabled)) {
                root.fail("blocked radio state is inconsistent");
                return;
            }
            if (state.status === "off" && (state.radioEnabled || state.radioBlocked)) {
                root.fail("off radio state is inconsistent");
                return;
            }
            if (state.status === "on" && !state.radioEnabled) {
                root.fail("on state without an enabled radio");
                return;
            }
            if (state.adapterName === "") {
                root.fail("adapter has no name");
                return;
            }
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

    BarPopouts.PopoutState {
        id: popoutState
    }

    StyledWindow {
        id: win

        name: "bluetooth-prototype"
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
                    text: "Caelestia Windows Bluetooth"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                // The original bar status icon. Instantiated only with the
                // observation opt-in: it binds Quickshell.Bluetooth directly.
                Loader {
                    id: statusLoader
                    active: Bluetooth.enabled
                    sourceComponent: BarStatus.BluetoothStatus {
                        colour: Colours.palette.m3onSurfaceVariant
                    }
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Bluetooth.reason
                color: Colours.palette.m3onSurfaceVariant
                font: Tokens.font.body.small
            }

            StyledRect {
                Layout.fillWidth: true
                implicitHeight: 1
                color: Colours.palette.m3outlineVariant
            }

            Flickable {
                id: viewport
                Layout.fillWidth: true
                Layout.fillHeight: true
                clip: true
                contentWidth: width
                contentHeight: popoutHost.item ? Math.max(popoutHost.item.implicitHeight, 1) : 0
                boundsBehavior: Flickable.StopAtBounds
                ScrollBar.vertical: ScrollBar {}

                // The original Bluetooth popout. It is instantiated only with
                // the observation opt-in. Read-only mode disables the original
                // toggles and device actions; the original "Open settings"
                // button delegates to Windows Settings on an explicit click.
                Loader {
                    id: popoutHost
                    active: Bluetooth.enabled
                    width: viewport.width
                    height: item ? Math.max(item.implicitHeight, 0) : 0
                    sourceComponent: BarPopouts.Bluetooth {
                        objectName: "windowsBluetoothPopout"
                        popouts: popoutState
                        controlsEnabled: Bluetooth.controlsEnabled
                        settingsDelegatesToWindows: true
                        settlingTimedOut: Bluetooth.timedOutDevices
                        onSettingsRequested: Qt.openUrlExternally(Bluetooth.settingsUri)
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
            return JSON.stringify(root.bluetoothState());
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
            if (root.failed)
                return;
            // Wait for the bounded first-adapter observation before judging the
            // settled state; the timeout below bounds the wait.
            if (Bluetooth.enabled && Bluetooth.status === "initializing")
                return;
            const state = root.bluetoothState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialBluetoothState === null)
                    return;
            } else if (step === 1) {
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 2) {
                console.log("CAELESTIA_BLUETOOTH_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_BLUETOOTH_CAPTURE", path);
                    console.log("CAELESTIA_BLUETOOTH_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_BLUETOOTH_FAIL: screenshot");
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
            console.error("CAELESTIA_BLUETOOTH_FAIL: timeout", Bluetooth.status, Bluetooth.reason);
            Qt.exit(1);
        }
    }
}
