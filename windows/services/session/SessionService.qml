import QtQuick

// Pure Windows session state for the bounded M2 session slice. This object
// imports neither Quickshell nor a native module, starts no process and has no
// detached-execution path. The host injects a NativeSessionBackend facade (or a
// recording fake in tests).
//
// The upstream Caelestia SessionManager contract is `exec(list<string>): bool`
// plus the direct logout/suspend/hibernate/poweroff/reboot methods used by
// daemons and lock. modules/session/Content.qml and launcher Actions call
// `exec()` and fall back to `Quickshell.execDetached()` when it returns false.
// On Windows every command is consumed here, including an unknown one, so that
// fallback can never run; the localized UI guard additionally refuses detached
// execution when the adapter advertises it. A Windows command is dispatched only
// through the explicit allowlist below and only after both opt-ins.
//
// Backend result gap: Quickshell.Windows.Session methods return void and only
// log failures (windows/deps/quickshell/src/windows/system/session.cpp lines
// 45-49, 51-55, 57-71, 73-87, 89-93, 95-99, 101-115, 117-121). The outcome
// "requested" therefore means exactly one native call was invoked; it never
// means the action succeeded or Windows accepted it.
QtObject {
    id: root

    // Injected NativeSessionBackend facade (or a test fake). It exposes:
    // canHibernate (bool), lock(), logout(), shutdown(), reboot(), suspend(),
    // hibernate() and rebootToFirmware().
    property var backend: null

    // Observation opt-in. With this false, no native backend is resolved and
    // every request is consumed as disabled.
    property bool enabled: false

    // Separate dispatch opt-in. Observation alone can report capabilities but
    // never calls a backend action.
    property bool actionsEnabled: false

    // A component load failure observed by the singleton wrapper. No native
    // status exists in that state.
    property string backendError: ""

    // Destructive actions need the original UI's confirmation flow. The
    // upstream session panel at this revision has no confirmation step, so this
    // slice exposes request/confirm for a future/original flow but never
    // auto-confirms. A request for one of these actions stops at
    // "confirmation-required" and does not call the backend.
    property string pendingAction: ""
    property var pendingCommand: []

    // The most recent consumed request. It is always consumed=true because the
    // upstream caller must not fall back to detached execution. `succeeded` is
    // deliberately always false.
    property var lastResult: ({})

    readonly property bool dispatchEnabled: enabled && actionsEnabled

    // The native backend failed to load, has not loaded yet, or is absent.
    readonly property bool available: enabled && backendError === "" && backend !== null

    readonly property bool hibernateCapabilityKnown: available
    readonly property bool hibernateSupported: available && backend !== null && backend.canHibernate === true
    // Compatibility spelling for hosts that read the native property name.
    readonly property bool canHibernate: hibernateSupported

    readonly property bool confirmationPending: pendingAction !== ""

    readonly property string status: {
        if (!enabled)
            return "disabled";
        if (backendError || !backend)
            return "unavailable";
        return actionsEnabled ? "actions-enabled" : "observing";
    }

    readonly property string reason: {
        if (!enabled)
            return "Windows session support is disabled.";
        if (backendError)
            return backendError;
        if (!backend)
            return "Waiting for the Windows session backend.";
        if (!actionsEnabled)
            return "Windows session capabilities are observable; action dispatch is disabled.";
        return "Windows session action dispatch is enabled for allowlisted actions. Destructive actions still require confirmation and native calls have no observable result.";
    }

    // Explicit allowlist. `method` is the exact native facade function; an
    // empty method is an intentional unsupported contract entry. Destructive
    // entries are refused without confirmation.
    readonly property var actionDefinitions: ({
        lock: { method: "lock", destructive: false, supported: true },
        logout: { method: "logout", destructive: true, supported: true },
        shutdown: { method: "shutdown", destructive: true, supported: true },
        reboot: { method: "reboot", destructive: true, supported: true },
        suspend: { method: "suspend", destructive: false, supported: true },
        hibernate: { method: "hibernate", destructive: false, supported: true },
        firmware: { method: "rebootToFirmware", destructive: true, supported: true },
        suspendthenhibernate: {
            method: "",
            destructive: false,
            supported: false,
            reason: "Windows has no combined suspend-then-hibernate operation; use suspend or hibernate."
        }
    })

    readonly property var actionNames: [
        "lock", "logout", "shutdown", "reboot", "suspend", "hibernate", "firmware"
    ]

    onEnabledChanged: {
        if (!enabled) {
            pendingAction = "";
            pendingCommand = [];
        }
    }

    onActionsEnabledChanged: {
        if (!actionsEnabled) {
            pendingAction = "";
            pendingCommand = [];
        }
    }

    // Copy a QML list<string>/JS array into plain tokens. A string, null,
    // missing array shape or a non-string element is an unsupported command, not
    // a partially executed one.
    function commandTokens(command): var {
        if (command === null || command === undefined || typeof command === "string")
            return [];
        if (typeof command.length !== "number")
            return [];

        const tokens = [];
        for (let index = 0; index < command.length; ++index) {
            if (typeof command[index] !== "string")
                return [];
            tokens.push(command[index]);
        }
        return tokens;
    }

    function normalizeToken(value): string {
        if (typeof value !== "string")
            return "";
        return value.replace(/[-_]/g, "").toLowerCase();
    }

    // Exact canonical names plus the upstream alias shapes. Extra arguments on
    // an otherwise canonical command are refused rather than ignored.
    function actionForToken(token): string {
        switch (token) {
        case "lock":
        case "locksession":
            return "lock";
        case "logout":
            return "logout";
        case "shutdown":
        case "poweroff":
            return "shutdown";
        case "reboot":
            return "reboot";
        case "suspend":
            return "suspend";
        case "hibernate":
            return "hibernate";
        case "firmware":
        case "firmwarereboot":
        case "rebootfirmware":
        case "reboottofirmware":
            return "firmware";
        case "suspendthenhibernate":
            return "suspendthenhibernate";
        default:
            return "";
        }
    }

    function resolveCommand(command): string {
        const tokens = commandTokens(command);
        if (tokens.length === 0)
            return "";
        if (tokens.length === 1)
            return actionForToken(normalizeToken(tokens[0]));

        const first = normalizeToken(tokens[0]);
        if (tokens.length === 2 && (first === "systemctl" || first === "loginctl"))
            return actionForToken(normalizeToken(tokens[1]));

        // Upstream's manual alias `loginctl terminate-user ''` means logout.
        if (tokens.length === 3 && first === "loginctl"
                && normalizeToken(tokens[1]) === "terminateuser" && tokens[2] === "")
            return "logout";

        return "";
    }

    function actionInfoFor(action): var {
        const definition = actionDefinitions[action];
        if (!definition)
            return null;

        const supported = definition.supported === true;
        const capability = supported && available
            && (action !== "hibernate" || hibernateSupported);
        const dispatchable = capability && dispatchEnabled;
        const requiresConfirmation = definition.destructive === true;
        const uiAvailable = dispatchable && !requiresConfirmation;

        let infoReason = "";
        if (!enabled)
            infoReason = "Windows session support is disabled.";
        else if (backendError)
            infoReason = backendError;
        else if (!backend)
            infoReason = "Waiting for the Windows session backend.";
        else if (!supported)
            infoReason = definition.reason;
        else if (action === "hibernate" && !hibernateSupported)
            infoReason = "Hibernation is not available on this system.";
        else if (!actionsEnabled)
            infoReason = "Windows session action dispatch is disabled.";
        else if (requiresConfirmation)
            infoReason = "This destructive action requires the original confirmation flow, which is not wired in this host.";
        else
            infoReason = "Dispatch is permitted; the native method returns void, so this is a request, not a result.";

        return {
            action: action,
            supported: supported,
            destructive: requiresConfirmation,
            requiresConfirmation: requiresConfirmation,
            capability: capability,
            dispatchable: dispatchable,
            canRequest: dispatchable,
            available: uiAvailable,
            reason: infoReason
        };
    }

    // UI and host helper. Accepts either an allowlisted action name or the
    // exact command list used by the original component.
    function sessionAction(value): var {
        const action = typeof value === "string" ? value : resolveCommand(value);
        const info = action ? actionInfoFor(action) : null;
        if (info)
            return info;

        return {
            action: "",
            supported: false,
            destructive: false,
            requiresConfirmation: false,
            capability: false,
            dispatchable: false,
            canRequest: false,
            available: false,
            reason: "Unsupported session command. It is consumed without execution."
        };
    }

    function recordResult(command, action, outcome, dispatched, resultReason): var {
        const result = {
            command: command.slice(),
            action: action || "",
            outcome: outcome,
            consumed: true,
            dispatched: dispatched === true,
            requested: outcome === "requested",
            succeeded: false,
            requiresConfirmation: outcome === "confirmation-required",
            reason: resultReason
        };
        lastResult = result;
        return result;
    }

    function evaluate(command, confirmed): var {
        const tokens = commandTokens(command);
        const action = resolveCommand(tokens);
        const definition = action ? actionDefinitions[action] : null;

        if (!enabled)
            return recordResult(tokens, action, "disabled", false,
                "Windows session support is disabled; the request was consumed without dispatch.");
        if (backendError)
            return recordResult(tokens, action, "unavailable", false, backendError);
        if (!backend)
            return recordResult(tokens, action, "unavailable", false,
                "The Windows session backend is not available; the request was consumed without dispatch.");
        if (!definition)
            return recordResult(tokens, action, "unsupported", false,
                "Unknown or arbitrary session command. It was consumed without detached or process execution.");
        if (definition.supported !== true)
            return recordResult(tokens, action, "unsupported", false, definition.reason);
        if (action === "hibernate" && !hibernateSupported)
            return recordResult(tokens, action, "unsupported", false,
                "Hibernation is not available on this system; the request was not sent.");
        if (!dispatchEnabled)
            return recordResult(tokens, action, "actions-disabled", false,
                "Windows session action dispatch is disabled; observation still reports capabilities only.");

        if (definition.destructive === true && !confirmed) {
            pendingAction = action;
            pendingCommand = tokens;
            return recordResult(tokens, action, "confirmation-required", false,
                "Destructive actions require the original confirmation flow; no action was sent.");
        }

        return dispatch(action, tokens);
    }

    // Upstream contract. Always true: every command is consumed so the original
    // UI cannot reach Quickshell.execDetached().
    function exec(command): bool {
        evaluate(command, false);
        return true;
    }

    // Non-executing request used by tests and future callers that inspect the
    // outcome. Returns the result object but still never bypasses confirmation.
    function request(command): var {
        return evaluate(command, false);
    }

    // Dispatch a destructive action only after a caller explicitly confirms the
    // pending request. Nothing in the Windows host calls this automatically.
    function confirm(): bool {
        if (pendingAction === "")
            return false;

        const action = pendingAction;
        const command = pendingCommand.slice();
        pendingAction = "";
        pendingCommand = [];

        if (!dispatchEnabled || !available) {
            recordResult(command, action, enabled ? "actions-disabled" : "disabled", false,
                "The session action could not be confirmed because dispatch is no longer enabled.");
            return false;
        }
        if (action === "hibernate" && !hibernateSupported) {
            recordResult(command, action, "unsupported", false,
                "Hibernation is not available on this system; the confirmed request was not sent.");
            return false;
        }

        return dispatch(action, command).dispatched === true;
    }

    function cancelConfirmation(): bool {
        if (pendingAction === "")
            return false;
        pendingAction = "";
        pendingCommand = [];
        return true;
    }

    function dispatch(action, command): var {
        const definition = actionDefinitions[action];
        const method = definition ? definition.method : "";
        if (!method || !backend || typeof backend[method] !== "function") {
            return recordResult(command, action, "unsupported", false,
                "The Windows session backend does not expose " + (method || "this action") + ".");
        }

        try {
            backend[method]();
        } catch (error) {
            return recordResult(command, action, "failed", false,
                "The native session call threw instead of returning a result: " + error);
        }

        return recordResult(command, action, "requested", true,
            "Requested " + method + "(); the native method returns void and only logs failures "
            + "(windows/deps/quickshell/src/windows/system/session.cpp). This is not a success result.");
    }
}
