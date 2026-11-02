pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Config
import qs.services

Singleton {
    id: root

    readonly property string python: Quickshell.env("CAELESTIA_WE_PYTHON") || ""
    readonly property string helper: Quickshell.shellPath("services/wallpaperengine_bridge.py")
    property var options: ({})
    readonly property bool enabled: options.enabled !== false
    readonly property bool controlsEnabled: enabled && running && detected
        && Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    property bool detected: false
    property bool running: false
    property bool snapshotReady: !Boolean(python)
    // This is an ownership guard, NOT rendered-output readiness. The bridge
    // has no first-frame or per-screen presentation acknowledgement (#146).
    // Yield before discovery when a helper is configured, and keep yielding
    // to a known running process even if integration is disabled. Startup
    // scan failure falls back to the shell; it cannot prove WE is absent.
    readonly property bool ownsDesktop: !snapshotReady || running
    property string status: python ? "discovering" : "unavailable"
    property string lastError: ""
    property string configPath: ""
    property var items: []
    property var monitors: ({})
    readonly property string monitor: String(options.monitor || "Monitor0")
    readonly property var current: monitors[monitor] ?? null
    readonly property string picker: !enabled ? "files" : ["engine", "files", "both"].includes(options.picker)
        ? options.picker : (running && detected && enabled ? "engine" : "files")
    property string lastPaletteKey: ""
    property string actionProject: ""
    // Wallpaper titles and file paths are user content (#116): anything
    // identifying goes to the log only behind an explicit opt-in.
    readonly property bool debugLogging: Quickshell.env("CAELESTIA_WE_DEBUG") === "1"
    // Full snapshots parse every workshop project.json, so idle polls run the
    // cheap status mode and escalate only when something changed (#125).
    property bool haveSnapshot: false
    property bool fullScanNeeded: true
    property int statusTicks: 0
    property string lastStatusActiveJson: ""
    property string itemsJson: ""
    property string monitorsJson: ""
    property bool scanPending: false
    property bool scanTimedOut: false

    function refresh(deep: bool): void {
        if (!python) {
            status = "unavailable";
            // No bridge binary: release the desktop instead of claiming it
            // forever (#125).
            if (!snapshotReady)
                snapshotReady = true;
            return;
        }
        if (deep === true)
            fullScanNeeded = true;
        startScan(!fullScanNeeded && haveSnapshot && statusTicks < 20);
    }

    function startScan(statusOnly: bool): void {
        if (scan.running || scanPending)
            return;
        scan.statusOnly = statusOnly;
        scanTimedOut = false;
        scanPending = true;
        scanWatchdog.restart();
        scan.running = true;
        if (!scan.running && scanPending) {
            // FailedToStart clears running without emitting exited.
            scanPending = false;
            scanWatchdog.stop();
            scanFailed("wallpaper engine helper failed to start");
        }
    }

    function scanFailed(message: string): void {
        if (!scan.statusOnly)
            fullScanNeeded = true;
        status = "error";
        lastError = message;
        // Retain the last good state during partial/locked JSON writes, but a
        // failure before the first good snapshot must not hold the desktop
        // hostage; the poll keeps retrying (#125).
        if (!snapshotReady)
            snapshotReady = true;
    }

    function applySnapshot(data): void {
        detected = data.detected;
        running = data.running;
        configPath = data.configPath || "";
        // Compare against one cached serialization instead of re-stringifying
        // the live models: redundant assignments would rebuild the carousel
        // delegates on every poll.
        const nextItems = JSON.stringify(data.items);
        if (nextItems !== itemsJson) {
            itemsJson = nextItems;
            items = data.items;
        }
        const nextMonitors = JSON.stringify(data.monitors);
        if (nextMonitors !== monitorsJson) {
            monitorsJson = nextMonitors;
            monitors = data.monitors;
        }
        lastStatusActiveJson = JSON.stringify(data.active ?? {});
        haveSnapshot = true;
        fullScanNeeded = false;
        statusTicks = 0;
        snapshotReady = true;
        status = !enabled ? "disabled" : running && detected ? "ready" : "absent";
        lastError = "";
        matchColours();
    }

    function applyDiscoveryFailure(data): void {
        // A readable process list still establishes start/stop even if the
        // selected-project config is locked/partial. Keep the last catalogue,
        // but never let its stale running flag hold the desktop hostage.
        running = data.running;
        snapshotReady = true;
        scanFailed(data.discoveryError);
    }

    function applyStatus(data): void {
        const stateChanged = detected !== data.detected || running !== data.running;
        detected = data.detected;
        running = data.running;
        if (data.configPath)
            configPath = data.configPath;
        snapshotReady = true;
        statusTicks++;
        const activeJson = JSON.stringify(data.active ?? {});
        const changed = stateChanged || activeJson !== lastStatusActiveJson;
        if (!haveSnapshot || fullScanNeeded || changed || statusTicks >= 20) {
            // First settle, a changed selection/state, or the periodic catalogue
            // refresh (workshop installs). Keep fullScanNeeded and lastStatusActiveJson
            // unacknowledged until applySnapshot succeeds.
            fullScanNeeded = true;
            Qt.callLater(() => startScan(false));
            return;
        }
        status = !enabled ? "disabled" : running && detected ? "ready" : "absent";
        lastError = "";
    }

    function matchColours(): void {
        if (!enabled || !detected || !running || !current?.preview || !SchemeGenerator.available)
            return;
        const key = current.path + "|" + current.preview + "|" + GlobalConfig.services.smartScheme;
        if (key === lastPaletteKey)
            return;
        lastPaletteKey = key;
        SchemeGenerator.applyWallpaper(current.preview, GlobalConfig.services.smartScheme);
        if (debugLogging)
            console.log("CAELESTIA_WE_CURRENT", JSON.stringify({monitor: monitor, title: current.title, project: current.path, preview: current.preview}));
    }

    function open(path: string): bool {
        if (!controlsEnabled || action.running || !/^Monitor\d+$/.test(monitor) || !items.some(item => item.path === path))
            return false;
        actionProject = path;
        action.running = true;
        return true; // Request accepted; config watcher confirms actual selection.
    }

    onCurrentChanged: matchColours()
    onEnabledChanged: {
        lastPaletteKey = "";
        // Disabling stops the idle timer; re-enabling must not wait for its
        // backed-off interval before the first scan.
        if (enabled)
            refresh(false);
        matchColours();
    }
    onRunningChanged: { lastPaletteKey = ""; matchColours(); }
    Component.onCompleted: refresh(false)

    FileView {
        path: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json"
        watchChanges: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            try { root.options = JSON.parse(text()).windows?.wallpaperEngine ?? {}; }
            catch (error) { root.lastError = String(error); }
        }
    }
    FileView {
        path: root.configPath
        watchChanges: true
        printErrors: false
        onFileChanged: { reload(); debounce.restart(); }
    }
    Timer { id: debounce; interval: 300; onTriggered: root.refresh(true) }
    // Catches WE starting/stopping and selection changes the config watcher
    // misses, including atomic replacement of config.json. Idle ticks run the
    // cheap status mode (#125). Discovery never launches Wallpaper Engine.
    // Poll at 15 s only while WE is present and running; absent, stopped or
    // failed scans back off to 60 s, still noticing a start within a minute.
    // The timer stops when the integration is disabled or no helper is set.
    readonly property int pollInterval: detected && running && status !== "error" ? 15000 : 60000
    Timer {
        id: pollTimer
        interval: root.pollInterval
        running: root.enabled && root.python !== ""
        repeat: true
        onTriggered: root.refresh(false)
    }
    // A hung or unspawnable scan must not claim the desktop forever (#125).
    Timer {
        id: scanWatchdog
        interval: 10000
        onTriggered: {
            if (root.scanPending || scan.running) {
                root.scanPending = false;
                root.scanTimedOut = true;
                if (scan.running) {
                    scan.signal(9);
                    scan.running = false;
                }
                root.scanFailed("wallpaper engine scan timed out");
            }
        }
    }
    Connections {
        target: SchemeGenerator
        function onFailed(message: string): void { root.lastPaletteKey = ""; }
        function onAvailableChanged(): void { root.matchColours(); }
    }
    Connections {
        target: GlobalConfig.services
        function onSmartSchemeChanged(): void { root.matchColours(); }
    }
    Process {
        id: scan
        property bool statusOnly: false
        command: [root.python, root.helper, "snapshot"].concat(statusOnly ? ["--status-only"] : [])
        stdout: StdioCollector { id: scanOutput }
        onRunningChanged: {
            if (!scan.running && root.scanPending) {
                Qt.callLater(() => {
                    if (!scan.running && root.scanPending) {
                        root.scanPending = false;
                        scanWatchdog.stop();
                        root.scanFailed("wallpaper engine helper failed to start");
                    }
                });
            }
        }
        onExited: code => {
            root.scanPending = false;
            scanWatchdog.stop();
            const timedOut = root.scanTimedOut;
            root.scanTimedOut = false;
            if (timedOut)
                return;
            try {
                const data = JSON.parse(scanOutput.text);
                if (code !== 0 || !data.ok)
                    throw new Error(data.error || "discovery failed");
                if (data.discoveryError)
                    root.applyDiscoveryFailure(data);
                else if (scan.statusOnly)
                    root.applyStatus(data);
                else
                    root.applySnapshot(data);
            } catch (error) {
                root.scanFailed(timedOut ? "wallpaper engine scan timed out" : String(error));
            }
        }
    }
    Process {
        id: action
        command: [root.python, root.helper, "open", "--project", root.actionProject,
            "--monitor", root.monitor.replace(/^Monitor/, "")]
        stdout: StdioCollector { id: actionOutput }
        onExited: code => {
            if (code !== 0) {
                root.lastError = actionOutput.text.trim();
                Toaster.toast("Wallpaper Engine", root.lastError, "wallpaper");
            }
            debounce.restart();
        }
    }
}
