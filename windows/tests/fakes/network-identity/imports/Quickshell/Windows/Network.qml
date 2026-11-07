pragma Singleton
import QtQuick

// This fake is the only Quickshell.Windows module on the fixture import path.
QtObject {
    property bool wifiInitialized: true
    property string wifiBackendError: ""
    property bool wifiAdapterPresent: true
    property bool wifiRadioOn: true
    property bool wifiScanning: false
    property int wifiSnapshot: 0
    property bool wifiConnecting: false
    property string wifiConnectingSsid: ""
    property string activeSsid: ""
    property string activeBssid: ""
    property int activeSignalQuality: 0
    property string activeSecurity: ""
    property string wifiStatus: "disconnected"
    property bool needsLocationPermission: false
    property bool hasInternet: false
    property bool ethernetConnected: false
    property var networks: ({ values: [] })
    property int legacyConnects: 0
    property int idConnects: 0
    property int legacyForgets: 0
    property int idForgets: 0
    property string lastId: ""
    property string lastPassword: ""
    signal wifiConnectResult(string ssid, bool success, string reason)
    function connectToNetwork(ssid, password): void { legacyConnects++; }
    function connectToNetworkById(id, password): void {
        idConnects++;
        lastId = id;
        lastPassword = password;
    }
    function forgetNetwork(ssid): void { legacyForgets++; }
    function forgetNetworkById(id): void { idForgets++; lastId = id; }
}
