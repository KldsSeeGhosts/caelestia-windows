import QtQuick
import Quickshell.Windows

// Loaded by URL only after Nmcli.enabled. Referencing the Windows Network
// singleton constructs the backend: its constructor starts connectivity and
// WLAN observation, and a successful WLAN open performs one nearby-network
// query even while the list is hidden (network.cpp:15-25,
// network_wifi.cpp:168-194). Construction sends no write command.
//
// The pinned backend has no initialization flag and no error string. This
// wrapper supplies a bounded adapter flag instead of inventing a native one:
// initialized becomes true on the first WLAN observation, or once a one-shot
// four-second settle window expires without one. The expiry reports absence,
// not a proven "no adapter": a WLAN service failure also leaves
// wifiAdapterPresent=false and only logs at debug level
// (network_wifi.cpp:169-173). A refused radio write also only warns and may
// open Windows Settings (network_wifi.cpp:250-255).
QtObject {
    id: root

    // Adapter lifecycle heuristic; see the comment above. Not a native flag.
    property bool initialized: false

    readonly property bool wifiAdapterPresent: Network.wifiAdapterPresent
    readonly property bool wifiRadioOn: Network.wifiRadioOn
    readonly property bool wifiScanning: Network.wifiScanning
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
        if (root.observed)
            root.initialized = true;
    }

    Component.onCompleted: {
        if (root.observed)
            root.initialized = true;
    }

    readonly property Timer settleTimer: Timer {
        interval: 4000
        repeat: false
        running: !root.initialized
        onTriggered: root.initialized = true
    }

    readonly property Connections nativeConnectResult: Connections {
        target: Network

        function onWifiConnectResult(ssid, success, reason): void {
            root.connectResult(ssid, success, reason);
        }
    }
}
