import QtQuick

// Windows adaptation of the bounded parts of services/Brightness.qml. This
// object imports no Quickshell or native module, creates no timers and runs no
// probe on its own. It is a route-policy state machine over an injected backend.
//
// STRICT-ROUTE CONTRACT (windows/deps/quickshell strict-route fork):
//   property bool strictRoutes (one-way: enable only while idle)
//   function setStrictRoutes(bool) [optional convenience]
//   signal brightnessWriteResult(QString screen, real value, bool ok,
//                                QString method, QString error)
//   function clearSoftwareDimming(QString screen)
//
// Writes are never attempted without that contract. The shared build is still
// at the old pin, which lacks every strict member: there an Interactive request
// stays read-only rather than reaching the legacy setBrightness() path, which
// silently retries \\.\LCD and falls back to software gamma and then reports
// ok = true. With strict routes the backend never falls back and emits exactly
// one brightnessWriteResult() per accepted write, so that signal is the only
// write confirmation and a pending write is not cleared by any other signal.
//
// Route queries remain safe in both builds. query()/probe() share startProbe();
// at the old pin that path drops software gamma dimming this process applied
// earlier, so the adapter still never probes automatically and only re-queries
// on an explicit user action after a gamma touch.
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

    // A strict-route policy failure is latched separately from the per-monitor
    // route records. An explicit route refresh (a user action) clears it.
    property string policyError: ""
    property bool strictRoutesEnabled: false

    // Evidence counters. They are informational for hosts and fixtures; no
    // caller may infer success from them.
    property int queryRequests: 0
    property int writeRequests: 0
    property int coalescedWrites: 0
    property int clearedDimmingRequests: 0
    property int refusedWrites: 0
    property bool everWrote: false
    // True once a write was forwarded for a software route or the backend
    // reported a software route for a hardware write.
    property bool gammaTouched: false
    property bool autoObservationDone: false

    readonly property var monitorStates: _states
    readonly property int monitorCount: _states.length

    readonly property bool nativeRequested: backend !== null
    readonly property bool ready: enabled && !backendError && backend !== null
    // Feature-detected on the object: typeof strictRoutes is "undefined" on the
    // old-pin wrapper, and a strict-capable backend always carries the result
    // signal. Never assume strict routes from a build number.
    readonly property bool strictBackend: backend !== null
        && typeof backend.strictRoutes === "boolean"
        && typeof backend.brightnessWriteResult === "function"
    // Writes are permitted only with the controls opt-in, the strict backend and
    // no latched policy failure. Interactive is separate from writeReady: a
    // pending write must never disable a slider mid-gesture.
    readonly property bool writesAllowed: enabled && controlsEnabled && strictBackend
        && policyError.length === 0
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
        if (policyError)
            return policyError;
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
        if (!strictBackend)
            return "Brightness writes need the strict-route backend. This backend exposes read-only routes, so the interactive slider stays read-only.";
        if (policyError)
            return policyError;
        if (!softwareEnabled)
            return "Windows brightness controls are enabled for hardware routes only. Software gamma writes need the separate software opt-in.";
        return "Windows brightness controls are enabled, including software gamma for monitors without a hardware route.";
    }

    // Internal per-screen policy record. Values are reactive so the facade and
    // host read them without copying.
    property var _states: []
    // Per-screen record generations survive a screen removal so a late query
    // result cannot authorize the reconnected monitor.
    property var _generations: ({})
    // Outstanding query requests per screen, tracked independently of the
    // screen records. Every backend.query() call pushes its record's globally
    // unique request token; every queried() completion consumes the oldest
    // outstanding token and is accepted only when it answers the token the
    // current record issued. The queues survive record replacement, so a
    // completion answering a request made against an older record is consumed
    // and discarded instead of authorizing the reconnected monitor. The native
    // backend answers one screen's queries in request order (a single worker
    // thread delivering queued connections), so the oldest outstanding
    // request is the one a completion answers.
    property var _queryRequests: ({})
    property int _querySerial: 0
    property Component _stateFactory: Component {
        MonitorState {}
    }

    component MonitorState: QtObject {
        property string screenName: ""
        // Bumped when the screen is removed; a fresh record for the same name
        // is created with the bumped value.
        property int generation: 0
        // Globally unique token of the query request this record issued. A
        // queried() completion is accepted only when it answers that token.
        property int queryToken: 0
        // Bumped after a terminal write failure. The drag removed the host
        // slider's value binding, so reassigning the unchanged confirmed level
        // emits nothing; hosts rebind the displayed value on this serial.
        property int resyncSerial: 0
        // unknown | querying | hardware | software-only | unsupported | failed
        property string state: "unknown"
        // wmi | lcd | ddc | software | ""
        property string route: ""
        property bool available: false
        property bool brightnessKnown: false
        property real brightness: 0
        property bool querying: false
        // A strict write is in flight. Further values coalesce to the latest
        // drag target and are sent after the terminal result.
        property bool writePending: false
        property bool hasQueuedWrite: false
        property real queuedValue: 0
        // Last level this adapter saw confirmed by a query, read-back or write.
        property real lastConfirmed: 0
        property bool lastConfirmedKnown: false
        property string expectedRoute: ""
        property real pendingValue: 0
        // Kept for the facade contract. Route-change fallbacks no longer exist
        // under strict routes, so no path sets it.
        property bool latched: false
        // none | pending | queried | hardware-requested | software-requested |
        // failed | refused
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

    // True when the slider may accept input: writes are permitted and the route
    // is known. Deliberately independent of writePending so a coalesced drag
    // never disables the slider mid-gesture. A latched monitor and a pending
    // query are still not interactive.
    function interactive(screen): bool {
        const state = stateFor(screen);
        if (!state)
            return false;
        if (!writesAllowed)
            return false;
        if (state.querying || state.latched)
            return false;
        if (state.state === "hardware")
            return state.route === "wmi" || state.route === "lcd" || state.route === "ddc";
        if (state.state === "software-only")
            return softwareEnabled && state.route === "software";
        return false;
    }

    // A write may be forwarded right now: interactive and no write in flight.
    function canWrite(screen): bool {
        const state = stateFor(screen);
        if (!state || !interactive(screen))
            return false;
        return !state.writePending;
    }

    function _generationFor(name): int {
        const value = _generations[name];
        return typeof value === "number" ? value : 0;
    }

    function _bumpGeneration(name): void {
        const map = Object.assign({}, _generations);
        map[name] = _generationFor(name) + 1;
        _generations = map;
    }

    function _pushQueryRequest(name, token): void {
        const map = Object.assign({}, _queryRequests);
        const queue = map[name] ?? [];
        map[name] = queue.concat([token]);
        _queryRequests = map;
    }

    // Consumes the oldest outstanding request token for a screen: the request
    // a queried() completion answers.
    function _popQueryRequest(name): int {
        const queue = _queryRequests[name];
        if (!Array.isArray(queue) || queue.length === 0)
            return -1;
        const map = Object.assign({}, _queryRequests);
        map[name] = queue.slice(1);
        _queryRequests = map;
        return queue[0];
    }

    // Drops the newest outstanding request token; a query() call that threw
    // synchronously can never complete.
    function _discardQueryRequest(name): void {
        const queue = _queryRequests[name];
        if (!Array.isArray(queue) || queue.length === 0)
            return;
        const map = Object.assign({}, _queryRequests);
        map[name] = queue.slice(0, queue.length - 1);
        _queryRequests = map;
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
            const created = _stateFactory.createObject(root, {
                screenName: name,
                generation: _generationFor(name)
            });
            if (created)
                next.push(created);
        }
        // Vanished screens are dropped with their pending query/write state and
        // their generation is bumped, so a late result cannot authorize the
        // reconnected monitor.
        for (const old of previous) {
            if (!next.some(state => state.screenName === old.screenName))
                _bumpGeneration(old.screenName);
        }
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
            state.hasQueuedWrite = false;
            state.queuedValue = 0;
            state.lastConfirmed = 0;
            state.lastConfirmedKnown = false;
            state.expectedRoute = "";
            state.pendingValue = 0;
            state.latched = false;
            state.lastOutcome = "none";
            state.lastError = "";
        }
        _generations = ({});
        // The backend connection is gone while disabled; the outstanding
        // requests can never complete and must not consume later ones.
        _queryRequests = ({});
        policyError = "";
        strictRoutesEnabled = false;
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
        _querySerial++;
        state.queryToken = _querySerial;
        state.state = "querying";
        state.route = "";
        state.available = false;
        state.brightnessKnown = false;
        state.brightness = 0;
        state.lastConfirmed = 0;
        state.lastConfirmedKnown = false;
        state.expectedRoute = "";
        state.pendingValue = 0;
        // A route refresh is the explicit user action that clears a latch.
        state.latched = false;
        state.lastOutcome = "none";
        state.lastError = "";
        queryRequests++;
        try {
            _pushQueryRequest(state.screenName, state.queryToken);
            backend.query(state.screenName);
        } catch (error) {
            _discardQueryRequest(state.screenName);
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
    // has applied no software dimming. At the old pin the query path drops
    // existing gamma dimming, so a later automatic query could silently undo a
    // write.
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
    // hosts must only call it from a user gesture. It also clears a latched
    // strict-route policy failure so the user can retry once the backend is idle.
    function refreshRoutes(): int {
        policyError = "";
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
        if (!strictBackend)
            return _refuse(state, "Brightness writes need the strict-route backend. This backend exposes read-only routes; the interactive slider stays read-only.");
        if (policyError.length > 0)
            return _refuse(state, policyError);
        if (typeof value !== "number" || !Number.isFinite(value))
            return _refuse(state, "The brightness value must be a finite number between 0 and 1.");
        const target = Math.max(0, Math.min(1, value));
        if (state.querying)
            return _refuse(state, "The brightness route is being queried; wait for it to finish.");
        if (state.latched)
            return _refuse(state, "This monitor's route changed during an earlier write. Refresh the route before writing again.");
        if (state.state === "unknown")
            return _refuse(state, "The brightness route is unknown; query it before writing.");
        if (state.state === "hardware") {
            if (state.route !== "wmi" && state.route !== "lcd" && state.route !== "ddc")
                return _refuse(state, "The reported hardware route is not writable.");
        } else if (state.state === "software-only") {
            if (!softwareEnabled)
                return _refuse(state, "This monitor only supports software gamma dimming; set CAELESTIA_WINDOWS_BRIGHTNESS_SOFTWARE=1 to allow it.");
            if (state.route !== "software")
                return _refuse(state, "The reported software route is not writable.");
        } else if (state.state === "failed") {
            return _refuse(state, "This monitor's hardware route failed its level read; no fallback is accepted.");
        } else {
            return _refuse(state, "This monitor has no writable brightness route.");
        }
        // Coalesce a drag: keep the terminal result as the only completion and
        // remember the latest target for the next strict write.
        if (state.writePending) {
            state.queuedValue = target;
            state.hasQueuedWrite = true;
            state.lastOutcome = "pending";
            coalescedWrites++;
            return true;
        }
        return _startWrite(state, target);
    }

    // Enable the one-way strict mode immediately before the first write. The
    // backend can refuse while a legacy write is still in flight; that refusal
    // is latched as a policy failure, never retried silently.
    function _ensureStrictRoutes(): bool {
        if (!strictBackend) {
            policyError = "Brightness writes need the strict-route backend. This backend exposes read-only routes; the interactive slider stays read-only.";
            return false;
        }
        if (backend.strictRoutes === true) {
            strictRoutesEnabled = true;
            return true;
        }
        try {
            if (typeof backend.setStrictRoutes === "function")
                backend.setStrictRoutes(true);
            else
                backend.strictRoutes = true;
        } catch (error) {
            policyError = "The strict-route backend could not be enabled: " + error;
            return false;
        }
        if (backend.strictRoutes !== true) {
            policyError = "The strict-route backend refused to enable strict routes. Refresh the route once the backend is idle, then retry.";
            return false;
        }
        strictRoutesEnabled = true;
        return true;
    }

    function _startWrite(state, value): bool {
        if (!_ensureStrictRoutes()) {
            state.lastOutcome = "refused";
            state.lastError = policyError;
            refusedWrites++;
            return false;
        }
        state.expectedRoute = state.route;
        state.pendingValue = value;
        state.writePending = true;
        state.hasQueuedWrite = false;
        state.queuedValue = value;
        state.lastOutcome = "pending";
        state.lastError = "";
        writeRequests++;
        everWrote = true;
        try {
            // Under strict routes the backend uses the stored route and never
            // falls back; brightnessWriteResult() is the only completion.
            backend.setBrightness(state.screenName, state.route === "ddc", value);
        } catch (error) {
            state.writePending = false;
            state.hasQueuedWrite = false;
            state.lastOutcome = "failed";
            state.lastError = "The brightness write failed: " + error;
            _snapBack(state);
            return false;
        }
        return true;
    }

    function _snapBack(state): void {
        if (state.lastConfirmedKnown) {
            state.brightness = state.lastConfirmed;
            state.brightnessKnown = true;
        } else {
            state.brightness = 0;
            state.brightnessKnown = false;
        }
        // The drag already removed the slider's value binding, so reassigning
        // an unchanged confirmed level emits no change signal. Bump a serial
        // the Windows host and the OSD hook use to rebind the displayed value;
        // it is monotonically increasing and never reset.
        state.resyncSerial++;
    }

    // A queued drag target is kept only while the authorization that accepted
    // it still holds. When the controls opt-in is revoked or a strict-route
    // policy failure latches while the first write is in flight, the queue is
    // dropped at that moment, so the terminal result of the in-flight write
    // settles the record without dispatching anything further. Disabling the
    // service resets the records and removing the screen drops the record with
    // its queue; those paths need no extra handling here. The dropped drag
    // target will never be applied, so the displayed value is also resynced.
    function _dropQueuedWrites(): void {
        for (const state of _states) {
            if (!state.hasQueuedWrite)
                continue;
            state.hasQueuedWrite = false;
            state.resyncSerial++;
        }
    }

    function _clearSoftwareDimming(): int {
        if (!backend || typeof backend.clearSoftwareDimming !== "function")
            return 0;
        let cleared = 0;
        for (const state of _states) {
            try {
                backend.clearSoftwareDimming(state.screenName);
                cleared++;
            } catch (error) {
                // A screen that vanished mid-iteration is not a policy failure.
            }
        }
        clearedDimmingRequests += cleared;
        return cleared;
    }

    function _onQueried(screenName, available, isDdc, brightness): void {
        // Match the completion to the request it answers: the oldest
        // outstanding token for this screen. The token queue is kept across
        // record replacement, so a completion answering a request issued to an
        // older record is consumed here and discarded; it never authorizes the
        // current record, whose own completion is still outstanding.
        const token = _popQueryRequest(screenName);
        const state = stateFor(screenName);
        if (token < 0 || !state || !state.querying || state.queryToken !== token)
            return;
        // The backend also sets isDdc for the software route (brightness.cpp:
        // 1230-1236); methodFor() is the only route source.
        const route = _currentRoute(screenName);
        const level = Number(brightness);
        const readable = available === true && Number.isFinite(level);
        const clamped = readable ? Math.max(0, Math.min(1, level)) : 0;
        state.querying = false;
        state.route = route;
        state.available = available === true;
        state.lastOutcome = "queried";
        if (route === "wmi" || route === "lcd" || route === "ddc") {
            state.state = available === true ? "hardware" : "failed";
            state.brightnessKnown = readable;
            state.brightness = clamped;
            state.lastConfirmedKnown = readable;
            state.lastConfirmed = clamped;
            state.lastError = available === true
                ? ""
                : routeLabel(route) + " did not report a readable brightness level.";
            return;
        }
        if (route === "software") {
            state.state = "software-only";
            state.brightnessKnown = readable;
            state.brightness = clamped;
            state.lastConfirmedKnown = readable;
            state.lastConfirmed = clamped;
            state.lastError = "";
            return;
        }
        state.state = "unsupported";
        state.brightnessKnown = false;
        state.brightness = 0;
        state.lastConfirmedKnown = false;
        state.lastError = "The backend reported no brightness route for this display.";
    }

    // Legacy signal. Under strict routes the backend no longer emits only this
    // boolean; every terminal old-pin path reported true even after a fallback,
    // so it can never confirm a write and stays inert.
    function _onBrightnessSetFinished(screenName, ok): void {
    }

    function _onBrightnessWriteResult(screenName, value, ok, method, error): void {
        const state = stateFor(screenName);
        // Late or duplicate results are ignored: only an outstanding strict
        // write for the current record can be confirmed.
        if (!state || !state.writePending)
            return;
        state.writePending = false;
        const reportedRoute = typeof method === "string" ? method : "";
        const reportedError = typeof error === "string" ? error : "";
        const confirmed = ok === true && reportedRoute === state.expectedRoute;
        if (!confirmed) {
            state.lastOutcome = "failed";
            state.hasQueuedWrite = false;
            if (reportedError.length > 0) {
                state.lastError = reportedError;
            } else if (reportedRoute.length > 0 && reportedRoute !== state.expectedRoute) {
                state.lastError = "The strict backend wrote through " + routeLabel(reportedRoute)
                    + " instead of " + routeLabel(state.expectedRoute) + ".";
            } else {
                state.lastError = "The strict-route backend rejected the brightness write.";
            }
            // Drop every queued target and snap back to the last confirmation.
            _snapBack(state);
            return;
        }
        const level = Number(value);
        const applied = Number.isFinite(level)
            ? Math.max(0, Math.min(1, level)) : state.pendingValue;
        state.lastOutcome = state.expectedRoute === "software"
            ? "software-requested" : "hardware-requested";
        state.brightnessKnown = true;
        state.brightness = applied;
        state.lastConfirmedKnown = true;
        state.lastConfirmed = applied;
        state.lastError = "";
        if (state.expectedRoute === "software")
            gammaTouched = true;
        if (state.hasQueuedWrite) {
            const next = state.queuedValue;
            state.hasQueuedWrite = false;
            // The queued dispatch goes through write()'s authorization of the
            // current state, exactly like an initial dispatch: the controls
            // opt-in can have been revoked, the service disabled or a policy
            // failure latched while the first write was in flight, and write()
            // re-checks the route and pending state on the live record. A
            // refused or dropped queue sends no backend call.
            if (_states.indexOf(state) >= 0
                && state.generation === _generationFor(state.screenName))
                write(state.screenName, next);
        }
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
        // A strict write never changes routes. Never clear writePending here: the
        // terminal brightnessWriteResult() is the only completion.
        if (state.writePending)
            return;
        state.route = reported;
        if (state.state === "hardware" && reported === "software")
            state.state = "software-only";
        else if (state.state === "software-only" && reported !== "software")
            state.state = "hardware";
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
        state.lastConfirmed = state.brightness;
        state.lastConfirmedKnown = true;
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
        function onBrightnessWriteResult(screenName, value, ok, method, error): void {
            root._onBrightnessWriteResult(screenName, value, ok, method, error);
        }
        function onRouteChanged(screenName, route): void {
            root._onRouteChanged(screenName, route);
        }
        function onSystemBrightnessChanged(screenName, brightness): void {
            root._onSystemBrightnessChanged(screenName, brightness);
        }
    }

    property bool _softwareWasEnabled: false
    onSoftwareEnabledChanged: {
        if (_softwareWasEnabled && !softwareEnabled)
            _clearSoftwareDimming();
        _softwareWasEnabled = softwareEnabled;
    }
    onBackendChanged: {
        strictRoutesEnabled = false;
        policyError = "";
        // The previous backend's completions will never arrive; its
        // outstanding query tokens must not consume the next backend's
        // completions.
        _queryRequests = ({});
    }
    onScreensChanged: _syncStates()
    onControlsEnabledChanged: {
        if (!controlsEnabled)
            _dropQueuedWrites();
    }
    onPolicyErrorChanged: {
        if (policyError.length > 0)
            _dropQueuedWrites();
    }
    onEnabledChanged: {
        if (!enabled)
            _resetStates();
        else
            autoObservationDone = false;
    }
    Component.onCompleted: _syncStates()
}
