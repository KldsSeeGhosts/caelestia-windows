import QtQuick

// Windows adaptation of the native system tray boundary. This object has no
// Quickshell/native import and never constructs SystemTray; the singleton
// facade (services/Tray.qml) injects the native item model only after the
// CAELESTIA_WINDOWS_TRAY opt-in, and fixtures inject plain objects.
//
// Native backend contract (src/windows/services/systray):
// - SystemTray exposes items and hookCapability with availability and reason.
// - SystemTrayItem.hasMenu is always true while menu is always null
//   (item.hpp lines 102-104), so the original TrayMenu has no semantic handle.
// - display() opens the owner's native context menu but ignores the parent
//   window and both requested coordinates (item.cpp lines 199-210).
// - scroll() is an empty stub (item.cpp line 197).
// - Activation and menu display call AllowSetForegroundWindow for the owner,
//   so they can foreground another application (item.cpp lines 149-153,
//   212-230). They are permitted only under the separate activation opt-in.
// SystemTray construction starts native tray hosting: TrayHost::instance()
// starts its prune timer and, after the first frame, starts Explorer
// interception and snapshots unless QS_WINDOWS_TRAY_HOOK=0.
QtObject {
    id: root

    // Injected facade exposes hookCapability and an items model with values.
    property var backend: null
    property bool enabled: false

    // Separate opt-in: activate(), secondaryActivate() and openMenu() send
    // requests only while this is true. Observation never needs it.
    property bool activationEnabled: false
    property string backendError: ""

    readonly property var hookCapability: backend?.hookCapability
        ?? ({availability: "unavailable", reason: "hook-capability-unknown"})
    readonly property bool interceptionEnabled: hookCapability.availability === "available"

    // Native context menus only. The original semantic TrayMenu cannot render
    // while menu is null; openMenu() routes to display() instead.
    readonly property string menuMode: "native"
    readonly property bool menuCoordinatesSupported: false
    readonly property bool scrollSupported: false
    readonly property string scrollResult: "unsupported"

    // --- Observation --------------------------------------------------------

    // Non-object entries are rejected. The native model can retain snapshots
    // after an owner disappears, so list membership and object identity are the
    // only liveness evidence QML receives.
    readonly property var list: {
        if (!root.enabled || !root.backend)
            return [];

        const values = root.backend.items?.values;
        if (!values)
            return [];
        return values.filter(item => item && typeof item === "object");
    }
    readonly property int count: list.length
    readonly property var titles: list.map(item => root.itemTitle(item))
    readonly property var ids: list.map(item => root.itemId(item))

    // Seeded items can survive a failed hook start. Model size is not health.
    readonly property string status: {
        if (!root.enabled)
            return "disabled";
        if (root.backendError !== "")
            return "unavailable";
        if (!root.backend)
            return "initializing";
        if (!root.backend.items || !root.backend.items.values)
            return "unavailable";
        if (root.hookCapability.availability === "disabled")
            return "not-observable";
        if (root.hookCapability.reason === "hook-starting")
            return "initializing";
        if (!root.interceptionEnabled)
            return "unavailable";
        if (root.count > 0)
            return "ready";
        return "empty";
    }
    readonly property bool ready: status === "empty" || status === "ready"

    readonly property string lastError: {
        if (!root.enabled)
            return "";
        if (root.backendError !== "")
            return root.backendError;
        if (root.backend && (!root.backend.items || !root.backend.items.values))
            return "The Windows tray backend did not expose an item model.";
        if (root.backend && root.status === "unavailable")
            return "Tray hook unavailable: " + (root.hookCapability.reason || "hook-capability-unknown");
        return "";
    }

    readonly property string reason: {
        if (!root.enabled)
            return "Windows tray observation is disabled.";
        if (root.status === "initializing")
            return "Waiting for the Windows tray backend.";
        if (root.status === "unavailable")
            return "The Windows tray backend is unavailable: " + root.lastError;
        if (root.status === "not-observable")
            return "Tray icons are not observable: tray interception is disabled, so Windows tray items are never enumerated.";
        if (root.status === "empty")
            return "Windows tray observation is active; no tray items are currently observed.";
        return "Windows tray observation is active: " + root.count + " item(s) observed.";
    }

    // --- Item projections ---------------------------------------------------

    function itemId(item): string {
        if (!item)
            return "";
        const id = item.id;
        return typeof id === "string" ? id : "";
    }

    function itemTitle(item): string {
        if (!item)
            return "";
        const title = item.title;
        return typeof title === "string" ? title : "";
    }

    function isListed(item): bool {
        return !!item && root.list.indexOf(item) >= 0;
    }

    function hasMenu(item): bool {
        return root.isListed(item) && item.hasMenu === true;
    }

    // Always null with the pinned backend, but read rather than assumed so a
    // future handle is not hidden by this adapter.
    function menuHandle(item): var {
        if (!root.isListed(item))
            return null;
        const handle = item.menu;
        return handle === undefined ? null : handle;
    }

    function hasRenderableMenu(item): bool {
        return root.hasMenu(item) && root.menuHandle(item) !== null;
    }

    readonly property bool semanticMenuAvailable: {
        for (const item of root.list) {
            if (root.hasRenderableMenu(item))
                return true;
        }
        return false;
    }

    // --- Observation history ------------------------------------------------

    // Explorer restarts are visible only as the item list being reset: every
    // entry removed, or a complete identity replacement without overlap. The
    // backend exposes no Explorer PID/generation to QML (ownerAlive() is not
    // invokable and the TaskbarCreated path lives inside the hook), so this is
    // observation of the list, not proof of an Explorer restart.
    property int listGeneration: 0
    property int listResets: 0
    property int peakCount: 0
    property string lastResetKind: ""
    property int lastResetPreviousCount: 0
    property var previousList: []

    // --- Request accounting -------------------------------------------------

    property string lastActivationAction: ""
    property string lastActivationResult: ""
    property string lastActivationReason: ""
    property int activationRequests: 0
    property int activationRefusals: 0
    property string lastMenuResult: ""
    property string lastMenuReason: ""
    property int menuRequests: 0
    // Dispatched display() requests. The backend reports no outcome and may
    // queue a request that expires, so this never claims a shown menu.
    property int menuSent: 0
    property int menuRefusals: 0
    property var lastMenuCoordinates: []
    property int staleRequests: 0
    property int scrollRequests: 0

    onListChanged: root.observeList()
    onEnabledChanged: {
        if (!root.enabled)
            root.clearObservation();
    }

    function itemsDiffer(previous, current): bool {
        if (previous.length !== current.length)
            return true;
        for (let i = 0; i < current.length; i++) {
            if (previous[i] !== current[i])
                return true;
        }
        return false;
    }

    function itemsOverlap(previous, current): bool {
        for (const item of current) {
            if (previous.indexOf(item) >= 0)
                return true;
        }
        return false;
    }

    function markReset(kind: string, previousCount: int): void {
        root.listGeneration++;
        root.listResets++;
        root.lastResetKind = kind;
        root.lastResetPreviousCount = previousCount;
    }

    function observeList(): void {
        if (!root.enabled) {
            root.clearObservation();
            return;
        }

        const current = root.list;
        const previous = root.previousList;
        if (!root.itemsDiffer(previous, current))
            return;

        root.peakCount = Math.max(root.peakCount, current.length);
        if (previous.length > 0 && current.length === 0) {
            root.markReset("empty", previous.length);
        } else if (previous.length > 0 && current.length > 0
            && !root.itemsOverlap(previous, current)) {
            root.markReset("replaced", previous.length);
        }
        root.previousList = current;
    }

    function clearObservation(): void {
        root.previousList = [];
        root.peakCount = 0;
        root.listGeneration = 0;
        root.listResets = 0;
        root.lastResetKind = "";
        root.lastResetPreviousCount = 0;
        root.lastActivationAction = "";
        root.lastActivationResult = "";
        root.lastActivationReason = "";
        root.activationRequests = 0;
        root.activationRefusals = 0;
        root.lastMenuResult = "";
        root.lastMenuReason = "";
        root.menuRequests = 0;
        root.menuSent = 0;
        root.menuRefusals = 0;
        root.lastMenuCoordinates = [];
        root.staleRequests = 0;
        root.scrollRequests = 0;
    }

    // --- Commands -----------------------------------------------------------

    // Whether a native request may be sent. An empty string means allowed; any
    // other value is the refusal reason. A stale item is counted separately.
    function activationRefusal(item): string {
        if (!root.enabled)
            return "Windows tray observation is disabled.";
        if (root.backendError !== "")
            return "The Windows tray backend is unavailable: " + root.backendError;
        if (root.status === "unavailable")
            return root.reason;
        if (!root.ready)
            return "The Windows tray backend has not settled.";
        if (!root.activationEnabled)
            return "Tray activation is disabled by policy; no native request was sent.";
        if (!root.isListed(item)) {
            root.staleRequests++;
            return "The tray item is no longer observed; the request was dropped.";
        }
        return "";
    }

    function requestActivation(action: string, item): bool {
        const method = action === "secondary" ? "secondaryActivate" : "activate";
        root.lastActivationAction = action;

        const refusal = root.activationRefusal(item);
        if (refusal !== "" || typeof item[method] !== "function") {
            root.activationRefusals++;
            root.lastActivationResult = "refused";
            root.lastActivationReason = refusal !== ""
                ? refusal
                : "The tray item does not implement " + method + "().";
            return false;
        }

        item[method]();
        root.activationRequests++;
        root.lastActivationResult = "sent";
        root.lastActivationReason = "The native request was sent; the backend reports no per-action result.";
        return true;
    }

    function activate(item): bool {
        return root.requestActivation("activate", item);
    }

    function secondaryActivate(item): bool {
        return root.requestActivation("secondary", item);
    }

    // Routes "open menu" to the backend's native context menu. Coordinates are
    // forwarded for a future backend but are ignored by the pinned one; the
    // result text records that instead of claiming placement.
    function openMenu(item, parentWindow, x, y): bool {
        const relativeX = Number.isFinite(x) ? Math.round(x) : 0;
        const relativeY = Number.isFinite(y) ? Math.round(y) : 0;
        root.menuRequests++;
        root.lastMenuCoordinates = [relativeX, relativeY];

        const refusal = root.activationRefusal(item);
        if (refusal !== "" || typeof item.display !== "function") {
            root.menuRefusals++;
            root.lastMenuResult = "refused";
            root.lastMenuReason = refusal !== ""
                ? refusal
                : "The tray item does not implement display().";
            return false;
        }

        item.display(parentWindow ?? null, relativeX, relativeY);
        root.menuSent++;
        root.lastMenuResult = "sent";
        root.lastMenuReason = "Native context menu requested; the backend reports no outcome and ignores the requested coordinates.";
        return true;
    }

    // Unsupported and consumed without warnings. The backend stub is never
    // called, so a read-only run cannot send a native message.
    function scroll(item, delta, horizontal): bool {
        root.scrollRequests++;
        return false;
    }
}
