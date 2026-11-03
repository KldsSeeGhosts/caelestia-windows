pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture for windows/services/hypr/HyprService.qml. Imports no
// Quickshell, no native Hyprland object, no configuration and no external
// state; reads no environment or hardware; never constructs Hypr.qml or
// NativeHyprBackend.qml. The fake backend mirrors the property names the real
// `Quickshell.Hyprland` wrapper exposes. Intended runner:
//   powershell -NoProfile -File windows/scripts/Test-HyprService.ps1 -QtPrefix <Windows Qt prefix>
QtObject {
    id: test

    // Shapes mirror HyprlandMonitor/HyprlandWorkspace/HyprlandToplevel as the
    // audit and backend describe them, plus the adapter's `initialized` flag.
    component FakeModel: QtObject {
        property var values: []
    }

    component FakeToplevel: QtObject {
        property string address: ""
        property string title: ""
        property var workspace: null
        property var monitor: null
        property var lastIpcObject: ({
            class: "",
            mapped: true,
            tags: [],
            floating: false
        })
    }

    component FakeWorkspace: QtObject {
        property int id: 0
        property string name: ""
        property var monitor: null
        property var toplevels: null
        property var lastIpcObject: ({
            windows: 0
        })
    }

    component FakeMonitor: QtObject {
        property int id: 0
        property string name: ""
        property bool focused: false
        property var activeWorkspace: null
        property var lastIpcObject: ({
            specialWorkspace: {
                name: "",
                id: 0
            }
        })
    }

    component FakeBackend: QtObject {
        property bool initialized: false
        property var monitors: null
        property var workspaces: null
        property var toplevels: null
        property var activeToplevel: null
        property var focusedWorkspace: null
        property var focusedMonitor: null
        property int dispatchCalls: 0
        property var dispatchLog: []
        // Default true so the pre-existing allowlist assertions keep passing.
        // Gate cases flip it at runtime; the legacy fake below omits it.
        property bool desktopControlSupported: true
        property var desktopControl: null
        property bool foregroundValidated: false

        function monitorFor(screen): var {
            return screen && screen.monitor ? screen.monitor : null;
        }
        function dispatch(request): void {
            dispatchCalls++;
            dispatchLog.push(request);
        }
    }

    // Older backends have no desktopControlSupported property. This fake
    // deliberately omits it so the fixture proves the typeof feature-detect.
    component LegacyBackend: QtObject {
        property bool initialized: true
        property int dispatchCalls: 0
        property var dispatchLog: []

        function dispatch(request): void {
            dispatchCalls++;
            dispatchLog.push(request);
        }
    }

    readonly property HyprService service: HyprService {}
    readonly property FakeBackend fixture: FakeBackend {}
    readonly property LegacyBackend legacyFixture: LegacyBackend {}
    readonly property QtObject nativeControl: QtObject {
        property var capability: ({})
        property var lastCommand: ({ outcome: "none" })
    }

    readonly property FakeModel monitorModel: FakeModel {}
    readonly property FakeModel workspaceModel: FakeModel {}
    readonly property FakeModel toplevelModel: FakeModel {}

    readonly property FakeModel ws1Toplevels: FakeModel {}
    readonly property FakeModel ws2Toplevels: FakeModel {}
    readonly property FakeModel ws3Toplevels: FakeModel {}
    readonly property FakeModel specialToplevels: FakeModel {}

    readonly property FakeMonitor monitor0: FakeMonitor {}
    readonly property FakeMonitor monitor1: FakeMonitor {}
    readonly property FakeWorkspace ws1: FakeWorkspace {}
    readonly property FakeWorkspace ws2: FakeWorkspace {}
    readonly property FakeWorkspace ws3: FakeWorkspace {}
    readonly property FakeWorkspace specialWs: FakeWorkspace {}
    readonly property FakeToplevel toplevel1: FakeToplevel {}
    readonly property FakeToplevel toplevel2: FakeToplevel {}
    readonly property FakeToplevel toplevel3: FakeToplevel {}

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function configureObservation(): void {
        monitor0.id = 0;
        monitor0.name = "DISPLAY1";
        monitor0.focused = true;
        monitor1.id = 1;
        monitor1.name = "DISPLAY2";
        monitor1.focused = false;

        ws1.id = 1;
        ws1.name = "1";
        ws1.monitor = monitor0;
        ws1.toplevels = ws1Toplevels;
        ws2.id = 2;
        ws2.name = "2";
        ws2.monitor = monitor0;
        ws2.toplevels = ws2Toplevels;
        ws3.id = 3;
        ws3.name = "3";
        ws3.monitor = monitor0;
        ws3.toplevels = ws3Toplevels;
        specialWs.id = 10;
        specialWs.name = "special:scratch";
        specialWs.monitor = monitor0;
        specialWs.toplevels = specialToplevels;

        // The pinned backend binds every monitor's activeWorkspace to the one
        // global focused workspace (monitor.cpp:22-24).
        monitor0.activeWorkspace = ws2;
        monitor1.activeWorkspace = ws2;

        toplevel1.address = "1a2b";
        toplevel1.title = "Alpha";
        toplevel1.workspace = ws2;
        toplevel1.monitor = monitor0;
        toplevel1.lastIpcObject = {
            class: "Alpha",
            mapped: true,
            tags: [],
            floating: false
        };
        toplevel2.address = "3c4d";
        toplevel2.title = "Beta";
        toplevel2.workspace = ws2;
        toplevel2.monitor = monitor0;
        toplevel2.lastIpcObject = {
            class: "Beta",
            mapped: true,
            tags: ["beta"],
            floating: true
        };
        toplevel3.address = "5e6f";
        toplevel3.title = "Gamma";
        toplevel3.workspace = ws1;
        toplevel3.monitor = monitor1;
        toplevel3.lastIpcObject = {
            class: "Gamma",
            mapped: true,
            tags: [],
            floating: false
        };

        ws1Toplevels.values = [toplevel3];
        ws2Toplevels.values = [toplevel1, toplevel2];
        ws3Toplevels.values = [];
        specialToplevels.values = [];

        monitorModel.values = [monitor0, monitor1];
        workspaceModel.values = [ws1, ws2, ws3, specialWs];
        toplevelModel.values = [toplevel1, toplevel2, toplevel3];

        fixture.monitors = monitorModel;
        fixture.workspaces = workspaceModel;
        fixture.toplevels = toplevelModel;
        fixture.focusedMonitor = monitor0;
        fixture.focusedWorkspace = ws2;
        fixture.activeToplevel = toplevel1;
        fixture.initialized = true;
    }

    function resetDispatch(): void {
        fixture.dispatchCalls = 0;
        fixture.dispatchLog = [];
        service.dispatchSequence = 0;
        service.commandsSent = 0;
        service.refusals = 0;
        service.consumed = 0;
        service.lastDispatch = "";
        service.lastDispatchSource = "";
        service.lastDispatchKind = "";
        service.lastRefusal = null;
        service.lastConsumed = null;
    }

    function expectRefusal(request, reason, message): void {
        const beforeCalls = fixture.dispatchCalls;
        const beforeRefusals = service.refusals;
        const beforeSequence = service.dispatchSequence;
        service.dispatch(request);
        check(service.refusals === beforeRefusals + 1, message + ": no refusal recorded");
        check(service.lastRefusalReason === reason,
            message + ": reason " + service.lastRefusalReason + " != " + reason);
        check(service.lastRefusalText.length > 0, message + ": empty refusal text");
        check(service.dispatchSequence === beforeSequence + 1, message + ": sequence");
        check(fixture.dispatchCalls === beforeCalls, message + ": refusal reached the backend");
    }

    function expectSend(request, translated, kind, message): void {
        const beforeCalls = fixture.dispatchCalls;
        const beforeSent = service.commandsSent;
        const beforeSequence = service.dispatchSequence;
        service.dispatch(request);
        check(fixture.dispatchCalls === beforeCalls + 1, message + ": backend not called once");
        check(fixture.dispatchLog[fixture.dispatchLog.length - 1] === translated,
            message + ": sent " + fixture.dispatchLog[fixture.dispatchLog.length - 1]
            + " != " + translated);
        check(service.lastDispatch === translated, message + ": lastDispatch");
        check(service.lastDispatchKind === kind,
            message + ": kind " + service.lastDispatchKind + " != " + kind);
        check(service.commandsSent === beforeSent + 1, message + ": commandsSent");
        check(service.dispatchSequence === beforeSequence + 1, message + ": sequence");
    }

    function expectConsume(request, message): void {
        const beforeCalls = fixture.dispatchCalls;
        const beforeConsumed = service.consumed;
        service.dispatch(request);
        check(fixture.dispatchCalls === beforeCalls, message + ": consumed request reached the backend");
        check(service.consumed === beforeConsumed + 1, message + ": consumed count");
        check(service.lastConsumedRequest === request, message + ": lastConsumedRequest");
    }

    // The backend has no desktop control (capability false or absent). Workspace
    // requests must be refused locally with the exact documented reason/text.
    function expectDesktopControlRefusal(request, message): void {
        const backend = service.backend;
        const beforeCalls = backend.dispatchCalls;
        const beforeRefusals = service.refusals;
        const beforeSequence = service.dispatchSequence;
        service.dispatch(request);
        check(service.refusals === beforeRefusals + 1, message + ": no refusal recorded");
        check(service.lastRefusalReason === "desktop-control-unavailable",
            message + ": reason " + service.lastRefusalReason + " != desktop-control-unavailable");
        check(service.lastRefusalText === "Native Windows desktop control is unavailable on this build or dispatch is disabled.",
            message + ": text " + service.lastRefusalText);
        check(service.dispatchSequence === beforeSequence + 1, message + ": sequence");
        check(backend.dispatchCalls === beforeCalls, message + ": refusal reached the backend");
    }

    function nativeContractStates(): void {
        service.enabled = true;
        service.dispatchEnabled = true;
        service.backend = fixture;
        fixture.desktopControl = nativeControl;
        const operations = { switch: true, create: true, move: true, remove: false, pin: false };
        const rows = [
            ["unknown-build", "unavailable", "unsupported-build"],
            ["disconnected", "unavailable", "provider-disconnected"],
            ["permission-denied", "denied", "permission-denied"],
            ["available", "available", ""]
        ];
        for (const row of rows) {
            nativeControl.capability = {
                availability: row[1], reason: row[2], provider: "build-gated-private-com",
                operations: row[1] === "available" ? operations
                    : { switch: false, create: false, move: false, remove: false, pin: false }
            };
            check(service.desktopControlCapability.availability === row[1], row[0] + " availability");
            check(service.desktopControlCapability.reason === row[2], row[0] + " reason");
            check(service.desktopControlCapability.provider === "build-gated-private-com", row[0] + " provider");
            check(service.desktopControlSupported === (row[1] === "available"), row[0] + " support");
            if (row[1] !== "available") {
                const before = fixture.dispatchCalls;
                service.dispatch("workspace 2");
                check(fixture.dispatchCalls === before, row[0] + " refuses dispatch");
                check(service.lastDesktopCommand.outcome === "denied", row[0] + " command denied");
                check(service.lastDesktopCommand.reason === row[2], row[0] + " command reason");
                check(service.lastDesktopCommand.requestId === undefined, row[0] + " synchronous refusal has no id");
            }
            console.log("DESKTOP_STATE " + row[0] + " " + JSON.stringify(service.desktopControlCapability));
        }
        service.dispatchEnabled = false;
        check(service.desktopControlCapability.availability === "disabled", "dispatch disabled availability");
        check(service.desktopControlCapability.reason === "dispatch-disabled", "dispatch disabled reason");
        service.dispatch("workspace 2");
        check(service.lastDesktopCommand.reason === "dispatch-disabled", "dispatch disabled refusal");
        console.log("DESKTOP_STATE dispatch-disabled " + JSON.stringify(service.desktopControlCapability));
        service.dispatchEnabled = true;
        service.dispatch("workspace 2");
        for (const outcome of ["accepted", "observed", "denied", "superseded", "timed-out"]) {
            nativeControl.lastCommand = {
                operation: "switch", outcome: outcome,
                reason: outcome === "denied" ? "command-rejected" : "",
                requestId: "42"
            };
            check(service.lastDesktopCommand.outcome === outcome, outcome + " is preserved");
            check(service.lastDesktopCommand.requestId === "42", outcome + " identity is preserved");
            console.log("DESKTOP_COMMAND " + JSON.stringify(service.lastDesktopCommand));
        }
        nativeControl.lastCommand = { operation: "switch", outcome: "denied", reason: "command-rejected" };
        check(service.lastDesktopCommand.requestId === undefined, "immediate rejection has no request id");
        check(service.lastDesktopCommand.outcome !== "observed", "rejection cannot render as success");
        monitorModel.values = [];
        workspaceModel.values = [];
        toplevelModel.values = [];
        check(service.status === "ready", "healthy empty model is ready");
        check(service.desktopControlCapability.availability === "available", "healthy empty model keeps capability");
        console.log("DESKTOP_STATE healthy-empty ready " + JSON.stringify(service.desktopControlCapability));
        nativeControl.capability = {
            availability: "available", reason: "", provider: "build-gated-private-com",
            operations: { switch: true, create: false, move: false, remove: false, pin: false }
        };
        const before = fixture.dispatchCalls;
        service.dispatch("movetoworkspace 1");
        check(fixture.dispatchCalls === before, "unsupported individual operation is refused");
        check(service.lastDesktopCommand.reason === "operation-unsupported", "individual operation reason");
        nativeControl.capability = { availability: "available", reason: "contradictory", operations: operations };
        check(service.desktopControlCapability.reason === "invalid-contract", "malformed current backend fails closed");
        check(service.desktopControlSupported === false, "malformed current backend cannot use legacy boolean");
        fixture.desktopControl = null;
        fixture.desktopControlSupported = true;
        service.dispatch("workspace 1");
        check(service.lastDesktopCommand.outcome === "unknown", "legacy void dispatch never claims acceptance");
        check(service.lastDesktopCommand.reason === "legacy-result-unavailable", "legacy result reason");
        console.log("DESKTOP_STATE legacy-boolean " + JSON.stringify(service.desktopControlCapability));
        service.backend = legacyFixture;
        check(service.desktopControlCapability.reason === "legacy-capability-unknown", "missing property reason");
        console.log("DESKTOP_STATE missing-contract " + JSON.stringify(service.desktopControlCapability));
        service.backend = null;
        check(service.desktopControlCapability.reason === "backend-unavailable", "missing backend reason");
    }

    function run(): void {
        // --- Safe default construction -----------------------------------------
        check(service.enabled === false && service.dispatchEnabled === false,
            "safe construction opt-ins");
        check(service.backend === null && service.backendError === "",
            "safe construction backend");
        check(service.status === "disabled", "safe construction status");
        check(service.reason.indexOf("disabled") >= 0, "disabled reason");
        check(!service.nativeInitialized && !service.available, "disabled has no observation");
        check(service.usingLua === false, "usingLua is false");
        check(service.globalFocusPerMonitor === true, "global focus limitation is explicit");
        check(service.desktopControlSupported === false, "disabled has no desktop control");
        check(service.monitors.values.length === 0 && service.workspaces.values.length === 0
            && service.toplevels.values.length === 0, "disabled exposes empty models");
        check(service.focusedMonitor === null && service.focusedWorkspace === null,
            "disabled has no focus");
        check(service.activeToplevel === null && service.activeWsId === 1,
            "disabled active state");
        check(service.monitorFor({}) === null, "disabled monitorFor");
        check(service.workspaceForMonitor(monitor0) === null,
            "disabled workspaceForMonitor");
        check(service.monitorNames().length === 0, "disabled monitorNames");
        check(service.dispatchSequence === 0 && service.commandsSent === 0
            && service.refusals === 0 && service.consumed === 0,
            "disabled counters");
        check(service.lastDispatch === "" && service.lastRefusal === null
            && service.lastConsumed === null, "disabled dispatch records");
        check(service.toplevelsForWs(1).length === 0, "disabled toplevelsForWs");
        check(service.trimWsName("special:scratch") === "scratch", "trimWsName special");
        check(service.trimWsName("2") === "2" && service.trimWsName(2) === "2",
            "trimWsName number-ish");
        check(service.trimWsName(null) === "" && service.trimWsName(undefined) === "",
            "trimWsName invalid");

        // The state object may not expose a tiler, taskbar, window manager or a
        // raw native dispatch path. Only the bounded helpers exist.
        for (const name of ["dispatch", "focusWorkspace", "toggleSpecial",
            "cycleSpecialWorkspace", "trimWsName", "toplevelsForWs",
            "isToplevelIgnored", "monitorFor", "workspaceForMonitor",
            "monitorNames", "reloadDynamicConfs"]) {
            check(typeof service[name] === "function", "missing bounded helper " + name);
        }
        for (const name of ["toggleFloating", "pinWindow", "dpms", "focusMonitor",
            "tiling", "windowManager", "taskbar", "dispatchNative", "exec",
            "cycleNext", "swapNext", "toggleGroup", "submap"]) {
            check(service[name] === undefined, "adapter exposes forbidden member " + name);
        }

        // Disabled dispatch is refused even for an allowlisted string.
        const beforeDisabledCalls = fixture.dispatchCalls;
        service.dispatch("workspace 1");
        check(service.refusals === 1 && service.lastRefusalReason === "dispatch-disabled",
            "disabled dispatch refusal");
        check(service.lastRefusalText.indexOf("CAELESTIA_WINDOWS_HYPR=1") >= 0
            && service.lastRefusalText.indexOf("CAELESTIA_WINDOWS_HYPR_DISPATCH=1") >= 0,
            "disabled refusal names both opt-ins");
        check(service.commandsSent === 0 && fixture.dispatchCalls === beforeDisabledCalls,
            "disabled dispatch reached the backend");
        service.focusWorkspace(3);
        check(service.lastRefusalReason === "dispatch-disabled",
            "disabled focusWorkspace is refused");
        service.toggleSpecial("scratch");
        check(service.consumed === 1 && service.lastConsumedRequest.indexOf("scratch") >= 0,
            "disabled toggleSpecial is consumed");
        service.cycleSpecialWorkspace("next");
        check(service.consumed === 2, "disabled cycleSpecialWorkspace is consumed");
        service.reloadDynamicConfs();
        check(fixture.dispatchCalls === beforeDisabledCalls, "disabled consumed calls reached the backend");

        // --- Observation without dispatch -------------------------------------
        service.enabled = true;
        check(service.status === "initializing", "enabled without backend initializes");
        check(service.reason.indexOf("Waiting") >= 0, "initializing reason");
        check(service.nativeInitialized === false, "no backend means not initialized");
        check(service.monitorFor({}) === null, "initializing monitorFor");
        resetDispatch();
        expectRefusal("workspace 2", "dispatch-disabled", "observe-only dispatch");
        expectRefusal("killwindow address:0x1", "dispatch-disabled",
            "observe-only killwindow");
        service.dispatchEnabled = true;
        expectRefusal("workspace 2", "unavailable", "dispatch without backend");
        check(fixture.dispatchCalls === 0, "unavailable dispatch reached the backend");

        service.backendError = "Fixture component initialization failed";
        check(service.status === "unavailable", "known component failure is unavailable");
        check(service.reason === service.backendError, "component failure is verbatim");
        expectRefusal("workspace 2", "unavailable", "unavailable dispatch");
        service.backendError = "";

        // A present but uninitialized backend stays initializing and hides state.
        service.backend = fixture;
        check(service.status === "initializing", "uninitialized backend initializes");
        check(service.monitors.values.length === 0, "uninitialized backend hides monitors");
        expectRefusal("workspace 2", "unavailable", "uninitialized dispatch");
        check(fixture.dispatchCalls === 0, "uninitialized dispatch reached the backend");

        // --- Observation mapping ----------------------------------------------
        configureObservation();
        check(service.status === "ready", "initialized backend is ready");
        check(service.nativeInitialized && service.available, "initialized flags");
        check(service.reason.indexOf("active") >= 0, "ready reason");
        check(service.monitors.values.length === 2 && service.workspaces.values.length === 4
            && service.toplevels.values.length === 3, "model counts");
        check(service.focusedMonitor === monitor0, "focused monitor mapping");
        check(service.focusedWorkspace === ws2, "focused workspace mapping");
        check(service.activeWsId === 2, "active workspace id");
        check(service.monitorFor({
            monitor: monitor0
        }) === monitor0, "monitorFor first screen");
        check(service.monitorFor({
            monitor: monitor1
        }) === monitor1, "monitorFor second screen");
        check(service.monitorFor({
            monitor: null
        }) === null && service.monitorFor(null) === null, "monitorFor unknown");
        check(JSON.stringify(service.monitorNames()) === JSON.stringify(["DISPLAY1", "DISPLAY2"]),
            "monitorNames projection");

        // Global focus per monitor: both monitors and every workspace point at
        // the one focused workspace/monitor; no per-monitor ownership is claimed.
        check(service.workspaceForMonitor(monitor0) === ws2
            && service.workspaceForMonitor(monitor1) === ws2,
            "workspaceForMonitor is global");
        check(monitor0.activeWorkspace === ws2 && monitor1.activeWorkspace === ws2,
            "both monitors report the global active workspace");
        check(ws1.monitor === monitor0 && ws3.monitor === monitor0,
            "every workspace reports the focused monitor");
        check(service.monitors.values.every(m => m.activeWorkspace === service.focusedWorkspace),
            "global focus equality holds for every monitor");
        fixture.focusedWorkspace = ws3;
        monitor0.activeWorkspace = ws3;
        monitor1.activeWorkspace = ws3;
        check(service.activeWsId === 3 && service.workspaceForMonitor(monitor1) === ws3,
            "global focus updates every monitor");
        fixture.focusedWorkspace = ws2;
        monitor0.activeWorkspace = ws2;
        monitor1.activeWorkspace = ws2;
        check(service.activeWsId === 2, "global focus restores");

        // activeToplevel mirrors services/Hypr.qml:19-22.
        check(service.activeToplevel === toplevel1, "occupied focused workspace exposes toplevel");
        ws2Toplevels.values = [];
        check(service.activeToplevel === null, "empty focused workspace hides toplevel");
        toplevel1.workspace = specialWs;
        check(service.activeToplevel === toplevel1, "special workspace exposes toplevel");
        toplevel1.workspace = ws2;
        ws2Toplevels.values = [toplevel1, toplevel2];
        fixture.activeToplevel = null;
        check(service.activeToplevel === null, "missing native active toplevel");
        fixture.activeToplevel = toplevel2;
        check(service.activeToplevel === toplevel2, "toplevel identity follows the backend");
        fixture.activeToplevel = toplevel1;

        // toplevelsForWs and ignored tags.
        check(service.toplevelsForWs(2).length === 2, "toplevelsForWs count");
        check(service.toplevelsForWs(1).length === 1
            && service.toplevelsForWs(999).length === 0, "toplevelsForWs filtering");
        check(service.isToplevelIgnored(toplevel1, []) === false, "mapped class is visible");
        check(service.isToplevelIgnored(toplevel1, ["Alpha"]) === false,
            "class tag does not match a window tag");
        toplevel2.lastIpcObject = {
            class: "Beta",
            mapped: true,
            tags: ["beta", "beta*"],
            floating: true
        };
        check(service.isToplevelIgnored(toplevel2, ["beta"]) === true,
            "ignored tag matches exactly");
        check(service.isToplevelIgnored(toplevel2, ["bet"]) === false,
            "ignored tag is not a prefix match");
        toplevel2.lastIpcObject = {
            class: "Beta",
            mapped: true,
            tags: ["beta*"],
            floating: true
        };
        check(service.isToplevelIgnored(toplevel2, ["beta"]) === true,
            "trailing wildcard on a window tag is stripped");
        toplevel2.lastIpcObject = {
            class: "",
            mapped: true,
            tags: [],
            floating: false
        };
        check(service.isToplevelIgnored(toplevel2, []) === true, "missing class is ignored");
        toplevel2.lastIpcObject = {
            class: "Beta",
            mapped: false,
            tags: [],
            floating: false
        };
        check(service.isToplevelIgnored(toplevel2, []) === true, "unmapped is ignored");
        toplevel2.lastIpcObject = {
            class: "Beta",
            mapped: true,
            tags: ["beta"],
            floating: true
        };
        check(service.isToplevelIgnored(toplevel2, ["beta"]) === true,
            "ignored tags are honoured");
        check(service.toplevelsForWs(2, ["beta"]).length === 1,
            "toplevelsForWs applies ignored tags");
        check(service.toplevelsForWs(2).length === 2, "toplevelsForWs ignores tags by default");

        // --- Desktop-control capability gate ----------------------------------
        // The fixture defaults to true (matching an accessor-backed backend), so
        // the allowlist section below keeps its original send assertions.
        check(service.desktopControlSupported === true, "fixture reports desktop control");
        fixture.desktopControlSupported = false;
        check(service.desktopControlSupported === false, "false capability is reported false");
        resetDispatch();
        expectDesktopControlRefusal("workspace 2", "workspace gated on false capability");
        expectDesktopControlRefusal("workspace r+1", "relative workspace gated on false capability");
        expectDesktopControlRefusal("workspace name:dev", "named workspace gated on false capability");
        expectDesktopControlRefusal("movetoworkspace 3,address:0x1a2b",
            "movetoworkspace gated on false capability");
        check(fixture.dispatchCalls === 0, "gated workspace requests reached the backend");
        // The gate is scoped to workspace control; close translation still works.
        expectSend("killwindow address:0x1", "closewindow address:0x1", "closewindow",
            "killwindow is unaffected by the workspace gate");

        // An absent property on an older backend must be treated as
        // unavailable instead of throwing or falling through to a send.
        service.backend = legacyFixture;
        check(service.nativeInitialized === true, "legacy backend is initialized");
        check(service.desktopControlSupported === false, "absent capability is reported false");
        resetDispatch();
        expectDesktopControlRefusal("workspace 2", "workspace gated on absent capability");
        expectDesktopControlRefusal("movetoworkspace 3,address:0x1",
            "movetoworkspace gated on absent capability");
        check(legacyFixture.dispatchCalls === 0,
            "gated workspace requests reached the legacy backend");
        service.dispatch("killwindow address:0x2");
        check(legacyFixture.dispatchCalls === 1
            && legacyFixture.dispatchLog[0] === "closewindow address:0x2",
            "killwindow still dispatches with an absent capability");

        // Restore the accessor-backed fake and prove a runtime flip both ways.
        service.backend = fixture;
        fixture.desktopControlSupported = true;
        check(service.desktopControlSupported === true, "true capability is reported true");
        resetDispatch();
        expectSend("workspace 2", "workspace 2", "workspace", "workspace with capability");
        fixture.desktopControlSupported = false;
        expectDesktopControlRefusal("workspace 2", "workspace gated after runtime flip off");
        fixture.desktopControlSupported = true;
        expectSend("workspace 2", "workspace 2", "workspace", "workspace after runtime flip on");
        resetDispatch();

        // --- Allowlisted dispatch ---------------------------------------------
        resetDispatch();
        expectSend("workspace 1", "workspace 1", "workspace", "workspace 1");
        expectSend("workspace 7", "workspace 7", "workspace", "workspace 7");
        expectSend("workspace 9999", "workspace 9999", "workspace", "workspace 9999");
        expectSend("workspace r+1", "workspace r+1", "workspace-relative",
            "workspace r+1");
        expectSend("workspace r-1", "workspace r-1", "workspace-relative",
            "workspace r-1");
        expectSend("workspace name:dev", "workspace name:dev", "workspace-name",
            "named workspace");
        expectSend("workspace name:a-b_c.d", "workspace name:a-b_c.d", "workspace-name",
            "named workspace safe characters");
        expectSend("workspace name:2", "workspace name:2", "workspace-name",
            "numeric name form");
        expectSend("movetoworkspace 2", "movetoworkspace 2", "movetoworkspace",
            "movetoworkspace active window");
        expectSend("movetoworkspace 3,address:0x1a2b", "movetoworkspace 3,address:0x1a2b",
            "movetoworkspace", "movetoworkspace lowercase");
        expectSend("movetoworkspace 12,address:0xABCDEF",
            "movetoworkspace 12,address:0xabcdef", "movetoworkspace",
            "movetoworkspace normalizes address");
        expectSend("killwindow address:0x1", "closewindow address:0x1", "closewindow",
            "killwindow translation");
        expectSend("killwindow address:0xABCD", "closewindow address:0xabcd",
            "closewindow", "killwindow normalizes address");
        check(service.commandsSent === 13 && fixture.dispatchCalls === 13,
            "allowlisted dispatches reached the backend once each");
        check(fixture.dispatchLog.indexOf("togglefloating address:0x1") < 0,
            "no refused request was forwarded");

        // dispatch is allowed only while observation is active too.
        const callsBeforeDisable = fixture.dispatchCalls;
        service.enabled = false;
        check(service.status === "disabled" && service.commandsSent === 0,
            "disable returns to disabled and clears counters");
        expectRefusal("workspace 2", "dispatch-disabled", "dispatch after disable");
        service.dispatchEnabled = true;
        expectRefusal("workspace 2", "dispatch-disabled",
            "dispatch flag without observation");
        check(fixture.dispatchCalls === callsBeforeDisable,
            "post-disable dispatch reached the backend");
        service.enabled = true;
        configureObservation();
        check(service.status === "ready", "observation restores after disable");

        // focusWorkspace routes through the same allowlist.
        resetDispatch();
        service.focusWorkspace(4);
        check(service.lastDispatch === "workspace 4" && fixture.dispatchCalls === 1,
            "focusWorkspace numeric dispatch");
        service.focusWorkspace("special:scratch");
        check(service.refusals === 1 && service.lastRefusalReason === "invalid"
            && fixture.dispatchCalls === 1, "focusWorkspace special is refused");
        service.focusWorkspace(-1);
        check(service.refusals === 2 && service.lastRefusalReason === "invalid",
            "focusWorkspace negative is refused");
        service.focusWorkspace(0);
        check(service.refusals === 3 && service.lastRefusalReason === "invalid",
            "focusWorkspace zero is refused");
        service.focusWorkspace("dev");
        check(service.refusals === 4 && fixture.dispatchCalls === 1,
            "focusWorkspace plain name stays allowlist-only");

        // Special-workspace helpers are consumed as no-ops.
        const callsBeforeSpecial = fixture.dispatchCalls;
        service.toggleSpecial("scratch");
        check(service.consumed === 1 && service.lastConsumedRequest
            .indexOf("togglespecialworkspace scratch") === 0,
            "toggleSpecial consumed");
        expectConsume("togglespecialworkspace scratch",
            "togglespecialworkspace request consumed");
        expectConsume("togglespecialworkspace special",
            "togglespecialworkspace special consumed");
        expectConsume("togglespecialworkspace", "bare togglespecialworkspace consumed");
        service.cycleSpecialWorkspace("next");
        check(service.consumed === 5, "cycleSpecialWorkspace consumed");
        check(fixture.dispatchCalls === callsBeforeSpecial,
            "special-workspace helpers reached the backend");

        // --- Refusals, malformed forms and injection --------------------------
        resetDispatch();
        for (const request of ["togglefloating address:0x1", "pin address:0x1",
            "dpms off", "dpms on", "focusmonitor 1", "cyclenext", "swapnext",
            "togglegroup", "submap foo", "exec sh", "movewindowpixel exact 1 1,address:0x1"]) {
            expectRefusal(request, "unsupported", "unsupported " + request);
        }
        // workspace forms
        expectRefusal("workspace 0", "invalid", "workspace zero");
        expectRefusal("workspace 00", "invalid", "workspace leading zero");
        expectRefusal("workspace 01", "invalid", "workspace padded id");
        expectRefusal("workspace -1", "invalid", "workspace negative");
        expectRefusal("workspace +1", "invalid", "workspace plus sign");
        expectRefusal("workspace 10000", "invalid", "workspace out of range");
        expectRefusal("workspace 1 ", "invalid", "workspace trailing space");
        expectRefusal("workspace  1", "invalid", "workspace double space");
        expectRefusal("workspace", "invalid", "workspace without argument");
        expectRefusal("workspace r+2", "invalid", "workspace relative step two");
        expectRefusal("workspace r1", "invalid", "workspace malformed relative");
        expectRefusal("workspace special:scratch", "invalid", "workspace special name");
        expectRefusal("workspace name:", "invalid", "workspace empty name");
        expectRefusal("workspace name:a:b", "invalid", "workspace colon in name");
        expectRefusal("workspace name:a b", "invalid", "workspace space in name");
        expectRefusal("workspace name:a/b", "invalid", "workspace slash in name");
        // movetoworkspace forms
        expectRefusal("movetoworkspace 1,address:0x1,extra", "invalid",
            "movetoworkspace extra comma");
        expectRefusal("movetoworkspace 1,address:0x", "invalid", "movetoworkspace empty address");
        expectRefusal("movetoworkspace 0,address:0x1", "invalid", "movetoworkspace zero workspace");
        expectRefusal("movetoworkspace 1,address:1", "invalid", "movetoworkspace no 0x");
        expectRefusal("movetoworkspace 1, address:0x1", "invalid", "movetoworkspace extra space");
        expectRefusal("movetoworkspace 1,address:0x1 ", "invalid", "movetoworkspace trailing space");
        expectRefusal("movetoworkspace 1,address:0x1,address:0x2", "invalid",
            "movetoworkspace two selectors");
        expectRefusal("movetoworkspace 1,address:0x1234567890abcdef0", "invalid",
            "movetoworkspace oversized address");
        expectRefusal("movetoworkspace", "invalid", "movetoworkspace without argument");
        // killwindow forms
        expectRefusal("killwindow address:0x", "invalid", "killwindow empty address");
        expectRefusal("killwindow address:0xzz", "invalid", "killwindow non-hex address");
        expectRefusal("killwindow  address:0x1", "invalid", "killwindow double space");
        expectRefusal("killwindow", "invalid", "killwindow without argument");
        // special-workspace malformed forms
        expectRefusal("togglespecialworkspace  scratch", "invalid",
            "togglespecialworkspace double space");
        expectRefusal("togglespecialworkspace scratch ", "invalid",
            "togglespecialworkspace trailing space");
        expectRefusal("togglespecialworkspace a:b", "invalid",
            "togglespecialworkspace colon");
        // injection and control characters
        expectRefusal("workspace 1;workspace 2", "injection", "semicolon injection");
        expectRefusal("workspace 1\nworkspace 2", "injection", "newline injection");
        expectRefusal("workspace 1\rworkspace 2", "injection", "carriage return injection");
        expectRefusal("workspace 1\t2", "injection", "tab injection");
        expectRefusal("workspace 1`id`", "injection", "backtick injection");
        expectRefusal("workspace 1$(whoami)", "injection", "subshell injection");
        expectRefusal("workspace 1|dpms off", "injection", "pipe injection");
        expectRefusal("workspace 1&workspace 2", "injection", "ampersand injection");
        expectRefusal("workspace 1>out", "injection", "redirect injection");
        expectRefusal("workspace \"1\"", "injection", "quote injection");
        expectRefusal("killwindow address:0x1; dpms off", "injection",
            "killwindow semicolon injection");
        expectRefusal("killwindow address:0x1 && workspace 2", "injection",
            "killwindow ampersand injection");
        expectRefusal("movetoworkspace 1,address:0x1\nworkspace 2", "injection",
            "movetoworkspace newline injection");
        expectRefusal("togglespecialworkspace a;b", "injection",
            "special semicolon injection");
        expectRefusal("workspace 1\nkillwindow address:0x1", "injection",
            "multiple command injection");
        // non-string and bounded-size requests
        expectRefusal(null, "not-string", "null request");
        expectRefusal(undefined, "not-string", "undefined request");
        expectRefusal(5, "not-string", "number request");
        expectRefusal(true, "not-string", "boolean request");
        expectRefusal({}, "not-string", "object request");
        expectRefusal([], "not-string", "array request");
        expectRefusal("", "invalid", "empty request");
        expectRefusal(" workspace 1", "unsupported", "leading space request");
        expectRefusal("workspace " + "1".repeat(90), "too-long", "oversized request");
        check(fixture.dispatchCalls === 0,
            "every refused or malformed request avoided the backend");
        check(service.commandsSent === 0, "refusals never counted as sends");

        // A valid request still works after the refusal set.
        expectSend("workspace 6", "workspace 6", "workspace",
            "dispatch after refusals");
        check(fixture.dispatchLog.length === 1 && fixture.dispatchCalls === 1,
            "exactly one backend dispatch after refusals");

        // --- Dispatch disabled again ------------------------------------------
        service.dispatchEnabled = false;
        expectRefusal("workspace 6", "dispatch-disabled", "dispatch opt-in removed");
        service.dispatchEnabled = true;
        expectSend("workspace 6", "workspace 6", "workspace",
            "dispatch opt-in restored");

        fixture.activeToplevel = toplevel1;
        fixture.focusedWorkspace = ws1;
        ws1Toplevels.values = [];
        check(service.activeToplevel === null, "unvalidated empty workspace keeps the upstream guard");
        fixture.foregroundValidated = true;
        check(service.activeToplevel === toplevel1, "validated Windows foreground is independent of workspace membership");
        fixture.activeToplevel = null;
        check(service.activeToplevel === null, "validated desktop remains empty");

        nativeContractStates();

        console.log("CAELESTIA_HYPR_FIXTURE_PASS " + JSON.stringify({
            assertions: assertions
        }));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_HYPR_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
