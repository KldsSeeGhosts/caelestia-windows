import QtQuick

// Windows adaptation of the bounded parts of services/Brightness.qml. This
// object imports no Quickshell or native module, creates no timers and runs no
// probe on its own. It is a route-policy state machine over an injected backend
// with the shape of NativeBrightnessBackend.qml:
//
//   query(screenName), probe(screenName), refresh(screenName),
//   setBrightness(screenName, isDdc, value), methodFor(screenName) -> string
//   signals: queried(QString, bool, bool, qreal),
//            brightnessSetFinished(QString, bool),
//            routeChanged(QString, QString),
//            systemBrightnessChanged(QString, qreal)
//
// PINNED BACKEND BEHAVIOUR THIS POLICY RELIES ON (windows/deps/quickshell):
// - query() and probe() share startProbe(). Both drop software gamma dimming
//   that this process applied earlier (brightness.cpp:1209-1221). probe() is
//   not a write-free substitute; it only skips the DDC/CI read. The adapter
//   therefore never probes automatically and only re-queries on an explicit
//   user action after a gamma fallback.
// - setBrightness() forces the DDC route when the route is unresolved
//   (brightness.cpp:1260-1266), so this adapter refuses writes while the route
//   is unknown.
// - A hardware write failure silently retries \\.\LCD and then software gamma,
//   and every terminal path emits brightnessSetFinished(..., true)
//   (brightness.cpp:1386-1413). An adapter cannot prevent that fallback or use
//   the boolean as proof of success; it must compare the route before and after
//   the write and latch a route change as a failure.
QtObject {
    id: root

    // Opt-ins. enabled is CAELESTIA_WINDOWS_BRIGHTNESS (query/observe only),
    // controlsEnabled is CAELESTIA_WINDOWS_BRIGHTNESS_CONTROLS (writes) and
    // softwareEnabled is the separate CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE
    // gamma opt-in. None of them is set by this object.
    property bool enabled: false
    property bool controlsEnabled: false
    property bool softwareEnabled: false

    property var backend: null
    property string backendError: ""
    // Screen-like objects with a string `name`, normally Quickshell.screens.
    property var screens: []

    // Evidence counters. They are informational for hosts and fixtures; no
    // caller may infer success from them.
    property int queryRequests: 0
    property int writeRequests: 0
    property int refusedWrites: 0
    property bool everWrote: false
    // True once a write was forwarded for a software route or the backend
    // changed a hardware route to software during a write.
    property bool gammaTouched: false
    property bool autoObservationDone: false

    readonly property var monitorStates: _states
    readonly property int monitorCount: _states.length

    readonly property bool nativeRequested: backend !== null
    readonly property bool ready: enabled && !backendError && backend !== null
    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError)
            return "unavailable";
        if (!backend)
            return "loading";
        return "observing";
    }
    readonly property string lastError: {
        if (!enabled)
            return "";
        if (backendError)
            return backendError;
        const failed = _states.find(state => state.lastError.length > 0);
        return failed ? failed.lastError : "";
    }
    readonly property string reason: {
        if (!enabled)
            return "Windows brightness is disabled. No native Brightness object, route query or probe is created.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows brightness backend.";
        if (!controlsEnabled)
            return "Windows brightness is observable through read-only route queries. Brightness writes are disabled.";
        if (!softwareEnabled)
            return "Windows brightness controls are enabled for hardware routes only. Software gamma writes need the separate software opt-in.";
        return "Windows brightness controls are enabled, including software gamma for monitors without a hardware route.";
    }

    // Internal per-screen policy record. Values are reactive so the facade and
    // host read them without copying.
    property var _states: []
    property Component _stateFactory: Component {
        MonitorState {}
    }

    component MonitorState: QtObject {
        property string screenName: ""
        // unknown | querying | hardware | software-only | unsupported | failed
        property string state: "unknown"
        // wmi | lcd | ddc | software | ""
        property string route: ""
        property bool available: false
        property bool brightnessKnown: false
        property real brightness: 0
        property bool querying: false
        // A write is in flight. A second write is refused, not queued.
        property bool writePending: false
        property string expectedRoute: ""
        property real pendingValue: 0
        property bool routeChangedDuringWrite: false
        // A route change during a write latches the monitor. A user route
        // refresh is the only thing that clears it.
        property bool latched: false
        // none | pending | queried | route-failed | hardware-requested |
        // software-requested | route-changed | failed | refused
        property string lastOutcome: "none"
        property string lastError: ""
    }

    function screenNameOf(screen): string {
        if (typeof screen === "string")
            return screen;
        const name = screen?.name;
        return typeof name === "string" ? name : "";
    }

    function stateFor(screen): var {
        const name = screenNameOf(screen);
        if (!name)
            return null;
        return _states.find(state => state.screenName === name) ?? null;
    }

    function routeLabel(route): string {
        if (route === "wmi")
            return "WMI";
        if (route === "lcd")
            return "\\\\.\\LCD";
        if (route === "ddc")
            return "DDC/CI";
        if (route === "software")
            return "software (gamma)";
        return "no route";
    }

    function capabilityLabel(capability): string {
        if (capability === "querying")
            return "Checking route";
        if (capability === "hardware")
            return "Hardware";
        if (capability === "software-only")
            return "Software only";
        if (capability === "unsupported")
            return "Unsupported";
        if (capability === "failed")
            return "Failed";
        return "Unknown";
    }

    function capabilityReason(screen): string {
        const state = stateFor(screen);
        if (!state)
            return "This screen is not present.";
        if (state.lastError.length > 0)
            return state.lastError;
        if (state.state === "unknown")
            return "The brightness route has not been checked.";
        if (state.state === "querying")
            return "The brightness route is being checked.";
        if (state.state === "hardware")
            return "Hardware brightness is available through " + routeLabel(state.route) + ".";
        if (state.state === "software-only") {
            return "Only software gamma dimming is available; the backlight cannot be controlled."
                + (softwareEnabled ? "" : " Software writes are disabled without the separate opt-in.");
        }
        if (state.state === "unsupported")
            return "No brightness control route was reported for this display.";
        return "The hardware route did not report a usable brightness level.";
    }

    function canQuery(): bool {
        return enabled && !backendError && backend !== null;
    }

    // True only for a completed route discovery on a hardware route, or on a
    // software-only route with the separate gamma opt-in. A latched monitor and
    // a pending query/write are never writable.
    function canWrite(screen): bool {
        const state = stateFor(screen);
        if (!state)
            return false;
        if (!enabled || !controlsEnabled || backendError || backend === null)
            return false;
        if (state.querying || state.writePending || state.latched)
            return false;
        if (state.state === "hardware")
            return state.route === "wmi" || state.route === "lcd" || state.route === "ddc";
        if (state.state === "software-only")
            return softwareEnabled && state.route === "software";
        return false;
    }

    function _syncStates(): void {
        const previous = _states;
        const next = [];
        const source = screens ?? [];
        for (let index = 0; index < source.length; index++) {
            const name = screenNameOf(source[index]);
            if (!name)
                continue;
            if (next.some(state => state.screenName === name))
                continue;
            const existing = previous.find(state => state.screenName === name);
            if (existing) {
                next.push(existing);
                continue;
            }
            const created = _stateFactory.createObject(root, {screenName: name});
            if (created)
                next.push(created);
        }
        // Vanished screens are dropped with their pending query/write state.
        // Late backend signals for them are ignored by stateFor().
        _states = next;
    }

    function _resetStates(): void {
        for (const state of _states) {
            state.state = "unknown";
            state.route = "";
            state.available = false;
            state.brightnessKnown = false;
            state.brightness = 0;
            state.querying = false;
            state.writePending = false;
            state.expectedRoute = "";
            state.pendingValue = 0;
            state.routeChangedDuringWrite = false;
            state.latched = false;
            state.lastOutcome = "none";
            state.lastError = "";
        }
    }

    function _currentRoute(screenName): string {
        if (!backend)
            return "";
        try {
            const route = backend.methodFor(screenName);
            return typeof route === "string" ? route : "";
        } catch (error) {
            return "";
        }
    }

    function _refuse(state, message): bool {
        state.lastOutcome = "refused";
        state.lastError = message;
        refusedWrites++;
        return false;
    }

    function queryMonitor(screen): bool {
        const state = stateFor(screen);
        if (!state)
            return false;
        if (!canQuery()) {
            state.lastError = enabled
                ? "The Windows brightness backend is unavailable."
                : "Windows brightness is disabled.";
            return false;
        }
        if (state.querying)
            return false;
        if (state.writePending) {
            state.lastError = "A brightness write is in flight; wait for it before refreshing the route.";
            return false;
        }
        state.querying = true;
        state.state = "querying";
        state.route = "";
        state.available = false;
        state.brightnessKnown = false;
        state.brightness = 0;
        state.expectedRoute = "";
        state.pendingValue = 0;
        state.routeChangedDuringWrite = false;
        // A route refresh is the explicit user action that clears a latch.
        state.latched = false;
        state.lastOutcome = "none";
        state.lastError = "";
        queryRequests++;
        try {
            backend.query(state.screenName);
        } catch (error) {
            state.querying = false;
            state.state = "failed";
            state.lastOutcome = "failed";
            state.lastError = "The brightness route query failed: " + error;
            return false;
        }
        return true;
    }

    function queryAll(): int {
        let requested = 0;
        for (const state of _states) {
            if (queryMonitor(state.screenName))
                requested++;
        }
        return requested;
    }

    // One automatic route discovery per process, and only while this process
    // has applied no software dimming. The backend drops existing gamma dimming
    // in startProbe(), so a later automatic query could silently undo a write.
    function beginObservation(): bool {
        if (!canQuery() || autoObservationDone)
            return false;
        if (gammaTouched)
            return false;
        autoObservationDone = true;
        queryAll();
        return true;
    }

    // Explicit user action: re-detect every route. This can reset software
    // dimming this process applied earlier (documented backend behaviour);
    // hosts must only call it from a user gesture.
    function refreshRoutes(): int {
        autoObservationDone = true;
        return queryAll();
    }

    function nudge(screen, delta): bool {
        const state = stateFor(screen);
        if (!state)
            return false;
        if (typeof delta !== "number" || !Number.isFinite(delta))
            return _refuse(state, "The brightness increment must be a finite number.");
        if (!state.brightnessKnown)
            return _refuse(state, "The current brightness is unknown; refresh the route before adjusting it.");
        return write(screen, state.brightness + delta);
    }

    function write(screen, value): bool {
        const state = stateFor(screen);
        if (!state)
            return false;
        if (!enabled)
            return _refuse(state, "Windows brightness is disabled.");
        if (backendError)
            return _refuse(state, backendError);
        if (!backend)
            return _refuse(state, "The Windows brightness backend is unavailable.");
        if (!controlsEnabled)
            return _refuse(state, "Brightness controls are disabled for read-only observation.");
        if (typeof value !== "number" || !Number.isFinite(value))
            return _refuse(state, "The brightness value must be a finite number between 0 and 1.");
        const target = Math.max(0, Math.min(1, value));
        if (state.querying)
            return _refuse(state, "The brightness route is being queried; wait for it to finish.");
        if (state.writePending)
            return _refuse(state, "A brightness write is already in flight for this monitor.");
        if (state.latched)
            return _refuse(state, "This monitor's route changed during an earlier write. Refresh the route before writing again.");
        if (state.state === "unknown")
            return _refuse(state, "The brightness route is unknown; query it before writing.");
        if (state.state === "hardware") {
            if (state.route !== "wmi" && state.route !== "lcd" && state.route !== "ddc")
                return _refuse(state, "The reported hardware route is not writable.");
            return _startWrite(state, target);
        }
        if (state.state === "software-only") {
            if (!softwareEnabled)
                return _refuse(state, "This monitor only supports software gamma dimming; set CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1 to allow it.");
            return _startWrite(state, target);
        }
        if (state.state === "failed")
            return _refuse(state, "This monitor's hardware route failed its level read; no fallback is accepted.");
        return _refuse(state, "This monitor has no writable brightness route.");
    }

    function _startWrite(state, value): bool {
        state.expectedRoute = state.route;
        state.pendingValue = value;
        state.writePending = true;
        state.routeChangedDuringWrite = false;
        state.lastOutcome = "pending";
        state.lastError = "";
        writeRequests++;
        everWrote = true;
        try {
            // The backend chooses the actual method from its own route and may
            // fall back internally; the adapter can only detect the outcome.
            backend.setBrightness(state.screenName, state.route === "ddc", value);
        } catch (error) {
            state.writePending = false;
            state.lastOutcome = "failed";
            state.lastError = "The brightness write failed: " + error;
            state.latched = true;
            return false;
        }
        return true;
    }

    function _onQueried(screenName, available, isDdc, brightness): void {
        const state = stateFor(screenName);
        if (!state || state.writePending)
            return;
        // The backend also sets isDdc for the software route (brightness.cpp:
        // 1230-1236); methodFor() is the only route source.
        const route = _currentRoute(screenName);
        const level = Number(brightness);
        const readable = available === true && Number.isFinite(level);
        state.querying = false;
        state.route = route;
        state.available = available === true;
        state.lastOutcome = "queried";
        if (route === "wmi" || route === "lcd" || route === "ddc") {
            state.state = available === true ? "hardware" : "failed";
            state.brightnessKnown = readable;
            state.brightness = readable ? Math.max(0, Math.min(1, level)) : 0;
            state.lastError = available === true
                ? ""
                : routeLabel(route) + " did not report a readable brightness level.";
            return;
        }
        if (route === "software") {
            state.state = "software-only";
            state.brightnessKnown = readable;
            state.brightness = readable ? Math.max(0, Math.min(1, level)) : 0;
            state.lastError = "";
            return;
        }
        state.state = "unsupported";
        state.brightnessKnown = false;
        state.brightness = 0;
        state.lastError = "The backend reported no brightness route for this display.";
    }

    function _onBrightnessSetFinished(screenName, ok): void {
        const state = stateFor(screenName);
        if (!state || !state.writePending)
            return;
        const expected = state.expectedRoute;
        const value = state.pendingValue;
        state.writePending = false;
        const route = _currentRoute(screenName);
        state.routeChangedDuringWrite = false;
        // Route change wins over the boolean. At this pin the backend emits
        // true even after its internal gamma fallback, so `ok` proves nothing.
        if (route !== expected) {
            _latchRouteChange(state, expected, route);
            return;
        }
        if (ok !== true) {
            state.lastOutcome = "failed";
            state.latched = true;
            state.brightnessKnown = false;
            state.brightness = 0;
            state.lastError = "The backend reported an unsuccessful brightness write. No retry is sent until you refresh the route.";
            return;
        }
        state.lastOutcome = expected === "software" ? "software-requested" : "hardware-requested";
        state.brightnessKnown = true;
        state.brightness = value;
        if (expected === "software")
            gammaTouched = true;
    }

    function _onRouteChanged(screenName, route): void {
        const state = stateFor(screenName);
        if (!state)
            return;
        const reported = typeof route === "string" ? route : "";
        if (reported.length === 0)
            return;
        if (state.querying)
            return; // The query path emits routeChanged immediately before queried.
        if (state.writePending && state.expectedRoute.length > 0 && reported !== state.expectedRoute) {
            _latchRouteChange(state, state.expectedRoute, reported);
            return;
        }
        if (state.writePending)
            return;
        state.route = reported;
        if (state.state === "hardware" && reported === "software")
            state.state = "software-only";
        else if (state.state === "software-only" && reported !== "software")
            state.state = "hardware";
    }

    function _latchRouteChange(state, expected, route): void {
        state.writePending = false;
        state.routeChangedDuringWrite = true;
        state.route = route;
        state.latched = true;
        state.state = route === "software" ? "software-only" : "failed";
        state.brightnessKnown = false;
        state.brightness = 0;
        if (route === "software")
            gammaTouched = true;
        state.lastOutcome = "route-changed";
        state.lastError = "The backend used " + routeLabel(route) + " instead of "
            + routeLabel(expected) + " for this write. A route change is reported as a failure, "
            + "not a success; no further writes are sent until the route is refreshed.";
    }

    function _onSystemBrightnessChanged(screenName, brightness): void {
        const state = stateFor(screenName);
        if (!state)
            return;
        const value = Number(brightness);
        if (!Number.isFinite(value))
            return;
        state.brightness = Math.max(0, Math.min(1, value));
        state.brightnessKnown = true;
        // Only WMI and \\.\LCD start a read-back; DDC/CI has no confirmation.
        if (state.state === "hardware" && !state.latched)
            state.available = true;
    }

    property Connections _backendConnections: Connections {
        target: root.enabled ? root.backend : null
        ignoreUnknownSignals: true
        function onQueried(screenName, available, isDdc, brightness): void {
            root._onQueried(screenName, available, isDdc, brightness);
        }
        function onBrightnessSetFinished(screenName, ok): void {
            root._onBrightnessSetFinished(screenName, ok);
        }
        function onRouteChanged(screenName, route): void {
            root._onRouteChanged(screenName, route);
        }
        function onSystemBrightnessChanged(screenName, brightness): void {
            root._onSystemBrightnessChanged(screenName, brightness);
        }
    }

    onScreensChanged: _syncStates()
    onEnabledChanged: {
        if (!enabled)
            _resetStates();
        else
            autoObservationDone = false;
    }
    Component.onCompleted: _syncStates()
}
