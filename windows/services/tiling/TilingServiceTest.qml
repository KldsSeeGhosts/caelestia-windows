pragma ComponentBehavior: Bound

import QtQuick

// Standalone fixture for windows/services/tiling/TilingService.qml. Imports
// no Quickshell, no native Tiling singleton, no configuration and no external
// state; reads no environment or hardware; never constructs Tiling.qml or
// NativeTilingBackend.qml. The fakes mirror the two backend shapes the
// wrapper can sit on: the fork branch with the allowlist and telemetry
// members, and the pinned build without them. The injected clock keeps the
// ten-second toast window deterministic without sleeping. Intended runner:
//   powershell -NoProfile -File windows/scripts/Test-TilingService.ps1 -QtPrefix <Windows Qt prefix>
QtObject {
    id: test

    // Fork shape (windows/m3-windows-stack cd170acf): allowlist plus
    // telemetry members and both signals.
    component FakeTilingBackend: QtObject {
        property bool initialized: true
        property bool enabled: false
        property bool supportsIncluded: true
        property string lastError: ""
        property int managedCount: 0
        property int failedCount: 0
        property var excludedApplied: null
        property var includedApplied: null
        property int enableRequests: 0

        function applyOptions(excluded, included): void {
            excludedApplied = excluded;
            includedApplied = included;
        }
        function requestEnable(): void {
            enableRequests++;
        }
    }

    // Pinned-build shape (14010429): no allowlist and no telemetry. The
    // wrapper over this pin drops the included list and never reports
    // counts, errors or signals.
    component LegacyTilingBackend: QtObject {
        property bool initialized: true
        property bool enabled: false
        property var excludedApplied: null
        property var includedApplied: null
        property int enableRequests: 0

        function applyOptions(excluded, included): void {
            excludedApplied = excluded;
            includedApplied = null;
        }
        function requestEnable(): void {
            enableRequests++;
        }
    }

    readonly property TilingService service: TilingService {}

    // One fake per scenario so enable/request bookkeeping stays isolated.
    readonly property FakeTilingBackend offBackend: FakeTilingBackend {}
    readonly property FakeTilingBackend observeBackend: FakeTilingBackend {}
    readonly property FakeTilingBackend noListBackend: FakeTilingBackend {}
    readonly property LegacyTilingBackend legacyBackend: LegacyTilingBackend {}
    readonly property FakeTilingBackend smokeBackend: FakeTilingBackend {}
    readonly property FakeTilingBackend liveBackend: FakeTilingBackend {}
    readonly property FakeTilingBackend refusedBackend: FakeTilingBackend {}
    readonly property FakeTilingBackend unknownBackend: FakeTilingBackend {}
    readonly property FakeTilingBackend observeOnly: FakeTilingBackend {}
    readonly property FakeTilingBackend failingBackend: FakeTilingBackend {}
    readonly property FakeTilingBackend burstBackend: FakeTilingBackend {}

    property double currentTime: 100000
    property var toasts: []

    property int assertions: 0

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function checkEqual(actual, expected, message): void {
        assertions++;
        if (actual !== expected)
            throw new Error(message + " (got " + JSON.stringify(actual)
                + ", expected " + JSON.stringify(expected) + ")");
    }

    function checkJson(actual, expected, message): void {
        assertions++;
        if (JSON.stringify(actual) !== JSON.stringify(expected))
            throw new Error(message + " (got " + JSON.stringify(actual)
                + ", expected " + JSON.stringify(expected) + ")");
    }

    // QtObject has no default property, so the recorder is a property value.
    readonly property Connections _toastRecorder: Connections {
        target: test.service

        function onToastDecision(title, message, icon, type): void {
            test.toasts.push({title: title, message: message, icon: icon, type: type});
        }
    }

    function resetToasts(): void {
        toasts = [];
    }

    function run(): void {
        service.clock = () => test.currentTime;

        // --- Pattern list parsing -------------------------------------------
        checkJson(service.parsePatternList(""), [], "empty text");
        checkJson(service.parsePatternList("a"), ["a"], "single entry");
        checkEqual(service.parsePatternList("a;b").length, 2, "two entries");
        checkJson(service.parsePatternList(" a ; b "), ["a", "b"], "trimmed entries");
        checkJson(service.parsePatternList("a;;b;"), ["a", "b"], "empty entries dropped");
        checkJson(service.parsePatternList(";"), [], "separator only");
        checkJson(service.parsePatternList("   "), [], "whitespace only");
        checkJson(service.parsePatternList(null), [], "null text");
        checkJson(service.parsePatternList(undefined), [], "undefined text");
        checkJson(service.parsePatternList(5), [], "non-string text");
        checkJson(service.parsePatternList("a*;title:Foo Bar"),
            ["a*", "title:Foo Bar"], "wildcards and title rules preserved");
        checkJson(service.parsePatternList(" title:X ; "), ["title:X"],
            "edges trimmed without touching interiors");

        // --- Off mode ---------------------------------------------------------
        service.configure("off", "firefox*", "explorer", false);
        checkEqual(service.mode, "off", "off mode");
        checkEqual(service.requestedMode, "off", "off requested");
        checkEqual(service.status, "disabled", "off status");
        checkEqual(service.reason, "Window tiling is off.", "off reason");
        check(!service.nativeRequested, "off never requests the native wrapper");
        check(!service.backendLoaded, "off has no backend");
        checkEqual(service.includedPatterns.length, 1,
            "off still reports the parsed included list for the status line");
        checkEqual(service.excludedPatterns.length, 1, "off parsed the excluded list");

        // Even a wrongly attached backend is never touched in off mode.
        service.backend = offBackend;
        checkEqual(service.status, "disabled", "off ignores an attached backend");
        check(offBackend.excludedApplied === null, "off applied no options");
        check(offBackend.includedApplied === null, "off applied no allowlist");
        checkEqual(offBackend.enableRequests, 0, "off never requested enabling");
        service.backend = null;

        // --- Invalid mode values ----------------------------------------------
        service.configure("full", "", "", false);
        checkEqual(service.mode, "off", "unknown mode word falls back to off");
        service.configure(null, "", "", false);
        checkEqual(service.mode, "off", "null mode falls back to off");
        service.configure(7, "", "", false);
        checkEqual(service.mode, "off", "non-string mode falls back to off");

        // --- Observe mode ------------------------------------------------------
        service.configure("observe", "", "explorer;ksg-shell", false);
        checkEqual(service.mode, "observe", "observe mode");
        checkEqual(service.requestedMode, "observe", "observe requested");
        check(service.nativeRequested, "observe requests the native wrapper");
        checkEqual(service.status, "observing", "observe status before backend");
        checkEqual(service.reason,
            "The tiler is constructed with its options applied and stays disabled.",
            "observe reason");

        service.backend = observeBackend;
        check(service.backendLoaded, "observe attached the backend");
        checkJson(observeBackend.excludedApplied, ["explorer", "ksg-shell"],
            "observe applied the excluded list");
        checkJson(observeBackend.includedApplied, [], "observe applied an empty allowlist");
        check(!observeBackend.enabled, "observe keeps the tiler disabled");
        checkEqual(observeBackend.enableRequests, 0, "observe never requested enabling");
        checkEqual(service.status, "observing", "observe status after backend");
        check(!service.backendEnabled, "observe backendEnabled false");
        check(service.backendIncludedSupported, "fork backend supports the allowlist");

        // Telemetry projection through the fork shape.
        observeBackend.managedCount = 7;
        checkEqual(service.managedCount, 7, "managedCount projected");
        observeBackend.failedCount = 3;
        checkEqual(service.failedCount, 3, "failedCount projected");
        observeBackend.lastError = "boom";
        checkEqual(service.lastError, "boom", "lastError projected");

        // Reconfiguring reapplies the options to the attached backend.
        service.configure("observe", "org.mozilla.firefox;title:Notes*", "explorer", false);
        checkJson(observeBackend.includedApplied,
            ["org.mozilla.firefox", "title:Notes*"], "reconfigured allowlist applied");
        checkEqual(observeBackend.enableRequests, 0, "observe still never enables");

        // --- Interactive without an allowlist -----------------------------------
        service.backend = null;
        service.configure("interactive", "", "", false);
        checkEqual(service.mode, "interactive", "interactive mode");
        check(service.nativeRequested, "interactive requests the native wrapper");
        service.backend = noListBackend;
        checkEqual(service.status, "refused", "interactive without included is refused");
        checkEqual(service.reason,
            "Interactive tiling requires CAELESTIA_WINDOWS_TILING_INCLUDED to name the windows it may manage.",
            "included-empty refusal reason");
        checkEqual(noListBackend.enableRequests, 0, "empty allowlist never enables");
        check(!noListBackend.enabled, "empty allowlist leaves the tiler disabled");

        // --- Interactive without backend allowlist support -----------------------
        service.configure("interactive", "fixture*", "explorer", false);
        service.backend = legacyBackend;
        checkEqual(service.status, "refused", "unsupported allowlist is refused");
        checkEqual(service.reason,
            "The pinned Windows backend does not support an inclusion allowlist; interactive tiling stays off.",
            "included-unsupported refusal reason");
        checkEqual(legacyBackend.enableRequests, 0, "legacy backend never enables");
        checkJson(legacyBackend.excludedApplied, ["explorer"],
            "legacy backend still receives the excluded list");
        check(legacyBackend.includedApplied === null, "legacy backend drops the allowlist");
        checkEqual(service.managedCount, 0, "legacy managedCount reports zero");
        checkEqual(service.failedCount, 0, "legacy failedCount reports zero");
        checkEqual(service.lastError, "", "legacy lastError reports empty");
        check(!service.backendIncludedSupported, "legacy backendIncludedSupported false");

        // --- Smoke forces interactive down to observe ------------------------------
        service.configure("interactive", "fixture*", "", true);
        checkEqual(service.mode, "observe", "smoke downgraded interactive to observe");
        checkEqual(service.requestedMode, "interactive", "smoke kept the requested mode");
        check(service.smoke, "smoke flag recorded");
        check(service.nativeRequested, "smoke observe still constructs the wrapper");
        service.backend = smokeBackend;
        checkEqual(smokeBackend.enableRequests, 0, "smoke never enables");
        checkEqual(service.status, "observing", "smoke status is observing");
        checkEqual(service.reason,
            "Interactive tiling is never allowed during smoke; observation only.",
            "smoke downgrade reason");

        // --- Permitted interactive -------------------------------------------------
        service.configure("interactive", "org.mozilla.firefox;title:Notes*", "explorer", false);
        checkEqual(service.status, "observing",
            "permitted interactive waits for the backend");
        service.backend = liveBackend;
        checkEqual(liveBackend.enableRequests, 1, "permitted interactive requested enabling");
        checkJson(liveBackend.includedApplied, ["org.mozilla.firefox", "title:Notes*"],
            "permitted interactive applied the allowlist");
        checkEqual(service.status, "observing", "still observing before the backend enables");
        liveBackend.enabled = true;
        check(service.backendEnabled, "backendEnabled projected");
        checkEqual(service.status, "tiling", "enabled backend reports tiling");
        checkEqual(service.reason, "The tiler is managing the included windows.",
            "tiling reason");
        checkEqual(service.toastCount, 0, "no toast decided without a failure");

        // --- Wrapper load failure ----------------------------------------------------
        service.backendError = "The Windows tiling backend component failed to load.";
        checkEqual(service.status, "refused", "backend error is a refusal");
        checkEqual(service.reason,
            "The Windows tiling backend component failed to load.",
            "backend error reason");
        service.backendError = "";
        checkEqual(service.status, "tiling", "cleared backend error restores tiling");

        // --- Enable refusal toasts ------------------------------------------------
        resetToasts();
        liveBackend.enabled = false;
        service.handleEnableRefused("tiler-mutex-held");
        checkEqual(service.status, "refused", "mutex refusal status");
        checkEqual(service.reason, "Another tiling manager is already running.",
            "mutex refusal reason");
        checkEqual(toasts.length, 1, "mutex refusal decided one toast");
        checkEqual(toasts[0].title, "Tiling is off", "enable-refused toast title");
        checkEqual(toasts[0].message, "Another tiling manager is already running.",
            "mutex toast message");
        checkEqual(toasts[0].icon, "view_quilt", "enable-refused toast icon");
        checkEqual(toasts[0].type, 3, "enable-refused toast is an error");
        service.handleEnableRefused("no-screen");
        checkEqual(toasts.length, 1, "a second refusal adds no toast");
        checkEqual(service.reason, "Another tiling manager is already running.",
            "the first refusal reason is kept");

        service.configure("interactive", "fixture*", "", false);
        service.backend = refusedBackend;
        resetToasts();
        service.handleEnableRefused("no-screen");
        checkEqual(toasts.length, 1, "no-screen refusal decided one toast");
        checkEqual(toasts[0].message, "No screen is available to tile on.",
            "no-screen toast message");
        checkEqual(toasts[0].type, 3, "no-screen toast is an error");
        checkEqual(service.reason, "No screen is available to tile on.",
            "no-screen refusal reason");

        service.configure("interactive", "fixture*", "", false);
        service.backend = unknownBackend;
        resetToasts();
        service.handleEnableRefused("bizarre");
        checkEqual(toasts.length, 1, "unknown refusal decided one toast");
        checkEqual(toasts[0].message, "Tiling could not be enabled.",
            "unknown refusal message fallback");

        // Observe mode ignores enable refusals entirely.
        service.configure("observe", "", "", false);
        service.backend = observeOnly;
        resetToasts();
        service.handleEnableRefused("tiler-mutex-held");
        checkEqual(toasts.length, 0, "observe never explains a refusal");
        checkEqual(service.status, "observing", "observe ignores enable refusal");

        // --- Failure records and toast copy ------------------------------------
        service.configure("interactive", "org.mozilla.firefox", "", false);
        service.backend = failingBackend;
        failingBackend.enabled = true;
        service.resolveToplevel = address => {
            if (address === "2a1b")
                return {appClass: "org.mozilla.firefox", title: "Mozilla Firefox"};
            if (address === "3c4d")
                return {appClass: "", title: "Sticky Notes"};
            return null;
        };
        resetToasts();
        currentTime = 100000;

        service.handleWindowTilingFailed("2a1b", "min-size");
        checkEqual(service.recentFailureCount, 1, "failure recorded");
        checkEqual(service.recentFailures[0].address, "2a1b", "recorded address");
        checkEqual(service.recentFailures[0].appClass, "org.mozilla.firefox",
            "recorded app class");
        checkEqual(service.recentFailures[0].title, "Mozilla Firefox", "recorded title");
        checkEqual(service.recentFailures[0].reason, "min-size", "recorded reason");
        check(service.recentFailures[0].time === 100000, "recorded injected time");
        checkEqual(toasts.length, 1, "min-size decided one toast");
        checkEqual(toasts[0].title, "Couldn't tile org.mozilla.firefox",
            "app class is preferred in the title");
        checkEqual(toasts[0].message,
            "It needs more space than its tile; it was left floating.",
            "min-size message");
        checkEqual(toasts[0].icon, "view_quilt", "failure toast icon");
        checkEqual(toasts[0].type, 2, "failure toast is a warning");

        currentTime = 111000;
        service.handleWindowTilingFailed("3c4d", "off-target");
        checkEqual(toasts[1].title, "Couldn't tile Sticky Notes",
            "title used when no app class resolves");
        checkEqual(toasts[1].message,
            "It kept moving away from its tile; it was left floating.",
            "off-target message");

        currentTime = 122000;
        service.handleWindowTilingFailed("5e6f", "correction-limit");
        checkEqual(toasts[2].title, "Couldn't tile a window",
            "generic wording without resolution");
        checkEqual(toasts[2].message,
            "It didn't fit its tile exactly, so it may leave a gap.",
            "correction-limit message");

        currentTime = 133000;
        service.handleWindowTilingFailed("5e6f", "unresponsive");
        checkEqual(toasts.length, 4, "same address with a new reason toasts again");
        checkEqual(toasts[3].message, "It stopped responding while being placed.",
            "unresponsive message");

        currentTime = 144000;
        service.handleWindowTilingFailed("9a0b", "bizarre");
        checkEqual(toasts[4].message, "It could not be placed in its tile.",
            "unknown reason message fallback");
        checkEqual(service.recentFailureCount, 5, "unknown reason still recorded");

        // Per address+reason dedupe: the record still grows, the toast does not.
        service.handleWindowTilingFailed("2a1b", "min-size");
        checkEqual(toasts.length, 5, "duplicate address+reason adds no toast");
        checkEqual(service.recentFailureCount, 6, "duplicate failure still recorded");

        // --- Recent-failure list cap ------------------------------------------
        for (let i = 0; i < 25; i++)
            service.handleWindowTilingFailed("cap" + i, "min-size");
        checkEqual(service.recentFailureCount, 20, "failure list capped at 20");
        checkEqual(service.recentFailures[0].address, "cap5", "oldest entries dropped");
        checkEqual(service.recentFailures[19].address, "cap24", "newest entry kept");
        check(!service.recentFailures.some(e => e.address === "2a1b"),
            "dropped entries are gone");
        // The frozen clock keeps the burst window saturated: cap0 and cap1 fit
        // the remaining budget, cap2 collapses, cap3..cap24 add nothing.
        checkEqual(toasts.length, 8, "cap loop toasts are burst limited");
        checkEqual(toasts[7].title, "Some windows couldn't be tiled",
            "cap loop produced the collapse toast");

        // --- Burst limit and collapse toast --------------------------------------
        currentTime = 200000;
        service.configure("interactive", "fixture*", "", false);
        service.backend = burstBackend;
        burstBackend.enabled = true;
        resetToasts();
        for (const address of ["a1", "a2", "a3", "a4"])
            service.handleWindowTilingFailed(address, "min-size");
        checkEqual(toasts.length, 4, "fourth failure collapses");
        checkEqual(toasts[2].title, "Couldn't tile a window", "first three toast individually");
        checkEqual(toasts[3].title, "Some windows couldn't be tiled", "collapse title");
        checkEqual(toasts[3].message, "", "collapse message");
        checkEqual(toasts[3].icon, "view_quilt", "collapse icon");
        checkEqual(toasts[3].type, 2, "collapse toast is a warning");
        check(!toasts.some(t => t.title === "Couldn't tile a4"),
            "the fourth failure has no individual toast");

        service.handleWindowTilingFailed("a5", "min-size");
        checkEqual(toasts.length, 4, "collapse does not repeat inside the window");

        currentTime = 210001;
        service.handleWindowTilingFailed("a6", "min-size");
        checkEqual(toasts.length, 5, "budget resets after the window passes");
        checkEqual(toasts[4].title, "Couldn't tile a window", "individual toasts resume");

        for (const address of ["a7", "a8", "a9"])
            service.handleWindowTilingFailed(address, "min-size");
        checkEqual(toasts[7].title, "Some windows couldn't be tiled",
            "a second window collapses again");
        checkEqual(toasts.length, 8, "exactly one collapse per window");

        // --- Enabled-session reset -------------------------------------------------
        burstBackend.enabled = false;
        burstBackend.enabled = true;
        resetToasts();
        service.handleWindowTilingFailed("a1", "min-size");
        checkEqual(toasts[0].title, "Couldn't tile a window",
            "a new enabled session renotifies the same address+reason");

        // --- Localization hook ------------------------------------------------------
        service.tr = text => "T:" + text;
        service.handleWindowTilingFailed("b1", "min-size");
        checkEqual(toasts[1].title, "T:Couldn't tile a window",
            "titles pass through the translate hook");
        checkEqual(toasts[1].message,
            "T:It needs more space than its tile; it was left floating.",
            "messages pass through the translate hook");
        service.tr = text => text;
        service.handleWindowTilingFailed("b2", "min-size");
        checkEqual(toasts[2].title, "Couldn't tile a window",
            "identity translate restores exact copy");
        checkEqual(service.toastCount, toasts.length,
            "toastCount matches the emitted decisions");

        console.log("CAELESTIA_TILING_FIXTURE_PASS " + JSON.stringify({
            assertions: assertions
        }));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            test.run();
        } catch (error) {
            console.error("CAELESTIA_TILING_FIXTURE_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
