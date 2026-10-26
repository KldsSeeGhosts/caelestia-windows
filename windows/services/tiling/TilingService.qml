import QtQuick

// Windows tiling state for M3-2 stages 4/5 groundwork. This object imports no
// Quickshell or native module and constructs no `Tiling` singleton: it holds
// the opt-in policy, projects an injected tiling backend and decides the
// original-surface toasts that explain fitting failures. Backends are injected
// in tests; NativeTilingBackend.qml supplies the pinned backend's
// `Quickshell.Windows` Tiling data in a real run.
//
// The backend contract (a wrapper around the `Tiling` singleton or a fake):
//   initialized          bool, true once construction has settled
//   enabled              bool, current tiler state; never written directly
//   supportsIncluded     bool, feature-detected `Tiling.included` allowlist
//   lastError            string, guarded read ("" when unsupported)
//   managedCount         int, guarded read (0 when unsupported)
//   failedCount          int, guarded read (0 when unsupported)
//   applyOptions(excluded, included)
//                        applies both pattern lists; included only takes effect
//                        on a backend that supports it
//   requestEnable()      the only path that may set the backend tiler enabled
//   enableRefused(reason)              signal (tiler-mutex-held, no-screen)
//   windowTilingFailed(address, reason)
//                        signal; address is lowercase hex without 0x, matching
//                        HyprlandToplevel addresses. Reasons: min-size,
//                        off-target, correction-limit, unresponsive.
//
// Policy. CAELESTIA_WINDOWS_TILING maps to mode off/observe/interactive
// (validated here; anything else is `off` with a warning). `off` never
// requests the native wrapper (`nativeRequested` stays false and the facade
// keeps its Loader inactive). `observe` constructs and applies options but
// `enabled` stays false. `interactive` may request enabling ONLY when the
// parsed inclusion list is non-empty AND the backend supports `included`;
// otherwise the mode refuses with a clear status reason and never enables.
// Smoke runs force interactive down to observe. The shared build pins the
// backend WITHOUT the allowlist/telemetry members, so everything beyond
// enabled/excluded is feature-detected with typeof and reports truthful
// defaults when absent.
//
// Toasts. Fitting failures are explained on Caelestia's original toast
// surface: the service decides title/message/icon/type and emits
// `toastDecision`; the facade forwards it to `Toaster.toast`. Copy strings go
// through `tr` so the facade can localize them like upstream daemons. Rate
// limits: at most one toast per window address per failure reason per enabled
// session, at most three failure toasts per ten seconds, and suppressed
// excess collapses into a single summary toast (itself at most once per ten
// seconds). An enable refusal emits exactly one error toast.
QtObject {
    id: root

    property var backend: null

    // Load failure of the native wrapper component, reported by the facade.
    property string backendError: ""

    // Localization hook. The identity default keeps the object testable
    // without Caelestia.I18n; the facade injects Tr.tr.
    property var tr: text => text

    // Resolves a failure address to {appClass, title} through the Hypr
    // toplevels when observation is available. The null default leaves the
    // generic "a window" wording.
    property var resolveToplevel: null

    // Deterministic clock for the rate-limit window. Real runs keep
    // Date.now().
    property var clock: () => Date.now()

    // Effective mode after the smoke policy. off|observe|interactive.
    readonly property string mode: root._mode

    // Requested mode before the smoke downgrade, for honest status output.
    readonly property string requestedMode: root._requestedMode

    readonly property bool smoke: root._smoke
    readonly property var includedPatterns: root._includedPatterns
    readonly property var excludedPatterns: root._excludedPatterns

    // The facade binds its native Loader to this flag: `off` never loads the
    // wrapper file, so the Tiling singleton is never imported or constructed.
    readonly property bool nativeRequested: root._mode !== "off"

    readonly property bool backendLoaded: root.backend !== null

    // --- Projected backend state (guarded feature detection) ----------------

    readonly property bool backendEnabled: root.backend !== null
        && root.backend.enabled === true
    readonly property bool backendIncludedSupported: root.backend !== null
        && root.backend.supportsIncluded === true
    readonly property int managedCount: root.backend !== null
        && typeof root.backend.managedCount === "number" ? root.backend.managedCount : 0
    readonly property int failedCount: root.backend !== null
        && typeof root.backend.failedCount === "number" ? root.backend.failedCount : 0
    readonly property string lastError: root.backend !== null
        && typeof root.backend.lastError === "string" ? root.backend.lastError : ""

    // Bounded recent-failure list (address, appClass, title, reason, time),
    // newest last, capped at 20 entries.
    readonly property var recentFailures: root._recentFailures
    readonly property int recentFailureCount: root._recentFailures.length
    readonly property int toastCount: root._toastCount

    // --- Status --------------------------------------------------------------

    // disabled | observing | refused | tiling
    readonly property string status: {
        if (root._mode === "off")
            return "disabled";
        if (root.backendError !== "")
            return "refused";
        if (root._mode !== "interactive")
            return "observing";
        if (root._policyRefusal !== "")
            return "refused";
        if (root._backendRefusal !== "")
            return "refused";
        if (root.backendEnabled)
            return "tiling";
        return "observing";
    }

    readonly property string reason: {
        if (root.status === "disabled")
            return "Window tiling is off.";
        if (root.backendError !== "")
            return root.backendError;
        if (root.status === "tiling")
            return "The tiler is managing the included windows.";
        if (root.status === "refused") {
            if (root._policyRefusal === "included-empty")
                return "Interactive tiling requires CAELESTIA_WINDOWS_TILING_INCLUDED to name the windows it may manage.";
            if (root._policyRefusal === "included-unsupported")
                return "The pinned Windows backend does not support an inclusion allowlist; interactive tiling stays off.";
            return root._enableRefusalText(root._backendRefusal);
        }
        if (root._requestedMode === "interactive" && root._smoke)
            return "Interactive tiling is never allowed during smoke; observation only.";
        return "The tiler is constructed with its options applied and stays disabled.";
    }

    // --- Signals --------------------------------------------------------------

    // Emitted when the original toast surface should show a decision. type
    // mirrors the Toast enum: 0 Info, 1 Success, 2 Warning, 3 Error.
    signal toastDecision(string title, string message, string icon, int type)

    // --- Internal state --------------------------------------------------------

    property string _mode: "off"
    property string _requestedMode: "off"
    property bool _smoke: false
    property var _includedPatterns: []
    property var _excludedPatterns: []
    property string _backendRefusal: ""
    property var _recentFailures: []
    property var _notifiedKeys: new Set()
    property var _toastTimes: []
    property var _collapseTimes: []
    property int _toastCount: 0

    // Interactive enable permission. An empty inclusion list or a backend
    // without `included` support refuses before requestEnable().
    readonly property string _policyRefusal: root._policyRefusalFor(root.backend)

    function _policyRefusalFor(backend): string {
        if (root._mode !== "interactive")
            return "";
        if (root._includedPatterns.length === 0)
            return "included-empty";
        if (backend !== null && backend.supportsIncluded !== true)
            return "included-unsupported";
        return "";
    }

    // --- Configuration ----------------------------------------------------------

    // Semicolon-separated wildcard patterns: entries are trimmed and empty
    // entries dropped. The backend compiles the wildcards itself; the service
    // only normalizes the list. Non-string input yields an empty list.
    function parsePatternList(text): var {
        if (typeof text !== "string")
            return [];
        return text.split(";").map(entry => entry.trim()).filter(entry => entry.length > 0);
    }

    // Called once by the facade before the native Loader becomes active.
    function configure(modeText, includedText, excludedText, smoke): void {
        let requested = "off";
        if (modeText === "observe" || modeText === "interactive") {
            requested = modeText;
        } else if (typeof modeText === "string" && modeText.length > 0 && modeText !== "off") {
            console.warn("Caelestia: unknown CAELESTIA_WINDOWS_TILING value '"
                + modeText + "'; tiling stays off.");
        }
        root._requestedMode = requested;
        root._smoke = smoke === true;
        root._mode = requested === "interactive" && root._smoke ? "observe" : requested;
        root._includedPatterns = root.parsePatternList(includedText);
        root._excludedPatterns = root.parsePatternList(excludedText);
        root._backendRefusal = "";
        root._resetToastSession();
        // A backend attached before configuration still receives the new
        // options; enabling is decided once at attach time.
        if (root.backend !== null && root._mode !== "off"
                && typeof root.backend.applyOptions === "function")
            root.backend.applyOptions(root._excludedPatterns, root._includedPatterns);
    }

    // --- Backend lifecycle -------------------------------------------------------

    onBackendChanged: {
        // A swapped or removed backend starts a fresh refusal bookkeeping.
        root._backendRefusal = "";
        const backend = root.backend;
        if (backend === null || root._mode === "off")
            return;
        if (typeof backend.applyOptions === "function")
            backend.applyOptions(root._excludedPatterns, root._includedPatterns);
        // Interactive enabling is requested only when the policy allows it;
        // the backend then either reports enabled or refuses through its
        // enableRefused signal.
        if (root._mode === "interactive" && root._policyRefusalFor(backend) === ""
                && typeof backend.requestEnable === "function")
            backend.requestEnable();
    }

    onBackendEnabledChanged: {
        if (root.backendEnabled)
            root._resetToastSession();
    }

    function _resetToastSession(): void {
        root._notifiedKeys = new Set();
        root._toastTimes = [];
        root._collapseTimes = [];
        root._toastCount = 0;
    }

    // --- Backend signals ----------------------------------------------------------

    // Sink for the backend's enableRefused(reason): tiler-mutex-held,
    // no-screen. Only an interactive mode that actually requested enabling
    // records the refusal and explains it with one error toast.
    function handleEnableRefused(reason): void {
        if (root._mode !== "interactive" || root._policyRefusal !== "")
            return;
        if (root._backendRefusal !== "")
            return;
        root._backendRefusal = typeof reason === "string" ? reason : String(reason ?? "");
        root._toastCount++;
        root.toastDecision(root.tr("Tiling is off"),
            root.tr(root._enableRefusalText(root._backendRefusal)), "view_quilt", 3);
    }

    function _enableRefusalText(reason): string {
        switch (reason) {
        case "tiler-mutex-held":
            return "Another tiling manager is already running.";
        case "no-screen":
            return "No screen is available to tile on.";
        default:
            return "Tiling could not be enabled.";
        }
    }

    // Sink for the backend's windowTilingFailed(address, reason). Records the
    // bounded failure list entry and decides the explanation toast.
    function handleWindowTilingFailed(address, reason): void {
        const addr = typeof address === "string" ? address : String(address ?? "");
        const why = typeof reason === "string" ? reason : String(reason ?? "");
        let appClass = "";
        let title = "";
        if (typeof root.resolveToplevel === "function") {
            const info = root.resolveToplevel(addr);
            if (info !== null && info !== undefined) {
                appClass = typeof info.appClass === "string" ? info.appClass : "";
                title = typeof info.title === "string" ? info.title : "";
            }
        }
        root._recentFailures = root._recentFailures.concat([{
            address: addr,
            appClass: appClass,
            title: title,
            reason: why,
            time: root.clock()
        }]).slice(-20);

        // At most one toast per window address per reason per enabled session.
        const key = addr + "|" + why;
        if (root._notifiedKeys.has(key))
            return;
        root._notifiedKeys.add(key);
        const name = appClass !== "" ? appClass : (title !== "" ? title : "a window");
        root._emitFailureToast(root.tr("Couldn't tile") + " " + name,
            root.tr(root._failureText(why)));
    }

    function _failureText(reason): string {
        switch (reason) {
        case "min-size":
            return "It needs more space than its tile; it was left floating.";
        case "off-target":
            return "It kept moving away from its tile; it was left floating.";
        case "correction-limit":
            return "It didn't fit its tile exactly, so it may leave a gap.";
        case "unresponsive":
            return "It stopped responding while being placed.";
        default:
            return "It could not be placed in its tile.";
        }
    }

    function _emitFailureToast(title, message): void {
        const now = root.clock();
        root._toastTimes = root._toastTimes.filter(t => now - t < 10000);
        if (root._toastTimes.length >= 3) {
            // Overall burst limit reached: this failure collapses into the
            // summary toast, shown at most once per ten-second window.
            root._collapseTimes = root._collapseTimes.filter(t => now - t < 10000);
            if (root._collapseTimes.length > 0)
                return;
            root._collapseTimes.push(now);
            root._toastCount++;
            root.toastDecision(root.tr("Some windows couldn't be tiled"), "", "view_quilt", 2);
            return;
        }
        root._toastTimes.push(now);
        root._toastCount++;
        root.toastDecision(title, message, "view_quilt", 2);
    }
}
