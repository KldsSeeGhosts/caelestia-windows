pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture. Imports no Quickshell, native Network, configuration or
// external state, reads no environment or hardware, and never constructs
// Nmcli.qml or NativeNetworkBackend.qml. Intended runner:
//   powershell -NoProfile -File windows/scripts/Test-NetworkService.ps1 -QtPrefix <Windows Qt prefix>
// The runner stages only this file, NetworkService.qml and the fixture's fake
// access-point shape through Qt's offscreen qml.exe.
QtObject {
    id: test

    // Shapes mirror the pinned backend's NetworkWifiNetwork
    // (network_wifi_item.hpp:15-21) and the adapter contract.
    component FakeNetwork: QtObject {
        property string ssid: ""
        property string bssid: ""
        property int strength: 0
        property int frequency: 0
        property bool active: false
        property string security: ""
        property bool hasProfile: false
    }

    component FakeModel: QtObject {
        property var values: []
    }

    component FakeBackend: QtObject {
        property bool initialized: false
        property string nativeError: ""
        property bool wifiAdapterPresent: false
        property bool wifiRadioOn: false
        property bool wifiScanning: false
        property bool wifiConnecting: false
        property string wifiConnectingSsid: ""
        property string activeSsid: ""
        property string activeBssid: ""
        property int activeSignalQuality: 0
        property string activeSecurity: ""
        property string wifiStatus: "disabled"
        property bool needsLocationPermission: false
        property bool hasInternet: false
        property bool ethernetConnected: false
        property var networks: null
        // The native completed-refresh generation.
        property int wifiSnapshot: 0

        property int radioWrites: 0
        property int scans: 0
        property int connects: 0
        property string lastConnectSsid: ""
        property string lastConnectPassword: "<unset>"
        property int disconnects: 0
        property int forgets: 0
        property string lastForgotten: ""
        property int listVisibilityCalls: 0
        property bool listVisibleArg: false
        property int wifiSettingsCalls: 0
        property int locationSettingsCalls: 0
        // Reproduce the pinned backend's synchronous callbacks: a denied
        // refresh inside setWifiListVisible(true) (network.cpp:75-78) and
        // WlanSetProfile/WlanConnect failures (network_wifi.cpp:423-447).
        property bool denyOnVisible: false
        property bool failConnectSync: false
        // The native timer starts after the refresh returns, so a nested
        // setWifiListVisible(false) during that refresh does not stop it.
        property bool scanTimerRunning: false

        signal connectResult(string ssid, bool success, string reason)

        function setWifiRadioEnabled(on): void {
            radioWrites++;
        }
        function scanWifiNetworks(): void {
            scans++;
        }
        function connectToNetwork(ssid, password): void {
            connects++;
            lastConnectSsid = ssid;
            lastConnectPassword = password;
            if (failConnectSync)
                connectResult(ssid, false, "failed");
        }
        function disconnectActive(): void {
            disconnects++;
        }
        function forgetNetwork(ssid): void {
            forgets++;
            lastForgotten = ssid;
        }
        function setWifiListVisible(visible): void {
            listVisibilityCalls++;
            listVisibleArg = visible;
            if (!visible) {
                scanTimerRunning = false;
                return;
            }
            if (denyOnVisible)
                needsLocationPermission = true;
            scanTimerRunning = true;
        }
        function openWifiSettings(): void {
            wifiSettingsCalls++;
        }
        function openLocationSettings(): void {
            locationSettingsCalls++;
        }
    }

    readonly property NetworkService service: NetworkService {}
    readonly property FakeBackend fixture: FakeBackend {}
    readonly property FakeModel model: FakeModel {}

    readonly property FakeNetwork openNetwork: FakeNetwork {
        ssid: "OpenNet"
        bssid: "AA:BB:CC:DD:EE:01"
        strength: 72
        frequency: 2412
        security: ""
    }
    readonly property FakeNetwork secureNoProfile: FakeNetwork {
        ssid: "GuestSecure"
        bssid: "AA:BB:CC:DD:EE:02"
        strength: 44
        frequency: 5180
        security: "WPA2"
    }
    readonly property FakeNetwork secureProfile: FakeNetwork {
        ssid: "SavedNet"
        bssid: "AA:BB:CC:DD:EE:03"
        strength: 88
        frequency: 5745
        security: "WPA3"
        hasProfile: true
    }

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function expectStatus(expected, message): void {
        check(service.status === expected,
            message + ": status " + service.status + " != " + expected + " (" + service.reason + ")");
    }

    function expectResult(kind, requested, verified, success, message): void {
        check(service.resultKind === kind, message + ": kind " + service.resultKind + " != " + kind);
        check(service.resultRequested === requested, message + ": requested flag");
        check(service.resultVerified === verified, message + ": verified flag");
        if (success === null)
            check(service.lastResult.success === null, message + ": success should be unknown");
        else
            check(service.lastResult.success === success, message + ": success " + service.lastResult.success + " != " + success);
        check(service.resultText.length > 0, message + ": empty result text");
    }

    function makeAvailable(): void {
        fixture.initialized = true;
        fixture.wifiAdapterPresent = true;
        fixture.wifiRadioOn = true;
        fixture.wifiStatus = "disconnected";
    }

    function resetCommandCounters(): void {
        fixture.radioWrites = 0;
        fixture.scans = 0;
        fixture.connects = 0;
        fixture.lastConnectSsid = "";
        fixture.lastConnectPassword = "<unset>";
        fixture.disconnects = 0;
        fixture.forgets = 0;
        fixture.lastForgotten = "";
        fixture.wifiSettingsCalls = 0;
        fixture.locationSettingsCalls = 0;
    }

    function run(): void {
        // --- Safe construction -------------------------------------------------
        check(service.enabled === false && service.controlsEnabled === false
            && service.backend === null && service.backendError === "",
            "safe construction defaults");
        expectStatus("disabled", "explicit disabled state");
        check(service.reason.length > 0, "disabled reason");
        check(!service.nativeInitialized && !service.adapterPresent && !service.radioOn
            && !service.locationDenied, "disabled has no native observation");
        check(service.activeSsid === "" && service.connectingSsid === ""
            && service.wifiStatus === "" && !service.scanning && !service.connecting,
            "disabled has no connection state");
        check(service.networkCount === 0 && service.networkSources.length === 0
            && service.activeSource === null, "disabled has no networks");
        check(!service.ethernetConnected && service.ethernetDeviceCount === 0
            && service.activeEthernetSource === null, "disabled has no ethernet device");
        check(service.listVisible === false && service.listHidden === false
            && !service.listAvailable, "disabled list state");
        check(service.lastResult === null && service.resultText === ""
            && service.resultSequence === 0 && service.commandsSent === 0
            && service.scansRequested === 0 && service.pendingSsid === "",
            "disabled has no command state");
        check(!service.ethernetControlSupported && !service.ethernetConfigSupported,
            "ethernet control and configuration are unsupported");

        // The state object may not expose a password path or the nmcli process
        // graph. It only requests actions through the bounded helpers.
        for (const name of ["requestRadio", "requestConnect", "requestDisconnect",
            "requestForget", "requestScan", "setListVisible", "requestWifiSettings",
            "requestLocationSettings", "reportEthernetUnavailable", "findNetwork",
            "hasSavedProfile", "isKnownSource", "connectReasonText"]) {
            check(typeof service[name] === "function", "missing bounded helper " + name);
        }
        for (const name of ["connectToNetwork", "connectWithPassword", "connectEthernet",
            "disconnectEthernet", "connectToNetworkWithPasswordCheck", "enableWifi",
            "rescanWifi", "disconnectFromNetwork", "forgetNetwork", "executeCommand",
            "getDeviceStatus"]) {
            check(service[name] === undefined, "adapter exposes process/credential member " + name);
        }

        // --- Disabled refusals never touch a backend ---------------------------
        service.requestRadio(true);
        expectResult("refused", false, true, false, "disabled radio refusal");
        check(service.commandsSent === 0, "disabled radio sent a command");
        service.requestConnect(openNetwork);
        expectResult("refused", false, true, false, "disabled connect refusal");
        service.requestDisconnect();
        expectResult("refused", false, true, false, "disabled disconnect refusal");
        service.requestForget("SavedNet");
        expectResult("refused", false, true, false, "disabled forget refusal");
        service.requestScan();
        expectResult("refused", false, true, false, "disabled scan refusal");
        check(service.resultText.length > 0, "disabled refusal names the state");
        check(service.commandsSent === 0 && service.scansRequested === 0,
            "disabled requests sent a command");

        // --- Enabled without a backend ----------------------------------------
        service.enabled = true;
        expectStatus("initializing", "backend loading state");
        check(service.reason.length > 0, "initializing reason names the wait");
        check(service.listHidden, "initializing hides the list");
        service.controlsEnabled = true;
        service.requestRadio(true);
        expectResult("refused", false, true, false, "initializing radio refusal");
        check(service.commandsSent === 0, "initializing request sent a command");
        service.controlsEnabled = false;

        // A known component failure is an explicit unavailable state.
        service.backendError = "Fixture component initialization failed";
        expectStatus("unavailable", "known component failure");
        check(service.reason === service.backendError, "component failure is reported verbatim");
        check(service.listHidden && service.networkCount === 0, "failed component hides the list");
        service.requestScan();
        expectResult("refused", false, true, false, "unavailable scan refusal");
        service.backendError = "";

        // --- Present but not initialized --------------------------------------
        service.backend = fixture;
        fixture.networks = model;
        model.values = [openNetwork, secureProfile];
        expectStatus("initializing", "uninitialized backend is initializing");
        check(service.networkCount === 0, "uninitialized backend hides retained networks");
        fixture.wifiAdapterPresent = true;
        fixture.wifiRadioOn = true;
        expectStatus("initializing", "adapter state without the lifecycle flag stays initializing");

        // --- No adapter --------------------------------------------------------
        fixture.initialized = true;
        fixture.wifiAdapterPresent = false;
        fixture.wifiRadioOn = false;
        expectStatus("no-adapter", "initialized without an adapter");
        check(service.reason.length > 0, "no-adapter reason");
        check(service.listHidden && service.networkCount === 0, "no-adapter hides the list");
        check(service.activeSsid === "", "no-adapter has no active SSID");
        service.controlsEnabled = true;
        resetCommandCounters();
        service.requestRadio(true);
        expectResult("refused", false, true, false, "no-adapter radio refusal");
        check(fixture.radioWrites === 0, "no-adapter radio reached the backend");
        service.controlsEnabled = false;

        // --- Initialization/subscription error --------------------------------
        // A refused subscription is an error even when the driver still lists
        // an adapter; it must never look like a ready or no-adapter state.
        fixture.wifiAdapterPresent = true;
        fixture.nativeError = "Windows refused WLAN notifications (error 5).";
        expectStatus("unavailable", "native initialization error is unavailable");
        check(service.reason === fixture.nativeError, "native error is reported verbatim");
        check(service.listHidden && service.networkCount === 0, "native error hides the list");
        check(!service.adapterPresent && !service.radioOn,
            "native error clears adapter and radio capabilities");
        resetCommandCounters();
        service.controlsEnabled = true;
        service.requestRadio(true);
        expectResult("refused", false, true, false, "native error radio refusal");
        check(fixture.radioWrites === 0, "native error radio reached the backend");
        service.controlsEnabled = false;
        fixture.nativeError = "";
        fixture.wifiAdapterPresent = false;
        expectStatus("no-adapter", "clearing the native error restores no-adapter");

        // --- Radio off ---------------------------------------------------------
        fixture.wifiAdapterPresent = true;
        fixture.wifiRadioOn = false;
        fixture.wifiStatus = "disabled";
        expectStatus("radio-off", "adapter present with the radio off");
        check(service.reason.length > 0, "radio-off reason");
        check(service.listHidden && service.networkCount === 0, "radio-off hides stale networks");
        fixture.activeSsid = "StaleNet";
        check(service.activeSsid === "", "radio-off hides a retained active SSID");
        fixture.activeSsid = "";

        // --- Disconnected observation -----------------------------------------
        fixture.wifiRadioOn = true;
        fixture.wifiStatus = "disconnected";
        expectStatus("disconnected", "radio on without a connection");
        check(service.reason.length > 0, "disconnected reason");
        check(service.listAvailable && !service.listHidden, "disconnected shows the list");
        model.values = [openNetwork, secureNoProfile, secureProfile, null, {ssid: ""},
            {ssid: 5}, "invalid"];
        check(service.networkCount === 3, "only object entries with a string SSID are projected");
        check(service.networkSources.indexOf(openNetwork) === 0
            && service.networkSources.indexOf(secureProfile) === 2, "model order is preserved");
        check(service.activeSource === null, "no active access point");
        check(service.findNetwork("OpenNet") === openNetwork, "find by SSID");
        check(service.findNetwork("") === null && service.findNetwork(null) === null
            && service.findNetwork(undefined) === null, "invalid SSID does not match");
        check(!service.hasSavedProfile("OpenNet") && service.hasSavedProfile("SavedNet"),
            "saved profile projection");
        check(service.isKnownSource(openNetwork) && !service.isKnownSource({ssid: "OpenNet"})
            && !service.isKnownSource(null) && !service.isKnownSource(undefined),
            "membership guard rejects foreign objects");

        // --- Published snapshots ----------------------------------------------
        // The completed-refresh generation mirrors the native one: a refresh
        // that found the same rows still advances it.
        check(service.backendSnapshot === fixture.wifiSnapshot,
            "the service mirrors the native completed-refresh generation");
        fixture.wifiSnapshot++;
        check(service.backendSnapshot === fixture.wifiSnapshot,
            "an unchanged refresh still advances the mirrored generation");
        check(service.networkSnapshot === fixture.wifiSnapshot,
            "a bare service publishes the generation directly");
        // With a wrapper-rebuilding adapter, the generation is published only
        // after the rebuild, so a consumer reading the list sees its rows.
        let sawRows = -1;
        service.snapshotReconciler = function() {
            sawRows = service.networkCount;
            service.publishSnapshot();
        };
        fixture.wifiSnapshot++;
        check(sawRows === 3, "the reconciler runs before the generation is published");
        check(service.networkSnapshot === fixture.wifiSnapshot,
            "the adapter publishes after it reconciled");
        service.snapshotReconciler = null;
        model.values = [openNetwork, secureNoProfile, secureProfile, null, {ssid: ""},
            {ssid: 5}, "invalid"];

        // --- Location permission denial ---------------------------------------
        fixture.activeSsid = "OpenNet";
        fixture.activeBssid = "AA:BB:CC:DD:EE:01";
        fixture.activeSignalQuality = 64;
        fixture.activeSecurity = "";
        fixture.hasInternet = true;
        expectStatus("connected", "connected observation before denial");
        check(service.activeSsid === "OpenNet", "active SSID observed");
        fixture.needsLocationPermission = true;
        expectStatus("location-denied", "location denial is explicit");
        check(service.reason.length > 0, "location reason");
        check(service.listHidden && service.networkCount === 0
            && service.activeSource === null, "location denial hides the list");
        check(service.activeSsid === "" && service.activeBssid === ""
            && service.activeSignalQuality === 0 && service.activeSecurity === "",
            "location denial does not repeat an unverifiable connection");
        resetCommandCounters();
        service.controlsEnabled = true;
        service.requestConnect(openNetwork);
        expectResult("refused", false, true, false, "location-denied connect refusal");
        check(fixture.connects === 0, "location-denied connect reached the backend");
        service.controlsEnabled = false;
        fixture.needsLocationPermission = false;
        expectStatus("connected", "denial recovery");
        check(service.activeSsid === "OpenNet" && service.networkCount === 3,
            "observation recovers after denial");

        // --- Connected, limited, connecting -----------------------------------
        fixture.activeSignalQuality = 137;
        check(service.activeSignalQuality === 100, "signal quality is clamped");
        fixture.hasInternet = false;
        check(service.limited, "connected without internet is limited");
        check(service.reason.length > 0, "limited reason");
        fixture.hasInternet = true;
        check(!service.limited, "internet clears the limited state");
        fixture.wifiConnecting = true;
        fixture.wifiConnectingSsid = "SavedNet";
        expectStatus("connecting", "connecting state");
        check(service.connecting && service.connectingSsid === "SavedNet", "connecting SSID");
        check(service.reason.length > 0, "connecting state provides a reason");
        service.controlsEnabled = true;
        resetCommandCounters();
        service.requestConnect(openNetwork);
        expectResult("refused", false, true, false, "busy connect refusal");
        check(fixture.connects === 0, "busy connect reached the backend");
        service.controlsEnabled = false;
        fixture.wifiConnecting = false;
        fixture.wifiConnectingSsid = "";
        expectStatus("connected", "connecting settles back to connected");

        // --- Bounded list visibility and scans --------------------------------
        check(service.listVisible === false, "list starts hidden");
        // Scans are radio activity: without the controls opt-in a visible list
        // neither starts the periodic timer nor accepts an explicit scan.
        service.controlsEnabled = false;
        resetCommandCounters();
        const visibilityControlsOff = fixture.listVisibilityCalls;
        service.setListVisible(true);
        check(fixture.listVisibilityCalls === visibilityControlsOff,
            "controls-off visibility started the scan timer");
        service.requestScan();
        expectResult("refused", false, true, false, "controls-off scan refusal");
        check(fixture.scans === 0, "controls-off scan reached the backend");
        service.setListVisible(false);
        service.controlsEnabled = true;
        resetCommandCounters();
        const visibilityBefore = fixture.listVisibilityCalls;
        service.requestScan();
        expectResult("refused", false, true, false, "hidden scan refusal");
        check(service.lastResult.reason === "hidden", "hidden scan reason");
        check(fixture.scans === 0 && fixture.listVisibilityCalls === visibilityBefore,
            "hidden scan reached the backend");
        service.setListVisible(true);
        check(service.listVisible, "list visibility intent recorded");
        check(fixture.listVisibilityCalls === visibilityBefore + 1 && fixture.listVisibleArg === true,
            "visible list asks the backend once");
        service.requestScan();
        expectResult("scan", true, false, null, "visible scan request");
        check(fixture.scans === 1 && service.scansRequested === 1, "visible scan sent one request");
        service.setListVisible(true);
        check(fixture.listVisibilityCalls === visibilityBefore + 1,
            "repeated visibility intent is not forwarded");
        service.setListVisible(false);
        check(fixture.listVisibilityCalls === visibilityBefore + 2 && fixture.listVisibleArg === false,
            "hiding stops the backend scan timer");
        service.requestScan();
        expectResult("refused", false, true, false, "hidden scan refusal after hiding");
        check(fixture.scans === 1, "hidden scan sent no request");

        // Availability changes stop and restart the backend timer while the
        // visibility intent is retained.
        service.setListVisible(true);
        let visibility = visibilityBefore + 3;
        check(fixture.listVisibilityCalls === visibility && fixture.listVisibleArg === true,
            "visibility re-applies when the list is usable");
        fixture.wifiRadioOn = false;
        expectStatus("radio-off", "radio-off while the list is visible");
        check(fixture.listVisibilityCalls === ++visibility && fixture.listVisibleArg === false,
            "radio-off stops the scan timer");
        fixture.wifiRadioOn = true;
        expectStatus("connected", "radio recovery");
        check(fixture.listVisibilityCalls === ++visibility && fixture.listVisibleArg === true,
            "radio recovery restarts the scan timer");
        fixture.needsLocationPermission = true;
        expectStatus("location-denied", "location denial while visible");
        check(fixture.listVisibilityCalls === ++visibility && fixture.listVisibleArg === false,
            "location denial stops the scan timer");
        fixture.needsLocationPermission = false;
        expectStatus("connected", "location recovery while visible");
        check(fixture.listVisibilityCalls === ++visibility && fixture.listVisibleArg === true,
            "location recovery restarts the scan timer");
        service.setListVisible(false);
        check(fixture.listVisibilityCalls === ++visibility && fixture.listVisibleArg === false,
            "visibility intent can be cleared");

        // --- Caller-scoped visibility across windows/sub-pages ----------------
        const ownerA = {};
        const ownerB = {};
        const ownersBase = fixture.listVisibilityCalls;
        service.acquireListVisibility(ownerA);
        check(service.listVisible && service.listVisibilityOwners.length === 1
            && fixture.listVisibilityCalls === ownersBase + 1 && fixture.listVisibleArg === true,
            "first owner starts the visible list");
        service.acquireListVisibility(ownerA);
        check(service.listVisibilityOwners.length === 1
            && fixture.listVisibilityCalls === ownersBase + 1,
            "duplicate acquire is idempotent");
        service.acquireListVisibility(ownerB);
        check(service.listVisibilityOwners.length === 2
            && fixture.listVisibilityCalls === ownersBase + 1,
            "second owner joins the visible list");
        service.releaseListVisibility(ownerA);
        check(service.listVisible && service.listVisibilityOwners.length === 1
            && fixture.listVisibilityCalls === ownersBase + 1,
            "releasing one owner keeps the list visible");
        service.releaseListVisibility(ownerB);
        check(!service.listVisible && service.listVisibilityOwners.length === 0
            && fixture.listVisibilityCalls === ownersBase + 2 && fixture.listVisibleArg === false,
            "last owner release stops the visible list");
        service.releaseListVisibility(ownerB);
        check(fixture.listVisibilityCalls === ownersBase + 2,
            "unknown release is ignored");

        // --- Connect result and credential boundary --------------------------
        model.values = [openNetwork, secureNoProfile, secureProfile];
        resetCommandCounters();
        const commandsBeforeConnect = service.commandsSent;
        fixture.wifiConnecting = false;
        fixture.activeSsid = "";
        service.controlsEnabled = false;
        service.requestConnect(openNetwork);
        expectResult("refused", false, true, false, "controls-off connect refusal");
        check(fixture.connects === 0, "controls-off connect reached the backend");

        service.controlsEnabled = true;
        service.setListVisible(true);
        fixture.wifiRadioOn = false;
        service.requestConnect(openNetwork);
        expectResult("refused", false, true, false, "radio-off connect refusal");
        check(fixture.connects === 0, "radio-off connect reached the backend");
        fixture.wifiRadioOn = true;

        service.requestConnect(openNetwork);
        expectResult("connect", true, false, null, "connect request is not optimistic success");
        check(fixture.connects === 1 && fixture.lastConnectSsid === "OpenNet",
            "connect request reached the backend");
        check(fixture.lastConnectPassword === "", "connect request sends no password");
        check(service.pendingSsid === "OpenNet"
            && service.commandsSent === commandsBeforeConnect + 1,
            "connect request is pending");
        check(service.activeSsid === "", "connect request did not invent a connection");

        // Unrelated and mismatched native results are not this adapter's result.
        const sequenceBeforeExternal = service.resultSequence;
        fixture.connectResult("SomeOtherNet", true, "");
        check(service.resultSequence === sequenceBeforeExternal, "external result is ignored");
        fixture.connectResult("SavedNet", true, "");
        check(service.resultSequence === sequenceBeforeExternal
            && service.pendingSsid === "OpenNet", "mismatched result is ignored");

        fixture.connectResult("OpenNet", true, "");
        expectResult("connect", true, true, true, "connect success result");
        check(service.lastResult.ssid === "OpenNet", "success records the requested SSID");
        check(service.pendingSsid === "", "success clears the pending request");
        check(service.activeSsid === "", "result does not fabricate native connection state");

        service.requestConnect(openNetwork);
        fixture.connectResult("OpenNet", false, "auth");
        expectResult("connect", true, true, false, "connect failure result");
        check(service.lastResult.reason === "auth", "failure keeps the native reason");
        check(fixture.lastConnectSsid === "OpenNet", "failed result belongs to the recorded call");
        service.requestConnect(openNetwork);
        fixture.connectResult("OpenNet", false, "other");
        expectResult("connect", true, true, false, "unspecified failure result");
        check(service.lastResult.reason === "other", "unspecified native reason is preserved");
        service.requestConnect(openNetwork);
        fixture.connectResult("OpenNet", false, "");
        expectResult("connect", true, true, false, "failure result without a native reason");

        // A secure network without a saved profile is not sent with an empty
        // password; the Windows credential prompt stays outside this slice.
        resetCommandCounters();
        service.requestConnect(secureNoProfile);
        expectResult("settings", false, true, false, "credential boundary result");
        check(fixture.connects === 0, "secure network without a profile reached the backend");
        check(fixture.lastConnectSsid === "", "credential boundary records no connect call");
        check(!("password" in service.lastResult), "result object carries no password field");
        check(JSON.stringify(service.lastResult).toLowerCase().indexOf("password") < 0,
            "result text carries no password field");

        // A saved profile or an open network may connect without a credential.
        service.requestConnect(secureProfile);
        check(fixture.connects === 1 && fixture.lastConnectSsid === "SavedNet"
            && fixture.lastConnectPassword === "", "saved profile connects without a password");
        fixture.connectResult("SavedNet", true, "");
        check(service.resultSucceeded, "saved profile success result");

        // --- Active, stale and removed access points -------------------------
        openNetwork.active = true;
        resetCommandCounters();
        service.requestConnect(openNetwork);
        expectResult("refused", false, true, false, "active network refusal");
        check(service.lastResult.reason === "active", "active refusal reason");
        check(fixture.connects === 0, "active connect reached the backend");
        openNetwork.active = false;

        model.values = [openNetwork, secureNoProfile];
        service.requestConnect(secureProfile);
        expectResult("refused", false, true, false, "removed network refusal");
        check(service.lastResult.reason === "stale", "stale refusal reason");
        check(fixture.connects === 0, "removed network connect reached the backend");
        model.values = [openNetwork, secureNoProfile, secureProfile];
        check(service.networkCount === 3, "removed network is gone from the list");

        // --- Disconnect -------------------------------------------------------
        service.controlsEnabled = false;
        service.requestDisconnect();
        expectResult("refused", false, true, false, "controls-off disconnect refusal");
        service.controlsEnabled = true;
        resetCommandCounters();
        const commandsBeforeDisconnect = service.commandsSent;
        fixture.activeSsid = "";
        service.requestDisconnect();
        expectResult("refused", false, true, false, "disconnected disconnect refusal");
        check(service.lastResult.reason === "not-connected", "not-connected reason");
        check(fixture.disconnects === 0, "disconnected disconnect reached the backend");
        fixture.activeSsid = "OpenNet";
        expectStatus("connected", "active connection for disconnect");
        service.requestDisconnect();
        expectResult("disconnect", true, false, null, "disconnect request is unverified");
        check(fixture.disconnects === 1
            && service.commandsSent === commandsBeforeDisconnect + 1,
            "disconnect request reached the backend");
        check(service.resultText.length > 0,
            "disconnect text states the missing confirmation");
        check(service.activeSsid === "OpenNet", "disconnect request did not invent a disconnection");

        // --- Forget -----------------------------------------------------------
        service.controlsEnabled = false;
        service.requestForget("SavedNet");
        expectResult("refused", false, true, false, "controls-off forget refusal");
        service.controlsEnabled = true;
        resetCommandCounters();
        service.requestForget("OpenNet");
        expectResult("refused", false, true, false, "no-profile forget refusal");
        check(service.lastResult.reason === "no-profile", "no-profile forget reason");
        check(fixture.forgets === 0, "no-profile forget reached the backend");
        service.requestForget("");
        check(service.lastResult.reason === "invalid", "empty SSID forget refusal");
        service.requestForget(42);
        check(service.lastResult.reason === "invalid", "non-string SSID forget refusal");
        service.requestForget("SavedNet");
        expectResult("forget", true, false, null, "forget request is unverified");
        check(fixture.forgets === 1 && fixture.lastForgotten === "SavedNet",
            "forget request reached the backend");
        check(service.resultText.length > 0,
            "forget text states the missing confirmation");

        // --- Radio ------------------------------------------------------------
        service.controlsEnabled = false;
        resetCommandCounters();
        const commandsBeforeRadio = service.commandsSent;
        service.requestRadio(true);
        expectResult("refused", false, true, false, "controls-off radio refusal");
        check(fixture.radioWrites === 0, "controls-off radio reached the backend");
        service.controlsEnabled = true;
        service.requestRadio(true);
        expectResult("radio", true, false, null, "radio request is unverified");
        check(fixture.radioWrites === 1
            && service.commandsSent === commandsBeforeRadio + 1,
            "radio request reached the backend");
        check(service.resultText.length > 0,
            "radio text states the missing confirmation");
        service.requestRadio(false);
        check(fixture.radioWrites === 2, "radio-off request reached the backend");

        // --- Ethernet boundary ------------------------------------------------
        fixture.ethernetConnected = false;
        check(service.ethernetDeviceCount === 0 && service.activeEthernetSource === null,
            "no ethernet device without a connected link");
        fixture.ethernetConnected = true;
        check(service.ethernetDeviceCount === 1 && service.ethernetConnected,
            "connected ethernet projects one device");
        const ethernet = service.activeEthernetSource;
        check(ethernet.connected && ethernet.state === "connected" && ethernet.iface === "",
            "ethernet device is truthful about the unknown name");
        check(ethernet.ipAddress === "" && ethernet.gateway === "" && ethernet.speed === ""
            && ethernet.subnet === "" && ethernet.macAddress === ""
            && Array.isArray(ethernet.dns) && ethernet.dns.length === 0,
            "advanced ethernet configuration is unavailable");
        check(!service.ethernetControlSupported && !service.ethernetConfigSupported,
            "ethernet capabilities stay unavailable");
        resetCommandCounters();
        const commandsBeforeEthernet = service.commandsSent;
        service.reportEthernetUnavailable();
        expectResult("unsupported", false, true, false, "ethernet control refusal");
        check(service.commandsSent === commandsBeforeEthernet
            && fixture.connects === 0 && fixture.disconnects === 0,
            "ethernet control sent a command");

        // --- Explicit Windows settings actions --------------------------------
        service.requestWifiSettings();
        expectResult("settings", true, false, null, "wifi settings request");
        check(fixture.wifiSettingsCalls === 1, "wifi settings request reached the backend");
        service.requestLocationSettings();
        check(fixture.locationSettingsCalls === 1, "location settings request reached the backend");
        service.enabled = false;
        fixture.wifiSettingsCalls = 0;
        service.requestWifiSettings();
        check(fixture.wifiSettingsCalls === 0, "disabled settings request reached the backend");
        service.enabled = true;

        // --- Backend shape robustness ----------------------------------------
        service.backend = {};
        expectStatus("initializing", "backend without a lifecycle flag");
        service.backend = {initialized: 1};
        expectStatus("initializing", "non-boolean lifecycle flag is not trusted");
        service.backend = {initialized: true, wifiAdapterPresent: false, wifiRadioOn: false};
        expectStatus("no-adapter", "backend without a native error reports no adapter");
        service.backend = {initialized: true, wifiAdapterPresent: false, nativeError: 42};
        expectStatus("no-adapter", "non-string native error is ignored");
        service.backend = {initialized: true, wifiAdapterPresent: true, wifiRadioOn: true,
            wifiStatus: "disconnected", networks: {values: null}};
        expectStatus("disconnected", "ready backend without a model");
        check(service.networkCount === 0, "missing model values are empty");
        service.backend = {initialized: true, wifiAdapterPresent: true, wifiRadioOn: true,
            wifiStatus: "disconnected", networks: {values: "not-an-array"}};
        check(service.networkCount === 0, "non-array model values are rejected");
        service.backend = {initialized: true, wifiAdapterPresent: true, wifiRadioOn: true,
            wifiStatus: 42, activeSsid: 42, activeSignalQuality: "x",
            networks: {values: [openNetwork]}};
        expectStatus("disconnected", "non-string native state is not trusted");
        check(service.activeSsid === "" && service.activeSignalQuality === 0
            && service.wifiStatus === "", "non-string native state is ignored");
        check(service.networkCount === 1, "valid entries survive a malformed backend");

        // --- Synchronous native callbacks -------------------------------------
        service.backend = fixture;
        makeAvailable();
        model.values = [openNetwork, secureProfile];
        fixture.activeSsid = "";
        fixture.needsLocationPermission = false;
        service.controlsEnabled = true;
        service.setListVisible(false);
        fixture.denyOnVisible = true;
        service.setListVisible(true);
        check(fixture.needsLocationPermission, "fake reported denial during activation");
        check(!fixture.scanTimerRunning && fixture.listVisibleArg === false
            && service.backendListVisible === false,
            "denial during activation leaves the scan timer stopped");
        fixture.denyOnVisible = false;
        fixture.needsLocationPermission = false;
        check(fixture.listVisibleArg === true && service.backendListVisible === true,
            "recovery after synchronous denial restarts the timer");
        service.setListVisible(false);

        resetCommandCounters();
        fixture.failConnectSync = true;
        service.requestConnect(openNetwork);
        check(fixture.connects === 1, "synchronous-failure connect reached the backend once");
        expectResult("connect", true, true, false, "synchronous connect failure stays verified");
        check(service.pendingSsid === "", "synchronous failure clears pending state");
        fixture.failConnectSync = false;

        // --- Disable clears observation and requests --------------------------
        service.backend = fixture;
        makeAvailable();
        model.values = [openNetwork, secureProfile];
        fixture.activeSsid = "OpenNet";
        service.controlsEnabled = true;
        service.setListVisible(true);
        const scansBeforeDisable = service.scansRequested;
        const visibilityBeforeDisable = fixture.listVisibilityCalls;
        service.requestScan();
        check(service.listVisible && service.scansRequested === scansBeforeDisable + 1,
            "prepared visible list");
        resetCommandCounters();
        service.enabled = false;
        expectStatus("disabled", "disable returns to disabled");
        check(service.listVisible === false && service.pendingSsid === ""
            && service.lastResult === null && service.commandsSent === 0
            && service.scansRequested === 0, "disable clears observation and command state");
        check(fixture.listVisibilityCalls === visibilityBeforeDisable + 1
            && fixture.listVisibleArg === false, "disable stops the backend scan timer");
        check(service.networkCount === 0 && !service.adapterPresent && !service.radioOn
            && service.activeSsid === "", "disable clears native projections");
        service.controlsEnabled = true;
        service.requestRadio(true);
        expectResult("refused", false, true, false, "controls cannot outlive observation");
        check(service.commandsSent === 0 && fixture.radioWrites === 0,
            "post-disable radio reached the backend");

        console.log("CAELESTIA_NETWORK_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_NETWORK_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
