import QtQuick
import Quickshell.Windows

// Loaded by URL only after Nmcli.enabled. Referencing the Windows Network
// singleton constructs the backend: its constructor starts connectivity and
// WLAN observation, which opens WLAN on a worker and publishes the outcome.
// Construction sends no write command.
//
// The backend publishes wifiInitialized when the open, explicit interface
// selection and notification subscription have finished, and wifiBackendError
// when they failed. A failed open or a refused subscription is therefore an
// error, not "no adapter". Older pinned backends expose neither property: for
// those the bounded observation fallback below still settles the wrapper.
QtObject {
    id: root

    // The native flag is absent on older pins; the fallback preserves their
    // behaviour until the backend pin moves.
    readonly property bool nativeStatusAvailable: typeof Network.wifiInitialized === "boolean"
    readonly property string nativeError: typeof Network.wifiBackendError === "string"
        ? Network.wifiBackendError : ""
    property bool legacySettled: false
    readonly property bool initialized: root.nativeStatusAvailable
        ? Network.wifiInitialized === true
        : (root.legacySettled || root.observed)

    readonly property bool wifiAdapterPresent: Network.wifiAdapterPresent
    readonly property bool wifiRadioOn: Network.wifiRadioOn
    readonly property bool wifiScanning: Network.wifiScanning
    // Advances once per completed refresh of the available-network list.
    readonly property int wifiSnapshot: Network.wifiSnapshot
    readonly property bool wifiConnecting: Network.wifiConnecting
    readonly property string wifiConnectingSsid: Network.wifiConnectingSsid
    readonly property string activeSsid: Network.activeSsid
    readonly property string activeBssid: Network.activeBssid
    readonly property int activeSignalQuality: Network.activeSignalQuality
    readonly property string activeSecurity: Network.activeSecurity
    readonly property string wifiStatus: Network.wifiStatus
    readonly property bool needsLocationPermission: Network.needsLocationPermission
    readonly property bool hasInternet: Network.hasInternet
    readonly property bool ethernetConnected: Network.ethernetConnected
    readonly property var networks: Network.networks

    readonly property bool observed: Network.wifiAdapterPresent || Network.wifiRadioOn
        || Network.activeSsid !== "" || Network.needsLocationPermission
        || Network.wifiStatus !== "disabled"

    // Re-emitted so the adapter does not have to know the native signal name.
    signal connectResult(string ssid, bool success, string reason)

    function setWifiListVisible(visible): void {
        Network.setWifiListVisible(visible === true);
    }
    function setWifiRadioEnabled(enabled): void {
        Network.setWifiRadioEnabled(enabled === true);
    }
    function scanWifiNetworks(): void {
        Network.scanWifiNetworks();
    }
    function connectToNetwork(ssid, password): void {
        // The adapter only ever passes an empty password: saved profiles and
        // open networks are the supported paths.
        Network.connectToNetwork(ssid, password ?? "");
    }
    function disconnectActive(): void {
        Network.disconnectActive();
    }
    function forgetNetwork(ssid): void {
        Network.forgetNetwork(ssid);
    }
    function openWifiSettings(): void {
        Network.openWifiSettings();
    }
    function openLocationSettings(): void {
        Network.openLocationSettings();
    }

    onObservedChanged: {
        if (!root.nativeStatusAvailable && root.observed)
            root.legacySettled = true;
    }

    Component.onCompleted: {
        if (!root.nativeStatusAvailable && root.observed)
            root.legacySettled = true;
    }

    // Compatibility fallback only: a pinned backend without the native flag
    // never reports initialization, so keep its old bounded settle window. The
    // fixed delay is not part of the native path.
    readonly property Timer settleTimer: Timer {
        interval: 4000
        repeat: false
        running: !root.nativeStatusAvailable && !root.legacySettled
        onTriggered: root.legacySettled = true
    }

    readonly property Connections nativeConnectResult: Connections {
        target: Network

        function onWifiConnectResult(ssid, success, reason): void {
            root.connectResult(ssid, success, reason);
        }
    }
}
