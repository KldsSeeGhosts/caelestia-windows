import QtQuick

// Windows adaptation of the bounded state of services/Hypr.qml. This object
// imports no Quickshell or native module and constructs no tracker: it projects
// an injected Hyprland observation backend and applies the Windows dispatch
// policy. Backends are injected in tests; NativeHyprBackend.qml supplies the
// pinned backend's `Quickshell.Hyprland` data in a real run.
//
// The backend contract (a `Quickshell.Hyprland`-shaped object or a test fake):
//   initialized        bool, true once the adapter is constructed, even if empty
//   monitors           object with a `values` array of monitor-shaped objects
//   workspaces         object with a `values` array of workspace-shaped objects
//   toplevels          object with a `values` array of toplevel-shaped objects
//   activeToplevel     toplevel or null
//   focusedWorkspace   workspace or null
//   focusedMonitor     monitor or null
//   monitorFor(screen) monitor or null
//   dispatch(request)  sends one validated request to the backend
//   desktopControlSupported (optional) bool; absent means workspace control is
//                      unavailable.
//   desktopControl     (optional) object with capability and lastCommand maps.
//
// Per-monitor workspace ownership is NOT claimed. The pinned backend binds every
// monitor's `activeWorkspace` and every workspace's `monitor` to the single
// global focused workspace/monitor (monitor.cpp:22-24, workspace.cpp:23), so
// `workspaceForMonitor()` deliberately returns the global focused workspace for
// every monitor. That limitation is documented in
// windows/services/hypr/README.md and exercised by the fixture.
//
// Dispatch policy. Observation (enabled) and dispatch (dispatchEnabled) are
// separate opt-ins and BOTH are required before anything reaches the backend.
// Only these forms are forwarded:
//   workspace <1..9999>
//   workspace r+1 | workspace r-1
//   workspace name:<safe-name>          (backend resolves existing names only)
//   movetoworkspace <1..9999>[,address:0x<hex>]
//   killwindow address:0x<hex>   -> closewindow address:0x<hex> (graceful close)
// Workspace forms additionally require the backend's native desktop-control
// `desktopControlSupported === true`. Without it they are refused with reason
// `desktop-control-unavailable` and never reach the backend.
// `togglespecialworkspace ...` is consumed as a no-op because Windows virtual
// desktops have no Hyprland special-workspace concept. Every other form,
// including injected separators, extra commas, control characters and multiple
// commands, is refused with a console warning and recorded in `lastRefusal`.
// The backend's own dispatcher would silently drop many of these, so the
// allowlist lives here, before the call.
QtObject {
    id: root

    property var backend: null

    // Observation opt-in. Disabled construction exposes empty models and a null
    // focused monitor, matching the M1 contract adapter.
    property bool enabled: false

    // Dispatch opt-in. Refused entirely unless enabled && dispatchEnabled.
    property bool dispatchEnabled: false

    // A loader can supply a known component failure. Native status is observed
    // through the backend contract instead.
    property string backendError: ""

    // Adapter lifecycle flag: the pinned Hyprland QML object has no initializing
    // or error signal, so `initialized` belongs to the wrapper/fixture. A
    // truthy non-boolean is not accepted.
    readonly property bool nativeInitialized: root.enabled && root.backendError === ""
        && root.backend !== null && root.backend.initialized === true
    readonly property bool available: root.nativeInitialized
    readonly property bool usingLua: false
    readonly property bool globalFocusPerMonitor: true

    readonly property var desktopControlCapability: {
        const unsupported = { switch: false, create: false, move: false, remove: false, pin: false };
        if (!root.enabled || !root.dispatchEnabled)
            return { availability: "disabled", reason: "dispatch-disabled", provider: "none", operations: unsupported };
        if (!root.nativeInitialized)
            return { availability: "unavailable", reason: "backend-unavailable", provider: "none", operations: unsupported };
        const capability = root.backend.desktopControl?.capability;
        if (capability && ["available", "unavailable", "disabled", "denied"].includes(capability.availability)
                && typeof capability.reason === "string"
                && (capability.availability !== "available" || capability.reason === "")
                && ["documented-api", "build-gated-private-com"].includes(capability.provider)
                && capability.operations)
            return capability;
        if (root.backend.desktopControl)
            return { availability: "unavailable", reason: "invalid-contract", provider: "unknown", operations: unsupported };
        const legacy = root.backend.desktopControlSupported === true;
        // A boolean-only backend cannot report a reason, so it is available with
        // the documented `legacy-unverified` exception to the empty-reason rule
        // (windows/docs/decisions/native-capability-contract.md, "Older
        // boolean-only backends"): its dispatch result stays unverified.
        return {
            availability: legacy ? "available" : "unavailable",
            reason: legacy ? "legacy-unverified" : "legacy-capability-unknown",
            provider: "unknown",
            operations: { switch: legacy, create: legacy, move: legacy, remove: false, pin: false }
        };
    }
    readonly property bool desktopControlSupported:
        root.desktopControlCapability.availability === "available"
        && root.desktopControlCapability.operations.switch === true
        && root.desktopControlCapability.operations.create === true

    // The bar's workspace widget dims to the theme's existing inactive opacity
    // and stops accepting input while this is false. It recovers on the next
    // capability change without a reload.
    readonly property bool workspaceControlAvailable:
        root.desktopControlCapability.availability === "available"
        && root.desktopControlCapability.operations.switch === true

    // One short sentence for the widget's tooltip, derived from the published
    // capability reason. The widget supplies the existing tooltip styling.
    readonly property string workspaceControlNotice: {
        if (root.workspaceControlAvailable)
            return "";
        const reason = root.desktopControlCapability.reason || "operation-unsupported";
        switch (reason) {
        case "unsupported-build":
            return "Workspace switching is unavailable on this Windows build.";
        case "permission-denied":
            return "Workspace switching is unavailable because Windows denied access.";
        case "provider-disconnected":
            return "Workspace switching is paused while Explorer restarts.";
        case "provider-unavailable":
            return "Workspace switching is unavailable because the Windows desktop provider could not start.";
        case "dispatch-disabled":
            return "Workspace switching is disabled in this shell configuration.";
        case "backend-unavailable":
            return "Workspace switching is unavailable while the Windows desktop service starts.";
        case "invalid-contract":
            return "Workspace switching is unavailable because the desktop service reported an invalid capability.";
        case "legacy-capability-unknown":
            return "Workspace switching is unavailable because Windows desktop control is not configured.";
        case "operation-unsupported":
            return "Workspace switching is not supported by the Windows desktop provider.";
        default:
            return "Workspace switching is unavailable.";
        }
    }

    // Diagnostics read this instead of the raw capability: the own-window move
    // is IVirtualDesktopManager::MoveWindowToDesktop, a documented API, while
    // switch/create still share the build-gated private COM provider. Keeping
    // the provider per operation avoids labelling the whole provider private.
    readonly property var desktopControlDiagnostics: {
        const capability = root.desktopControlCapability;
        const provider = capability.provider ?? "unknown";
        return {
            availability: capability.availability,
            reason: capability.reason,
            provider: provider,
            operations: capability.operations,
            operationProviders: {
                switch: provider,
                create: provider,
                move: "documented-api",
                remove: provider,
                pin: provider
            }
        };
    }
    property var _desktopRefusal: null
    readonly property var lastDesktopCommand: root._desktopRefusal
        ?? (root.nativeInitialized ? root.backend.desktopControl?.lastCommand : null)
        ?? { outcome: "unknown", reason: "legacy-result-unavailable" }

    readonly property QtObject _emptyModel: QtObject {
        readonly property var values: []
    }

    readonly property var monitors: root.nativeInitialized ? root.backend.monitors : root._emptyModel
    readonly property var workspaces: root.nativeInitialized ? root.backend.workspaces : root._emptyModel
    readonly property var toplevels: root.nativeInitialized ? root.backend.toplevels : root._emptyModel

    readonly property var focusedWorkspace: root.nativeInitialized
        ? (root.backend.focusedWorkspace ?? null) : null
    readonly property var focusedMonitor: root.nativeInitialized
        ? (root.backend.focusedMonitor ?? null) : null

    // Mirrors services/Hypr.qml:19-22: the active toplevel is only exposed when
    // it belongs to a special workspace or the focused workspace is occupied.
    readonly property var activeToplevel: {
        if (!root.nativeInitialized)
            return null;
        const candidate = root.backend.activeToplevel;
        if (!candidate)
            return null;
        // Native Windows foreground validation is independent of the backend's
        // workspace membership model, which may omit a real foreground app.
        if (root.backend.foregroundValidated === true)
            return candidate;
        const workspaceName = typeof candidate.workspace?.name === "string"
            ? candidate.workspace.name : "";
        const focusedValues = root.backend.focusedWorkspace?.toplevels?.values;
        const focusedCount = Array.isArray(focusedValues) ? focusedValues.length : 0;
        return workspaceName.startsWith("special:") || focusedCount > 0 ? candidate : null;
    }

    readonly property int activeWsId: root.focusedWorkspace?.id ?? 1
    readonly property string status: {
        if (!root.enabled)
            return "disabled";
        if (root.backendError !== "")
            return "unavailable";
        if (!root.nativeInitialized)
            return "initializing";
        return "ready";
    }
    readonly property string reason: {
        switch (root.status) {
        case "disabled":
            return "Hyprland observation is disabled.";
        case "unavailable":
            return root.backendError;
        case "initializing":
            return "Waiting for the Windows Hyprland observation backend.";
        default:
            return "Hyprland observation is active.";
        }
    }

    property int dispatchSequence: 0
    property int commandsSent: 0
    property int refusals: 0
    property int consumed: 0
    property string lastDispatch: ""
    property string lastDispatchSource: ""
    property string lastDispatchKind: ""
    property var lastRefusal: null
    property var lastConsumed: null

    readonly property string lastRefusalRequest: root.lastRefusal?.request ?? ""
    readonly property string lastRefusalReason: root.lastRefusal?.reason ?? ""
    readonly property string lastRefusalText: root.lastRefusal?.text ?? ""
    readonly property string lastConsumedRequest: root.lastConsumed?.request ?? ""

    onEnabledChanged: {
        if (!root.enabled)
            root._reset();
    }

    function _reset(): void {
        root.dispatchSequence = 0;
        root.commandsSent = 0;
        root.refusals = 0;
        root.consumed = 0;
        root.lastDispatch = "";
        root.lastDispatchSource = "";
        root.lastDispatchKind = "";
        root.lastRefusal = null;
        root.lastConsumed = null;
        root._desktopRefusal = null;
    }

    // The pinned backend's toplevel address is a lowercase hex HWND without the
    // `0x` prefix (hyprland_toplevel.cpp:218-219). Refusal text escapes the
    // request so a newline or separator cannot forge a second log line.
    function _display(request): string {
        if (typeof request !== "string")
            return "<" + typeof request + ">";
        const bounded = request.length > 80 ? request.slice(0, 77) + "..." : request;
        return JSON.stringify(bounded);
    }

    function _refuse(request, reason, text): void {
        // Only a refused desktop command may replace the native desktop result:
        // a refused window or unsupported command would otherwise show up as
        // that command's denied result.
        if (root._desktopRequest(request))
            root._desktopRefusal = { outcome: "denied", reason: reason };
        root.dispatchSequence++;
        root.refusals++;
        root.lastRefusal = {
            request: typeof request === "string" ? request : "<" + typeof request + ">",
            reason: reason,
            text: text,
            sequence: root.dispatchSequence
        };
        console.warn("Caelestia: refused a Hypr dispatch request (" + reason + ")");
    }

    // The verbs this adapter forwards as native desktop commands.
    function _desktopRequest(request): bool {
        if (typeof request !== "string") return false;
        const space = request.indexOf(" ");
        const verb = space < 0 ? request : request.slice(0, space);
        return verb === "workspace" || verb === "movetoworkspace";
    }

    function _send(source, translated, kind): void {
        root.dispatchSequence++;
        root.commandsSent++;
        root.lastDispatchSource = source;
        root.lastDispatch = translated;
        root.lastDispatchKind = kind;
        root._desktopRefusal = null;
        root.backend.dispatch(translated);
    }

    // Workspace-changing requests are gated on the native desktop-control capability.
    // The backend has no synthetic-shortcut fallback. Without a compatible
    // provider the adapter refuses before backend.dispatch().
    function _sendWorkspace(source, translated, kind): void {
        const capability = root.desktopControlCapability;
        const operation = kind === "movetoworkspace" ? "move" : "switch";
        if (capability.availability !== "available" || capability.operations[operation] !== true) {
            root._refuse(source, "desktop-control-unavailable",
                "Native Windows desktop control is unavailable on this build or dispatch is disabled.");
            root._desktopRefusal = { operation: operation, outcome: "denied",
                reason: capability.reason || "operation-unsupported" };
            return;
        }
        root._send(source, translated, kind);
    }

    function _consume(source, text): void {
        root.dispatchSequence++;
        root.consumed++;
        root.lastConsumed = {
            request: source,
            text: text,
            sequence: root.dispatchSequence
        };
        console.info("Caelestia: " + text);
    }

    // The only entry point that can reach backend.dispatch().
    function dispatch(request): void {
        if (!root.enabled || !root.dispatchEnabled) {
            root._refuse(request, "dispatch-disabled",
                "Hypr dispatch is disabled. Set CAELESTIA_WINDOWS_HYPR=1 and "
                + "CAELESTIA_WINDOWS_HYPR_DISPATCH=1 to allow an allowlisted request.");
            return;
        }
        if (!root.nativeInitialized) {
            root._refuse(request, "unavailable",
                "Hypr dispatch is unavailable while the Windows Hyprland observation backend "
                + "is not initialized.");
            return;
        }
        if (typeof request !== "string") {
            root._refuse(request, "not-string", "Hypr dispatch refused a non-string request.");
            return;
        }
        if (request.length === 0) {
            root._refuse(request, "invalid", "Hypr dispatch refused an empty request.");
            return;
        }
        if (request.length > 96) {
            root._refuse(request, "too-long",
                "Hypr dispatch refused a request longer than 96 characters.");
            return;
        }
        // Reject command separators and control characters before any pattern
        // match. Quotes and backslashes cannot appear in an allowed form either.
        if (/[\u0000-\u001f\u007f;`$|&<>\\"']/.test(request)) {
            root._refuse(request, "injection",
                "Hypr dispatch refused " + root._display(request)
                + ": command separators, quotes or control characters are not accepted.");
            return;
        }

        const workspace = /^workspace ([1-9][0-9]{0,3})$/.exec(request);
        if (workspace) {
            root._sendWorkspace(request, request, "workspace");
            return;
        }
        if (request === "workspace r+1" || request === "workspace r-1") {
            root._sendWorkspace(request, request, "workspace-relative");
            return;
        }
        const named = /^workspace name:([A-Za-z0-9_.-]{1,64})$/.exec(request);
        if (named) {
            // The pinned backend resolves only an existing name (dispatcher.cpp
            // :417-420). It never creates a workspace from this form, so the
            // adapter forwards it unchanged instead of pretending otherwise.
            root._sendWorkspace(request, request, "workspace-name");
            return;
        }
        const move = /^movetoworkspace ([1-9][0-9]{0,3})(?:,address:0x([0-9a-fA-F]{1,16}))?$/
            .exec(request);
        if (move) {
            const translated = "movetoworkspace " + move[1]
                + (move[2] ? ",address:0x" + move[2].toLowerCase() : "");
            root._sendWorkspace(request, translated, "movetoworkspace");
            return;
        }
        const kill = /^killwindow address:0x([0-9a-fA-F]{1,16})$/.exec(request);
        if (kill) {
            // killwindow has no backend case (dispatcher.cpp:398-400).
            // closewindow is a graceful WM_CLOSE (window_tracker.cpp:374-378):
            // a documented semantic downgrade, not a force-kill.
            const translated = "closewindow address:0x" + kill[1].toLowerCase();
            root._send(request, translated, "closewindow");
            return;
        }
        if (/^togglespecialworkspace(?: [A-Za-z0-9_.-]{1,64})?$/.test(request)) {
            root._consume(request,
                "Special workspaces are not available on Windows; request consumed.");
            return;
        }

        const space = request.indexOf(" ");
        const verb = space < 0 ? request : request.slice(0, space);
        switch (verb) {
        case "workspace":
            root._refuse(request, "invalid",
                "Hypr dispatch refused " + root._display(request)
                + ": expected workspace <1-9999>, workspace r+1/r-1 or "
                + "workspace name:<safe-name>.");
            return;
        case "movetoworkspace":
            root._refuse(request, "invalid",
                "Hypr dispatch refused " + root._display(request)
                + ": expected movetoworkspace <1-9999>[,address:0x<hex>].");
            return;
        case "killwindow":
            root._refuse(request, "invalid",
                "Hypr dispatch refused " + root._display(request)
                + ": expected killwindow address:0x<hex>.");
            return;
        case "togglespecialworkspace":
            root._refuse(request, "invalid",
                "Hypr dispatch refused " + root._display(request)
                + ": malformed special-workspace request.");
            return;
        default:
            root._refuse(request, "unsupported",
                "Hypr dispatch refused " + root._display(request)
                + ": this backend command is not supported by the Windows adapter.");
        }
    }

    // Upstream sends `workspace <ws>` through dispatch; special-workspace names
    // fail the allowlist and are refused rather than sent as a dead focus.
    function focusWorkspace(ws): void {
        if (typeof ws === "number" && Number.isInteger(ws) && ws > 0) {
            root.dispatch("workspace " + ws);
            return;
        }
        if (typeof ws === "string" && ws.length > 0 && !ws.startsWith("special:")) {
            root.dispatch("workspace " + ws);
            return;
        }
        root._refuse(typeof ws === "string" ? ws : "<" + typeof ws + ">", "invalid",
            "Hypr focus refused a workspace that is not a positive id or name.");
    }

    // Special workspaces do not exist on Windows. The original UI calls these
    // helpers; they are consumed without a warning and never reach the backend.
    function toggleSpecial(name): void {
        const display = typeof name === "string" ? name : "<" + typeof name + ">";
        root._consume("togglespecialworkspace " + display,
            "Special workspaces are not available on Windows; the toggle was consumed.");
    }

    function cycleSpecialWorkspace(direction): void {
        const display = typeof direction === "string" ? direction : "<" + typeof direction + ">";
        root._consume("cycleSpecialWorkspace " + display,
            "Special workspaces are not available on Windows; the cycle was consumed.");
    }

    // The pinned backend never reports a special workspace
    // (monitor.cpp:89), so the original upstream cycle would return before
    // dispatching. This wrapper makes that fact explicit without reading native
    // fields that do not exist on Windows.
    function trimWsName(name): string {
        if (typeof name !== "string" && typeof name !== "number")
            return "";
        return String(name).replace(/^special:/, "");
    }

    function toplevelsForWs(ws, ignoredTags = []): var {
        const values = root.toplevels?.values;
        if (!Array.isArray(values))
            return [];
        return values.filter(t => t && t.workspace && t.workspace.id === ws
            && !root.isToplevelIgnored(t, ignoredTags));
    }

    function isToplevelIgnored(toplevel, ignoredTags = []): bool {
        const ipc = toplevel?.lastIpcObject;
        if (!ipc?.class || !ipc.mapped)
            return true;
        if (!Array.isArray(ignoredTags) || !Array.isArray(ipc.tags))
            return false;
        return ipc.tags.some(tag => typeof tag === "string"
            && ignoredTags.includes(tag.replace(/\*$/, "")));
    }

    function monitorFor(screen): var {
        if (!root.nativeInitialized || typeof root.backend.monitorFor !== "function")
            return null;
        return root.backend.monitorFor(screen);
    }

    // Explicit limitation: the backend has one global focused workspace, so this
    // returns it for every monitor instead of inventing per-monitor ownership.
    function workspaceForMonitor(monitor): var {
        if (!root.nativeInitialized)
            return null;
        return root.focusedWorkspace;
    }

    function monitorNames(): var {
        const values = root.monitors?.values;
        if (!Array.isArray(values))
            return [];
        return values.map(entry => entry?.name ?? "");
    }

    // Windows has no Hyprland configuration socket. Keeping the call loadable
    // avoids a static reference failure in consumers that reload dynamic rules.
    function reloadDynamicConfs(): void {
    }
}
