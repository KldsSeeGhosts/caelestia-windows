import QtQuick

// Windows adaptation of the bounded parts of the Quickshell.Bluetooth contract
// consumed by modules/bar/components/status/BluetoothStatus.qml and
// modules/bar/popouts/Bluetooth.qml. This object has no native imports, timers,
// IPC, or process calls. The facade owns the clock and calls tick() with a
// wall-clock millisecond timestamp so every bounded state is deterministic in
// tests and a system suspend gap still counts against the advertised window.
// Backends may be injected.
//
// The pinned backend exposes a default adapter, adapter/device models, radio and
// discovery state, pairing state and pair/connect/disconnect/forget commands.
// It does NOT expose its initial adapter-scan completion to QML: WinBluetooth
// has isScanned()/scanned(hasAdapter) but BluetoothQml publishes only
// defaultAdapter/adapters/devices (bluetooth.hpp lines 32, 67-77;
// bluetooth.cpp lines 37-41, 119-126). A null default adapter therefore cannot
// be distinguished from a still-initializing worker. This adapter reports
// "initializing" until a bounded first-observation window expires; the timeout
// is an observation bound, not proof that Windows completed a hardware scan.
//
// Construction and every observed state change make no writes. Radio, discovery,
// pairing and connection requests exist only behind controlsEnabled, an explicit
// caller action, a present adapter and a settled radio. The only automatic
// operations are bounded stops: discovery is turned off and a shell-requested
// pairing is cancelled after their windows expire. Nothing is ever auto-enabled.
QtObject {
    id: root

    // The injected backend is the NativeBluetoothBackend facade (or a test fake)
    // exposing: adapter (BluetoothAdapter-like or null), adapters and devices
    // (models with .values).
    property var backend: null
    property bool enabled: false
    property bool controlsEnabled: false

    // A loader can supply a known component failure. Native initialization
    // failures are logged by the backend worker and are not exposed here.
    property string backendError: ""

    // Bounded observation windows. The facade timer ticks every 500 ms while
    // clockActive is true; tests drive tick() directly.
    property int initializationTimeoutMs: 8000
    property int discoveryTimeoutMs: 30000
    property int settlingTimeoutMs: 20000

    // BluetoothAdapterState numeric values from Quickshell.Bluetooth.
    readonly property int stateDisabled: 0
    readonly property int stateEnabled: 1
    readonly property int stateEnabling: 2
    readonly property int stateDisabling: 3
    readonly property int stateBlocked: 4

    // BluetoothDeviceState numeric values from Quickshell.Bluetooth.
    readonly property int deviceDisconnected: 0
    readonly property int deviceConnected: 1
    readonly property int deviceDisconnecting: 2
    readonly property int deviceConnecting: 3

    // The Windows Settings page is the only supported place to complete a PIN
    // or passkey pairing. This object never opens it; a host must do so from an
    // explicit user action such as the original popout's "Open settings" button.
    readonly property string settingsUri: "ms-settings:bluetooth"

    // Unsupported controls at the pinned backend. The native setters warn and
    // change nothing (adapter.cpp lines 87-94; device.cpp lines 168-188), so the
    // adapter refuses them rather than pretending a request was applied.
    readonly property bool discoverableSupported: false
    readonly property bool renameSupported: false
    readonly property bool trustedSupported: false
    readonly property bool blockedSupported: false
    readonly property bool wakeSupported: false

    readonly property bool backendReady: enabled && !backendError && !!backend
        && backend.ready === true
    readonly property var adapter: backendReady ? (backend?.adapter ?? null) : null
    readonly property bool hasAdapter: adapter !== null

    // The native model can retain objects after an adapter disappears; hide the
    // whole list unless the adapter is present, so a removed adapter cannot
    // leave a stale device UI behind.
    readonly property var devices: {
        if (!backendReady || !hasAdapter)
            return [];

        const values = backend?.devices?.values;
        if (!values)
            return [];
        return values.filter(device => device && typeof device === "object");
    }
    readonly property int deviceCount: devices.length

    readonly property string adapterName: {
        const value = adapter?.name;
        return typeof value === "string" ? value : "";
    }
    readonly property int adapterState: {
        const value = adapter?.state;
        return Number.isInteger(value) && value >= stateDisabled && value <= stateBlocked
            ? value : -1;
    }
    readonly property bool radioEnabled: hasAdapter && adapter?.enabled === true
    readonly property bool radioBlocked: adapterState === stateBlocked
    readonly property bool radioPending: adapterState === stateEnabling
        || adapterState === stateDisabling
    readonly property bool radioOff: adapterState === stateDisabled && !radioEnabled
    readonly property bool radioUnknown: hasAdapter && adapterState === -1

    readonly property bool discovering: hasAdapter && adapter?.discovering === true

    // Discovery is caller-scoped for the same reason network scans are: two
    // Nexus windows (or a page and its pairing sub-page) can be discovering at
    // once, and closing one must not stop the other. The owning page registers
    // itself; the last release stops the adapter.
    property var discoveryOwners: []

    // Clock bookkeeping. tick() is the only writer; a map is reassigned instead
    // of mutated so QML bindings observe the change.
    property double clockMs: 0
    property double _adapterWaitStartedAt: 0
    property bool _initializationTimedOut: false
    property double _discoveryStartedAt: 0
    property bool discoveryTimedOut: false
    property var _pendingStartedAt: ({})
    property var _timedOutPending: ({})
    property var _timedOutPairing: ({})

    // True only while a bounded wait or an operation needs the 500 ms facade
    // timer. An idle adapter, a settled radio and an empty device list do not
    // tick. The bookkeeping maps keep the clock alive for one final tick so a
    // completed wait cannot leave a stale start/deadline behind.
    readonly property bool clockActive: {
        if (!enabled)
            return false;
        if (!backendReady) {
            // Take one final tick to clear waits that belonged to the previous
            // backend instance.
            return _adapterWaitStartedAt !== 0 || _initializationTimedOut
                || _discoveryStartedAt !== 0 || discoveryTimedOut
                || Object.keys(_pendingStartedAt).length > 0
                || Object.keys(_timedOutPending).length > 0;
        }

        // Waiting for the first adapter observation.
        if (!hasAdapter && !_initializationTimedOut)
            return true;

        // An adapter appeared; take one final tick to clear the wait.
        if (hasAdapter && (_adapterWaitStartedAt !== 0 || _initializationTimedOut))
            return true;

        // Caller-requested discovery has a bounded stop.
        if (discovering && controlsEnabled && status === "on" && !discoveryTimedOut)
            return true;

        // Discovery stopped; take one final tick to clear its bound.
        if (!discovering && (_discoveryStartedAt !== 0 || discoveryTimedOut))
            return true;

        // Pairing/connect/disconnect deadlines.
        if (devices.some(device => isPending(device) && !isSettlingTimedOut(device)))
            return true;

        return Object.keys(_pendingStartedAt).length > 0
            || Object.keys(_timedOutPending).length > 0;
    }

    readonly property bool initializationExpired: _initializationTimedOut
    readonly property bool initialized: backendReady && hasAdapter

    // Explicit service states. "no-adapter" means the bounded first-observation
    // window expired without an adapter; the backend cannot confirm a completed
    // scan. "blocked" and "off" are distinct radio states.
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "error";
        if (!backend)
            return "initializing";
        if (!backendReady)
            return "initializing";
        if (!hasAdapter)
            return initializationExpired ? "no-adapter" : "initializing";
        if (radioBlocked)
            return "blocked";
        if (radioPending)
            return "radio-pending";
        if (radioEnabled)
            return "on";
        if (radioOff)
            return "off";
        return "unknown-radio";
    }
    readonly property bool ready: status === "on" || status === "off"
        || status === "blocked"
    readonly property bool noAdapter: status === "no-adapter"

    readonly property bool pairing: devices.some(device => device.pairing === true)
    readonly property bool pairingNeedsWindowsSettings: pairing
        || Object.keys(_timedOutPairing).length > 0

    readonly property var pendingDevices: devices.filter(device => isPending(device)
        && !isSettlingTimedOut(device))
    readonly property int pendingCount: pendingDevices.length
    readonly property bool hasPending: pendingCount > 0
    readonly property int connectedCount: devices.filter(device => device.connected === true).length

    // Address-keyed map for the original popout's bounded settling hook. Only
    // devices whose native Connecting/Disconnecting/pairing state outlived the
    // window appear here; the request itself is not re-sent.
    readonly property var timedOutDevices: _timedOutPending

    readonly property string reason: {
        if (!enabled)
            return "Windows Bluetooth is disabled.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows Bluetooth backend.";
        if (status === "initializing")
            return "Waiting for the first Bluetooth adapter observation.";
        if (status === "no-adapter")
            return "No Bluetooth adapter was observed within the bounded startup window. Windows may still have no adapter; this shell cannot confirm a completed hardware scan.";
        if (status === "blocked")
            return "The Bluetooth radio is blocked by a hardware switch or policy. Enable it in Windows Settings.";
        if (status === "off")
            return "The Bluetooth radio is off. Turn it on explicitly to observe devices.";
        if (status === "radio-pending")
            return "The Bluetooth radio is changing state.";
        if (status === "unknown-radio")
            return "Windows reported an unknown Bluetooth radio state.";
        return "Bluetooth is on: " + deviceCount + " device(s) observed, "
            + connectedCount + " connected."
            + (controlsEnabled
            ? " Radio, discovery, pairing and forget requests are available for explicit actions; Windows may refuse a request and the backend does not report a per-command result."
            : " This run only observes Bluetooth; every control stays disabled.")
            + (pairingNeedsWindowsSettings
            ? " If Windows asks for a PIN or passkey, complete pairing in Windows Settings."
            : "");
    }

    readonly property bool canToggleRadio: controlsEnabled && !backendError
        && (status === "on" || status === "off")
    readonly property bool canSetDiscovering: controlsEnabled && status === "on"
    readonly property bool canControlDevices: controlsEnabled && status === "on"

    // Bounded timeout accounting. Call from the facade timer (or directly in a
    // fixture) with a wall-clock millisecond timestamp. Timestamps, not tick
    // counts, are stored, so a suspend/resume gap is measured too.
    function tick(ms: double): void {
        if (!Number.isFinite(ms))
            return;

        clockMs = ms;
        if (!backendReady) {
            _adapterWaitStartedAt = 0;
            _initializationTimedOut = false;
            _discoveryStartedAt = 0;
            discoveryTimedOut = false;
            _pendingStartedAt = ({});
            _timedOutPending = ({});
            _timedOutPairing = ({});
            return;
        }

        if (!hasAdapter) {
            if (_adapterWaitStartedAt === 0)
                _adapterWaitStartedAt = ms;
            if (!_initializationTimedOut
                    && ms - _adapterWaitStartedAt >= initializationTimeoutMs) {
                _initializationTimedOut = true;
            }
        } else {
            _adapterWaitStartedAt = 0;
            _initializationTimedOut = false;
        }

        tickDiscovery(ms);
        tickPending(ms);
    }

    function tickDiscovery(ms: double): void {
        if (discovering) {
            if (_discoveryStartedAt === 0)
                _discoveryStartedAt = ms;
            if (!discoveryTimedOut && controlsEnabled && status === "on"
                    && ms - _discoveryStartedAt >= discoveryTimeoutMs) {
                discoveryTimedOut = true;
                // Bounded stop only: discovery is never started automatically,
                // and a read-only observer never writes.
                if (adapter && adapter.discovering === true)
                    adapter.discovering = false;
            }
        } else {
            _discoveryStartedAt = 0;
            discoveryTimedOut = false;
        }
    }

    function tickPending(ms: double): void {
        const started = ({});
        const timedOut = ({});
        const timedOutPairing = ({});

        for (const device of devices) {
            const key = deviceKey(device);
            if (!key)
                continue;

            const pairing = device.pairing === true;
            const connecting = device.state === deviceConnecting
                || device.state === deviceDisconnecting;
            if (!pairing && !connecting)
                continue;

            const previous = _pendingStartedAt[key];
            const since = (typeof previous === "number" && previous > 0) ? previous : ms;
            started[key] = since;

            const wasTimedOut = _timedOutPending[key] === true;
            const expired = wasTimedOut || ms - since >= settlingTimeoutMs;
            if (!expired)
                continue;

            timedOut[key] = true;
            if (pairing)
                timedOutPairing[key] = true;

            // A pairing operation has no native timeout. Cancel only a request
            // this process observed while controls were enabled; a read-only
            // observer never mutates native state.
            if (!wasTimedOut && pairing && controlsEnabled
                    && typeof device.cancelPair === "function") {
                device.cancelPair();
            }
        }

        _pendingStartedAt = started;
        _timedOutPending = timedOut;
        _timedOutPairing = timedOutPairing;
    }

    function deviceKey(device): string {
        if (!device)
            return "";
        const address = typeof device.address === "string" ? device.address : "";
        if (address.length > 0)
            return address;
        const path = typeof device.path === "string" ? device.path : "";
        return path;
    }

    function isListed(device): bool {
        return !!device && devices.indexOf(device) >= 0;
    }

    function isPending(device): bool {
        if (!device)
            return false;
        return device.pairing === true || device.state === deviceConnecting
            || device.state === deviceDisconnecting;
    }

    function isSettlingTimedOut(device): bool {
        const key = deviceKey(device);
        return key !== "" && _timedOutPending[key] === true;
    }

    // Explicit controls. Each returns whether a request was permitted; it never
    // claims Windows applied it. A false return sent nothing.
    function setRadioEnabled(on): bool {
        if (!canToggleRadio || typeof on !== "boolean")
            return false;
        if (on && radioBlocked)
            return false;
        if (adapter?.enabled === on)
            return true;
        adapter.enabled = on;
        return true;
    }

    function setDiscovering(on): bool {
        if (!canSetDiscovering || typeof on !== "boolean")
            return false;
        if (adapter.discovering === on)
            return true;
        if (on) {
            _discoveryStartedAt = 0;
            discoveryTimedOut = false;
        }
        adapter.discovering = on;
        return true;
    }

    function startDiscovery(): bool {
        return setDiscovering(true);
    }

    function stopDiscovery(): bool {
        return setDiscovering(false);
    }

    function acquireDiscovery(owner): bool {
        if (!owner)
            return false;
        if (root.discoveryOwners.indexOf(owner) < 0)
            root.discoveryOwners = [...root.discoveryOwners, owner];
        return root.setDiscovering(true);
    }

    function releaseDiscovery(owner): bool {
        if (!owner)
            return false;
        const next = root.discoveryOwners.filter(item => item !== owner);
        if (next.length === root.discoveryOwners.length)
            return false;
        root.discoveryOwners = next;
        if (next.length > 0)
            return true;
        return root.setDiscovering(false);
    }

    // A page can acquire while the radio is still settling; start once the
    // adapter is allowed to discover and an owner is still interested.
    onCanSetDiscoveringChanged: {
        if (root.canSetDiscovering && root.discoveryOwners.length > 0)
            root.setDiscovering(true);
    }

    onEnabledChanged: {
        if (!root.enabled)
            root.discoveryOwners = [];
    }

    function canConnect(device): bool {
        return canControlDevices && isListed(device)
            && !isSettlingTimedOut(device)
            && device.connected !== true && device.pairing !== true;
    }

    function canDisconnect(device): bool {
        return canControlDevices && isListed(device)
            && !isSettlingTimedOut(device)
            && device.connected === true && device.pairing !== true;
    }

    function canPair(device): bool {
        return canControlDevices && isListed(device)
            && !isSettlingTimedOut(device)
            && device.paired !== true && device.pairing !== true;
    }

    function canForget(device): bool {
        return canControlDevices && isListed(device)
            && !isSettlingTimedOut(device) && device.pairing !== true
            && (device.bonded === true || device.paired === true);
    }

    function connectDevice(device): bool {
        if (!canConnect(device))
            return false;
        device.connected = true;
        return true;
    }

    function disconnectDevice(device): bool {
        if (!canDisconnect(device))
            return false;
        device.connected = false;
        return true;
    }

    function pairDevice(device): bool {
        if (!canPair(device))
            return false;
        device.pair();
        return true;
    }

    function forgetDevice(device): bool {
        if (!canForget(device))
            return false;
        device.forget();
        return true;
    }

    function cancelPairing(device): bool {
        if (!controlsEnabled || !isListed(device) || device.pairing !== true)
            return false;
        device.cancelPair();
        return true;
    }

    // Unsupported controls always refuse and never touch the native object.
    function setDiscoverable(discoverable): bool {
        return false;
    }

    function renameDevice(device, name): bool {
        return false;
    }

    function setTrusted(device, trusted): bool {
        return false;
    }

    function setBlocked(device, blocked): bool {
        return false;
    }

    function setWakeAllowed(device, allowed): bool {
        return false;
    }
}
