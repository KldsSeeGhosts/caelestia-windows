import QtQuick

// Windows adaptation of the bounded state of services/Nmcli.qml. This object
// imports no Quickshell or native module and runs no process: it projects the
// pinned Windows backend's connectivity/WLAN state, exposes the explicit
// Windows states, and gates every mutating request behind the separate controls
// opt-in. Backends may be injected in tests.
//
// The pinned backend (14010429) has no initialization/error state for Network.
// Construction starts connectivity and WLAN observation after the first frame,
// and a successful WLAN open performs one available-network query even while
// the list is hidden. The backend supplies no "ready", "last error" or radio
// write result, so this adapter distinguishes what it observes from what it can
// only request:
//   - initialized is a bounded adapter flag (see NativeNetworkBackend.qml), not
//     a native capability;
//   - a missing adapter and a WLAN service failure both surface as
//     wifiAdapterPresent=false (network_wifi.cpp:169-173);
//   - connect has a real result signal (wifiConnectResult), while radio,
//     disconnect, forget and scan have none (network_wifi.cpp:232-258,
//     451-460, 260-271). Requests without a result are never reported applied.
//
// There is deliberately no password argument or credential store here. A
// secured network without a saved Windows profile is not connected by this
// slice; Windows Settings owns that credential prompt.
QtObject {
    id: root

    // The injected backend is the NativeNetworkBackend facade (or a test fake)
    // exposing initialized, wifiAdapterPresent, wifiRadioOn, wifiScanning,
    // wifiConnecting, wifiConnectingSsid, activeSsid, activeBssid,
    // activeSignalQuality, activeSecurity, wifiStatus, hasInternet,
    // needsLocationPermission, ethernetConnected, networks (.values),
    // setWifiListVisible(), scanWifiNetworks(), connectToNetwork(ssid, ""),
    // disconnectActive(), forgetNetwork(ssid), setWifiRadioEnabled(),
    // openWifiSettings(), openLocationSettings() and the
    // connectResult(ssid, success, reason) signal.
    property var backend: null
    property bool enabled: false
    property bool controlsEnabled: false

    // A loader can supply a known component failure. Native status is observed
    // through the backend contract instead.
    property string backendError: ""

    // Bounded lifecycle flag supplied by the native wrapper. A truthy
    // non-boolean is not accepted.
    readonly property bool nativeInitialized: enabled && !backendError && backend !== null
        && backend.initialized === true

    readonly property bool adapterPresent: nativeInitialized && backend.wifiAdapterPresent === true
    readonly property bool radioOn: adapterPresent && backend.wifiRadioOn === true
    readonly property bool locationDenied: nativeInitialized && backend.needsLocationPermission === true

    // A denied current-connection query returns before writing state
    // (network_wifi.cpp:369-372), so a previous SSID can survive. While
    // location is denied the adapter reports no current connection rather than
    // repeating an unverifiable value.
    readonly property string activeSsid: {
        if (!radioOn || locationDenied)
            return "";

        const ssid = backend?.activeSsid;
        return typeof ssid === "string" ? ssid : "";
    }
    readonly property string activeBssid: {
        if (!radioOn || locationDenied)
            return "";
        const bssid = backend?.activeBssid;
        return typeof bssid === "string" ? bssid : "";
    }
    readonly property int activeSignalQuality: {
        if (!radioOn || locationDenied)
            return 0;
        const quality = backend?.activeSignalQuality;
        return Number.isFinite(quality) ? Math.max(0, Math.min(100, Math.round(quality))) : 0;
    }
    readonly property string activeSecurity: {
        if (!radioOn || locationDenied)
            return "";
        const security = backend?.activeSecurity;
        return typeof security === "string" ? security : "";
    }

    readonly property bool hasInternet: nativeInitialized && backend.hasInternet === true
    readonly property bool limited: activeSsid !== "" && !hasInternet
    readonly property string wifiStatus: {
        if (!nativeInitialized)
            return "";
        const status = backend.wifiStatus;
        return typeof status === "string" ? status : "";
    }

    readonly property bool scanning: nativeInitialized && backend.wifiScanning === true
    readonly property bool connecting: nativeInitialized && backend.wifiConnecting === true
    readonly property string connectingSsid: {
        if (!connecting)
            return "";
        const ssid = backend?.wifiConnectingSsid;
        return typeof ssid === "string" ? ssid : "";
    }

    // Eight explicit states. "initializing" is the bounded wait for the first
    // observation; "unavailable" is a component load failure. The remaining
    // order is adapter, location, radio, connection, so a denied list is never
    // presented as a connected or disconnected observation.
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (!nativeInitialized)
            return "initializing";
        if (!adapterPresent)
            return "no-adapter";
        if (locationDenied)
            return "location-denied";
        if (!radioOn)
            return "radio-off";
        if (connecting)
            return "connecting";
        if (activeSsid !== "")
            return "connected";
        return "disconnected";
    }

    // Lists are only truthful while the adapter, radio and location permission
    // allow a WLAN query. Windows hides nearby networks without location
    // permission, and a radio-off list would only be a stale snapshot.
    readonly property bool listAvailable: status === "connected" || status === "connecting"
        || status === "disconnected"
    readonly property bool listHidden: enabled && !listAvailable

    readonly property string reason: {
        switch (root.status) {
        case "disabled":
            return "Windows network is disabled.";
        case "unavailable":
            return root.backendError;
        case "initializing":
            return "Waiting for the Windows network backend to report adapter and radio state.";
        case "no-adapter":
            return "No Wi-Fi adapter was reported. Wired status is still observed; the WLAN service may also be unavailable.";
        case "location-denied":
            return "Windows location permission is required to list Wi-Fi networks. The network list stays hidden.";
        case "radio-off":
            return "Wi-Fi is turned off.";
        case "connecting":
            return "Connecting to " + (root.connectingSsid || "a network") + "...";
        case "connected":
            return "Connected to " + root.activeSsid + (root.limited ? " without internet access." : ".");
        default:
            return "Wi-Fi is on; no network is connected.";
        }
    }

    // The visible AP projection. Only object entries with a non-empty string
    // SSID are accepted; the array identity changes only when list membership
    // or an SSID changes, so per-AP signal updates do not rebuild the repeater.
    readonly property var networkSources: {
        if (!root.listAvailable)
            return [];

        const values = root.backend?.networks?.values;
        if (!Array.isArray(values))
            return [];

        const list = [];
        for (let i = 0; i < values.length; i++) {
            const value = values[i];
            if (!value || typeof value !== "object")
                continue;
            const ssid = value.ssid;
            if (typeof ssid !== "string" || ssid.length === 0)
                continue;
            list.push(value);
        }
        return list;
    }
    readonly property int networkCount: networkSources.length
    readonly property var activeSource: networkSources.find(network => network.active === true) ?? null

    readonly property bool ethernetConnected: nativeInitialized && backend.ethernetConnected === true
    // The pinned backend exposes only a connected flag for wired networking: no
    // adapter list, link speed, usage, address or saved-connection details
    // (network.hpp:27-41 keeps Ethernet to two booleans). Controls and advanced
    // configuration are therefore unavailable rather than approximated.
    readonly property bool ethernetControlSupported: false
    readonly property bool ethernetConfigSupported: false
    readonly property var ethernetSources: root.ethernetConnected ? [{
        iface: "",
        type: "ethernet",
        state: "connected",
        connection: "",
        connected: true,
        ipAddress: "",
        gateway: "",
        dns: [],
        subnet: "",
        macAddress: "",
        speed: ""
    }] : []
    readonly property int ethernetDeviceCount: ethernetSources.length
    readonly property var activeEthernetSource: root.ethernetConnected ? root.ethernetSources[0] : null

    // Explicit command feedback. A request is not a result: verified is true
    // only when a native signal reported the outcome (connect), while radio,
    // disconnect and forget stay requested/unverified.
    property var lastResult: null
    property int resultSequence: 0
    property int commandsSent: 0
    property int scansRequested: 0
    property string pendingSsid: ""

    readonly property string resultText: lastResult?.text ?? ""
    readonly property string resultKind: lastResult?.kind ?? ""
    readonly property string resultSsid: lastResult?.ssid ?? ""
    readonly property bool resultVerified: lastResult?.verified === true
    readonly property bool resultRequested: lastResult?.requested === true
    readonly property bool resultSucceeded: lastResult?.success === true

    // List visibility is caller intent. The backend starts its eight-second
    // scan timer only through setWifiListVisible(true) (network.cpp:71-82), so
    // this adapter never asks for a scan or a visibility refresh while hidden.
    property bool listVisible: false

    // Tracks the last visibility written to the current backend so a loader
    // swap or a state change does not repeat an identical request.
    property bool backendListVisible: false

    onBackendChanged: {
        root.backendListVisible = false;
        root._applyListVisibility();
    }

    function _result(kind, ssid, requested, verified, success, reason, text): void {
        root.resultSequence++;
        root.lastResult = {
            kind: kind,
            ssid: ssid ?? "",
            requested: requested === true,
            verified: verified === true,
            success: success === true ? true : (success === false ? false : null),
            reason: reason ?? "",
            text: text ?? "",
            sequence: root.resultSequence
        };
    }

    function _refusalText(action): string {
        if (!root.enabled)
            return action + " is unavailable because Windows network is disabled.";
        if (root.backendError)
            return action + " is unavailable: " + root.backendError;
        if (root.backend === null || root.backend.initialized !== true)
            return action + " is unavailable while the Windows network backend initializes.";
        switch (root.status) {
        case "no-adapter":
            return action + " is unavailable: no Wi-Fi adapter was reported.";
        case "location-denied":
            return action + " is unavailable until Windows location permission is granted.";
        case "radio-off":
            return action + " is unavailable while Wi-Fi is off.";
        default:
            return action + " is unavailable.";
        }
    }

    function _refuse(action): void {
        root._result("refused", "", false, true, false, "controls-disabled",
            root.controlsEnabled ? root._refusalText(action) : action
            + " is disabled for read-only observation.");
    }

    function connectReasonText(reason): string {
        switch (reason) {
        case "auth":
            return "authentication failed";
        case "other":
            return "Windows reported an unspecified failure";
        default:
            return typeof reason === "string" && reason.length > 0 ? reason : "no reason reported";
        }
    }

    function findNetwork(ssid): var {
        if (typeof ssid !== "string" || ssid.length === 0)
            return null;
        return root.networkSources.find(network => network.ssid === ssid) ?? null;
    }

    function hasSavedProfile(ssid): bool {
        return root.findNetwork(ssid)?.hasProfile === true;
    }

    function isKnownSource(source): bool {
        return !!source && root.networkSources.indexOf(source) >= 0;
    }

    // A radio write failure only logs and may open Windows Settings
    // (network_wifi.cpp:250-255). No native result exists, so the request is
    // reported as unverified.
    function requestRadio(on): void {
        const action = on === true ? "Turning Wi-Fi on" : "Turning Wi-Fi off";
        if (!root.controlsEnabled) {
            root._refuse(action);
            return;
        }
        if (!root.adapterPresent) {
            root._result("refused", "", false, true, false, "unavailable", root._refusalText(action));
            return;
        }
        root.commandsSent++;
        root.backend.setWifiRadioEnabled(on === true);
        root._result("radio", "", true, false, null, "",
            action + " requested. Windows has not confirmed the change.");
    }

    // The backend's connectToNetwork() trusts its caller (network.cpp:41-54):
    // an unknown SSID is treated as an open network and a profile may be
    // written. Membership, state and credential policy are enforced here before
    // the call.
    function requestConnect(source): void {
        if (!root.controlsEnabled) {
            root._refuse("Connecting");
            return;
        }
        if (!root.listAvailable || !root.adapterPresent) {
            root._result("refused", "", false, true, false, "unavailable", root._refusalText("Connecting"));
            return;
        }
        if (root.connecting) {
            root._result("refused", "", false, true, false, "busy",
                "Connecting was not requested because another connection request is in progress.");
            return;
        }
        if (!root.isKnownSource(source)) {
            root._result("refused", "", false, true, false, "stale",
                "Connecting was not requested because that network is no longer in the visible list.");
            return;
        }

        const ssid = source.ssid;
        if (source.active === true) {
            root._result("refused", ssid, false, true, false, "active", ssid + " is already connected.");
            return;
        }

        const security = typeof source.security === "string" ? source.security : "";
        if (security.length > 0 && source.hasProfile !== true) {
            root._result("settings", ssid, false, true, false, "no-profile",
                ssid + " has no saved Windows profile. Connect to it in Windows Settings; this slice collects no credentials.");
            return;
        }

        root.pendingSsid = ssid;
        root.commandsSent++;
        root.backend.connectToNetwork(ssid, "");
        root._result("connect", ssid, true, false, null, "", "Connecting to " + ssid + "...");
    }

    // Disconnect has no native result (network_wifi.cpp:451-454).
    function requestDisconnect(): void {
        if (!root.controlsEnabled) {
            root._refuse("Disconnecting");
            return;
        }
        if (!root.nativeInitialized || !root.adapterPresent) {
            root._result("refused", "", false, true, false, "unavailable", root._refusalText("Disconnecting"));
            return;
        }
        if (root.activeSsid === "") {
            root._result("refused", "", false, true, false, "not-connected",
                "Disconnecting was not requested because no Wi-Fi network is connected.");
            return;
        }
        root.commandsSent++;
        root.backend.disconnectActive();
        root._result("disconnect", root.activeSsid, true, false, null, "",
            "Disconnect requested for " + root.activeSsid + ". Windows has not confirmed the change.");
    }

    // Forget deletes the profile named by the SSID when no profile name is
    // known (network_wifi.cpp:456-460). Only a visible AP with a saved profile
    // may reach it.
    function requestForget(ssid): void {
        const action = "Forgetting a network";
        if (!root.controlsEnabled) {
            root._refuse(action);
            return;
        }
        if (!root.listAvailable) {
            root._result("refused", typeof ssid === "string" ? ssid : "", false, true, false,
                "unavailable", root._refusalText(action));
            return;
        }
        if (typeof ssid !== "string" || ssid.length === 0) {
            root._result("refused", "", false, true, false, "invalid",
                "Forgetting requires a network name.");
            return;
        }
        if (!root.hasSavedProfile(ssid)) {
            root._result("refused", ssid, false, true, false, "no-profile",
                "Forgetting was not requested because " + ssid + " has no saved Windows profile.");
            return;
        }
        root.commandsSent++;
        root.backend.forgetNetwork(ssid);
        root._result("forget", ssid, true, false, null, "",
            "Forget requested for " + ssid + ". Windows has not confirmed the change.");
    }

    function setListVisible(visible): void {
        const next = visible === true;
        if (root.listVisible === next)
            return;
        root.listVisible = next;
        root._applyListVisibility();
    }

    function _applyListVisibility(): void {
        if (!root.backend || typeof root.backend.setWifiListVisible !== "function")
            return;
        // Only a visible, queryable list asks the backend to refresh and start
        // its periodic scan. Any other state, including disabling the service,
        // stops the timer. Duplicate state is not forwarded.
        const next = root.enabled && root.listVisible && root.listAvailable;
        if (root.backendListVisible === next)
            return;
        root.backendListVisible = next;
        root.backend.setWifiListVisible(next);
    }

    // No native result exists for a scan. wifiScanning is the only evidence.
    function requestScan(): void {
        if (!root.enabled) {
            root._result("refused", "", false, true, false, "disabled", root._refusalText("Scanning"));
            return;
        }
        if (!root.listVisible) {
            root._result("refused", "", false, true, false, "hidden",
                "Network scans run only while the network list is visible.");
            return;
        }
        if (!root.listAvailable) {
            root._result("refused", "", false, true, false, "unavailable", root._refusalText("Scanning"));
            return;
        }
        if (!root.backend || typeof root.backend.scanWifiNetworks !== "function") {
            root._result("refused", "", false, true, false, "unavailable", root._refusalText("Scanning"));
            return;
        }
        root.scansRequested++;
        root.backend.scanWifiNetworks();
        root._result("scan", "", true, false, null, "",
            "Network scan requested. Windows reports scanning state; there is no per-scan result.");
    }

    function requestWifiSettings(): void {
        if (!root.enabled || !root.backend || typeof root.backend.openWifiSettings !== "function")
            return;
        root.backend.openWifiSettings();
        root._result("settings", "", true, false, null, "", "Windows Wi-Fi settings requested.");
    }

    function requestLocationSettings(): void {
        if (!root.enabled || !root.backend || typeof root.backend.openLocationSettings !== "function")
            return;
        root.backend.openLocationSettings();
        root._result("settings", "", true, false, null, "", "Windows location settings requested.");
    }

    function reportEthernetUnavailable(): void {
        root._result("unsupported", "", false, true, false, "unsupported",
            "Ethernet control is unavailable: the Windows backend exposes only a connected flag.");
    }

    onListAvailableChanged: root._applyListVisibility()
    onEnabledChanged: {
        if (!root.enabled) {
            root.listVisible = false;
            root.pendingSsid = "";
            root.lastResult = null;
            root.commandsSent = 0;
            root.scansRequested = 0;
            root._applyListVisibility();
        }
    }
    Component.onDestruction: {
        if (root.backend && typeof root.backend.setWifiListVisible === "function")
            root.backend.setWifiListVisible(false);
    }

    readonly property var connectTarget: root.backend
        && typeof root.backend.setWifiListVisible === "function" ? root.backend : null

    readonly property Connections connectResultWatch: Connections {
        target: root.connectTarget
        ignoreUnknownSignals: true

        // Only a result for this adapter's pending request may change the
        // command state. Connection notifications also fire for changes made
        // outside this adapter (Windows UI, another tool); those are not our
        // success to claim.
        function onConnectResult(ssid, success, reason): void {
            if (typeof ssid !== "string" || ssid === "" || ssid !== root.pendingSsid)
                return;

            root.pendingSsid = "";
            const ok = success === true;
            root._result("connect", ssid, true, true, ok, reason,
                ok ? "Connected to " + ssid + "." : "Could not connect to " + ssid + ": "
                    + root.connectReasonText(reason) + ".");
        }
    }
}
