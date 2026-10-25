pragma ComponentBehavior: Bound

import QtQuick

// Standalone route-policy fixture. Imports no Quickshell/native Brightness or
// configuration module, reads no environment or hardware, and never constructs
// Brightness.qml or NativeBrightnessBackend.qml. Intended runner:
//   powershell -NoProfile -File windows/scripts/Test-BrightnessService.ps1 -QtPrefix <Windows Qt prefix>
// The runner uses Qt qml.exe offscreen with only this file and BrightnessService.qml.
QtObject {
    id: test

    // Shapes mirror the native Quickshell.Windows.Brightness API. The fixture
    // keeps every signal explicit so the adapter's Connections target behaves
    // like the native wrapper.
    component FakeBackend: QtObject {
        id: fake

        property string method: "wmi"
        // Per-screen routes, like the native backend. A query pins the route a
        // screen was observed with; a later write can change only that screen.
        property var routes: ({})
        property bool available: true
        property real level: 0.5
        property bool respondToQuery: true
        property string queryRoute: ""
        property string writeRoute: ""
        property bool emitRouteChangeOnWrite: true
        property bool emitFinish: true
        property bool finishOk: true
        property int queryCalls: 0
        property int probeCalls: 0
        property int refreshCalls: 0
        property int setCalls: 0
        property var lastSet: null

        signal queried(string screenName, bool available, bool isDdc, real brightness)
        signal brightnessSetFinished(string screenName, bool ok)
        signal routeChanged(string screenName, string method)
        signal systemBrightnessChanged(string screenName, real brightness)

        function methodFor(screenName): string {
            return fake.routes[screenName] ?? fake.method;
        }

        function query(screenName): void {
            fake.queryCalls++;
            if (!fake.respondToQuery)
                return;
            const route = fake.queryRoute.length > 0 ? fake.queryRoute : fake.method;
            fake.routes[screenName] = route;
            fake.routeChanged(screenName, route);
            fake.queried(screenName, fake.available,
                route === "ddc" || route === "software", fake.level);
        }

        function probe(screenName): void {
            fake.probeCalls++;
        }

        function refresh(screenName): void {
            fake.refreshCalls++;
        }

        function setBrightness(screenName, isDdc, value): void {
            fake.setCalls++;
            fake.lastSet = {screenName: screenName, isDdc: isDdc, value: value};
            if (fake.writeRoute.length > 0) {
                fake.routes[screenName] = fake.writeRoute;
                if (fake.emitRouteChangeOnWrite)
                    fake.routeChanged(screenName, fake.writeRoute);
            }
            if (fake.emitFinish)
                fake.brightnessSetFinished(screenName, fake.finishOk);
        }
    }

    readonly property BrightnessService service: BrightnessService {}
    readonly property FakeBackend backend: FakeBackend {}
    readonly property BrightnessService observation: BrightnessService {}
    readonly property FakeBackend observationBackend: FakeBackend {}
    readonly property BrightnessService recovery: BrightnessService {}
    readonly property FakeBackend recoveryBackend: FakeBackend {}

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

    readonly property EmptyBackend emptyBackend: EmptyBackend {}
    readonly property SilentBackend silentBackend: SilentBackend {}

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
        check(service.monitorCount === 0 && service.monitorStates.length === 0,
            "disabled starts without monitor state");
        check(service.queryRequests === 0 && service.writeRequests === 0
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
        check(!service.canWrite("DISPLAY1"), "unknown route is not writable");
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
        check(service.reason.indexOf("read-only") >= 0, "default reason is read-only");

        // --- Every capability state -------------------------------------------
        // In-flight query: no automatic probe, no write allowed.
        backend.respondToQuery = false;
        check(service.queryMonitor("DISPLAY1") === true, "route query is requested");
        expectCapability("DISPLAY1", "querying", "query in flight");
        check(backend.queryCalls === 1 && backend.probeCalls === 0,
            "query never falls back to probe");
        check(service.queryRequests === 1, "query request counted");
        check(service.queryMonitor("DISPLAY1") === false, "duplicate query is refused");
        check(!service.canWrite("DISPLAY1"), "querying route is not writable");
        expectRefused("DISPLAY1", 0.5, "write during query");
        backend.respondToQuery = true;

        // Hardware: WMI, LCD and DDC are three distinct named routes.
        backend.method = "wmi";
        backend.available = true;
        backend.level = 0.42;
        backend.queried("DISPLAY1", true, false, 0.42);
        expectCapability("DISPLAY1", "hardware", "WMI hardware route");
        check(service.stateFor("DISPLAY1").route === "wmi", "WMI route is named");
        check(service.routeLabel("wmi") === "WMI", "WMI label");
        check(service.stateFor("DISPLAY1").brightnessKnown
            && Math.abs(service.stateFor("DISPLAY1").brightness - 0.42) < 0.000001,
            "queried brightness is recorded");
        check(service.stateFor("DISPLAY1").lastOutcome === "queried", "query outcome");

        backend.method = "lcd";
        backend.level = 0.6;
        check(service.queryMonitor("DISPLAY1") === true, "re-query for LCD");
        expectCapability("DISPLAY1", "hardware", "LCD hardware route");
        check(service.stateFor("DISPLAY1").route === "lcd"
            && service.routeLabel("lcd") === "\\\\.\\LCD", "LCD route and label");

        backend.method = "ddc";
        backend.level = 0.55;
        check(service.queryMonitor("DISPLAY1") === true, "re-query for DDC");
        expectCapability("DISPLAY1", "hardware", "DDC hardware route");
        check(service.stateFor("DISPLAY1").route === "ddc"
            && service.routeLabel("ddc") === "DDC/CI", "DDC route and label");

        // Denied/failed hardware: a hardware route exists but no level was read.
        backend.method = "ddc";
        backend.available = false;
        backend.level = 1;
        check(service.queryMonitor("DISPLAY2") === true, "query second monitor");
        expectCapability("DISPLAY2", "failed", "denied DDC route");
        check(service.stateFor("DISPLAY2").route === "ddc"
            && service.stateFor("DISPLAY2").lastError.indexOf("DDC/CI") >= 0,
            "failed route names DDC/CI");
        check(!service.stateFor("DISPLAY2").brightnessKnown, "failed read is not a brightness");
        check(!service.canWrite("DISPLAY2"), "failed route is not writable");
        expectRefused("DISPLAY2", 0.5, "write to a failed route");

        // Software-only: the built-in panel has no hardware backlight route.
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}, {name: "DISPLAY3"}];
        backend.method = "software";
        backend.available = false;
        check(service.queryMonitor("DISPLAY3") === true, "query software monitor");
        expectCapability("DISPLAY3", "software-only", "software gamma route");
        check(service.stateFor("DISPLAY3").route === "software"
            && service.routeLabel("software") === "software (gamma)", "software route label");
        check(!service.canWrite("DISPLAY3"), "software route is not writable without its opt-in");
        expectRefused("DISPLAY3", 0.5, "software write without opt-in");
        check(backend.setCalls === 0, "no write reached the backend");

        // Unsupported: no route at all.
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}, {name: "DISPLAY3"},
            {name: "DISPLAY4"}];
        backend.method = "";
        check(service.queryMonitor("DISPLAY4") === true, "query unsupported monitor");
        expectCapability("DISPLAY4", "unsupported", "no route");
        check(service.stateFor("DISPLAY4").lastError.indexOf("no brightness route") >= 0,
            "unsupported reason is explicit");
        check(service.routeLabel("") === "no route", "empty route label");
        expectRefused("DISPLAY4", 0.5, "write to an unsupported monitor");

        // --- Read-only refuses every write ------------------------------------
        backend.method = "wmi";
        backend.available = true;
        backend.level = 0.42;
        check(service.queryMonitor("DISPLAY1") === true, "restore DISPLAY1 hardware route");
        expectCapability("DISPLAY1", "hardware", "DISPLAY1 hardware again");
        check(!service.canWrite("DISPLAY1"), "controls opt-in is absent");
        expectRefused("DISPLAY1", 0.5, "read-only write");
        check(backend.setCalls === 0 && backend.probeCalls === 0,
            "read-only observation sent no write or probe");

        // --- Hardware controls and value guards -------------------------------
        service.controlsEnabled = true;
        check(service.canWrite("DISPLAY1"), "hardware route becomes writable");
        check(service.write("DISPLAY1", 0.75) === true, "hardware write is forwarded");
        check(backend.setCalls === 1, "one backend write");
        close(backend.lastSet.value, 0.75, "written value");
        check(backend.lastSet.isDdc === false, "WMI write is not marked DDC");
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "hardware write outcome");
        check(service.stateFor("DISPLAY1").brightnessKnown, "hardware write is recorded");
        close(service.stateFor("DISPLAY1").brightness, 0.75, "hardware write value");
        check(!service.stateFor("DISPLAY1").latched, "successful write is not latched");
        check(service.writeRequests === 1 && service.everWrote, "write counters");

        const refusedBefore = service.refusedWrites;
        for (const bad of [NaN, Infinity, -Infinity, "0.5", null, undefined, {}]) {
            expectRefused("DISPLAY1", bad, "nonfinite value " + String(bad));
        }
        check(service.refusedWrites === refusedBefore + 7, "invalid values are refused and counted");
        check(backend.setCalls === 1, "invalid values never reach the backend");

        check(service.write("DISPLAY1", -0.5) === true, "negative value is clamped");
        close(backend.lastSet.value, 0, "negative clamps to zero");
        check(service.write("DISPLAY1", 1.5) === true, "oversized value is clamped");
        close(backend.lastSet.value, 1, "oversized clamps to one");
        check(service.write("DISPLAY1", 0.333) === true, "in-range value passes");
        close(backend.lastSet.value, 0.333, "in-range value");

        // --- Software gamma opt-in --------------------------------------------
        service.softwareEnabled = true;
        check(service.canWrite("DISPLAY3"), "software route becomes writable with its opt-in");
        check(service.write("DISPLAY3", 0.3) === true, "software write is forwarded");
        check(backend.lastSet.screenName === "DISPLAY3", "software write target");
        check(backend.lastSet.isDdc === false, "software write is not a DDC write");
        check(service.stateFor("DISPLAY3").lastOutcome === "software-requested",
            "software write outcome");
        check(service.gammaTouched, "software write marks gamma as touched");
        check(!service.stateFor("DISPLAY1").latched, "other monitors keep their policy");

        // --- Route change after a write is a failure, not success -------------
        backend.method = "wmi";
        backend.available = true;
        backend.level = 0.4;
        check(service.queryMonitor("DISPLAY1") === true, "refresh DISPLAY1 before fallback test");
        expectCapability("DISPLAY1", "hardware", "DISPLAY1 ready for fallback test");
        const callsBeforeFallback = backend.setCalls;
        backend.writeRoute = "software";
        backend.emitRouteChangeOnWrite = true;
        backend.emitFinish = true;
        check(service.write("DISPLAY1", 0.5) === true, "fallback write is forwarded");
        check(backend.setCalls === callsBeforeFallback + 1, "fallback write reached the backend");
        expectCapability("DISPLAY1", "software-only", "route change latches software-only");
        check(service.stateFor("DISPLAY1").route === "software", "latched route is software");
        check(service.stateFor("DISPLAY1").latched, "route change latches the monitor");
        check(service.stateFor("DISPLAY1").lastOutcome === "route-changed",
            "route change outcome is not success");
        check(service.stateFor("DISPLAY1").lastError.indexOf("instead of") >= 0,
            "route change names the expected and actual route");
        check(service.stateFor("DISPLAY1").lastError.indexOf("WMI") >= 0,
            "route change names the expected hardware route");
        check(!service.stateFor("DISPLAY1").brightnessKnown
            && service.stateFor("DISPLAY1").brightness === 0,
            "unconfirmed fallback write reports no brightness");
        check(!service.canWrite("DISPLAY1"), "latched monitor is not writable");
        const callsAfterFallback = backend.setCalls;
        expectRefused("DISPLAY1", 0.6, "write after a route change");
        check(backend.setCalls === callsAfterFallback, "latched monitor sent no second write");

        // A user route refresh is the explicit action that clears the latch.
        backend.writeRoute = "";
        backend.method = "software";
        check(service.queryMonitor("DISPLAY1") === true, "user refresh clears the latch");
        check(!service.stateFor("DISPLAY1").latched, "refresh clears the latch");
        expectCapability("DISPLAY1", "software-only", "refreshed software route");
        check(service.stateFor("DISPLAY1").lastOutcome === "queried", "refresh outcome");

        // Method lookup alone detects a fallback with no routeChanged signal.
        backend.method = "wmi";
        check(service.queryMonitor("DISPLAY1") === true, "restore WMI route");
        expectCapability("DISPLAY1", "hardware", "WMI route restored");
        backend.writeRoute = "software";
        backend.emitRouteChangeOnWrite = false;
        check(service.write("DISPLAY1", 0.45) === true, "silent fallback write is forwarded");
        expectCapability("DISPLAY1", "software-only", "method lookup detects silent fallback");
        check(service.stateFor("DISPLAY1").latched
            && service.stateFor("DISPLAY1").lastOutcome === "route-changed",
            "method-lookup fallback latches");
        backend.writeRoute = "";
        backend.emitRouteChangeOnWrite = true;

        // A WMI -> LCD retry is a hardware alternative, but still a route
        // change and therefore still a failure for the requested route.
        backend.method = "wmi";
        check(service.queryMonitor("DISPLAY1") === true, "restore WMI for LCD retry test");
        backend.writeRoute = "lcd";
        check(service.write("DISPLAY1", 0.55) === true, "LCD retry write is forwarded");
        expectCapability("DISPLAY1", "failed", "hardware alternative is a route-change failure");
        check(service.stateFor("DISPLAY1").route === "lcd"
            && service.stateFor("DISPLAY1").latched, "LCD route is latched as failed");
        backend.writeRoute = "";
        backend.method = "lcd";
        backend.available = true;
        check(service.queryMonitor("DISPLAY1") === true, "refresh onto the LCD route");
        expectCapability("DISPLAY1", "hardware", "LCD route accepted after refresh");
        check(service.write("DISPLAY1", 0.5) === true, "write on the detected LCD route");
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "LCD write does not latch when the route matches");

        // --- Pending write handling -------------------------------------------
        backend.method = "wmi";
        check(service.queryMonitor("DISPLAY1") === true, "restore WMI for pending test");
        backend.emitFinish = false;
        check(service.write("DISPLAY1", 0.2) === true, "start a pending write");
        check(service.stateFor("DISPLAY1").writePending, "write is pending");
        check(!service.canWrite("DISPLAY1"), "pending write blocks another write");
        const pendingQueries = backend.queryCalls;
        check(service.queryMonitor("DISPLAY1") === false, "route refresh waits for a pending write");
        check(backend.queryCalls === pendingQueries, "refresh during a pending write is inert");
        const pendingCalls = backend.setCalls;
        expectRefused("DISPLAY1", 0.8, "second write while pending");
        check(backend.setCalls === pendingCalls, "pending write is not queued");
        backend.emitFinish = true;
        backend.brightnessSetFinished("DISPLAY1", true);
        check(!service.stateFor("DISPLAY1").writePending, "finish clears pending");
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "finish records the hardware request");
        backend.brightnessSetFinished("DISPLAY1", true);
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "stale duplicate finish is ignored");

        backend.emitFinish = false;
        check(service.write("DISPLAY1", 0.9) === true, "start a second pending write");
        backend.brightnessSetFinished("DISPLAY9", true);
        check(service.stateFor("DISPLAY1").writePending, "foreign finish is ignored");
        backend.brightnessSetFinished("DISPLAY1", true);
        check(!service.stateFor("DISPLAY1").writePending, "own finish is applied");
        backend.emitFinish = true;

        // The boolean is not trusted over the route, but an explicit false is
        // still latched for shape when it ever becomes reachable.
        backend.finishOk = false;
        check(service.write("DISPLAY1", 0.7) === true, "write with a false result");
        expectCapability("DISPLAY1", "hardware", "false finish keeps the observed route");
        check(service.stateFor("DISPLAY1").latched
            && service.stateFor("DISPLAY1").lastOutcome === "failed",
            "false finish latches as failed");
        backend.finishOk = true;
        backend.method = "wmi";
        check(service.queryMonitor("DISPLAY1") === true, "recover after the false result");

        // --- System read-back ------------------------------------------------
        backend.systemBrightnessChanged("DISPLAY1", 0.31);
        close(service.stateFor("DISPLAY1").brightness, 0.31, "read-back updates brightness");
        check(service.stateFor("DISPLAY1").brightnessKnown, "read-back marks brightness known");
        backend.systemBrightnessChanged("DISPLAY1", NaN);
        close(service.stateFor("DISPLAY1").brightness, 0.31, "invalid read-back is ignored");
        backend.systemBrightnessChanged("DISPLAY9", 0.2);
        check(service.stateFor("DISPLAY1").brightness === 0.31, "foreign read-back is ignored");

        // --- Monitors without a route are never written -----------------------
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}, {name: "DISPLAY3"},
            {name: "DISPLAY4"}, {name: "DISPLAY5"}];
        check(!service.canWrite("DISPLAY5"), "unknown route is not writable");
        expectRefused("DISPLAY5", 0.5, "write to an unknown route");
        // Only the second pending write and the false-result write after the
        // snapshot were forwarded; no unknown-route write reached the backend.
        check(backend.setCalls === pendingCalls + 2, "no unknown-route write reached the backend");

        // --- Hot unplug -------------------------------------------------------
        backend.respondToQuery = false;
        check(service.queryMonitor("DISPLAY2") === true, "query before hot unplug");
        expectCapability("DISPLAY2", "querying", "query in flight before unplug");
        const queryCallsBeforeUnplug = backend.queryCalls;
        const requestsBeforeUnplug = service.queryRequests;
        service.screens = [{name: "DISPLAY1"}];
        check(service.monitorCount === 1, "unplugged screens leave the monitor list");
        check(service.stateFor("DISPLAY2") === null, "unplugged screen has no state");
        backend.queried("DISPLAY2", true, true, 0.5);
        check(service.queryRequests === requestsBeforeUnplug, "late query does not re-query");
        check(backend.queryCalls === queryCallsBeforeUnplug, "unplug sends no query");
        check(service.write("DISPLAY2", 0.5) === false, "unplugged screen cannot be written");
        backend.respondToQuery = true;
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}];
        expectCapability("DISPLAY2", "unknown", "re-plugged screen has no stale state");
        check(service.stateFor("DISPLAY2").route === "", "re-plugged screen has no stale route");

        // Removing a screen mid-write drops the pending record without a crash.
        backend.method = "wmi";
        backend.available = true;
        check(service.queryMonitor("DISPLAY2") === true, "query re-plugged screen");
        backend.emitFinish = false;
        check(service.write("DISPLAY2", 0.6) === true, "start a write then unplug");
        service.screens = [{name: "DISPLAY1"}];
        backend.brightnessSetFinished("DISPLAY2", true);
        backend.emitFinish = true;
        check(service.stateFor("DISPLAY2") === null, "mid-write unplug drops state");
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}];
        expectCapability("DISPLAY2", "unknown", "mid-write unplug is not resurrected");

        // --- Automatic observation and explicit refresh -----------------------
        check(observation.enabled === false && observationBackend.queryCalls === 0,
            "observation fixture is inert");
        observation.screens = [{name: "OBS1"}, {name: "OBS2"}];
        observation.enabled = true;
        observation.backend = observationBackend;
        check(observation.beginObservation() === true, "automatic observation runs once");
        check(observationBackend.queryCalls === 2, "automatic observation queries every screen");
        check(observation.autoObservationDone, "automatic observation is marked done");
        check(observation.beginObservation() === false, "automatic observation is not repeated");
        check(observationBackend.queryCalls === 2, "second automatic observation is inert");
        check(observationBackend.probeCalls === 0, "automatic observation never probes");
        expectCapabilityOn(observation, "OBS1", "hardware", "automatic observation settles a route");

        observation.controlsEnabled = true;
        observationBackend.method = "wmi";
        observationBackend.writeRoute = "software";
        check(observation.write("OBS1", 0.5) === true, "simulate a gamma fallback");
        check(observation.gammaTouched, "fallback marks gamma as touched");
        observationBackend.writeRoute = "";
        check(observation.beginObservation() === false, "gamma state blocks automatic re-query");
        check(observationBackend.queryCalls === 2, "blocked automatic re-query sends nothing");
        check(observation.refreshRoutes() === 2, "explicit refresh is allowed");
        check(observationBackend.queryCalls === 4, "explicit refresh queries every screen");

        // A fresh process-like service refuses automatic observation after a
        // software write even though it never auto-observed before.
        recovery.screens = [{name: "REC1"}];
        recovery.enabled = true;
        recovery.backend = recoveryBackend;
        recoveryBackend.method = "software";
        check(recovery.queryMonitor("REC1") === true, "recovery fixture route query");
        recovery.controlsEnabled = true;
        recovery.softwareEnabled = true;
        check(recovery.write("REC1", 0.4) === true, "recovery fixture software write");
        check(recovery.gammaTouched, "software write marks gamma in the recovery fixture");
        const recoveryQueries = recoveryBackend.queryCalls;
        check(recovery.beginObservation() === false, "gamma state blocks first automatic query");
        check(recoveryBackend.queryCalls === recoveryQueries, "blocked first query sends nothing");
        check(recovery.refreshRoutes() === 1, "explicit refresh still works");
        check(recoveryBackend.queryCalls === recoveryQueries + 1, "explicit refresh reaches backend");

        // --- Disable clears every observation --------------------------------
        service.autoObservationDone = true;
        service.controlsEnabled = false;
        service.softwareEnabled = false;
        service.enabled = false;
        check(service.status === "disabled", "disable returns to disabled");
        check(service.monitorCount === 2, "screen records remain for the facade");
        expectCapability("DISPLAY1", "unknown", "disable resets the capability");
        check(service.stateFor("DISPLAY1").route === ""
            && !service.stateFor("DISPLAY1").brightnessKnown
            && !service.stateFor("DISPLAY1").latched
            && service.stateFor("DISPLAY1").lastOutcome === "none",
            "disable clears route, brightness, latch and outcome");
        check(!service.canWrite("DISPLAY1"), "disable blocks writes");
        expectRefused("DISPLAY1", 0.5, "write while disabled");
        check(service.queryMonitor("DISPLAY1") === false, "disable blocks queries");
        check(service.backend.probeCalls === 0, "disable never probed");
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

        console.log("CAELESTIA_BRIGHTNESS_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
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




