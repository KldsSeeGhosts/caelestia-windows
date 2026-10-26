pragma ComponentBehavior: Bound

import QtQuick

// Standalone strict-route policy fixture. Imports no Quickshell/native
// Brightness or configuration module, reads no environment or hardware, and
// never constructs Brightness.qml or NativeBrightnessBackend.qml. Intended
// runner:
//   powershell -NoProfile -File windows/scripts/Test-BrightnessService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and BrightnessService.qml.
QtObject {
    id: test
    property QtObject unpluggedRecord: null

    // Strict-capable model of the backend the adapter is written against:
    // the pinned strict-route members (525786f,
    // src/windows/system/brightness.cpp) plus the id-carrying query API
    // (queryRequest/queryFinished). Timing and argument order come from the
    // native source, so the adapter is exercised against realistic completion
    // behavior:
    //   - queryRequest(name) returns a process-unique, strictly increasing
    //     positive id immediately (ids come from the test-wide counter, so no
    //     two fakes ever issue the same id) and queues the completion.
    //     Completions may be delivered OUT of request order:
    //     deliverQuery(id) delivers one specific request, deliverQuery() the
    //     oldest. A delivered completion emits routeChanged(screen, route),
    //     then queryFinished(id, screen, available, isDdc, brightness) for
    //     id-carrying requests, then queried(screen, available, isDdc,
    //     brightness), with isDdc true only for the ddc and software routes.
    //     The plain query() queues an id-less completion that emits
    //     routeChanged and queried only.
    //   - queryIdsSupported false removes queryRequest, modeling the pinned
    //     525786f backend, which carries the strict members but no ids.
    //   - A hardware write completes QUEUED: brightnessSetFinished(ok) and
    //     then exactly one brightnessWriteResult(value, ok, route, error),
    //     with the per-screen in-flight bookkeeping finalized before the
    //     signals, so a handler can submit the next strict write immediately.
    //   - Unresolved-route and overlapping (in-flight) writes are rejected
    //     DIRECTLY, synchronously inside setBrightness(), with ok=false
    //     results carrying the native error text; throwOnSet models a
    //     synchronous dispatch failure.
    //   - A software-route write completes DIRECTLY.
    //   - strictRoutes can be enabled only while the worker is idle and can
    //     never be disabled (attempts are counted and refused). Flipping the
    //     property emits exactly one strictRoutesChanged, from the property's
    //     own change signal.
    //   - clearSoftwareDimming() emits nothing.
    // Probe and write outcomes are captured when the call is made (the worker
    // reads the display then); the fixture delivers the queued completions
    // explicitly through deliverQuery()/completeWrite().
    component FakeBackend: QtObject {
        id: fake

        // Probe outcome captured per queryRequest()/query() call.
        property string probeRoute: "wmi"
        property bool probeAvailable: true
        property real probeLevel: 0.5
        // Hardware/software write outcome captured per setBrightness() call.
        property bool writeOk: true
        property string writeError: ""
        // When set, setBrightness() throws synchronously.
        property bool throwOnSet: false
        // Route the queued result reports; empty means the stored route (the
        // realistic case). Set to model a result reported through another
        // route than the one dispatched.
        property string resultRoute: ""
        // strictRoutes policy.
        property bool strictRoutes: false
        property bool refuseStrict: false
        property int strictEnableCalls: 0
        property int strictRefusals: 0
        property int strictDisableAttempts: 0
        property bool sawStrictAtWrite: false
        // The id-carrying query API. False models the pinned 525786f backend.
        property bool queryIdsSupported: true
        // Stored routes; a name absent from the map or mapped to "" is
        // unresolved, exactly like the native BrightnessRoute default.
        property var routes: ({})
        // Screens whose software gamma ramp this backend has dimmed.
        property var gammaDimmed: ({})
        // Counters.
        property int queryCalls: 0
        property int probeCalls: 0
        property int refreshCalls: 0
        property int setCalls: 0
        property int legacySetCalls: 0
        property int clearCalls: 0
        property var clearedScreens: []
        property var lastSet: null
        // Pending worker completions. Queries may complete out of request
        // order; each entry carries the id it answers (0 for plain query()).
        property var _queryCompletions: []
        property var _writeCompletions: []
        property var _inFlight: []
        readonly property int pendingQueries: _queryCompletions.length
        readonly property int pendingWrites: _writeCompletions.length

        signal queried(string screenName, bool available, bool isDdc, real brightness)
        signal queryFinished(real requestId, string screenName, bool available, bool isDdc, real brightness)
        signal brightnessSetFinished(string screenName, bool ok)
        signal brightnessWriteResult(string screenName, real value, bool ok, string method, string error)
        signal routeChanged(string screenName, string route)
        signal systemBrightnessChanged(string screenName, real brightness)
        // strictRoutesChanged comes from the strictRoutes property's own
        // change signal when setStrictRoutes() flips it: exactly one emission
        // per successful enable, none for a refusal.

        // Deliberately a `var` like the wrapper's: a callable when supported,
        // undefined otherwise, matching the adapter's feature detection.
        readonly property var queryRequest: fake.queryIdsSupported
            ? ((screenName) => fake._requestQuery(screenName))
            : undefined

        // Enabling is one-way and idle-only: a disable attempt is counted and
        // refused, and an enable is refused while any write is active,
        // matching the strict backend contract. The property assignment is
        // the only strictRoutesChanged emission.
        function setStrictRoutes(enabled): void {
            if (fake.strictRoutes === enabled)
                return;
            if (enabled !== true) {
                fake.strictDisableAttempts++;
                return;
            }
            if (fake.refuseStrict || fake._inFlight.length > 0) {
                fake.strictRefusals++;
                return;
            }
            fake.strictEnableCalls++;
            fake.strictRoutes = true;
        }

        function methodFor(screenName): string {
            const route = fake.routes[screenName];
            return typeof route === "string" ? route : "";
        }

        function _queueQueryCompletion(id, screenName): void {
            fake._queryCompletions = fake._queryCompletions.concat([{
                id: id,
                screenName: screenName,
                route: fake.probeRoute,
                available: fake.probeAvailable,
                brightness: fake.probeLevel
            }]);
        }

        function _requestQuery(screenName): real {
            fake.queryCalls++;
            const id = test.allocQueryId();
            fake._queueQueryCompletion(id, screenName);
            return id;
        }

        // Plain parity API; the adapter only uses it on backends without ids.
        function query(screenName): void {
            fake.queryCalls++;
            fake._queueQueryCompletion(0, screenName);
        }

        // Delivers one queued query completion: the one carrying `id` when
        // given, otherwise the oldest. The stored route is updated first,
        // then routeChanged, queryFinished (id-carrying requests only) and
        // queried are emitted in the native order. Completions are kept in
        // the queue, so requests may be delivered out of order.
        function deliverQuery(id): void {
            const completions = fake._queryCompletions;
            let index = 0;
            if (id !== undefined && id !== null)
                index = completions.findIndex(completion => completion.id === id);
            if (index < 0 || index >= completions.length)
                return;
            const completion = completions[index];
            fake._queryCompletions = completions.slice(0, index)
                .concat(completions.slice(index + 1));
            fake.routes = Object.assign({}, fake.routes,
                {[completion.screenName]: completion.route});
            const isDdc = completion.route === "ddc" || completion.route === "software";
            fake.routeChanged(completion.screenName, completion.route);
            if (completion.id > 0)
                fake.queryFinished(completion.id, completion.screenName,
                    completion.available, isDdc, completion.brightness);
            fake.queried(completion.screenName, completion.available,
                isDdc, completion.brightness);
        }

        function probe(screenName): void {
            fake.probeCalls++;
        }

        function refresh(screenName): void {
            fake.refreshCalls++;
        }

        function clearSoftwareDimming(screenName): void {
            fake.clearCalls++;
            if (fake.gammaDimmed[screenName] !== true)
                return; // The native call is a no-op without retained dimming.
            const dimmed = Object.assign({}, fake.gammaDimmed);
            dimmed[screenName] = false;
            fake.gammaDimmed = dimmed;
            fake.clearedScreens = fake.clearedScreens.concat([screenName]);
            // Emits nothing.
        }

        function setBrightness(screenName, isDdc, value): void {
            fake.setCalls++;
            if (fake.throwOnSet)
                throw "native setBrightness dispatch failed";
            const clamped = Math.max(0, Math.min(1, value));
            fake.lastSet = {screenName: screenName, isDdc: isDdc, value: clamped};
            if (!fake.strictRoutes) {
                // Legacy dispatch: an unresolved route is written as DDC/CI
                // and the single worker is occupied like a strict write, but
                // the completion carries no strict result. The adapter must
                // never reach this path; legacySetCalls proves it.
                fake.legacySetCalls++;
                const stored = fake.methodFor(screenName);
                const route = stored.length > 0 ? stored : "ddc";
                fake.routes = Object.assign({}, fake.routes, {[screenName]: route});
                fake._inFlight = fake._inFlight.concat([screenName]);
                fake._writeCompletions = fake._writeCompletions.concat([{
                    screenName: screenName, value: clamped, route: route,
                    ok: true, error: "", legacy: true
                }]);
                return;
            }
            fake.sawStrictAtWrite = true;
            const route = fake.methodFor(screenName);
            if (route.length === 0) {
                fake.brightnessSetFinished(screenName, false);
                fake.brightnessWriteResult(screenName, clamped, false, "unresolved",
                    "no route resolved for this screen; query it before writing");
                return;
            }
            if (fake._inFlight.indexOf(screenName) >= 0) {
                fake.brightnessSetFinished(screenName, false);
                fake.brightnessWriteResult(screenName, clamped, false, route,
                    "a brightness write is already in flight for this screen");
                return;
            }
            if (route === "software") {
                const ok = fake.writeOk;
                if (ok && clamped < 1) {
                    const dimmed = Object.assign({}, fake.gammaDimmed);
                    dimmed[screenName] = true;
                    fake.gammaDimmed = dimmed;
                }
                fake.brightnessSetFinished(screenName, ok);
                fake.brightnessWriteResult(screenName, clamped, ok, "software",
                    ok ? "" : "software gamma write failed");
                return;
            }
            fake._inFlight = fake._inFlight.concat([screenName]);
            fake._writeCompletions = fake._writeCompletions.concat([{
                screenName: screenName,
                value: clamped,
                route: fake.resultRoute.length > 0 ? fake.resultRoute : route,
                ok: fake.writeOk,
                error: fake.writeOk ? "" : fake.writeError,
                legacy: false
            }]);
        }

        // Delivers the oldest queued hardware write completion. In-flight
        // bookkeeping is finalized before the signals, so a result handler can
        // submit the next strict write immediately.
        function completeWrite(): void {
            if (fake._writeCompletions.length === 0)
                return;
            const completion = fake._writeCompletions[0];
            fake._writeCompletions = fake._writeCompletions.slice(1);
            if (fake._inFlight.indexOf(completion.screenName) >= 0)
                fake._inFlight = fake._inFlight.filter(
                    name => name !== completion.screenName);
            fake.brightnessSetFinished(completion.screenName, completion.ok);
            if (completion.legacy)
                return; // brightnessWriteResult exists only for strict writes.
            fake.brightnessWriteResult(completion.screenName, completion.value,
                completion.ok, completion.route, completion.ok ? "" : completion.error);
        }
    }

    // Old-pin shape: no strictRoutes and no brightnessWriteResult. The adapter
    // must refuse Interactive writes instead of using the legacy fallback path.
    // Its query still completes synchronously: only feature detection and
    // write refusal are asserted against it, and neither depends on the
    // completion timing the strict model above carries.
    component OldBackend: QtObject {
        id: old

        property string method: "wmi"
        property var routes: ({})
        property bool available: true
        property real level: 0.5
        property int queryCalls: 0
        property int setCalls: 0
        signal queried(string screenName, bool available, bool isDdc, real brightness)
        signal brightnessSetFinished(string screenName, bool ok)
        signal routeChanged(string screenName, string method)
        signal systemBrightnessChanged(string screenName, real brightness)

        function methodFor(screenName): string {
            return old.routes[screenName] ?? old.method;
        }

        function query(screenName): void {
            old.queryCalls++;
            old.routes[screenName] = old.method;
            old.routeChanged(screenName, old.method);
            old.queried(screenName, old.available, old.method === "ddc", old.level);
        }

        function setBrightness(screenName, isDdc, value): void {
            old.setCalls++;
            old.brightnessSetFinished(screenName, true);
        }
    }

    // QObject-shaped malformed backends. Connections.target is QObject-typed,
    // so a plain JS object cannot represent an injected backend shape.
    component EmptyBackend: QtObject {
    }
    component SilentBackend: QtObject {
        function query(screenName): void {
        }
        function methodFor(screenName) {
            return 5;
        }
    }
    // Strict-looking but missing the result signal: feature detection must
    // require both members.
    component PartialStrictBackend: QtObject {
        property bool strictRoutes: false
        function query(screenName): void {
        }
        function methodFor(screenName) {
            return "wmi";
        }
    }

    // Mirrors the modules/osd/Content.qml brightness hook one-to-one against a
    // live service record: `displayed` starts with the same value binding the
    // OSD FilledSlider has, an imperative drag assignment breaks that binding,
    // and the record's resyncSerial restores it — the exact mechanics of the
    // brightnessResyncSerial hook.
    component DisplayProbe: QtObject {
        id: probe

        property var record: null
        property real displayed: record?.brightness ?? 0
        property int resyncs: 0
        property Connections hook: Connections {
            target: probe.record
            function onResyncSerialChanged(): void {
                probe.resyncs++;
                probe.displayed = Qt.binding(() => probe.record.brightness);
            }
        }
    }

    readonly property BrightnessService service: BrightnessService {}
    readonly property FakeBackend backend: FakeBackend {}
    readonly property BrightnessService observation: BrightnessService {}
    readonly property FakeBackend observationBackend: FakeBackend {}
    readonly property BrightnessService recovery: BrightnessService {}
    readonly property FakeBackend recoveryBackend: FakeBackend {}
    readonly property BrightnessService legacy: BrightnessService {}
    readonly property OldBackend legacyBackend: OldBackend {}
    readonly property BrightnessService blocked: BrightnessService {}
    readonly property FakeBackend blockedBackend: FakeBackend {}
    readonly property BrightnessService generationCase: BrightnessService {}
    readonly property FakeBackend generationBackend: FakeBackend {}
    readonly property BrightnessService disableCase: BrightnessService {}
    readonly property FakeBackend disableBackend: FakeBackend {}
    readonly property BrightnessService swapCase: BrightnessService {}
    readonly property FakeBackend swapBackendA: FakeBackend {}
    readonly property FakeBackend swapBackendB: FakeBackend {}
    readonly property BrightnessService noId: BrightnessService {}
    // The pinned 525786f shape: strict members present, query ids absent.
    readonly property FakeBackend noIdBackend: FakeBackend { queryIdsSupported: false }

    readonly property EmptyBackend emptyBackend: EmptyBackend {}
    readonly property SilentBackend silentBackend: SilentBackend {}
    readonly property PartialStrictBackend partialBackend: PartialStrictBackend {}

    // The fake model checked directly, independently of any adapter.
    readonly property FakeBackend modelBackend: FakeBackend {}
    property var fakeModelEvents: []
    property Connections fakeModelLog: Connections {
        target: test.modelBackend
        ignoreUnknownSignals: true
        function onQueried(screenName, available, isDdc, brightness): void {
            test.pushFakeEvent("queried", [screenName, available, isDdc, brightness]);
        }
        function onQueryFinished(requestId, screenName, available, isDdc, brightness): void {
            test.pushFakeEvent("queryFinished", [requestId, screenName, available, isDdc, brightness]);
        }
        function onBrightnessSetFinished(screenName, ok): void {
            test.pushFakeEvent("setFinished", [screenName, ok]);
        }
        function onBrightnessWriteResult(screenName, value, ok, method, error): void {
            test.pushFakeEvent("writeResult", [screenName, value, ok, method, error]);
        }
        function onRouteChanged(screenName, route): void {
            test.pushFakeEvent("routeChanged", [screenName, route]);
        }
        function onStrictRoutesChanged(): void {
            test.pushFakeEvent("strictRoutesChanged", []);
        }
    }
    function pushFakeEvent(kind, args): void {
        fakeModelEvents = fakeModelEvents.concat([[kind, args]]);
    }

    // Process-unique query ids: one strictly increasing counter behind every
    // fake, so no two backends ever issue the same id, exactly like the
    // process-wide native singleton across wrapper reloads.
    property real _queryIdSerial: 0

    function allocQueryId(): real {
        _queryIdSerial++;
        return _queryIdSerial;
    }

    readonly property DisplayProbe osdProbe: DisplayProbe {}
    readonly property DisplayProbe blockedProbe: DisplayProbe {}

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function close(actual, expected, message): void {
        check(Math.abs(actual - expected) < 0.000001,
            message + ": " + actual + " != " + expected);
    }

    function expectCapabilityOn(target, name, expected, message): void {
        const state = target.stateFor(name);
        check(state !== null, message + ": missing state for " + name);
        check(state.state === expected,
            message + ": state " + state.state + " != " + expected + " (" + state.lastError + ")");
    }

    function expectCapability(name, expected, message): void {
        expectCapabilityOn(service, name, expected, message);
    }

    function expectRefused(name, value, message): void {
        const before = backend.setCalls;
        check(service.write(name, value) === false, message + ": write was not refused");
        check(backend.setCalls === before, message + ": refused write reached the backend");
    }

    function run(): void {
        // --- Safe construction -------------------------------------------------
        check(service.enabled === false && service.controlsEnabled === false
            && service.softwareEnabled === false, "safe opt-in defaults");
        check(service.backend === null && service.backendError === ""
            && service.screens.length === 0, "safe backend/screens defaults");
        check(service.status === "disabled", "explicit disabled status");
        check(service.reason.indexOf("disabled") >= 0, "disabled reason");
        check(!service.ready && !service.nativeRequested && !service.canQuery(),
            "disabled is not ready and cannot query");
        check(!service.strictBackend && !service.writesAllowed
            && service.policyError === "" && !service.strictRoutesEnabled,
            "disabled has no strict capability or latched policy");
        check(service.monitorCount === 0 && service.monitorStates.length === 0,
            "disabled starts without monitor state");
        check(service.queryRequests === 0 && service.writeRequests === 0
            && service.coalescedWrites === 0 && service.clearedDimmingRequests === 0
            && !service.everWrote && !service.gammaTouched, "disabled counters start at zero");
        check(service.beginObservation() === false, "disabled cannot auto-observe");
        check(service.refreshRoutes() === 0, "disabled cannot refresh routes");
        check(service.write("DISPLAY1", 0.5) === false, "disabled refuses writes");
        check(service.refusedWrites === 0, "a write without a screen state is not counted");
        check(service.queryMonitor("DISPLAY1") === false, "disabled refuses route queries");
        check(service.beginObservation() === false && service.queryRequests === 0,
            "disabled automatic observation stays inert");

        // --- Screens without a backend ----------------------------------------
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}];
        check(service.monitorCount === 2, "screens create monitor states");
        expectCapability("DISPLAY1", "unknown", "new screen is unknown");
        expectCapability("DISPLAY2", "unknown", "second screen is unknown");
        check(service.stateFor("DISPLAY1").route === ""
            && service.stateFor("DISPLAY1").brightnessKnown === false,
            "unknown route and brightness are not invented");
        check(service.stateFor({name: "DISPLAY1"}) === service.stateFor("DISPLAY1"),
            "stateFor accepts a screen object");
        check(service.stateFor("MISSING") === null && service.stateFor(null) === null
            && service.stateFor({}) === null, "missing screen has no state");
        check(!service.canWrite("DISPLAY1") && !service.interactive("DISPLAY1"),
            "unknown route is neither interactive nor writable");
        check(service.write("DISPLAY1", 0.5) === false, "disabled write on a screen is refused");
        check(service.refusedWrites === 1, "disabled refusal is counted");
        check(service.queryMonitor("DISPLAY1") === false && service.queryRequests === 0,
            "enabling is required before querying");
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY1"}, {name: ""}, null];
        check(service.monitorCount === 1, "duplicate and empty screen names are collapsed");
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}];

        // --- Enabled but no backend or a failed component ---------------------
        service.enabled = true;
        check(service.status === "loading", "enabled without a backend is loading");
        check(service.reason.indexOf("Waiting") >= 0, "loading reason names the wait");
        check(service.canQuery() === false, "loading cannot query");
        check(service.queryMonitor("DISPLAY1") === false && service.queryRequests === 0,
            "loading query stays inert");
        check(service.write("DISPLAY1", 0.5) === false, "loading refuses writes");

        service.backendError = "Fixture component failure";
        check(service.status === "unavailable", "component failure is unavailable");
        check(service.lastError === service.backendError
            && service.reason === service.backendError, "component failure is reported verbatim");
        check(service.canQuery() === false, "unavailable backend cannot query");
        check(service.queryMonitor("DISPLAY1") === false, "unavailable query is refused");
        check(service.write("DISPLAY1", 0.5) === false, "unavailable write is refused");
        service.backendError = "";
        check(service.status === "loading", "clearing the component failure returns to loading");

        service.backend = backend;
        check(service.status === "observing" && service.ready && service.nativeRequested,
            "injected backend becomes observable");
        check(service.strictBackend, "strict route API is feature-detected");
        check(service.reason.indexOf("read-only") >= 0, "default reason is read-only");
        check(!service.strictRoutesEnabled && backend.strictEnableCalls === 0,
            "strict routes are not enabled before a write is requested");

        // --- Every capability state -------------------------------------------
        backend.probeRoute = "wmi";
        backend.probeAvailable = true;
        backend.probeLevel = 0.42;
        check(service.queryMonitor("DISPLAY1") === true, "route query is requested");
        expectCapability("DISPLAY1", "querying", "query in flight");
        check(backend.queryCalls === 1 && backend.probeCalls === 0,
            "query never falls back to probe");
        check(backend.pendingQueries === 1,
            "the query completes only when the worker delivers it");
        check(service.queryRequests === 1, "query request counted");
        check(service.queryMonitor("DISPLAY1") === false, "duplicate query is refused");
        check(!service.canWrite("DISPLAY1") && !service.interactive("DISPLAY1"),
            "querying route is neither interactive nor writable");
        expectRefused("DISPLAY1", 0.5, "write during query");
        backend.deliverQuery();
        expectCapability("DISPLAY1", "hardware", "WMI hardware route");
        check(service.stateFor("DISPLAY1").route === "wmi", "WMI route is named");
        check(service.routeLabel("wmi") === "WMI", "WMI label");
        check(service.stateFor("DISPLAY1").brightnessKnown
            && Math.abs(service.stateFor("DISPLAY1").brightness - 0.42) < 0.000001,
            "queried brightness is recorded");
        check(service.stateFor("DISPLAY1").lastConfirmedKnown
            && Math.abs(service.stateFor("DISPLAY1").lastConfirmed - 0.42) < 0.000001,
            "queried brightness becomes the last confirmed value");
        check(service.stateFor("DISPLAY1").lastOutcome === "queried", "query outcome");

        backend.probeRoute = "lcd";
        backend.probeLevel = 0.6;
        check(service.queryMonitor("DISPLAY1") === true, "re-query for LCD");
        backend.deliverQuery();
        expectCapability("DISPLAY1", "hardware", "LCD hardware route");
        check(service.stateFor("DISPLAY1").route === "lcd"
            && service.routeLabel("lcd") === "\\\\.\\LCD", "LCD route and label");

        backend.probeRoute = "ddc";
        backend.probeLevel = 0.55;
        check(service.queryMonitor("DISPLAY1") === true, "re-query for DDC");
        backend.deliverQuery();
        expectCapability("DISPLAY1", "hardware", "DDC hardware route");
        check(service.stateFor("DISPLAY1").route === "ddc"
            && service.routeLabel("ddc") === "DDC/CI", "DDC route and label");

        backend.probeRoute = "ddc";
        backend.probeAvailable = false;
        backend.probeLevel = 1;
        check(service.queryMonitor("DISPLAY2") === true, "query second monitor");
        backend.deliverQuery();
        expectCapability("DISPLAY2", "failed", "denied DDC route");
        check(service.stateFor("DISPLAY2").route === "ddc"
            && service.stateFor("DISPLAY2").lastError.indexOf("DDC/CI") >= 0,
            "failed route names DDC/CI");
        check(!service.stateFor("DISPLAY2").brightnessKnown, "failed read is not a brightness");
        check(!service.canWrite("DISPLAY2"), "failed route is not writable");
        expectRefused("DISPLAY2", 0.5, "write to a failed route");

        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}, {name: "DISPLAY3"}];
        backend.probeRoute = "software";
        backend.probeAvailable = false;
        check(service.queryMonitor("DISPLAY3") === true, "query software monitor");
        backend.deliverQuery();
        expectCapability("DISPLAY3", "software-only", "software gamma route");
        check(service.stateFor("DISPLAY3").route === "software"
            && service.routeLabel("software") === "software (gamma)", "software route label");
        check(!service.canWrite("DISPLAY3"), "software route is not writable without its opt-in");
        expectRefused("DISPLAY3", 0.5, "software write without opt-in");
        check(backend.setCalls === 0, "no write reached the backend");

        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}, {name: "DISPLAY3"},
            {name: "DISPLAY4"}];
        backend.probeRoute = "";
        check(service.queryMonitor("DISPLAY4") === true, "query unsupported monitor");
        backend.deliverQuery();
        expectCapability("DISPLAY4", "unsupported", "no route");
        check(service.stateFor("DISPLAY4").lastError.indexOf("no brightness route") >= 0,
            "unsupported reason is explicit");
        check(service.routeLabel("") === "no route", "empty route label");
        expectRefused("DISPLAY4", 0.5, "write to an unsupported monitor");

        // --- Read-only refuses every write ------------------------------------
        backend.probeRoute = "wmi";
        backend.probeAvailable = true;
        backend.probeLevel = 0.42;
        check(service.queryMonitor("DISPLAY1") === true, "restore DISPLAY1 hardware route");
        backend.deliverQuery();
        expectCapability("DISPLAY1", "hardware", "DISPLAY1 hardware again");
        check(!service.canWrite("DISPLAY1") && !service.interactive("DISPLAY1"),
            "controls opt-in is absent");
        expectRefused("DISPLAY1", 0.5, "read-only write");
        check(backend.setCalls === 0 && backend.probeCalls === 0,
            "read-only observation sent no write or probe");

        // --- Strict controls, coalescing and value guards ---------------------
        service.controlsEnabled = true;
        check(service.strictBackend && service.writesAllowed, "strict writes are allowed");
        check(service.interactive("DISPLAY1") && service.canWrite("DISPLAY1"),
            "hardware route becomes interactive and writable");
        const firstWriteResync = service.stateFor("DISPLAY1").resyncSerial;
        check(service.write("DISPLAY1", 0.75) === true, "hardware write is forwarded");
        check(backend.setCalls === 1, "one backend write");
        close(backend.lastSet.value, 0.75, "written value");
        check(backend.lastSet.isDdc === false, "WMI write is not marked DDC");
        check(backend.strictRoutes, "strict routes were enabled before the first write");
        check(backend.sawStrictAtWrite, "the backend observed strict routes during the write");
        check(backend.strictEnableCalls === 1, "strict routes are enabled exactly once");
        check(service.strictRoutesEnabled, "the adapter records strict mode");
        check(service.stateFor("DISPLAY1").writePending,
            "the hardware write is in flight until the worker delivers");
        check(service.stateFor("DISPLAY1").lastOutcome === "pending",
            "in-flight write outcome");
        backend.completeWrite();
        check(!service.stateFor("DISPLAY1").writePending, "the delivered result clears pending");
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "hardware write outcome");
        check(service.stateFor("DISPLAY1").brightnessKnown, "hardware write is recorded");
        close(service.stateFor("DISPLAY1").brightness, 0.75, "hardware write value");
        close(service.stateFor("DISPLAY1").lastConfirmed, 0.75, "confirmed write value");
        check(!service.stateFor("DISPLAY1").latched, "successful write is not latched");
        check(service.stateFor("DISPLAY1").resyncSerial === firstWriteResync,
            "a successful write does not bump the resync serial");
        check(service.writeRequests === 1 && service.everWrote, "write counters");
        // One-way strict: a disable request is refused by the backend and the
        // adapter never even attempts one.
        backend.setStrictRoutes(false);
        check(backend.strictRoutes, "strict routes cannot be disabled");
        check(backend.strictDisableAttempts === 1, "the backend recorded the refused disable");
        check(service.write("DISPLAY1", 0.8) === true, "second write is forwarded");
        backend.completeWrite();
        check(backend.strictEnableCalls === 1, "strict routes are not re-enabled per write");

        const refusedBefore = service.refusedWrites;
        for (const bad of [NaN, Infinity, -Infinity, "0.5", null, undefined, {}]) {
            expectRefused("DISPLAY1", bad, "nonfinite value " + String(bad));
        }
        check(service.refusedWrites === refusedBefore + 7, "invalid values are refused and counted");

        check(service.write("DISPLAY1", -0.5) === true, "negative value is clamped");
        close(backend.lastSet.value, 0, "negative clamps to zero");
        backend.completeWrite();
        check(service.write("DISPLAY1", 1.5) === true, "oversized value is clamped");
        close(backend.lastSet.value, 1, "oversized clamps to one");
        backend.completeWrite();
        check(service.write("DISPLAY1", 0.333) === true, "in-range value passes");
        close(backend.lastSet.value, 0.333, "in-range value");
        backend.completeWrite();

        // --- Software gamma opt-in and clearSoftwareDimming -------------------
        service.softwareEnabled = true;
        check(service.interactive("DISPLAY3"), "software route becomes interactive with its opt-in");
        check(service.write("DISPLAY3", 0.3) === true, "software write is forwarded");
        check(backend.lastSet.screenName === "DISPLAY3", "software write target");
        check(backend.lastSet.isDdc === false, "software write is not a DDC write");
        check(backend.pendingWrites === 0,
            "the software write completed directly inside setBrightness");
        check(service.stateFor("DISPLAY3").lastOutcome === "software-requested",
            "software write outcome");
        check(service.gammaTouched, "software write marks gamma as touched");
        check(!service.stateFor("DISPLAY1").latched, "other monitors keep their policy");
        const monitorsBeforeClear = service.monitorCount;
        const clearCallsBefore = backend.clearCalls;
        service.softwareEnabled = false;
        check(backend.clearCalls === clearCallsBefore + monitorsBeforeClear,
            "turning the gamma opt-in off clears software dimming for every screen");
        check(service.clearedDimmingRequests === monitorsBeforeClear,
            "software dimming clears are counted");
        check(backend.clearedScreens.indexOf("DISPLAY3") >= 0,
            "the software screen's dimming was cleared");
        check(!service.interactive("DISPLAY3"), "software route is read-only again");
        service.softwareEnabled = true;

        // --- Pending write: terminal-only completion and coalescing ----------
        backend.probeRoute = "wmi";
        backend.probeAvailable = true;
        backend.probeLevel = 0.5;
        check(service.queryMonitor("DISPLAY1") === true, "restore WMI for pending test");
        backend.deliverQuery();
        expectCapability("DISPLAY1", "hardware", "DISPLAY1 ready for pending test");
        close(service.stateFor("DISPLAY1").lastConfirmed, 0.5,
            "query refreshed the confirmed value");
        const pendingStart = backend.setCalls;
        check(service.write("DISPLAY1", 0.2) === true, "start a pending strict write");
        check(backend.setCalls === pendingStart + 1, "pending write reached the backend");
        check(service.stateFor("DISPLAY1").writePending, "write is pending");
        check(service.interactive("DISPLAY1"),
            "a pending write does not disable the slider");
        check(!service.canWrite("DISPLAY1"), "writeReady is false while pending");
        check(service.stateFor("DISPLAY1").lastOutcome === "pending", "pending outcome");
        // Legacy completion is inert; only the strict result may settle a write.
        backend.brightnessSetFinished("DISPLAY1", true);
        check(service.stateFor("DISPLAY1").writePending,
            "legacy brightnessSetFinished does not clear a strict write");
        backend.routeChanged("DISPLAY1", "software");
        check(service.stateFor("DISPLAY1").writePending,
            "a route change does not clear a strict write");
        const pendingQueries = backend.queryCalls;
        check(service.queryMonitor("DISPLAY1") === false, "route refresh waits for a pending write");
        check(backend.queryCalls === pendingQueries, "refresh during a pending write is inert");
        // Coalesce the newest drag target without a second backend call.
        check(service.write("DISPLAY1", 0.8) === true, "a second value coalesces while pending");
        check(backend.setCalls === pendingStart + 1, "the coalesced value is not sent yet");
        check(service.coalescedWrites === 1, "the coalesced write is counted");
        check(service.stateFor("DISPLAY1").queuedValue === 0.8,
            "the latest drag target is retained");
        check(service.write("DISPLAY1", 0.9) === true, "the newest target replaces the queue");
        check(service.stateFor("DISPLAY1").queuedValue === 0.9, "the newest target wins");
        check(service.coalescedWrites === 2, "each coalesced write is counted");
        // Terminal result for the first write sends the queued target.
        backend.completeWrite();
        close(service.stateFor("DISPLAY1").lastConfirmed, 0.2,
            "the terminal result confirms the first value");
        check(service.stateFor("DISPLAY1").writePending,
            "the queued target is sent immediately after the terminal result");
        check(backend.setCalls === pendingStart + 2, "the queued write reached the backend");
        close(backend.lastSet.value, 0.9, "the queued write carries the newest target");
        check(service.interactive("DISPLAY1"), "the slider remains interactive across coalescing");
        backend.completeWrite();
        check(!service.stateFor("DISPLAY1").writePending, "the terminal result clears pending");
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "the coalesced write settles as a hardware request");
        close(service.stateFor("DISPLAY1").brightness, 0.9, "final brightness");

        // Duplicate and foreign results are ignored.
        const staleCalls = backend.setCalls;
        backend.brightnessWriteResult("DISPLAY1", 0.9, true, "wmi", "");
        backend.brightnessWriteResult("DISPLAY9", 0.4, true, "wmi", "");
        check(backend.setCalls === staleCalls, "stale results sent no write");
        close(service.stateFor("DISPLAY1").brightness, 0.9, "stale results change nothing");
        check(backend.pendingWrites === 0, "no write is left in flight");

        // A failure drops every queued target and snaps the DISPLAYED value
        // back to the last confirmed level, while leaving the slider
        // interactive for a retry. The probe carries the same value binding
        // and resync hook as the staged OSD slider.
        backend.writeOk = false;
        backend.writeError = "DDC/CI write denied";
        check(service.write("DISPLAY1", 0.15) === true, "start a failing pending write");
        osdProbe.record = service.stateFor("DISPLAY1");
        close(osdProbe.displayed, 0.9, "the display binds the last confirmed value");
        osdProbe.displayed = 0.05; // The drag breaks the value binding.
        check(service.write("DISPLAY1", 0.05) === true, "queue a second target behind it");
        const failResync = service.stateFor("DISPLAY1").resyncSerial;
        const failSetCalls = backend.setCalls;
        backend.completeWrite();
        check(!service.stateFor("DISPLAY1").writePending, "a failed result clears pending");
        check(!service.stateFor("DISPLAY1").hasQueuedWrite,
            "a failed result drops the queued target");
        check(backend.setCalls === failSetCalls, "no queued write is sent after a failure");
        check(service.stateFor("DISPLAY1").lastOutcome === "failed", "failure outcome");
        check(service.stateFor("DISPLAY1").lastError.indexOf("DDC/CI write denied") >= 0,
            "backend failure text is surfaced");
        closedSnap();
        check(service.stateFor("DISPLAY1").resyncSerial === failResync + 1,
            "a terminal failure bumps the resync serial");
        check(osdProbe.resyncs === 1,
            "the resync serial restored the display binding exactly once");
        close(osdProbe.displayed, 0.9,
            "the displayed value snaps back to the confirmed level");
        check(service.interactive("DISPLAY1"), "a failed write keeps the slider interactive");
        check(!service.stateFor("DISPLAY1").latched, "a failed write is not a route latch");
        backend.writeOk = true;
        backend.writeError = "";
        check(service.write("DISPLAY1", 0.6) === true, "the user can retry after a failure");
        backend.completeWrite();
        close(service.stateFor("DISPLAY1").brightness, 0.6, "retry confirms the new value");
        check(service.stateFor("DISPLAY1").resyncSerial === failResync + 1,
            "a successful retry does not bump the resync serial");
        check(osdProbe.resyncs === 1, "a successful retry does not rebind the display");

        // A result that reports another route is a failure, never success.
        backend.resultRoute = "lcd";
        check(service.write("DISPLAY1", 0.25) === true, "start a wrong-route pending write");
        backend.completeWrite();
        check(service.stateFor("DISPLAY1").lastOutcome === "failed",
            "a wrong-route result is a failure");
        check(service.stateFor("DISPLAY1").lastError.indexOf("WMI") >= 0
            && service.stateFor("DISPLAY1").lastError.indexOf("LCD") >= 0,
            "the wrong-route failure names both routes");
        close(service.stateFor("DISPLAY1").brightness, 0.6,
            "a wrong-route failure snaps back to the confirmed value");
        backend.resultRoute = "";
        // A synchronous dispatch rejection is a terminal failure of the
        // attempted write: it snaps the displayed value back too.
        backend.throwOnSet = true;
        const throwResync = service.stateFor("DISPLAY1").resyncSerial;
        const throwResyncs = osdProbe.resyncs;
        check(service.write("DISPLAY1", 0.2) === false,
            "a dispatch throw refuses the write");
        check(service.stateFor("DISPLAY1").lastOutcome === "failed",
            "the synchronous throw is a terminal failure");
        check(service.stateFor("DISPLAY1").lastError.indexOf("dispatch failed") >= 0,
            "the dispatch failure text is surfaced");
        check(service.stateFor("DISPLAY1").resyncSerial === throwResync + 1,
            "the direct rejection bumps the resync serial");
        check(osdProbe.resyncs === throwResyncs + 1,
            "the direct rejection rebound the display");
        close(osdProbe.displayed, 0.6, "the display snapped back after the throw");
        backend.throwOnSet = false;

        // --- Authorization changes drop queued targets immediately ------------
        // The review's case: queue a drag target, revoke the controls opt-in,
        // complete the first write OK: zero further backend calls.
        const dropResync = service.stateFor("DISPLAY1").resyncSerial;
        const dropResyncs = osdProbe.resyncs;
        check(service.write("DISPLAY1", 0.35) === true, "start a write before revoking controls");
        osdProbe.displayed = 0.8; // The drag target that will never be applied.
        check(service.write("DISPLAY1", 0.8) === true, "queue the drag target");
        check(service.stateFor("DISPLAY1").hasQueuedWrite, "the drag target is queued");
        service.controlsEnabled = false;
        check(!service.stateFor("DISPLAY1").hasQueuedWrite,
            "revoking the controls opt-in drops the queued target immediately");
        check(service.stateFor("DISPLAY1").writePending,
            "the in-flight write keeps running after the queue is dropped");
        check(service.stateFor("DISPLAY1").resyncSerial === dropResync + 1,
            "dropping the queue resyncs the displayed drag target");
        check(osdProbe.resyncs === dropResyncs + 1,
            "the dropped drag target rebound the display");
        close(osdProbe.displayed, service.stateFor("DISPLAY1").brightness,
            "the display snapped back to the confirmed level");
        const dropSetCalls = backend.setCalls;
        backend.completeWrite();
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "the in-flight write still settles normally");
        close(service.stateFor("DISPLAY1").brightness, 0.35,
            "the in-flight write still confirms its own value");
        check(backend.setCalls === dropSetCalls,
            "completing the first write OK sent zero further backend calls");
        check(backend.pendingWrites === 0, "nothing was queued behind the dropped target");
        check(!service.interactive("DISPLAY1"), "revoked controls keep the slider read-only");
        service.controlsEnabled = true;

        // A latched policy failure drops queued targets the moment it latches,
        // whatever latched it.
        check(service.write("DISPLAY1", 0.4) === true, "start a write before a policy latch");
        check(service.write("DISPLAY1", 0.45) === true, "queue a target behind it");
        const policyResync = service.stateFor("DISPLAY1").resyncSerial;
        service.policyError = "Simulated strict-route policy failure.";
        check(!service.stateFor("DISPLAY1").hasQueuedWrite,
            "a latched policy failure drops the queued target immediately");
        check(service.stateFor("DISPLAY1").resyncSerial === policyResync + 1,
            "the policy drop also resyncs the display");
        const policySetCalls = backend.setCalls;
        backend.completeWrite();
        close(service.stateFor("DISPLAY1").brightness, 0.4,
            "the in-flight write confirms before the policy refusal applies");
        check(backend.setCalls === policySetCalls,
            "the queued target was not dispatched after the policy latch");
        check(!service.interactive("DISPLAY1"), "a latched policy failure blocks the slider");
        service.policyError = "";
        check(service.interactive("DISPLAY1"), "clearing the policy failure restores the slider");

        // Every refusal of a write attempt snaps the dragged display back:
        // nothing was dispatched, so the confirmed value must be restored
        // exactly like a terminal failure.
        const refuseResync = service.stateFor("DISPLAY1").resyncSerial;
        const refuseResyncs = osdProbe.resyncs;
        expectRefused("DISPLAY1", NaN, "refusal after the drop tests");
        check(service.stateFor("DISPLAY1").resyncSerial === refuseResync + 1,
            "a refused write bumps the resync serial");
        check(osdProbe.resyncs === refuseResyncs + 1,
            "the refused write rebound the display");
        close(osdProbe.displayed, service.stateFor("DISPLAY1").brightness,
            "the refused write restored the confirmed display value");

        // --- Old-pin backend: Interactive is refused, slider read-only --------
        check(legacy.enabled === false && legacyBackend.queryCalls === 0,
            "legacy fixture is inert");
        check(typeof legacyBackend.strictRoutes === "undefined",
            "the old-pin fixture has no strictRoutes property");
        check(typeof legacyBackend.brightnessWriteResult === "undefined",
            "the old-pin fixture has no brightnessWriteResult signal");
        legacy.screens = [{name: "OLD1"}];
        legacy.enabled = true;
        legacy.backend = legacyBackend;
        check(legacy.queryMonitor("OLD1") === true, "old-pin route query works");
        expectCapabilityOn(legacy, "OLD1", "hardware", "old-pin hardware route");
        check(!legacy.strictBackend, "the old-pin backend is not strict-capable");
        legacy.controlsEnabled = true;
        check(!legacy.writesAllowed, "Interactive is refused without strict routes");
        check(!legacy.interactive("OLD1") && !legacy.canWrite("OLD1"),
            "the slider stays read-only on the old pin");
        check(legacy.reason.indexOf("strict-route backend") >= 0,
            "the read-only reason names the strict-route backend");
        const legacyWrites = legacy.writeRequests;
        check(legacy.write("OLD1", 0.5) === false, "the old-pin write is refused");
        check(legacyBackend.setCalls === 0, "no legacy setBrightness call was made");
        check(legacy.writeRequests === legacyWrites, "a refused write is not forwarded");
        check(legacy.refusedWrites === 1, "the old-pin refusal is counted");
        check(legacy.lastError.indexOf("strict-route backend") >= 0,
            "the write refusal explains the missing backend support");
        check(!legacy.strictRoutesEnabled, "strict mode is never claimed on the old pin");
        // Toggling the gamma opt-in on a backend without clearSoftwareDimming
        // must stay guard-safe.
        legacy.softwareEnabled = true;
        legacy.softwareEnabled = false;
        check(legacy.clearedDimmingRequests === 0,
            "the old pin has no clearSoftwareDimming to call");

        // A strict-looking backend without the result signal is also refused.
        legacy.backend = partialBackend;
        check(!legacy.strictBackend, "strictRoutes alone is not enough");
        check(!legacy.interactive("OLD1"), "a partial strict backend stays read-only");
        legacy.backend = legacyBackend;

        // --- Latched strict policy failure -----------------------------------
        blocked.screens = [{name: "BLOCK1"}];
        blocked.enabled = true;
        blocked.backend = blockedBackend;
        blockedBackend.refuseStrict = true;
        blockedBackend.probeRoute = "wmi";
        blockedBackend.probeAvailable = true;
        blockedBackend.probeLevel = 0.4;
        check(blocked.queryMonitor("BLOCK1") === true, "blocked fixture route query");
        blockedBackend.deliverQuery();
        expectCapabilityOn(blocked, "BLOCK1", "hardware", "blocked fixture hardware route");
        blocked.controlsEnabled = true;
        check(blocked.strictBackend, "the blocking fixture is strict-capable");
        check(blocked.queryIdsSupported, "the blocking fixture carries query ids");
        // The review's exact case: the first denied drag snaps back. The
        // confirmed level is 0.4 and the drag moved the display to 0.9, so
        // the strict-enable refusal must bump the resync serial from 0 and
        // restore 0.4.
        blockedProbe.record = blocked.stateFor("BLOCK1");
        close(blockedProbe.displayed, 0.4, "the display binds the confirmed 0.4");
        blockedProbe.displayed = 0.9; // The drag breaks the value binding.
        check(blocked.stateFor("BLOCK1").resyncSerial === 0,
            "no resync happened before the denied write");
        check(blocked.write("BLOCK1", 0.9) === false,
            "a strict-route enable refusal refuses the write");
        check(blocked.stateFor("BLOCK1").resyncSerial === 1,
            "the strict-enable refusal bumps the resync serial from 0 to 1");
        check(blockedProbe.resyncs === 1, "the denied drag's display was rebound");
        close(blockedProbe.displayed, 0.4, "the displayed 0.9 snapped back to 0.4");
        check(blockedBackend.setCalls === 0, "no write reached a backend without strict routes");
        check(blockedBackend.strictRefusals === 1,
            "the backend recorded the refused strict enable");
        check(blocked.policyError.length > 0, "the policy failure is latched");
        check(blocked.lastError === blocked.policyError, "the policy failure is the last error");
        check(!blocked.writesAllowed && !blocked.interactive("BLOCK1"),
            "a latched policy failure keeps the slider read-only");
        check(!blocked.stateFor("BLOCK1").latched,
            "a policy failure is not a per-monitor route latch");
        blockedBackend.refuseStrict = false;
        check(blocked.refreshRoutes() === 1, "a user refresh retries after a policy failure");
        blockedBackend.deliverQuery();
        check(blocked.policyError === "", "the refresh clears the policy latch");
        check(blocked.interactive("BLOCK1"), "the monitor becomes interactive again");
        check(blocked.write("BLOCK1", 0.45) === true, "the retried write is forwarded");
        check(blockedBackend.strictRoutes, "strict routes are enabled on the retry");
        blockedBackend.completeWrite();
        close(blocked.stateFor("BLOCK1").brightness, 0.45, "the retried write confirms");
        check(blocked.stateFor("BLOCK1").resyncSerial === 1,
            "the successful retry does not bump the resync serial again");

        // --- Automatic observation and explicit refresh -----------------------
        check(observation.enabled === false && observationBackend.queryCalls === 0,
            "observation fixture is inert");
        observation.screens = [{name: "OBS1"}, {name: "OBS2"}];
        observation.enabled = true;
        observation.backend = observationBackend;
        check(observation.beginObservation() === true, "automatic observation runs once");
        check(observationBackend.queryCalls === 2, "automatic observation queries every screen");
        check(observationBackend.pendingQueries === 2,
            "automatic observation leaves the queries queued");
        check(observation.autoObservationDone, "automatic observation is marked done");
        check(observation.beginObservation() === false, "automatic observation is not repeated");
        check(observationBackend.queryCalls === 2, "second automatic observation is inert");
        check(observationBackend.probeCalls === 0, "automatic observation never probes");
        observationBackend.deliverQuery();
        observationBackend.deliverQuery();
        expectCapabilityOn(observation, "OBS1", "hardware", "automatic observation settles a route");

        observation.controlsEnabled = true;
        observation.softwareEnabled = true;
        observationBackend.probeRoute = "software";
        check(observation.queryMonitor("OBS1") === true, "query the software route");
        observationBackend.deliverQuery();
        expectCapabilityOn(observation, "OBS1", "software-only", "software route observed");
        check(observation.write("OBS1", 0.5) === true, "software write under strict routes");
        check(observation.gammaTouched, "software write marks gamma as touched");
        // A directly completed software failure is a terminal rejection: it
        // settles as failed and bumps the resync serial.
        observationBackend.writeOk = false;
        const obsResync = observation.stateFor("OBS1").resyncSerial;
        check(observation.write("OBS1", 0.25) === true, "a directly failing software write");
        check(observation.stateFor("OBS1").lastOutcome === "failed",
            "the direct software rejection settles as a failure");
        check(observation.stateFor("OBS1").resyncSerial === obsResync + 1,
            "the direct software rejection bumps the resync serial");
        observationBackend.writeOk = true;
        check(observation.beginObservation() === false, "gamma state blocks automatic re-query");
        check(observationBackend.queryCalls === 3, "blocked automatic re-query sends nothing");
        check(observation.refreshRoutes() === 2, "explicit refresh is allowed");
        check(observationBackend.queryCalls === 5, "explicit refresh queries every screen");
        observationBackend.deliverQuery();
        observationBackend.deliverQuery();

        recovery.screens = [{name: "REC1"}];
        recovery.enabled = true;
        recovery.backend = recoveryBackend;
        recoveryBackend.probeRoute = "software";
        check(recovery.queryMonitor("REC1") === true, "recovery fixture route query");
        recoveryBackend.deliverQuery();
        recovery.controlsEnabled = true;
        recovery.softwareEnabled = true;
        check(recovery.write("REC1", 0.4) === true, "recovery fixture software write");
        check(recovery.gammaTouched, "software write marks gamma in the recovery fixture");
        const recoveryQueries = recoveryBackend.queryCalls;
        check(recovery.beginObservation() === false, "gamma state blocks first automatic query");
        check(recoveryBackend.queryCalls === recoveryQueries, "blocked first query sends nothing");
        check(recovery.refreshRoutes() === 1, "explicit refresh still works");
        check(recoveryBackend.queryCalls === recoveryQueries + 1, "explicit refresh reaches backend");
        recoveryBackend.deliverQuery();

        // --- Generation: a reconnected monitor is not authorized by a stale query
        // The review's ordering for finding 1: query A on the old record,
        // disconnect/reconnect, query B on the fresh record, then deliver A's
        // completion first. A's id was issued to the old record and never
        // matches the fresh one, so it is discarded; only B authorizes.
        generationCase.screens = [{name: "GEN1"}, {name: "GEN2"}];
        generationCase.enabled = true;
        generationCase.backend = generationBackend;
        generationBackend.probeRoute = "wmi";
        generationBackend.probeAvailable = true;
        generationBackend.probeLevel = 0.5;
        check(generationCase.queryMonitor("GEN2") === true, "query A before unplug");
        expectCapabilityOn(generationCase, "GEN2", "querying", "query A is in flight before unplug");
        const oldGeneration = generationCase.stateFor("GEN2").generation;
        const queryCallsBeforeUnplug = generationBackend.queryCalls;
        const requestsBeforeUnplug = generationCase.queryRequests;
        const queryAId = generationCase.stateFor("GEN2").queryId;
        generationCase.screens = [{name: "GEN1"}];
        check(generationCase.monitorCount === 1, "unplugged screens leave the monitor list");
        check(generationCase.stateFor("GEN2") === null, "unplugged screen has no state");
        generationCase.screens = [{name: "GEN1"}, {name: "GEN2"}];
        expectCapabilityOn(generationCase, "GEN2", "unknown", "re-plugged screen has no stale state");
        check(generationCase.stateFor("GEN2").route === "", "re-plugged screen has no stale route");
        check(generationCase.stateFor("GEN2").generation > oldGeneration,
            "removing and re-adding a screen bumps its record generation");
        check(generationCase.queryMonitor("GEN2") === true, "query B on the reconnected record");
        expectCapabilityOn(generationCase, "GEN2", "querying", "query B is in flight");
        const queryBId = generationCase.stateFor("GEN2").queryId;
        check(queryBId > queryAId, "the reconnected record's id postdates A's");
        check(generationBackend.queryCalls === queryCallsBeforeUnplug + 1,
            "the re-plug sent exactly one new query");
        check(generationCase.queryRequests === requestsBeforeUnplug + 1,
            "the re-query is counted");
        generationBackend.deliverQuery(queryAId);
        expectCapabilityOn(generationCase, "GEN2", "querying",
            "A's stale completion does not authorize the new record");
        check(generationCase.stateFor("GEN2").brightnessKnown === false,
            "A's level is discarded with its request");
        generationBackend.deliverQuery(queryBId);
        expectCapabilityOn(generationCase, "GEN2", "hardware",
            "B's completion authorizes the new record");
        close(generationCase.stateFor("GEN2").brightness, 0.5, "B's level is recorded");
        check(generationCase.stateFor("GEN2").queryId === queryBId,
            "the accepted query is tagged with this record's id");

        // A completion carrying an id no request ever issued, and the plain
        // queried signal while ids are supported, are both ignored.
        check(generationCase.queryMonitor("GEN2") === true, "query C before a second unplug");
        const queryCId = generationCase.stateFor("GEN2").queryId;
        generationBackend.queryFinished(test.allocQueryId(), "GEN2", true, true, 0.9);
        generationBackend.queried("GEN2", true, true, 0.9);
        expectCapabilityOn(generationCase, "GEN2", "querying",
            "an unissued id and the plain queried signal settle nothing");
        check(generationCase.stateFor("GEN2").brightnessKnown === false,
            "the unmatched deliveries invented no level");
        check(generationBackend.queryCalls === queryCallsBeforeUnplug + 2,
            "an unmatched result sends no query");

        // A completion delivered while the screen is absent is consumed and
        // cannot resurrect state.
        generationCase.screens = [{name: "GEN1"}];
        generationBackend.deliverQuery(queryCId);
        check(generationCase.stateFor("GEN2") === null,
            "a late completion does not resurrect the record");
        check(generationBackend.queryCalls === queryCallsBeforeUnplug + 2,
            "the unplug sent no extra query");
        check(generationCase.queryRequests === requestsBeforeUnplug + 2,
            "the unplug re-issued no request");
        generationCase.screens = [{name: "GEN1"}, {name: "GEN2"}];
        expectCapabilityOn(generationCase, "GEN2", "unknown",
            "the twice-reconnected screen starts fresh");

        // The review's ordering for finding 2: a deferred older request can
        // complete AFTER a newer one (the backend's startup gate settles
        // before draining deferred work). The newer request's completion is
        // delivered first and is accepted on its own id; the older deferred
        // completion is then discarded.
        check(generationCase.queryMonitor("GEN2") === true, "query A2 on the second record");
        const a2Id = generationCase.stateFor("GEN2").queryId;
        generationCase.screens = [{name: "GEN1"}];
        generationCase.screens = [{name: "GEN1"}, {name: "GEN2"}];
        check(generationCase.queryMonitor("GEN2") === true, "query B2 on the third record");
        const b2Id = generationCase.stateFor("GEN2").queryId;
        check(b2Id > a2Id, "B2's id postdates A2's");
        generationBackend.deliverQuery(b2Id);
        expectCapabilityOn(generationCase, "GEN2", "hardware",
            "the newer request is accepted even when it completes first");
        close(generationCase.stateFor("GEN2").brightness, 0.5, "B2's level is recorded");
        generationBackend.deliverQuery(a2Id);
        expectCapabilityOn(generationCase, "GEN2", "hardware",
            "the older deferred completion is discarded afterwards");
        close(generationCase.stateFor("GEN2").brightness, 0.5,
            "the older deferred completion changes nothing");
        check(generationCase.stateFor("GEN2").queryId === b2Id,
            "the third record is tagged with its own request");

        // Removing a screen mid-write drops the pending record and its queued
        // target without a crash or a dispatch.
        generationCase.controlsEnabled = true;
        check(generationCase.write("GEN2", 0.6) === true, "start a write then unplug");
        check(generationCase.write("GEN2", 0.7) === true, "queue a target behind it");
        const unplugSetCalls = generationBackend.setCalls;
        test.unpluggedRecord = generationCase.stateFor("GEN2");
        generationCase.screens = [{name: "GEN1"}];
        generationBackend.completeWrite();
        check(generationCase.stateFor("GEN2") === null, "mid-write unplug drops state");
        check(generationBackend.setCalls === unplugSetCalls,
            "the completed write dispatched nothing for the absent screen");
        generationCase.screens = [{name: "GEN1"}, {name: "GEN2"}];
        expectCapabilityOn(generationCase, "GEN2", "unknown", "mid-write unplug is not resurrected");
        check(!generationCase.stateFor("GEN2").writePending,
            "a re-added screen has no pending write");
        check(!generationCase.stateFor("GEN2").hasQueuedWrite,
            "a re-added screen has no queued target");

        // --- Finding 1: disable/re-enable with a stale delivery ---------------
        // The review's exact sequence: query A at 0.2, disable, re-enable,
        // query B at 0.8, then deliver A's completion. A's id was issued
        // before the reset; ids never repeat, so it cannot match B's record.
        disableCase.screens = [{name: "DIS1"}];
        disableCase.enabled = true;
        disableCase.backend = disableBackend;
        disableBackend.probeRoute = "wmi";
        disableBackend.probeAvailable = true;
        disableBackend.probeLevel = 0.2;
        check(disableCase.queryMonitor("DIS1") === true, "query A at 0.2 before disabling");
        const staleDisableId = disableCase.stateFor("DIS1").queryId;
        check(staleDisableId > 0, "query A carries a backend-issued id");
        disableCase.enabled = false;
        check(!disableCase.stateFor("DIS1").querying,
            "disable clears the outstanding query");
        disableCase.enabled = true;
        disableBackend.probeLevel = 0.8;
        check(disableCase.queryMonitor("DIS1") === true, "query B at 0.8 after re-enabling");
        const freshDisableId = disableCase.stateFor("DIS1").queryId;
        check(freshDisableId > staleDisableId, "ids strictly increase and never repeat");
        disableBackend.deliverQuery(staleDisableId);
        expectCapabilityOn(disableCase, "DIS1", "querying",
            "A's stale completion does not consume B's result");
        check(disableCase.stateFor("DIS1").brightnessKnown === false,
            "A's 0.2 is discarded, not displayed");
        disableBackend.deliverQuery(freshDisableId);
        expectCapabilityOn(disableCase, "DIS1", "hardware",
            "B's completion authorizes the current record");
        close(disableCase.stateFor("DIS1").brightness, 0.8,
            "the record holds B's 0.8, never A's 0.2");

        // --- A stale completion's route change -----------------------------------
        // The backend emits routeChanged before queryFinished. Query A resolves
        // to an unreadable WMI route, query B (after a disable/re-enable) to a
        // readable LCD route. B is delivered and accepted first; A then
        // arrives. Its id is rejected, but its routeChanged must not move the
        // authorized record to WMI: the record queries again instead.
        disableBackend.probeRoute = "wmi";
        disableBackend.probeAvailable = false;
        check(disableCase.queryMonitor("DIS1") === true, "query A on an unreadable WMI route");
        const staleRouteId = disableCase.stateFor("DIS1").queryId;
        disableCase.enabled = false;
        disableCase.enabled = true;
        disableBackend.probeRoute = "lcd";
        disableBackend.probeAvailable = true;
        disableBackend.probeLevel = 0.8;
        check(disableCase.queryMonitor("DIS1") === true, "query B on a readable LCD route");
        disableBackend.deliverQuery(disableCase.stateFor("DIS1").queryId);
        expectCapabilityOn(disableCase, "DIS1", "hardware", "B authorizes the LCD route");
        check(disableCase.stateFor("DIS1").route === "lcd", "B's route is LCD");
        const callsBeforeStale = disableBackend.queryCalls;
        disableBackend.deliverQuery(staleRouteId);
        expectCapabilityOn(disableCase, "DIS1", "querying",
            "A's route change withdraws write authorization");
        check(disableBackend.queryCalls === callsBeforeStale + 1,
            "A's route change starts one fresh query");
        check(disableCase.write("DIS1", 0.5) === false,
            "no write dispatches through A's unconfirmed WMI route");
        disableBackend.deliverQuery(disableCase.stateFor("DIS1").queryId);
        expectCapabilityOn(disableCase, "DIS1", "hardware",
            "the fresh query re-authorizes the real route");
        check(disableCase.stateFor("DIS1").route === "lcd",
            "the record is back on the LCD route");

        // --- 64-bit ids --------------------------------------------------------
        // An id past INT_MAX must survive the record and the signal intact.
        const bigId = 4294967297;
        disableCase.stateFor("DIS1").queryId = bigId;
        check(disableCase.stateFor("DIS1").queryId === bigId,
            "a record keeps a 64-bit query id exactly");
        let forwardedId = 0;
        const recordId = id => { forwardedId = id; };
        disableBackend.queryFinished.connect(recordId);
        disableBackend.queryFinished(bigId, "NOPE", false, false, 0);
        disableBackend.queryFinished.disconnect(recordId);
        check(forwardedId === bigId, "queryFinished carries a 64-bit id exactly");
        disableCase.stateFor("DIS1").queryId = 0;
        // Allocation past INT_MAX stays positive and completes.
        test._queryIdSerial = 2147483647;
        check(disableCase.queryMonitor("DIS1") === true, "a query past INT_MAX is issued");
        check(disableCase.stateFor("DIS1").queryId === 2147483648, "the allocated id is not narrowed");
        disableBackend.deliverQuery(disableCase.stateFor("DIS1").queryId);
        expectCapabilityOn(disableCase, "DIS1", "hardware", "a 64-bit id completes and authorizes");

        // --- Wrapper replacement with a stale delivery ------------------------
        // The native singleton is process-wide and survives a wrapper reload,
        // so a late native completion is forwarded by the NEW wrapper. Its id
        // was issued before the reload and cannot match the new request.
        swapCase.screens = [{name: "SWAP1"}];
        swapCase.enabled = true;
        swapCase.backend = swapBackendA;
        swapBackendA.probeRoute = "wmi";
        swapBackendA.probeAvailable = true;
        swapBackendA.probeLevel = 0.2;
        check(swapCase.queryMonitor("SWAP1") === true, "query A through the first wrapper");
        const staleSwapId = swapCase.stateFor("SWAP1").queryId;
        swapCase.backend = swapBackendB;
        expectCapabilityOn(swapCase, "SWAP1", "unknown",
            "a backend swap drops the outstanding query");
        swapBackendB.probeRoute = "wmi";
        swapBackendB.probeAvailable = true;
        swapBackendB.probeLevel = 0.8;
        check(swapCase.queryMonitor("SWAP1") === true, "query B through the second wrapper");
        const freshSwapId = swapCase.stateFor("SWAP1").queryId;
        check(freshSwapId !== staleSwapId, "the two wrappers never issue the same id");
        swapBackendB.queryFinished(staleSwapId, "SWAP1", true, false, 0.2);
        expectCapabilityOn(swapCase, "SWAP1", "querying",
            "the stale id forwarded by the new wrapper is discarded");
        swapBackendA.deliverQuery(staleSwapId);
        expectCapabilityOn(swapCase, "SWAP1", "querying",
            "the detached wrapper's own delivery changes nothing");
        swapBackendB.deliverQuery(freshSwapId);
        expectCapabilityOn(swapCase, "SWAP1", "hardware",
            "B's completion authorizes the swapped record");
        close(swapCase.stateFor("SWAP1").brightness, 0.8,
            "the swapped record holds B's level, never A's 0.2");

        // --- The no-id backend stays read-only --------------------------------
        // The pinned 525786f shape: strict members present, query ids absent.
        // Queries still update read-only display state, but no result can
        // authorize a hardware write or interactive control.
        check(typeof noIdBackend.queryRequest === "undefined",
            "the no-id fake exposes no queryRequest");
        noId.screens = [{name: "NOID1"}];
        noId.enabled = true;
        noId.backend = noIdBackend;
        check(!noId.queryIdsSupported, "the service detects the missing id API");
        noIdBackend.probeRoute = "wmi";
        noIdBackend.probeAvailable = true;
        noIdBackend.probeLevel = 0.5;
        check(noId.queryMonitor("NOID1") === true, "queries still run for display state");
        noIdBackend.deliverQuery();
        expectCapabilityOn(noId, "NOID1", "hardware", "display state still settles read-only");
        close(noId.stateFor("NOID1").brightness, 0.5, "the read-only level is displayed");
        noId.controlsEnabled = true;
        check(noId.strictBackend, "the no-id backend still carries the strict members");
        check(!noId.writesAllowed, "without ids no result can authorize a write");
        check(!noId.interactive("NOID1") && !noId.canWrite("NOID1"),
            "the slider stays read-only on a backend without ids");
        check(noId.reason.indexOf("match query results") >= 0,
            "the reason names the unmatched query results");
        const noIdSetCalls = noIdBackend.setCalls;
        const noIdResync = noId.stateFor("NOID1").resyncSerial;
        check(noId.write("NOID1", 0.7) === false, "the write is refused");
        check(noIdBackend.setCalls === noIdSetCalls
            && noIdBackend.strictEnableCalls === 0,
            "nothing reached the backend, not even a strict enable");
        check(noId.lastError.indexOf("match query results") >= 0,
            "the write refusal explains the id gap");
        check(noId.stateFor("NOID1").resyncSerial === noIdResync + 1,
            "the no-id refusal still snaps the display back");
        check(!noId.strictRoutesEnabled, "strict mode is never claimed without ids");
        check(noIdBackend.legacySetCalls === 0,
            "the read-only gate never fell through to the legacy write path");

        // --- Disable clears every observation --------------------------------
        service.autoObservationDone = true;
        // Drop the extra screens first, as an unplug would; the disable
        // checks below describe the two-screen desktop.
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}];
        check(service.monitorCount === 2, "screen records remain for the facade");
        // A pending write and its queued target are dropped by the disable
        // itself: the controls opt-in stays on, so only enabled=false drops
        // them.
        check(service.write("DISPLAY1", 0.5) === true, "start a pending write before disabling");
        check(service.write("DISPLAY1", 0.55) === true, "queue a drag target before disabling");
        const clearBeforeDisable = backend.clearCalls;
        service.softwareEnabled = false;
        check(backend.clearCalls === clearBeforeDisable + service.monitorCount,
            "disabling the gamma opt-in still clears dimming");
        service.enabled = false;
        check(!service.stateFor("DISPLAY1").writePending
            && !service.stateFor("DISPLAY1").hasQueuedWrite,
            "disable drops the pending and queued write with the record");
        check(service.status === "disabled", "disable returns to disabled");
        service.controlsEnabled = false;
        expectCapability("DISPLAY1", "unknown", "disable resets the capability");
        check(service.stateFor("DISPLAY1").route === ""
            && !service.stateFor("DISPLAY1").brightnessKnown
            && !service.stateFor("DISPLAY1").latched
            && service.stateFor("DISPLAY1").lastOutcome === "none",
            "disable clears route, brightness, latch and outcome");
        check(!service.canWrite("DISPLAY1") && !service.interactive("DISPLAY1"),
            "disable blocks writes");
        expectRefused("DISPLAY1", 0.5, "write while disabled");
        check(service.queryMonitor("DISPLAY1") === false, "disable blocks queries");
        check(service.backend.probeCalls === 0, "disable never probed");
        check(!service.strictRoutesEnabled && service.policyError === "",
            "disable clears the strict mode record and policy error");
        service.enabled = true;
        check(!service.autoObservationDone, "re-enable allows one new automatic observation");
        check(service.status === "observing", "re-enable returns to observing");

        // --- Malformed backend shapes ----------------------------------------
        service.backend = emptyBackend;
        check(service.status === "observing", "an object backend is still observing");
        check(service.queryMonitor("DISPLAY1") === false, "query without a backend method fails");
        expectCapability("DISPLAY1", "failed", "missing query method is a failed route");
        check(service.stateFor("DISPLAY1").lastError.indexOf("query failed") >= 0,
            "missing query method is reported");
        check(service.write("DISPLAY1", 0.5) === false, "failed state refuses writes");
        service.backend = silentBackend;
        service.queryMonitor("DISPLAY1");
        check(service.stateFor("DISPLAY1").state === "querying",
            "non-string method and missing signals leave a bounded querying state");
        service.backend = backend;

        // --- The fake models the id-carrying strict backend -------------------
        // Direct checks of the model itself, independent of any adapter: every
        // timing and argument below comes from the pinned backend source
        // (strictSet, finishSet, setStrictRoutes, clearSoftwareDimming) plus
        // the queryRequest/queryFinished contract.
        check(modelBackend.pendingQueries === 0 && modelBackend.pendingWrites === 0,
            "the model fake starts idle");
        // A legacy write occupies the single worker and completes without a
        // strict result; enabling strict routes is refused until it is done.
        modelBackend.setBrightness("MODEL1", false, 0.5);
        check(modelBackend.legacySetCalls === 1 && modelBackend.pendingWrites === 1,
            "a legacy write occupies the single worker");
        check(modelBackend.methodFor("MODEL1") === "ddc",
            "a legacy unresolved route is written as DDC/CI");
        const eventsBeforeRefusedEnable = fakeModelEvents.length;
        modelBackend.setStrictRoutes(true);
        check(!modelBackend.strictRoutes && modelBackend.strictRefusals === 1,
            "enabling strict routes is refused while a write is active");
        check(fakeModelEvents.length === eventsBeforeRefusedEnable,
            "a refused strict enable emits no strictRoutesChanged");
        modelBackend.completeWrite();
        check(modelBackend.pendingWrites === 0, "the legacy write completed");
        check(fakeModelEvents[fakeModelEvents.length - 1][0] === "setFinished",
            "a legacy write emits brightnessSetFinished only");
        check(fakeModelEvents.every(event => event[0] !== "writeResult"),
            "a legacy write emits no strict result");
        const eventsBeforeEnable = fakeModelEvents.length;
        modelBackend.setStrictRoutes(true);
        check(modelBackend.strictRoutes && modelBackend.strictEnableCalls === 1,
            "enabling strict routes succeeds once idle");
        check(fakeModelEvents.length === eventsBeforeEnable + 1
            && fakeModelEvents[eventsBeforeEnable][0] === "strictRoutesChanged",
            "enabling emits exactly one strictRoutesChanged");
        modelBackend.setStrictRoutes(false);
        check(modelBackend.strictRoutes && modelBackend.strictDisableAttempts === 1,
            "strict routes cannot be disabled");
        check(fakeModelEvents.length === eventsBeforeEnable + 1,
            "a refused disable emits no second strictRoutesChanged");
        // Unresolved route: direct synchronous rejection inside setBrightness.
        const eventsBeforeUnresolved = fakeModelEvents.length;
        modelBackend.setBrightness("MODEL2", false, 0.5);
        check(fakeModelEvents.length === eventsBeforeUnresolved + 2,
            "an unresolved write is rejected directly");
        const unresolvedFinish = fakeModelEvents[fakeModelEvents.length - 2];
        const unresolvedResult = fakeModelEvents[fakeModelEvents.length - 1];
        check(unresolvedFinish[0] === "setFinished" && unresolvedFinish[1][1] === false,
            "the direct rejection first reports brightnessSetFinished(false)");
        check(unresolvedResult[0] === "writeResult"
            && unresolvedResult[1][0] === "MODEL2"
            && Math.abs(unresolvedResult[1][1] - 0.5) < 0.000001
            && unresolvedResult[1][2] === false
            && unresolvedResult[1][3] === "unresolved"
            && unresolvedResult[1][4] === "no route resolved for this screen; query it before writing",
            "the unresolved rejection carries the native route and text");
        // Hardware write: queued completion, and an overlapping write to the
        // same screen is rejected directly.
        modelBackend.probeRoute = "wmi";
        modelBackend.query("MODEL1");
        modelBackend.deliverQuery();
        check(modelBackend.methodFor("MODEL1") === "wmi", "the model query stored the route");
        modelBackend.setBrightness("MODEL1", false, 0.4);
        check(modelBackend.pendingWrites === 1,
            "a hardware write completes only when the worker delivers");
        const eventsBeforeOverlap = fakeModelEvents.length;
        modelBackend.setBrightness("MODEL1", true, 0.6);
        check(fakeModelEvents.length === eventsBeforeOverlap + 2,
            "the overlapping write is rejected directly");
        const overlapResult = fakeModelEvents[fakeModelEvents.length - 1];
        check(overlapResult[0] === "writeResult" && overlapResult[1][0] === "MODEL1"
            && Math.abs(overlapResult[1][1] - 0.6) < 0.000001
            && overlapResult[1][2] === false && overlapResult[1][3] === "wmi"
            && overlapResult[1][4] === "a brightness write is already in flight for this screen",
            "the overlap rejection names the stored route and native text");
        check(modelBackend.pendingWrites === 1, "the overlap added no second write");
        // Completing the in-flight write finalizes bookkeeping first, so a
        // handler can immediately submit the next strict write.
        modelBackend.completeWrite();
        modelBackend.setBrightness("MODEL1", false, 0.6);
        check(modelBackend.pendingWrites === 1,
            "the next strict write is accepted immediately after the result");
        modelBackend.completeWrite();
        // Software route: direct completion inside setBrightness.
        modelBackend.probeRoute = "software";
        modelBackend.query("MODEL3");
        modelBackend.deliverQuery();
        const eventsBeforeSoftware = fakeModelEvents.length;
        modelBackend.writeOk = false;
        modelBackend.setBrightness("MODEL3", false, 0.2);
        check(fakeModelEvents.length === eventsBeforeSoftware + 2,
            "a software write completes directly");
        const softwareResult = fakeModelEvents[fakeModelEvents.length - 1];
        check(softwareResult[0] === "writeResult"
            && softwareResult[1][0] === "MODEL3"
            && Math.abs(softwareResult[1][1] - 0.2) < 0.000001
            && softwareResult[1][2] === false
            && softwareResult[1][3] === "software"
            && softwareResult[1][4] === "software gamma write failed",
            "a failed software write carries the native route and text");
        check(modelBackend.pendingWrites === 0, "the software write left nothing queued");
        modelBackend.writeOk = true;
        modelBackend.setBrightness("MODEL3", false, 0.2);
        check(modelBackend.gammaDimmed["MODEL3"] === true,
            "the software write dimmed the gamma ramp");
        // clearSoftwareDimming emits nothing and only clears dimmed screens.
        const eventsBeforeClear = fakeModelEvents.length;
        modelBackend.clearSoftwareDimming("MODEL3");
        modelBackend.clearSoftwareDimming("MODEL2");
        check(fakeModelEvents.length === eventsBeforeClear,
            "clearSoftwareDimming emits nothing");
        check(modelBackend.clearedScreens.indexOf("MODEL3") >= 0
            && modelBackend.clearedScreens.indexOf("MODEL2") < 0,
            "clearSoftwareDimming only clears screens with retained dimming");
        // Plain queries complete queued, with the native
        // routeChanged-then-queried sequence and isDdc mapping.
        modelBackend.probeRoute = "ddc";
        modelBackend.probeLevel = 0.7;
        modelBackend.probeAvailable = true;
        modelBackend.query("MODEL4");
        modelBackend.probeRoute = "wmi";
        modelBackend.query("MODEL5");
        const eventsBeforeQueries = fakeModelEvents.length;
        modelBackend.deliverQuery();
        modelBackend.deliverQuery();
        check(fakeModelEvents.length === eventsBeforeQueries + 4,
            "each queued query delivers routeChanged then queried");
        check(fakeModelEvents[eventsBeforeQueries][0] === "routeChanged"
            && fakeModelEvents[eventsBeforeQueries][1][0] === "MODEL4",
            "the oldest query completes first");
        check(fakeModelEvents[eventsBeforeQueries + 1][0] === "queried"
            && fakeModelEvents[eventsBeforeQueries + 1][1][0] === "MODEL4"
            && fakeModelEvents[eventsBeforeQueries + 1][1][1] === true
            && fakeModelEvents[eventsBeforeQueries + 1][1][2] === true
            && Math.abs(fakeModelEvents[eventsBeforeQueries + 1][1][3] - 0.7) < 0.000001,
            "the ddc query reports the native argument order and isDdc");
        check(fakeModelEvents[eventsBeforeQueries + 3][0] === "queried"
            && fakeModelEvents[eventsBeforeQueries + 3][1][0] === "MODEL5"
            && fakeModelEvents[eventsBeforeQueries + 3][1][2] === false,
            "the wmi query reports isDdc false");
        // The id-carrying API: queryRequest returns a process-unique,
        // strictly increasing positive id immediately, completions stay
        // queued until delivered and may be delivered out of request order,
        // and every completion also fires the plain queried signal.
        modelBackend.probeRoute = "ddc";
        modelBackend.probeLevel = 0.7;
        modelBackend.probeAvailable = true;
        const idEarly = modelBackend.queryRequest("MODEL6");
        modelBackend.probeRoute = "wmi";
        modelBackend.probeLevel = 0.3;
        const idLate = modelBackend.queryRequest("MODEL7");
        check(idEarly > 0 && idLate > idEarly,
            "queryRequest returns positive, strictly increasing ids");
        check(modelBackend.pendingQueries === 2, "id queries queue until delivered");
        const eventsBeforeIds = fakeModelEvents.length;
        modelBackend.deliverQuery(idLate);
        modelBackend.deliverQuery(idEarly);
        check(fakeModelEvents.length === eventsBeforeIds + 6,
            "each id completion delivers routeChanged, queryFinished and queried");
        const lateEvents = fakeModelEvents.slice(eventsBeforeIds, eventsBeforeIds + 3);
        check(lateEvents[0][0] === "routeChanged" && lateEvents[0][1][0] === "MODEL7",
            "the later request can be delivered first");
        check(lateEvents[1][0] === "queryFinished" && lateEvents[1][1][0] === idLate
            && lateEvents[1][1][1] === "MODEL7" && lateEvents[1][1][2] === true
            && lateEvents[1][1][3] === false
            && Math.abs(lateEvents[1][1][4] - 0.3) < 0.000001,
            "queryFinished carries the id and the native argument order");
        check(lateEvents[2][0] === "queried" && lateEvents[2][1][0] === "MODEL7",
            "the id completion also fires the plain queried signal");
        const earlyEvents = fakeModelEvents.slice(eventsBeforeIds + 3);
        check(earlyEvents[0][0] === "routeChanged" && earlyEvents[0][1][0] === "MODEL6",
            "the earlier request is delivered after the later one");
        check(earlyEvents[1][0] === "queryFinished" && earlyEvents[1][1][0] === idEarly
            && earlyEvents[1][1][1] === "MODEL6" && earlyEvents[1][1][3] === true,
            "the earlier completion carries its own id and isDdc");

        check(backend.legacySetCalls === 0 && observationBackend.legacySetCalls === 0
            && recoveryBackend.legacySetCalls === 0 && blockedBackend.legacySetCalls === 0
            && generationBackend.legacySetCalls === 0 && disableBackend.legacySetCalls === 0
            && swapBackendA.legacySetCalls === 0 && swapBackendB.legacySetCalls === 0
            && noIdBackend.legacySetCalls === 0,
            "the adapter never used a legacy write path");

        destructionCheck.start();
    }

    readonly property Timer destructionCheck: Timer {
        interval: 1
        onTriggered: {
            try {
                check(test.unpluggedRecord === null, "unplugged monitor record is destroyed after event delivery");
                console.log("CAELESTIA_BRIGHTNESS_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
                Qt.quit();
            } catch (error) {
                console.error("CAELESTIA_BRIGHTNESS_FIXTURE_FAIL " + error.message);
                Qt.exit(1);
            }
        }
    }

    // Assertion helper for the failure snap-back that reads the live record.
    function closedSnap(): void {
        const state = service.stateFor("DISPLAY1");
        check(state.lastConfirmedKnown, "a confirmed value exists for the snap-back");
        close(state.brightness, state.lastConfirmed, "a failed write snaps back");
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_BRIGHTNESS_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
