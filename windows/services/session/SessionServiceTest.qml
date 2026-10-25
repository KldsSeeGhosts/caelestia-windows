pragma ComponentBehavior: Bound

import QtQuick

// Standalone session-service fixture. Imports no Quickshell/native module and
// executes no real session action. A recording fake backend is the only target
// of dispatch. Runner:
// powershell -NoProfile -File windows/scripts/Test-SessionService.ps1 -QtPrefix <Windows Qt prefix>
QtObject {
    id: test

    component FakeBackend: QtObject {
        property bool canHibernate: false
        property var calls: []

        function lock(): void { calls.push("lock"); }
        function logout(): void { calls.push("logout"); }
        function shutdown(): void { calls.push("shutdown"); }
        function reboot(): void { calls.push("reboot"); }
        function suspend(): void { calls.push("suspend"); }
        function hibernate(): void { calls.push("hibernate"); }
        function rebootToFirmware(): void { calls.push("rebootToFirmware"); }
    }

    component ThrowingBackend: QtObject {
        property bool canHibernate: true
        property var calls: []

        function lock(): void { throw new Error("fixture failure"); }
    }

    readonly property SessionService service: SessionService {}
    readonly property FakeBackend backend: FakeBackend {}
    readonly property ThrowingBackend throwing: ThrowingBackend {}

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function equal(actual, expected, message): void {
        check(actual === expected,
            message + ": " + JSON.stringify(actual) + " != " + JSON.stringify(expected));
    }

    function callsAre(expected, message): void {
        equal(JSON.stringify(backend.calls), JSON.stringify(expected),
            message + " (recorded " + JSON.stringify(backend.calls) + ")");
    }

    function reset(): void {
        backend.calls = [];
        service.pendingAction = "";
        service.pendingCommand = [];
        service.lastResult = {};
    }

    function expectOutcome(expected, message): void {
        equal(service.lastResult.outcome, expected, message);
    }

    function expectConsumedNoDispatch(message): void {
        equal(service.lastResult.consumed, true, message + " consumed");
        equal(service.lastResult.dispatched, false, message + " not dispatched");
        equal(service.lastResult.requested, false, message + " not requested");
        equal(service.lastResult.succeeded, false, message + " not succeeded");
    }

    function expectRequested(call, message): void {
        expectOutcome("requested", message + " outcome");
        equal(service.lastResult.dispatched, true, message + " dispatched");
        equal(service.lastResult.requested, true, message + " requested");
        equal(service.lastResult.succeeded, false, message + " not succeeded");
        equal(service.lastResult.requiresConfirmation, false, message + " not confirmation");
        check(service.lastResult.reason.indexOf("returns void") >= 0, message + " documents the void backend");
        check(service.lastResult.reason.indexOf("session.cpp") >= 0, message + " cites the backend gap");
        callsAre([call], message + " recorded exactly one call");
    }

    function expectActionsUnavailable(message): void {
        for (const action of service.actionNames) {
            const state = service.sessionAction(action);
            check(state && state.available === false, message + " " + action + " unavailable");
            check(state && state.dispatchable === false, message + " " + action + " not dispatchable");
        }
    }

    function run(): void {
        // --- Safe construction and no fallback surface -----------------------
        equal(service.enabled, false, "disabled construction");
        equal(service.actionsEnabled, false, "actions disabled construction");
        equal(service.backend, null, "no backend construction");
        equal(service.backendError, "", "no construction error");
        equal(service.dispatchEnabled, false, "dispatch disabled construction");
        equal(service.status, "disabled", "status disabled");
        check(service.reason.length > 0, "disabled reason");
        equal(service.available, false, "disabled not available");
        equal(service.hibernateCapabilityKnown, false, "disabled hibernate unknown");
        equal(service.hibernateSupported, false, "disabled hibernate unsupported");
        equal(service.canHibernate, false, "disabled canHibernate false");
        equal(service.confirmationPending, false, "no pending confirmation");
        check(service.actionNames.length === 7, "seven explicit actions");
        for (const action of ["lock", "logout", "shutdown", "reboot", "suspend", "hibernate", "firmware"]) {
            check(service.actionDefinitions[action], "definition " + action);
        }
        check(service.actionDefinitions.suspendthenhibernate, "explicit unsupported combined action");

        // The adapter must expose no process/detached execution API.
        for (const name of ["execDetached", "Process", "createProcess", "runProcess", "spawn"]) {
            equal(service[name], undefined, "no fallback member " + name);
        }

        equal(service.exec(["lock"]), true, "disabled command consumed");
        expectOutcome("disabled", "disabled outcome");
        expectConsumedNoDispatch("disabled command");
        equal(service.confirmationPending, false, "disabled does not arm confirmation");
        service.request(["lock"]);
        expectOutcome("disabled", "disabled request outcome");

        // --- Allowlist resolution -------------------------------------------
        equal(service.resolveCommand(["lock"]), "lock", "canonical lock");
        equal(service.resolveCommand(["loginctl", "lock-session"]), "lock", "loginctl lock alias");
        equal(service.resolveCommand(["systemctl", "poweroff"]), "shutdown", "systemctl poweroff alias");
        equal(service.resolveCommand(["loginctl", "terminate-user", ""]), "logout", "terminate-user alias");
        equal(service.resolveCommand(["shutdown"]), "shutdown", "canonical shutdown");
        equal(service.resolveCommand(["poweroff"]), "shutdown", "poweroff alias");
        equal(service.resolveCommand(["reboot"]), "reboot", "canonical reboot");
        equal(service.resolveCommand(["suspend"]), "suspend", "canonical suspend");
        equal(service.resolveCommand(["hibernate"]), "hibernate", "canonical hibernate");
        equal(service.resolveCommand(["firmware"]), "firmware", "canonical firmware");
        equal(service.resolveCommand(["firmware-reboot"]), "firmware", "hyphenated firmware");
        equal(service.resolveCommand(["Firmware_Reboot"]), "firmware", "case/underscore firmware");
        equal(service.resolveCommand(["suspendThenHibernate"]), "suspendthenhibernate", "combined action recognized");
        equal(service.resolveCommand(["reboot", "now"]), "", "extra arguments refused");
        equal(service.resolveCommand(["loginctl", "reboot", "now"]), "", "aliased extra arguments refused");
        equal(service.resolveCommand(["rm", "-rf", "/"]), "", "arbitrary command refused");
        equal(service.resolveCommand(["lock", 1]), "", "non-string argument refused");
        equal(service.resolveCommand([]), "", "empty command refused");
        equal(service.resolveCommand(null), "", "null command refused");
        equal(service.resolveCommand("lock"), "", "bare string is not a list");

        equal(service.sessionAction("lock").supported, true, "lock supported contract");
        equal(service.sessionAction("lock").available, false, "lock unavailable while disabled");
        equal(service.sessionAction(["logout"]).requiresConfirmation, true, "logout needs confirmation");
        equal(service.sessionAction(["logout"]).available, false, "logout unavailable while disabled");
        equal(service.sessionAction("bogus").supported, false, "unknown action unsupported");
        equal(service.sessionAction([]).supported, false, "empty action unsupported");

        // --- Enabled without a backend --------------------------------------
        service.enabled = true;
        equal(service.status, "unavailable", "enabled without backend unavailable");
        equal(service.available, false, "enabled without backend not available");
        equal(service.exec(["lock"]), true, "missing backend command consumed");
        expectOutcome("unavailable", "missing backend outcome");
        expectConsumedNoDispatch("missing backend");
        equal(service.sessionAction("lock").capability, false, "missing backend lock capability false");

        service.backendError = "Fixture facade load failure";
        equal(service.status, "unavailable", "facade failure unavailable");
        equal(service.reason, service.backendError, "facade failure reason verbatim");
        service.backendError = "";

        // --- Observe-only mode ----------------------------------------------
        service.backend = backend;
        equal(service.status, "observing", "observe status");
        equal(service.available, true, "observe available");
        equal(service.hibernateCapabilityKnown, true, "observe capability known");
        equal(service.hibernateSupported, false, "observe hibernate unavailable by default");
        service.actionsEnabled = false;
        equal(service.exec(["lock"]), true, "observe command consumed");
        expectOutcome("actions-disabled", "observe refusal outcome");
        expectConsumedNoDispatch("observe refusal");
        callsAre([], "observe refusal sends no call");
        equal(service.sessionAction("lock").capability, true, "observe lock capability observed");
        equal(service.sessionAction("lock").dispatchable, false, "observe lock not dispatchable");
        equal(service.sessionAction("lock").available, false, "observe lock unavailable for UI");
        check(service.sessionAction("lock").reason.indexOf("dispatch is disabled") >= 0,
            "observe reason names the dispatch opt-in");
        expectActionsUnavailable("observe mode");

        equal(service.exec(["caelestia-m1-unavailable-probe"]), true, "observe unknown consumed");
        expectOutcome("unsupported", "observe unknown outcome");
        expectConsumedNoDispatch("observe unknown");
        callsAre([], "observe unknown sends no call");

        backend.canHibernate = true;
        equal(service.hibernateSupported, true, "observe hibernate capability follows backend");
        equal(service.sessionAction("hibernate").capability, true, "observe hibernate capability true");
        equal(service.sessionAction("hibernate").available, false, "observe hibernate still unavailable for UI");
        backend.canHibernate = false;

        // --- Dispatch opt-in: non-destructive actions -----------------------
        service.actionsEnabled = true;
        equal(service.status, "actions-enabled", "actions status");
        equal(service.dispatchEnabled, true, "dispatch enabled");
        equal(service.sessionAction("lock").available, true, "lock available with actions opt-in");
        equal(service.sessionAction("suspend").available, true, "suspend available with actions opt-in");
        equal(service.sessionAction("hibernate").available, false, "hibernate unavailable without capability");
        equal(service.sessionAction("hibernate").capability, false, "hibernate capability false");

        reset();
        equal(service.exec(["lock"]), true, "lock exec consumed");
        expectRequested("lock", "lock dispatch");
        equal(service.lastResult.action, "lock", "lock action recorded");
        equal(service.lastResult.command.length, 1, "lock command recorded");
        equal(service.lastResult.command[0], "lock", "lock token recorded");
        callsAre(["lock"], "lock called once");

        reset();
        equal(service.exec(["loginctl", "lock-session"]), true, "lock alias consumed");
        expectRequested("lock", "lock alias dispatch");

        reset();
        service.request(["suspend"]);
        expectRequested("suspend", "suspend dispatch");

        reset();
        service.request(["systemctl", "suspend"]);
        expectRequested("suspend", "suspend alias dispatch");

        reset();
        backend.canHibernate = true;
        equal(service.hibernateSupported, true, "hibernate capability after backend update");
        equal(service.sessionAction("hibernate").available, true, "hibernate available with capability");
        equal(service.sessionAction("hibernate").capability, true, "hibernate capability true");
        equal(service.exec(["hibernate"]), true, "hibernate exec consumed");
        expectRequested("hibernate", "hibernate dispatch");

        // --- Hibernate capability gating ------------------------------------
        reset();
        backend.canHibernate = false;
        equal(service.hibernateSupported, false, "hibernate gated off when unavailable");
        equal(service.sessionAction("hibernate").capability, false, "gated hibernate capability false");
        equal(service.sessionAction("hibernate").available, false, "gated hibernate unavailable");
        equal(service.exec(["hibernate"]), true, "gated hibernate consumed");
        expectOutcome("unsupported", "gated hibernate outcome");
        expectConsumedNoDispatch("gated hibernate");
        check(service.lastResult.reason.indexOf("Hibernation is not available") >= 0,
            "gated hibernate reason");
        callsAre([], "gated hibernate sends no call");

        equal(service.exec(["suspendThenHibernate"]), true, "combined action consumed");
        expectOutcome("unsupported", "combined action unsupported");
        expectConsumedNoDispatch("combined action");
        check(service.lastResult.reason.indexOf("combined suspend-then-hibernate") >= 0,
            "combined action reason");
        callsAre([], "combined action sends no call");

        // --- Destructive confirmation gate ----------------------------------
        reset();
        equal(service.exec(["logout"]), true, "logout exec consumed");
        expectOutcome("confirmation-required", "logout confirmation outcome");
        expectConsumedNoDispatch("logout confirmation");
        equal(service.lastResult.requiresConfirmation, true, "logout requires confirmation");
        equal(service.lastResult.action, "logout", "pending logout action");
        equal(service.confirmationPending, true, "logout armed confirmation");
        equal(service.pendingAction, "logout", "pending action name");
        equal(service.pendingCommand[0], "logout", "pending command name");
        callsAre([], "logout not sent without confirmation");
        equal(service.confirm(), true, "logout confirmation dispatched");
        expectRequested("logout", "confirmed logout");
        equal(service.confirmationPending, false, "confirmation cleared after dispatch");
        equal(service.pendingAction, "", "pending action cleared");
        equal(service.confirm(), false, "second confirmation is a no-op");
        expectOutcome("requested", "second confirmation leaves the result");

        reset();
        service.exec(["shutdown"]);
        expectOutcome("confirmation-required", "shutdown confirmation outcome");
        equal(service.lastResult.action, "shutdown", "shutdown pending action");
        callsAre([], "shutdown not sent without confirmation");
        equal(service.confirm(), true, "shutdown confirmation dispatched");
        expectRequested("shutdown", "confirmed shutdown");

        reset();
        service.exec(["poweroff"]);
        equal(service.confirm(), true, "poweroff alias confirmation dispatched");
        expectRequested("shutdown", "poweroff maps to shutdown");

        reset();
        service.exec(["reboot"]);
        equal(service.confirm(), true, "reboot confirmation dispatched");
        expectRequested("reboot", "confirmed reboot");

        reset();
        service.exec(["firmware-reboot"]);
        expectOutcome("confirmation-required", "firmware confirmation outcome");
        equal(service.lastResult.action, "firmware", "firmware pending action");
        equal(service.lastResult.requiresConfirmation, true, "firmware requires confirmation");
        callsAre([], "firmware not sent without confirmation");
        equal(service.confirm(), true, "firmware confirmation dispatched");
        expectRequested("rebootToFirmware", "confirmed firmware reboot");

        reset();
        service.exec(["logout"]);
        equal(service.confirmationPending, true, "cancel fixture armed");
        equal(service.cancelConfirmation(), true, "cancel clears pending");
        equal(service.confirmationPending, false, "cancel leaves no pending action");
        equal(service.confirm(), false, "cancel prevents later dispatch");
        callsAre([], "cancelled confirmation sends no call");

        reset();
        service.exec(["logout"]);
        service.exec(["shutdown"]);
        equal(service.pendingAction, "shutdown", "latest destructive request replaces pending action");
        equal(service.confirm(), true, "latest pending action dispatches");
        expectRequested("shutdown", "replaced pending action dispatch");
        callsAre(["shutdown"], "replaced pending action sent only once");

        reset();
        service.exec(["logout"]);
        equal(service.confirm(), true, "pending logout before disable");
        service.actionsEnabled = false;
        equal(service.confirmationPending, false, "disable clears pending confirmation");
        service.actionsEnabled = true;

        // --- Unknown/arbitrary commands consumed without execution ----------
        reset();
        equal(service.exec(["rm", "-rf", "/"]), true, "arbitrary command consumed");
        expectOutcome("unsupported", "arbitrary command outcome");
        expectConsumedNoDispatch("arbitrary command");
        equal(service.lastResult.action, "", "arbitrary command has no action");
        equal(service.lastResult.command.length, 3, "arbitrary command is recorded verbatim");
        check(service.lastResult.reason.indexOf("without detached or process execution") >= 0,
            "arbitrary command reason states no fallback");
        callsAre([], "arbitrary command sends no call");

        equal(service.exec([]), true, "empty command consumed");
        expectOutcome("unsupported", "empty command outcome");
        equal(service.exec(null), true, "null command consumed");
        expectOutcome("unsupported", "null command outcome");
        equal(service.exec("reboot"), true, "bare string command consumed");
        expectOutcome("unsupported", "bare string command outcome");
        equal(service.exec(["reboot", "now"]), true, "extra-argument command consumed");
        expectOutcome("unsupported", "extra-argument command outcome");
        equal(service.exec(["reboot", 1]), true, "non-string token consumed");
        expectOutcome("unsupported", "non-string token outcome");
        callsAre([], "malformed commands send no call");

        // --- Backend shape robustness ---------------------------------------
        reset();
        service.backend = {canHibernate: true};
        equal(service.hibernateSupported, true, "bare backend canHibernate observed");
        equal(service.sessionAction("lock").capability, true, "bare backend capability reported");
        equal(service.exec(["lock"]), true, "bare backend command consumed");
        expectOutcome("unsupported", "missing backend method unsupported");
        expectConsumedNoDispatch("missing backend method");
        check(service.lastResult.reason.indexOf("does not expose") >= 0, "missing method reason");

        service.backend = {canHibernate: 1};
        equal(service.hibernateSupported, false, "non-boolean hibernate capability rejected");
        equal(service.exec(["hibernate"]), true, "non-boolean hibernate consumed");
        expectOutcome("unsupported", "non-boolean hibernate unsupported");

        service.backend = throwing;
        equal(service.exec(["lock"]), true, "throwing backend command consumed");
        expectOutcome("failed", "throwing backend outcome");
        equal(service.lastResult.dispatched, false, "throwing backend not dispatched");
        equal(service.lastResult.succeeded, false, "throwing backend not succeeded");
        check(service.lastResult.reason.indexOf("threw") >= 0, "throwing backend reason");

        service.backend = backend;
        reset();
        backend.canHibernate = true;

        // --- Disable clears observation and dispatch ------------------------
        service.exec(["shutdown"]);
        equal(service.confirmationPending, true, "pending before disable");
        service.enabled = false;
        equal(service.status, "disabled", "disable returns to disabled");
        equal(service.available, false, "disable clears availability");
        equal(service.hibernateSupported, false, "disable clears hibernate capability");
        equal(service.confirmationPending, false, "disable clears pending confirmation");
        expectActionsUnavailable("disabled after use");
        equal(service.exec(["lock"]), true, "post-disable command consumed");
        expectOutcome("disabled", "post-disable outcome");
        expectConsumedNoDispatch("post-disable");
        callsAre([], "disable prevents dispatch");

        // --- Verified result and capability counts --------------------------
        equal(service.lastResult.succeeded, false, "no success claim");
        equal(service.lastResult.requested, false, "disabled result is not a request");
        check(JSON.stringify(service.lastResult).indexOf("\"succeeded\":true") < 0,
            "serialized result never claims success");

        console.log("CAELESTIA_SESSION_FIXTURE_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_SESSION_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
