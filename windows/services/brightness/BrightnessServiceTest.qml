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

    // Strict-capable shape: one-way `strictRoutes`, one
    // `brightnessWriteResult` per forwarded write, clearSoftwareDimming, plus
    // the old signals so the fixture can prove they no longer complete writes.
    component FakeBackend: QtObject {
        id: fake

        property string method: "wmi"
        property var routes: ({})
        property bool available: true
        property real level: 0.5
        property bool respondToQuery: true
        property string queryRoute: ""
        // Write behaviour.
        property bool strictRoutes: false
        property bool refuseStrict: false
        property int strictEnableCalls: 0
        property int strictDisableAttempts: 0
        property bool sawStrictAtWrite: false
        property string writeRoute: ""
        property bool emitRouteChangeOnWrite: true
        property bool emitResult: true
        property bool writeOk: true
        property string writeError: ""
        property string resultRoute: ""
        property bool emitFinish: true
        property bool finishOk: true
        property int queryCalls: 0
        property int probeCalls: 0
        property int refreshCalls: 0
        property int setCalls: 0
        property int clearCalls: 0
        property var clearedScreens: []
        property var lastSet: null

        signal queried(string screenName, bool available, bool isDdc, real brightness)
        signal brightnessSetFinished(string screenName, bool ok)
        signal brightnessWriteResult(string screenName, real value, bool ok, string method, string error)
        signal routeChanged(string screenName, string method)
        signal systemBrightnessChanged(string screenName, real brightness)

        // Enabling is one-way: a disable request is counted and refused,
        // matching the strict backend contract.
        function setStrictRoutes(enabled): void {
            if (enabled !== true) {
                fake.strictDisableAttempts++;
                return;
            }
            fake.strictEnableCalls++;
            if (fake.refuseStrict || fake.strictRoutes)
                return;
            fake.strictRoutes = true;
        }

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

        function clearSoftwareDimming(screenName): void {
            fake.clearCalls++;
            fake.clearedScreens = fake.clearedScreens.concat([screenName]);
        }

        function setBrightness(screenName, isDdc, value): void {
            fake.setCalls++;
            fake.lastSet = {screenName: screenName, isDdc: isDdc, value: value};
            if (fake.strictRoutes)
                fake.sawStrictAtWrite = true;
            if (fake.writeRoute.length > 0) {
                fake.routes[screenName] = fake.writeRoute;
                if (fake.emitRouteChangeOnWrite)
                    fake.routeChanged(screenName, fake.writeRoute);
            }
            if (fake.emitFinish)
                fake.brightnessSetFinished(screenName, fake.finishOk);
            if (!fake.emitResult)
                return;
            const route = fake.resultRoute.length > 0
                ? fake.resultRoute : fake.methodFor(screenName);
            fake.brightnessWriteResult(screenName, value, fake.writeOk, route, fake.writeError);
        }
    }

    // Old-pin shape: no strictRoutes and no brightnessWriteResult. The adapter
    // must refuse Interactive writes instead of using the legacy fallback path.
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

    readonly property EmptyBackend emptyBackend: EmptyBackend {}
    readonly property SilentBackend silentBackend: SilentBackend {}
    readonly property PartialStrictBackend partialBackend: PartialStrictBackend {}

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
        backend.respondToQuery = false;
        check(service.queryMonitor("DISPLAY1") === true, "route query is requested");
        expectCapability("DISPLAY1", "querying", "query in flight");
        check(backend.queryCalls === 1 && backend.probeCalls === 0,
            "query never falls back to probe");
        check(service.queryRequests === 1, "query request counted");
        check(service.queryMonitor("DISPLAY1") === false, "duplicate query is refused");
        check(!service.canWrite("DISPLAY1") && !service.interactive("DISPLAY1"),
            "querying route is neither interactive nor writable");
        expectRefused("DISPLAY1", 0.5, "write during query");
        backend.respondToQuery = true;

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
        check(service.stateFor("DISPLAY1").lastConfirmedKnown
            && Math.abs(service.stateFor("DISPLAY1").lastConfirmed - 0.42) < 0.000001,
            "queried brightness becomes the last confirmed value");
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
        check(service.write("DISPLAY1", 0.75) === true, "hardware write is forwarded");
        check(backend.setCalls === 1, "one backend write");
        close(backend.lastSet.value, 0.75, "written value");
        check(backend.lastSet.isDdc === false, "WMI write is not marked DDC");
        check(backend.strictRoutes, "strict routes were enabled before the first write");
        check(backend.sawStrictAtWrite, "the backend observed strict routes during the write");
        check(backend.strictEnableCalls === 1, "strict routes are enabled exactly once");
        check(service.strictRoutesEnabled, "the adapter records strict mode");
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "hardware write outcome");
        check(service.stateFor("DISPLAY1").brightnessKnown, "hardware write is recorded");
        close(service.stateFor("DISPLAY1").brightness, 0.75, "hardware write value");
        close(service.stateFor("DISPLAY1").lastConfirmed, 0.75, "confirmed write value");
        check(!service.stateFor("DISPLAY1").latched, "successful write is not latched");
        check(service.writeRequests === 1 && service.everWrote, "write counters");
        // One-way strict: a disable request is refused by the backend and the
        // adapter never even attempts one.
        backend.setStrictRoutes(false);
        check(backend.strictRoutes, "strict routes cannot be disabled");
        check(backend.strictDisableAttempts === 1, "the backend recorded the refused disable");
        check(service.write("DISPLAY1", 0.8) === true, "second write is forwarded");
        check(backend.strictEnableCalls === 1, "strict routes are not re-enabled per write");

        const refusedBefore = service.refusedWrites;
        for (const bad of [NaN, Infinity, -Infinity, "0.5", null, undefined, {}]) {
            expectRefused("DISPLAY1", bad, "nonfinite value " + String(bad));
        }
        check(service.refusedWrites === refusedBefore + 7, "invalid values are refused and counted");

        check(service.write("DISPLAY1", -0.5) === true, "negative value is clamped");
        close(backend.lastSet.value, 0, "negative clamps to zero");
        check(service.write("DISPLAY1", 1.5) === true, "oversized value is clamped");
        close(backend.lastSet.value, 1, "oversized clamps to one");
        check(service.write("DISPLAY1", 0.333) === true, "in-range value passes");
        close(backend.lastSet.value, 0.333, "in-range value");

        // --- Software gamma opt-in and clearSoftwareDimming -------------------
        service.softwareEnabled = true;
        check(service.interactive("DISPLAY3"), "software route becomes interactive with its opt-in");
        check(service.write("DISPLAY3", 0.3) === true, "software write is forwarded");
        check(backend.lastSet.screenName === "DISPLAY3", "software write target");
        check(backend.lastSet.isDdc === false, "software write is not a DDC write");
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
        backend.method = "wmi";
        backend.available = true;
        backend.level = 0.5;
        check(service.queryMonitor("DISPLAY1") === true, "restore WMI for pending test");
        expectCapability("DISPLAY1", "hardware", "DISPLAY1 ready for pending test");
        close(service.stateFor("DISPLAY1").lastConfirmed, 0.5,
            "query refreshed the confirmed value");
        backend.emitResult = false;
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
        backend.brightnessWriteResult("DISPLAY1", 0.2, true, "wmi", "");
        close(service.stateFor("DISPLAY1").lastConfirmed, 0.2,
            "the terminal result confirms the first value");
        check(service.stateFor("DISPLAY1").writePending,
            "the queued target is sent immediately after the terminal result");
        check(backend.setCalls === pendingStart + 2, "the queued write reached the backend");
        close(backend.lastSet.value, 0.9, "the queued write carries the newest target");
        check(service.interactive("DISPLAY1"), "the slider remains interactive across coalescing");
        backend.brightnessWriteResult("DISPLAY1", 0.9, true, "wmi", "");
        check(!service.stateFor("DISPLAY1").writePending, "the terminal result clears pending");
        check(service.stateFor("DISPLAY1").lastOutcome === "hardware-requested",
            "the coalesced write settles as a hardware request");
        close(service.stateFor("DISPLAY1").brightness, 0.9, "final brightness");
        backend.emitResult = true;

        // Duplicate and foreign results are ignored.
        const staleCalls = backend.setCalls;
        backend.brightnessWriteResult("DISPLAY1", 0.9, true, "wmi", "");
        backend.brightnessWriteResult("DISPLAY9", 0.4, true, "wmi", "");
        check(backend.setCalls === staleCalls, "stale results sent no write");
        close(service.stateFor("DISPLAY1").brightness, 0.9, "stale results change nothing");

        // A failure drops every queued target and snaps back to the last
        // confirmed value, while leaving the slider interactive for a retry.
        backend.emitResult = false;
        check(service.write("DISPLAY1", 0.15) === true, "start a failing pending write");
        check(service.write("DISPLAY1", 0.05) === true, "queue a second target behind it");
        const failSetCalls = backend.setCalls;
        backend.brightnessWriteResult("DISPLAY1", 0.15, false, "wmi", "DDC/CI write denied");
        check(!service.stateFor("DISPLAY1").writePending, "a failed result clears pending");
        check(!service.stateFor("DISPLAY1").hasQueuedWrite,
            "a failed result drops the queued target");
        check(backend.setCalls === failSetCalls, "no queued write is sent after a failure");
        check(service.stateFor("DISPLAY1").lastOutcome === "failed", "failure outcome");
        check(service.stateFor("DISPLAY1").lastError.indexOf("DDC/CI write denied") >= 0,
            "backend failure text is surfaced");
        closedSnap();
        check(service.interactive("DISPLAY1"), "a failed write keeps the slider interactive");
        check(!service.stateFor("DISPLAY1").latched, "a failed write is not a route latch");
        check(service.write("DISPLAY1", 0.6) === true, "the user can retry after a failure");
        backend.brightnessWriteResult("DISPLAY1", 0.6, true, "wmi", "");
        close(service.stateFor("DISPLAY1").brightness, 0.6, "retry confirms the new value");
        backend.emitResult = true;

        // A result that reports another route is a failure, never success.
        backend.emitResult = false;
        check(service.write("DISPLAY1", 0.25) === true, "start a wrong-route pending write");
        backend.brightnessWriteResult("DISPLAY1", 0.25, true, "lcd", "");
        check(service.stateFor("DISPLAY1").lastOutcome === "failed",
            "a wrong-route result is a failure");
        check(service.stateFor("DISPLAY1").lastError.indexOf("WMI") >= 0
            && service.stateFor("DISPLAY1").lastError.indexOf("LCD") >= 0,
            "the wrong-route failure names both routes");
        close(service.stateFor("DISPLAY1").brightness, 0.6,
            "a wrong-route failure snaps back to the confirmed value");
        backend.emitResult = true;

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
        check(blocked.queryMonitor("BLOCK1") === true, "blocked fixture route query");
        expectCapabilityOn(blocked, "BLOCK1", "hardware", "blocked fixture hardware route");
        blocked.controlsEnabled = true;
        check(blocked.strictBackend, "the blocking fixture is strict-capable");
        check(blocked.write("BLOCK1", 0.5) === false,
            "a strict-route enable refusal refuses the write");
        check(blockedBackend.setCalls === 0, "no write reached a backend without strict routes");
        check(blocked.policyError.length > 0, "the policy failure is latched");
        check(blocked.lastError === blocked.policyError, "the policy failure is the last error");
        check(!blocked.writesAllowed && !blocked.interactive("BLOCK1"),
            "a latched policy failure keeps the slider read-only");
        check(!blocked.stateFor("BLOCK1").latched,
            "a policy failure is not a per-monitor route latch");
        blockedBackend.refuseStrict = false;
        check(blocked.refreshRoutes() === 1, "a user refresh retries after a policy failure");
        check(blocked.policyError === "", "the refresh clears the policy latch");
        check(blocked.interactive("BLOCK1"), "the monitor becomes interactive again");
        check(blocked.write("BLOCK1", 0.45) === true, "the retried write is forwarded");
        check(blockedBackend.strictRoutes, "strict routes are enabled on the retry");
        close(blocked.stateFor("BLOCK1").brightness, 0.45, "the retried write confirms");

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
        observation.softwareEnabled = true;
        observationBackend.method = "software";
        check(observation.queryMonitor("OBS1") === true, "query the software route");
        expectCapabilityOn(observation, "OBS1", "software-only", "software route observed");
        check(observation.write("OBS1", 0.5) === true, "software write under strict routes");
        check(observation.gammaTouched, "software write marks gamma as touched");
        check(observation.beginObservation() === false, "gamma state blocks automatic re-query");
        check(observationBackend.queryCalls === 3, "blocked automatic re-query sends nothing");
        check(observation.refreshRoutes() === 2, "explicit refresh is allowed");
        check(observationBackend.queryCalls === 5, "explicit refresh queries every screen");

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

        // --- Generation: a reconnected monitor is not authorized by a stale query
        backend.respondToQuery = false;
        check(service.queryMonitor("DISPLAY2") === true, "query DISPLAY2 before unplug");
        expectCapability("DISPLAY2", "querying", "query in flight before unplug");
        const oldGeneration = service.stateFor("DISPLAY2").generation;
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
        check(service.stateFor("DISPLAY2").generation > oldGeneration,
            "removing and re-adding a screen bumps its record generation");
        // A query result with no outstanding query for the current record is
        // ignored, even for a hardware-shaped signal.
        const directGeneration = service.stateFor("DISPLAY2").generation;
        backend.queried("DISPLAY2", true, true, 0.5);
        expectCapability("DISPLAY2", "unknown", "a result without an outstanding query is ignored");
        check(service.stateFor("DISPLAY2").generation === directGeneration,
            "an ignored result does not move the generation");
        check(service.queryMonitor("DISPLAY2") === true, "query the reconnected screen");
        expectCapability("DISPLAY2", "hardware", "the reconnected screen settles normally");
        check(service.stateFor("DISPLAY2").queryGeneration === directGeneration,
            "the accepted query is tagged with the current generation");

        // Removing a screen mid-write drops the pending record without a crash.
        backend.method = "wmi";
        backend.available = true;
        backend.emitResult = false;
        check(service.queryMonitor("DISPLAY2") === true, "requery reconnected screen");
        expectCapability("DISPLAY2", "hardware", "reconnected hardware route");
        check(service.write("DISPLAY2", 0.6) === true, "start a write then unplug");
        service.screens = [{name: "DISPLAY1"}];
        backend.brightnessWriteResult("DISPLAY2", 0.6, true, "wmi", "");
        backend.emitResult = true;
        check(service.stateFor("DISPLAY2") === null, "mid-write unplug drops state");
        service.screens = [{name: "DISPLAY1"}, {name: "DISPLAY2"}];
        expectCapability("DISPLAY2", "unknown", "mid-write unplug is not resurrected");
        check(!service.stateFor("DISPLAY2").writePending,
            "a re-added screen has no pending write");

        // --- Disable clears every observation --------------------------------
        service.autoObservationDone = true;
        service.controlsEnabled = false;
        const clearBeforeDisable = backend.clearCalls;
        service.softwareEnabled = false;
        check(backend.clearCalls === clearBeforeDisable + service.monitorCount,
            "disabling the gamma opt-in still clears dimming");
        service.enabled = false;
        check(service.status === "disabled", "disable returns to disabled");
        check(service.monitorCount === 2, "screen records remain for the facade");
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

        console.log("CAELESTIA_BRIGHTNESS_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
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
