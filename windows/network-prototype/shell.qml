//@ pragma AppId org.caelestia.windows-network-prototype
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
import qs.utils
import qs.modules.bar.popouts as BarPopouts

// A separate bounded M2 host for the original network popout. Other services,
// global shortcuts, IPC mutations, nmcli processes, credential prompts and all
// shell controllers stay unloaded.
ShellRoot {
    id: root

    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"
    readonly property int screenIndex: Number(Quickshell.env("CAELESTIA_SHELL_SCREEN") || "0")
    readonly property ShellScreen selectedScreen: Quickshell.screens[screenIndex] ?? null
    readonly property int previewWidth: Math.min(520, (selectedScreen?.width ?? 800) - 160)
    readonly property int previewHeight: Math.min(680, (selectedScreen?.height ?? 780) - 160)
    // Smoke is no-input and must not request a scan. The adapter's visible-list
    // policy starts the backend's eight-second scan timer only when this is
    // true, so a smoke run keeps every scan path off while still rendering the
    // list snapshot from the backend's single startup query.
    readonly property bool listRequested: !root.smoke
    property var initialNetworkState: null
    property bool failed: false

    settings.watchFiles: false

    function networkState(): var {
        const result = Nmcli.lastResult;
        return {
            status: Nmcli.status, reason: Nmcli.reason, enabled: Nmcli.enabled,
            controlsEnabled: Nmcli.controlsEnabled,
            backendLoaded: Nmcli.backend !== null,
            nativeRequested: Nmcli.nativeRequested,
            initialized: Nmcli.nativeInitialized,
            adapterPresent: Nmcli.adapterPresent, radioOn: Nmcli.radioOn,
            locationDenied: Nmcli.locationDenied,
            needsLocationPermission: Nmcli.locationDenied,
            connected: Nmcli.activeSsid !== "", activeSsid: Nmcli.activeSsid,
            activeSignalQuality: Nmcli.activeSignalQuality,
            hasInternet: Nmcli.hasInternet, limited: Nmcli.limited,
            wifiStatus: Nmcli.wifiStatus, scanning: Nmcli.scanning,
            connecting: Nmcli.connecting, connectingSsid: Nmcli.connectingSsid,
            listVisible: Nmcli.listVisible, listAvailable: Nmcli.listAvailable,
            listHidden: Nmcli.listHidden,
            networkCount: Nmcli.networkCount,
            networks: Nmcli.networks.map(point => point.ssid),
            activeIdentity: Nmcli.active?.ssid ?? "",
            ethernetConnected: Nmcli.ethernetConnected,
            ethernetDeviceCount: Nmcli.ethernetDeviceCount,
            ethernetControlSupported: Nmcli.ethernetControlSupported,
            ethernetConfigSupported: Nmcli.ethernetConfigSupported,
            lastResultKind: result?.kind ?? "", lastResultText: result?.text ?? "",
            resultRequested: Nmcli.resultRequested, resultVerified: Nmcli.resultVerified,
            resultSucceeded: Nmcli.resultSucceeded, resultSequence: Nmcli.resultSequence,
            commandsSent: Nmcli.commandsSent, scansRequested: Nmcli.scansRequested,
            pendingSsid: Nmcli.pendingSsid,
            popoutLoaded: popoutHost.item !== null,
            popoutControlsEnabled: popoutHost.item?.controlsEnabled ?? null,
            popoutNativeConnect: popoutHost.item?.nativeConnect ?? null,
            popoutEthernetControlAvailable: popoutHost.item?.ethernetControlAvailable ?? null,
            popoutNativeConnectingSsid: popoutHost.item?.nativeConnectingSsid ?? "",
            statusIcon: statusIcon.text
        };
    }

    function fail(message: string): void {
        root.failed = true;
        console.error("CAELESTIA_NETWORK_FAIL: " + message);
        Qt.exit(1);
    }

    function checkInitialState(state): void {
        const requested = Quickshell.env("CAELESTIA_SHELL_SCALE");
        if ((requested !== "native" && Math.abs(win.devicePixelRatio - Number(requested)) > 0.01)
                || win.width !== root.previewWidth || win.height !== root.previewHeight
                || bodyFont.status !== FontLoader.Ready || iconFont.status !== FontLoader.Ready
                || state.enabled !== (Quickshell.env("CAELESTIA_WINDOWS_NETWORK") === "1")
                || state.controlsEnabled !== (state.enabled
                    && Quickshell.env("CAELESTIA_WINDOWS_NETWORK_CONTROLS") === "1")) {
            root.fail("UI, fonts, DPI or service opt-in policy");
            return;
        }
        if (state.listVisible !== root.listRequested) {
            root.fail("list visibility policy does not match the run mode");
            return;
        }
        if (state.enabled) {
            if (!state.nativeRequested) {
                root.fail("enabled mode did not activate the native backend loader");
                return;
            }
            if (!state.popoutLoaded || popoutHost.item === null) {
                root.fail("original network popout did not load");
                return;
            }
            if (state.popoutControlsEnabled !== state.controlsEnabled
                    || !state.popoutNativeConnect
                    || state.popoutEthernetControlAvailable !== false
                    || state.popoutNativeConnectingSsid !== state.connectingSsid) {
                root.fail("original popout hooks are not wired to the service");
                return;
            }
        } else {
            // Disabled construction: no native loader, facade, or component.
            if (state.status !== "disabled" || state.nativeRequested
                    || state.backendLoaded || state.popoutLoaded
                    || popoutHost.item !== null) {
                root.fail("disabled mode constructed the backend or original component");
                return;
            }
        }
        // Observation never sends a radio, connect, disconnect, forget or scan
        // request by itself.
        if (state.commandsSent !== 0 || state.scansRequested !== 0
                || state.lastResultKind !== "" || state.pendingSsid !== "") {
            root.fail("startup sent a network command");
            return;
        }
        root.initialNetworkState = state;
        console.log("CAELESTIA_NETWORK_SCREEN", JSON.stringify({
            index: root.screenIndex, name: win.screen.name,
            x: win.screen.x, y: win.screen.y, dpr: win.devicePixelRatio,
            width: win.width, height: win.height
        }));
        console.log("CAELESTIA_NETWORK_INITIAL", JSON.stringify(state));
    }

    function checkSettledState(state): void {
        if (!state.enabled) {
            if (state.status !== "disabled") {
                root.fail("disabled service did not settle: " + state.status);
                return;
            }
            return;
        }
        if (["no-adapter", "radio-off", "location-denied", "connected", "disconnected"]
                .indexOf(state.status) < 0) {
            root.fail("enabled service did not settle: " + state.status);
            return;
        }
        // Smoke is always read-only and no-scan: the launcher must never pass
        // the control opt-in, and no request may be advertised as available.
        if (state.controlsEnabled || state.commandsSent !== 0 || state.scansRequested !== 0
                || state.lastResultKind !== "" || state.pendingSsid !== "") {
            root.fail("smoke run enabled controls or sent a command");
            return;
        }
        if (state.listVisible !== false) {
            root.fail("smoke run requested a visible-list scan");
            return;
        }
        if (state.popoutLoaded !== true || state.popoutControlsEnabled !== false) {
            root.fail("original popout is not loaded with controls disabled");
            return;
        }
        if (state.initialized !== true || state.adapterPresent !== (state.status !== "no-adapter")) {
            root.fail("adapter state disagrees with the settled status");
            return;
        }
        if (state.networkCount !== state.networks.length) {
            root.fail("network count disagrees with the projected list");
            return;
        }
        if (state.listAvailable) {
            if (state.listHidden || state.status === "location-denied"
                    || state.status === "radio-off" || state.status === "no-adapter") {
                root.fail("available list is marked hidden");
                return;
            }
            for (const ssid of state.networks) {
                if (typeof ssid !== "string" || ssid.length === 0) {
                    root.fail("projected access point has no SSID");
                    return;
                }
            }
        } else {
            if (!state.listHidden || state.networkCount !== 0 || state.networks.length !== 0) {
                root.fail("hidden list exposed access points");
                return;
            }
        }
        if (state.status === "location-denied") {
            if (!state.needsLocationPermission || state.reason.indexOf("location permission") < 0
                    || state.activeSsid !== "") {
                root.fail("location denial is not explicit or hides connection state");
                return;
            }
        }
        if (state.status === "radio-off" && (state.radioOn || state.activeSsid !== "")) {
            root.fail("radio-off retained a radio or connection state");
            return;
        }
        if (state.status === "no-adapter" && (state.adapterPresent || state.radioOn)) {
            root.fail("no-adapter retained adapter or radio state");
            return;
        }
        if (state.status === "connected") {
            if (state.activeSsid === ""
                    || state.limited !== (state.activeSsid !== "" && !state.hasInternet)) {
                root.fail("connected state is inconsistent");
                return;
            }
        } else if (state.activeSsid !== "") {
            root.fail("disconnected state retained an active SSID");
            return;
        }
        if (state.ethernetDeviceCount !== (state.ethernetConnected ? 1 : 0)
                || state.ethernetControlSupported || state.ethernetConfigSupported) {
            root.fail("ethernet boundary is inconsistent");
            return;
        }
        if (typeof state.statusIcon !== "string" || state.statusIcon.length === 0) {
            root.fail("original status glyph is empty");
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

    // The original network popout requires a popout state object.
    BarPopouts.PopoutState {
        id: popoutState

        currentName: "network"
        hasCurrent: true
    }

    StyledWindow {
        id: win

        name: "network-prototype"
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
                    text: "Caelestia Windows network"
                    font: Tokens.font.body.large
                    Layout.fillWidth: true
                }
                // The original bar status expression for the network entry
                // (modules/bar/components/StatusIcons.qml).
                MaterialIcon {
                    id: statusIcon

                    animate: true
                    text: Nmcli.activeEthernet ? "cable" : Nmcli.active
                        ? Icons.getNetworkIcon(Nmcli.active.strength ?? 0) : "wifi_off"
                    color: Colours.palette.m3onSurfaceVariant
                }
                StyledText {
                    text: Nmcli.status
                    font: Tokens.font.label.medium
                    color: Colours.palette.m3onSurfaceVariant
                }
            }

            StyledText {
                Layout.fillWidth: true
                wrapMode: Text.WordWrap
                text: Nmcli.reason
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

                // The original network popout. It is instantiated only with the
                // observation opt-in; every control hook is wired to the
                // bounded facade, and Ethernet control stays unavailable.
                Loader {
                    id: popoutHost
                    active: Nmcli.enabled
                    width: viewport.width
                    height: item ? Math.max(item.implicitHeight, 0) : 0
                    sourceComponent: BarPopouts.Network {
                        objectName: "windowsNetworkPopout"
                        popouts: popoutState
                        view: Nmcli.activeEthernet ? "ethernet" : "wireless"
                        controlsEnabled: Nmcli.controlsEnabled
                        nativeConnect: true
                        nativeConnectingSsid: Nmcli.connectingSsid
                        ethernetControlAvailable: Nmcli.ethernetControlSupported
                        statusText: Nmcli.resultText.length > 0
                            ? Nmcli.resultText : (Nmcli.listHidden ? Nmcli.reason : "")
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
            return JSON.stringify(root.networkState());
        }
        function quit(): void { Qt.quit(); }
    }

    Component.onCompleted: {
        if (!selectedScreen)
            Qt.callLater(() => Qt.exit(1));
        Nmcli.setListVisible(root.listRequested);
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
            // Wait for the bounded adapter settle before judging the state; the
            // timeout below bounds the wait.
            if (Nmcli.enabled && Nmcli.status === "initializing")
                return;
            const state = root.networkState();
            if (step === 0) {
                root.checkInitialState(state);
                if (root.failed || root.initialNetworkState === null)
                    return;
            } else if (step === 1) {
                root.checkSettledState(state);
                if (root.failed)
                    return;
            } else if (step === 2) {
                console.log("CAELESTIA_NETWORK_FINAL", JSON.stringify(state));
                const path = Quickshell.env("CAELESTIA_SHELL_SCREENSHOT");
                CUtils.saveItem(win.contentItem, Qt.resolvedUrl(path), () => {
                    console.log("CAELESTIA_NETWORK_CAPTURE", path);
                    console.log("CAELESTIA_NETWORK_PASS", CUtils.qtVersion);
                    Qt.quit();
                }, () => {
                    console.error("CAELESTIA_NETWORK_FAIL: screenshot");
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
            console.error("CAELESTIA_NETWORK_FAIL: timeout", Nmcli.status, Nmcli.reason);
            Qt.exit(1);
        }
    }
}
