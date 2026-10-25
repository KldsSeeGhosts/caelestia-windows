pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture. Imports no Quickshell/native Bluetooth/configuration
// module, reads no environment or hardware, and never constructs Bluetooth.qml.
// Intended runner: powershell -NoProfile -File windows/scripts/Test-BluetoothService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and
// BluetoothService.qml. All bounded waits are driven by explicit tick() calls,
// so the fixture never sleeps or depends on wall time.
QtObject {
    id: test

    component FakeAdapter: QtObject {
        id: adapter

        property string name: "Test Adapter"
        property bool enabled: false
        property int state: 0
        property bool discovering: false
        property int radioRequests: 0
        property int discoveryRequests: 0

        onEnabledChanged: {
            radioRequests++;
            state = enabled ? 2 : 3;
        }
        onDiscoveringChanged: discoveryRequests++;
    }

    component FakeDevice: QtObject {
        property string address: "AA:BB:CC:DD:EE:01"
        property string path: "device-1"
        property string name: "Headset"
        property string icon: "audio-headset"
        property int state: 0
        property bool connected: false
        property bool paired: false
        property bool bonded: false
        property bool pairing: false
        property bool batteryAvailable: false
        property real battery: 0
        property int connectWrites: 0
        property int disconnectWrites: 0
        property int pairCalls: 0
        property int cancelCalls: 0
        property int forgetCalls: 0

        onConnectedChanged: {
            if (connected)
                connectWrites++;
            else
                disconnectWrites++;
        }

        function pair(): void {
            pairCalls++;
            pairing = true;
        }

        function cancelPair(): void {
            cancelCalls++;
            pairing = false;
        }

        function forget(): void {
            forgetCalls++;
            bonded = false;
            paired = false;
        }
    }

    component FakeModel: QtObject {
        property var values: []
    }

    component FakeBackend: QtObject {
        property bool ready: true
        property var adapter: null
        property var devices: null
        property var adapters: null
    }

    readonly property BluetoothService service: BluetoothService {}
    readonly property FakeAdapter adapter: FakeAdapter {}
    readonly property FakeDevice device1: FakeDevice {}
    readonly property FakeDevice device2: FakeDevice {
        address: "AA:BB:CC:DD:EE:02"
        path: "device-2"
        name: "Mouse"
        icon: "input-mouse"
    }
    readonly property FakeModel model: FakeModel {}
    readonly property FakeBackend backend: FakeBackend {
        devices: model
    }

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error("CAELESTIA_BLUETOOTH_FIXTURE_FAIL: " + message);
    }

    function equal(actual, expected, message): void {
        check(actual === expected, message + ": " + actual + " != " + expected);
    }

    function reset(): void {
        service.enabled = false;
        service.controlsEnabled = false;
        service.backendError = "";
        service.backend = null;
        service.tick(0);

        backend.adapter = null;
        model.values = [];

        adapter.enabled = false;
        adapter.state = 0;
        adapter.discovering = false;

        for (const device of [device1, device2]) {
            device.state = 0;
            device.connected = false;
            device.paired = false;
            device.bonded = false;
            device.pairing = false;
            device.batteryAvailable = false;
            device.battery = 0;
            // Change handlers above count fixture setup; each scenario compares
            // deltas from a clean baseline.
            device.connectWrites = 0;
            device.disconnectWrites = 0;
            device.pairCalls = 0;
            device.cancelCalls = 0;
            device.forgetCalls = 0;
        }
        adapter.radioRequests = 0;
        adapter.discoveryRequests = 0;
    }

    function activate(controls): void {
        service.backend = backend;
        service.enabled = true;
        service.controlsEnabled = controls;
    }

    function radioOn(): void {
        adapter.enabled = true;
        adapter.state = 1;
        adapter.discovering = false;
        activate(true);
        service.tick(0);
    }

    function testDisabled(): void {
        reset();
        equal(service.status, "disabled", "disabled status");
        equal(service.reason, "Windows Bluetooth is disabled.", "disabled reason");
        check(!service.backendReady, "disabled backend readiness");
        equal(service.adapter, null, "disabled adapter");
        equal(service.devices.length, 0, "disabled devices");
        check(!service.canToggleRadio, "disabled radio control");
        check(!service.canSetDiscovering, "disabled discovery control");
        check(!service.canControlDevices, "disabled device control");
        check(!service.setRadioEnabled(false), "disabled refuses radio");
        check(!service.setDiscovering(true), "disabled refuses discovery");
        check(!service.setDiscoverable(true), "disabled refuses discoverable");
        check(!service.renameDevice(null, "x"), "disabled refuses rename");
        check(!service.setTrusted(null, true), "disabled refuses trusted");
        check(!service.setBlocked(null, true), "disabled refuses blocked");
        check(!service.setWakeAllowed(null, true), "disabled refuses wake");
        check(!service.discoverableSupported, "discoverable unsupported flag");
        check(!service.renameSupported, "rename unsupported flag");
        check(!service.trustedSupported, "trusted unsupported flag");
        check(!service.blockedSupported, "blocked unsupported flag");
        check(!service.wakeSupported, "wake unsupported flag");
        equal(service.settingsUri, "ms-settings:bluetooth", "settings target");
        equal(adapter.radioRequests, 0, "disabled made no radio request");
        equal(adapter.discoveryRequests, 0, "disabled made no discovery request");
    }

    function testInitializingAndNullAdapter(): void {
        reset();
        backend.adapter = null;
        backend.ready = false;
        activate(false);
        service.tick(500);
        equal(service.status, "initializing", "unready backend is initializing");
        check(!service.backendReady, "unready backend is not ready");
        check(!service.setRadioEnabled(true), "unready backend refuses radio");
        backend.ready = true;
        service.tick(1000);
        equal(service.status, "initializing", "initializing status");
        check(!service.hasAdapter, "initializing has no adapter");
        check(!service.initializationExpired, "initializing bound not expired");
        equal(service.devices.length, 0, "initializing hides devices");
        equal(service.reason, "Waiting for the first Bluetooth adapter observation.",
            "initializing reason");
        check(!service.canToggleRadio, "initializing refuses radio");
        check(!service.setRadioEnabled(true), "initializing radio request refused");

        service.tick(8999);
        equal(service.status, "initializing", "initializing before timeout");
        check(!service.initializationExpired, "bound not expired before timeout");

        service.tick(9000);
        equal(service.status, "no-adapter", "null adapter after bound");
        check(service.initializationExpired, "bound expired");
        check(service.noAdapter, "no-adapter flag");
        check(service.reason.indexOf("No Bluetooth adapter was observed") >= 0,
            "no-adapter reason");
        check(!service.canToggleRadio, "no-adapter refuses radio");
        equal(service.radioEnabled, false, "no-adapter radio");
        equal(service.devices.length, 0, "no-adapter devices");

        // An adapter appearing later leaves the null observation state and
        // clears the timeout. Devices become observable only with the adapter.
        backend.adapter = adapter;
        model.values = [device1];
        service.tick(11000);
        equal(service.status, "off", "adapter appearance settles radio off");
        check(service.hasAdapter, "adapter observed");
        check(!service.initializationExpired, "adapter clears initialization bound");
        equal(service.adapterName, "Test Adapter", "adapter name");
        equal(service.devices.length, 1, "adapter exposes devices");
        equal(service.deviceCount, 1, "device count");

        // Adapter removal hides a retained device model immediately; a later
        // timeout reports null adapter rather than a healthy empty list.
        backend.adapter = null;
        equal(service.devices.length, 0, "removed adapter hides stale devices");
        check(!service.hasAdapter, "removed adapter");
        service.tick(12000);
        equal(service.status, "initializing", "re-observation after removal");
        service.tick(20000);
        equal(service.status, "no-adapter", "removed adapter settles null");
    }

    function testRadioStates(): void {
        reset();
        backend.adapter = adapter;
        activate(false);
        service.tick(1000);
        equal(service.status, "off", "off status");
        check(service.radioOff, "radio off flag");
        check(!service.radioEnabled, "radio off not enabled");
        check(!service.canToggleRadio, "read-only refuses radio toggle");

        service.controlsEnabled = true;
        check(service.canToggleRadio, "interactive radio toggle permitted");
        const offWrites = adapter.radioRequests;
        check(service.setRadioEnabled(false), "same-value radio request permitted");
        equal(adapter.radioRequests, offWrites, "same-value radio request is a no-op");

        check(service.setRadioEnabled(true), "radio on request permitted");
        equal(adapter.enabled, true, "radio request reached the adapter");
        equal(adapter.radioRequests, offWrites + 1, "one radio request");
        equal(service.status, "radio-pending", "radio enabling is pending");
        check(service.radioPending, "radio pending flag");
        check(!service.canToggleRadio, "pending radio refuses another toggle");

        adapter.state = 1;
        service.tick(2000);
        equal(service.status, "on", "radio on status");
        check(service.radioEnabled, "radio enabled flag");
        check(service.canToggleRadio, "settled radio toggle permitted");
        check(service.canSetDiscovering, "settled radio permits discovery");

        check(service.setRadioEnabled(false), "radio off request permitted");
        equal(adapter.enabled, false, "radio off reached the adapter");
        equal(service.status, "radio-pending", "radio disabling is pending");
        adapter.state = 0;
        service.tick(3000);
        equal(service.status, "off", "radio settles off");

        adapter.enabled = false;
        adapter.state = 4;
        service.tick(4000);
        equal(service.status, "blocked", "blocked radio status");
        check(service.radioBlocked, "blocked radio flag");
        check(!service.canToggleRadio, "blocked radio refuses toggle");
        const blockedWrites = adapter.radioRequests;
        check(!service.setRadioEnabled(true), "blocked radio refuses enable");
        equal(adapter.radioRequests, blockedWrites, "blocked radio sent nothing");

        adapter.enabled = false;
        adapter.state = 9;
        service.tick(5000);
        equal(service.status, "unknown-radio", "unknown radio status");
        check(service.radioUnknown, "unknown radio flag");
        check(!service.canToggleRadio, "unknown radio refuses toggle");
        check(!service.setRadioEnabled(true), "unknown radio refuses enable");
        check(!service.setRadioEnabled("yes"), "non-boolean radio request refused");
        check(!service.setDiscovering("yes"), "non-boolean discovery request refused");
    }

    function testDiscoveryBound(): void {
        reset();
        backend.adapter = adapter;
        radioOn();
        const base = adapter.discoveryRequests;
        check(!service.discovering, "discovery starts off");

        service.tick(1000);
        equal(adapter.discoveryRequests, base, "observation never starts discovery");
        check(!service.discoveryTimedOut, "no discovery timeout without discovery");

        check(service.startDiscovery(), "explicit discovery request permitted");
        equal(adapter.discovering, true, "discovery reached the adapter");
        equal(adapter.discoveryRequests, base + 1, "one discovery request");
        check(service.discovering, "service observes discovery");

        service.tick(2000);
        service.tick(31999);
        check(!service.discoveryTimedOut, "discovery not timed out before bound");
        equal(adapter.discovering, true, "discovery still running before bound");

        service.tick(32000);
        check(service.discoveryTimedOut, "discovery timed out at bound");
        check(!service.discovering, "bounded stop reached the adapter");
        equal(adapter.discoveryRequests, base + 2, "bounded stop is one request");

        service.tick(32500);
        check(!service.discoveryTimedOut, "timeout clears after discovery stops");

        // Read-only observation never stops or starts discovery.
        service.controlsEnabled = false;
        adapter.discovering = true;
        const readOnlyBase = adapter.discoveryRequests;
        service.tick(40000);
        service.tick(140000);
        check(!service.discoveryTimedOut, "read-only discovery is not timed out");
        equal(adapter.discoveryRequests, readOnlyBase,
            "read-only observation did not stop discovery");
        check(!service.stopDiscovery(), "read-only refuses discovery stop");
        adapter.discovering = false;
        service.tick(150000);
    }

    function testDevicePendingAndTimeout(): void {
        reset();
        backend.adapter = adapter;
        radioOn();
        model.values = [device1];
        service.tick(1000);

        equal(service.devices.length, 1, "listed device");
        check(service.canConnect(device1), "disconnected device can be connected");
        check(!service.canDisconnect(device1), "disconnected device cannot disconnect");
        check(service.canPair(device1), "unpaired device can be paired");
        check(!service.canForget(device1), "unbonded device cannot be forgotten");

        const connects = device1.connectWrites;
        check(service.connectDevice(device1), "explicit connect permitted");
        equal(device1.connected, true, "connect reached the device");
        equal(device1.connectWrites, connects + 1, "one connect write");

        // Simulate the native Connecting state and its bounded projection.
        device1.state = 3;
        service.tick(2000);
        equal(service.pendingCount, 1, "connecting device is pending");
        check(service.hasPending, "pending flag");
        check(!service.isSettlingTimedOut(device1), "not timed out before bound");
        service.tick(21999);
        check(!service.isSettlingTimedOut(device1), "not timed out at bound - 1");
        const timedOutDisconnects = device1.disconnectWrites;
        service.tick(22000);
        check(service.isSettlingTimedOut(device1), "connecting timed out at bound");
        equal(service.pendingCount, 0, "timed-out device leaves pending projection");
        check(!service.canConnect(device1), "timed-out device refuses connect");
        check(!service.canDisconnect(device1), "timed-out device refuses disconnect");
        check(service.timedOutDevices[device1.address] === true,
            "timed-out address map");
        equal(device1.disconnectWrites, timedOutDisconnects,
            "no synthetic disconnect sent");

        // Native settling clears the projection and the gate.
        device1.state = 0;
        service.tick(22500);
        check(!service.isSettlingTimedOut(device1), "native settle clears timeout");
        check(service.canDisconnect(device1), "connected device can disconnect");
        check(service.disconnectDevice(device1), "explicit disconnect permitted");
        equal(device1.connected, false, "disconnect reached the device");
        equal(device1.disconnectWrites, timedOutDisconnects + 1, "one disconnect write");

        // Pairing has no native timeout; the adapter bounds it and cancels only
        // the operation it observed while controls were enabled.
        device1.paired = false;
        device1.bonded = false;
        device1.pairing = false;
        service.tick(23000);
        check(service.canPair(device1), "unpaired device can be paired again");
        check(service.pairDevice(device1), "explicit pair permitted");
        equal(device1.pairCalls, 1, "pair reached the device");
        check(device1.pairing, "pairing is pending");
        check(!service.canPair(device1), "pairing device refuses another pair");
        check(!service.canConnect(device1), "pairing device refuses connect");

        service.tick(30000);
        check(!service.isSettlingTimedOut(device1), "pairing not timed out early");
        service.tick(49999);
        check(!service.isSettlingTimedOut(device1), "pairing not timed out at bound - 1");
        equal(device1.cancelCalls, 0, "pairing not cancelled early");
        service.tick(50000);
        check(service.isSettlingTimedOut(device1), "pairing timed out at bound");
        equal(device1.cancelCalls, 1, "pairing timeout cancelled the request");
        check(!device1.pairing, "cancel settled pairing locally");
        check(service.pairingNeedsWindowsSettings,
            "timed-out pairing points at Windows Settings");
        check(!service.canPair(device1), "timed-out pairing refuses pair");
        service.tick(50500);
        check(!service.isSettlingTimedOut(device1), "settled pairing clears timeout");
        check(!service.pairingNeedsWindowsSettings,
            "settled pairing clears Settings guidance");

        // A read-only observer never cancels a pairing it did not request.
        service.controlsEnabled = false;
        device1.pairing = true;
        const readOnlyCancels = device1.cancelCalls;
        service.tick(60000);
        service.tick(90000);
        equal(device1.cancelCalls, readOnlyCancels,
            "read-only observation did not cancel pairing");
        check(!service.cancelPairing(device1), "read-only refuses cancel");
        device1.pairing = false;
        service.tick(91000);

        // Forget is an explicit control and is gated by bonded/paired state.
        service.controlsEnabled = true;
        device1.bonded = true;
        device1.paired = true;
        service.tick(92000);
        check(service.canForget(device1), "bonded device can be forgotten");
        check(service.forgetDevice(device1), "explicit forget permitted");
        equal(device1.forgetCalls, 1, "forget reached the device");
        equal(device1.bonded, false, "forget cleared bonded state");
    }

    function testStaleRemovalAndReadOnly(): void {
        reset();
        backend.adapter = adapter;
        radioOn();
        model.values = [device1, device2];
        service.tick(1000);
        equal(service.devices.length, 2, "both devices listed");
        equal(service.connectedCount, 0, "no connected devices");

        model.values = [device2];
        equal(service.devices.length, 1, "removed device leaves the list");
        check(!service.isListed(device1), "removed device is not listed");
        check(!service.canConnect(device1), "removed device refuses connect");
        check(!service.connectDevice(device1), "removed device connect refused");

        model.values = [device1, device2];
        equal(service.devices.length, 2, "re-arrived device is listed");
        check(service.isListed(device1), "re-arrived device is listed by identity");

        service.controlsEnabled = false;
        service.tick(2000);
        check(!service.canConnect(device1), "read-only refuses connect");
        check(!service.canDisconnect(device1), "read-only refuses disconnect");
        check(!service.canPair(device1), "read-only refuses pair");
        check(!service.canForget(device1), "read-only refuses forget");
        check(!service.connectDevice(device1), "read-only connect refused");
        check(!service.disconnectDevice(device1), "read-only disconnect refused");
        check(!service.pairDevice(device1), "read-only pair refused");
        check(!service.forgetDevice(device1), "read-only forget refused");
        equal(device1.connectWrites, 0, "read-only sent no connect");
        equal(device1.pairCalls, 0, "read-only sent no pair");
        equal(device1.forgetCalls, 0, "read-only sent no forget");

        // A disconnected device is observable but not controllable in
        // read-only mode; connection state never grants control by itself.
        service.controlsEnabled = true;
        device1.connected = true;
        service.tick(3000);
        equal(service.connectedCount, 1, "connected device counted");
        check(service.canDisconnect(device1), "connected device can disconnect");
        service.controlsEnabled = false;
        check(!service.canDisconnect(device1), "read-only connection cannot disconnect");
    }

    function testUnsupportedControls(): void {
        reset();
        backend.adapter = adapter;
        radioOn();
        model.values = [device1];
        service.tick(1000);

        const radioWrites = adapter.radioRequests;
        const discoveryWrites = adapter.discoveryRequests;
        check(!service.setDiscoverable(true), "discoverable setter refused");
        check(!service.renameDevice(device1, "Renamed"), "rename refused");
        check(!service.setTrusted(device1, true), "trusted setter refused");
        check(!service.setBlocked(device1, true), "blocked setter refused");
        check(!service.setWakeAllowed(device1, true), "wake setter refused");
        equal(device1.name, "Headset", "rename did not reach the device");
        equal(device1.bonded, false, "trusted did not reach the device");
        equal(device1.pairing, false, "blocked did not reach the device");
        equal(adapter.discoveryRequests, discoveryWrites,
            "unsupported controls sent no discovery request");
        equal(adapter.radioRequests, radioWrites,
            "unsupported controls sent no radio request");

        // Unsupported flags stay false while the adapter is absent, disabled
        // or present; they are a backend property, not a transient state.
        service.enabled = false;
        service.tick(2000);
        check(!service.discoverableSupported, "unsupported flag after disable");
        check(!service.renameSupported, "rename flag after disable");
        check(!service.trustedSupported, "trusted flag after disable");
        check(!service.blockedSupported, "blocked flag after disable");
        check(!service.wakeSupported, "wake flag after disable");
    }

    Component.onCompleted: {
        testDisabled();
        testInitializingAndNullAdapter();
        testRadioStates();
        testDiscoveryBound();
        testDevicePendingAndTimeout();
        testStaleRemovalAndReadOnly();
        testUnsupportedControls();
        reset();
        console.log("CAELESTIA_BLUETOOTH_FIXTURE_PASS " + JSON.stringify({
            assertions: assertions,
            service: "BluetoothService.qml"
        }));
        Qt.quit();
    }
}
