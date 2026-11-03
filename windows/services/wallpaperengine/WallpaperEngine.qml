pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
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
    //
    // WINDOWS_DESKTOP_OWNERSHIP_BEGIN
    // #214: a detected process is an ownership claim, not proof of ownership.
    // The backend acknowledges the underlay only while a visible wallpaper
    // window is inside the desktop host. Wallpaper Engine keeps running after
    // its wallpaper is closed, though: the window leaves the host while
    // wallpaper64.exe stays alive, and the process scan alone would keep
    // claiming a desktop nobody owns. Once the backend has acknowledged the
    // underlay, a genuine withdrawal (no refused embed, no above-icons embed,
    // host still active) releases the claim so the shell's own wallpaper is
    // visible again. A new process, a refused embed or a lost host stays
    // fail-closed until a fresh acknowledgement.
    readonly property bool underlaySupported: "underlayActive" in Native.DesktopLayer
    readonly property bool underlayActive: underlaySupported && Native.DesktopLayer.underlayActive
    readonly property bool embedRefusedSupported: "embedRefused" in Native.DesktopLayer
    readonly property bool embedRefused: embedRefusedSupported && Native.DesktopLayer.embedRefused
    property bool desktopClaimed: false
    property bool desktopHandedBack: false
    readonly property bool ownsDesktop: !snapshotReady || (running && !desktopHandedBack)
    onRunningChanged: {
        // A stop is still engine-era discovery: keep the handback latch so a
        // native wallpaper notification cannot replace the verified source
        // after the claim is gone. A process start clears the latch and has no
        // claim yet: fail closed until the backend finds its wallpaper window
        // in the desktop host (#214).
        desktopClaimed = running && underlayActive;
        if (running)
            desktopHandedBack = false;
    }
    onUnderlayActiveChanged: {
        if (underlayActive) {
            desktopClaimed = true;
            desktopHandedBack = false;
        } else if (embedRefusedSupported && desktopClaimed && !embedRefused
                   && Native.DesktopLayer.enabled && Native.DesktopLayer.active
                   && Native.DesktopLayer.aboveIcons.length === 0) {
            // The acknowledged wallpaper window left the host while the
            // process keeps running: a genuine handback. A refusal or our own
            // above-icons embed is not, and stays fail-closed. Release the
            // claim before clearing the acknowledgement so the adapter never
            // sees externalActive still true with underlayActive false.
            desktopHandedBack = true;
            desktopClaimed = false;
        }
    }
    onEmbedRefusedChanged: {
        // A refused SetParent leaves a panel top level. Never keep a stale
        // claim through it; only a fresh acknowledgement restores the claim.
        if (embedRefused) {
            desktopClaimed = false;
            desktopHandedBack = false;
        } else if (underlayActive) {
            desktopClaimed = true;
            desktopHandedBack = false;
        }
    }
    function seedDesktopClaim(): void {
        // A QML reload keeps the native host and its acknowledgement; start
        // claimed so a handback after the reload is not mistaken for startup.
        desktopClaimed = underlayActive;
        desktopHandedBack = false;
    }
    // WINDOWS_DESKTOP_OWNERSHIP_END
    property string status: python ? "discovering" : "unavailable"
    property string lastError: ""
    property string configPath: ""
    property var items: []
    property var monitors: ({})
    readonly property string monitor: String(options.monitor || "Monitor0")
    readonly property var current: monitors[monitor] ?? null
    readonly property string picker: !enabled ? "files" : ["engine", "files", "both"].includes(options.picker)
        ? options.picker : (running && detected && enabled ? "engine" : "files")
    property string actionProject: ""
    // Full snapshots parse every workshop project.json, so idle polls run the
    // cheap status mode and escalate only when something changed (#125).
    property bool haveSnapshot: false
    property bool fullScanNeeded: true
    property int statusTicks: 0
    property string itemsJson: ""
    property string monitorsJson: ""
    property bool scanPending: false
    property bool scanTimedOut: false
    // The config watcher starts a status scan immediately; a scan that is
    // already running gets one queued status pass instead of being dropped.
    property bool activeScan: false
    property bool activeScanPending: false
    property bool configScanRequested: false
    property bool configPrimed: false
    property double scanStartedAt: 0

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
        scanStartedAt = Date.now();
        scanWatchdog.restart();
        scan.running = true;
        if (!scan.running && scanPending) {
            // FailedToStart clears running without emitting exited.
            scanPending = false;
            scanWatchdog.stop();
            scanFailed("wallpaper engine helper failed to start");
        }
    }

    // A selection change only moves the active projects; the workshop
    // catalogue does not change. Status mode resolves those projects without
    // the full catalogue walk, and the complete config read is itself the
    // change event, so the palette path never waits for a fixed debounce.
    function refreshActive(): void {
        if (!python || !haveSnapshot)
            return;
        if (scan.running || scanPending) {
            activeScanPending = true;
            return;
        }
        activeScan = true;
        console.debug("CAELESTIA_PALETTE_TIMING stage=active_scan_start ts=" + Date.now());
        startScan(true);
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
        haveSnapshot = true;
        fullScanNeeded = false;
        statusTicks = 0;
        snapshotReady = true;
        status = !enabled ? "disabled" : running && detected ? "ready" : "absent";
        lastError = "";
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
        // Status mode carries the resolved selected projects, so a config
        // change reaches currentImage without waiting for the catalogue scan.
        if (data.monitors) {
            const nextMonitors = JSON.stringify(data.monitors);
            if (nextMonitors !== monitorsJson) {
                monitorsJson = nextMonitors;
                console.debug("CAELESTIA_PALETTE_TIMING stage=monitors_changed source=status ts=" + Date.now());
                monitors = data.monitors;
            }
        }
        snapshotReady = true;
        statusTicks++;
        if (!haveSnapshot || fullScanNeeded || stateChanged || statusTicks >= 20) {
            // First settle, a start/stop, or the periodic catalogue refresh
            // (workshop installs). A selection-only change is already applied
            // above and does not need the catalogue walk. Keep fullScanNeeded
            // unacknowledged until applySnapshot succeeds.
            fullScanNeeded = true;
            Qt.callLater(() => startScan(false));
            return;
        }
        status = !enabled ? "disabled" : running && detected ? "ready" : "absent";
        lastError = "";
    }

    function open(path: string): bool {
        if (!controlsEnabled || action.running || !/^Monitor\d+$/.test(monitor) || !items.some(item => item.path === path))
            return false;
        actionProject = path;
        action.running = true;
        return true; // Request accepted; config watcher confirms actual selection.
    }

    onEnabledChanged: {
        // Disabling stops the idle timer; re-enabling must not wait for its
        // backed-off interval before the first scan.
        if (enabled)
            refresh(false);
    }
    Component.onCompleted: {
        seedDesktopClaim();
        refresh(false);
    }

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
        onFileChanged: {
            root.configScanRequested = false;
            reload();
            debounce.restart();
        }
        onLoaded: {
            // The first load follows configPath appearing after the startup
            // snapshot; only later loads are changes.
            if (!root.configPrimed) {
                root.configPrimed = true;
                return;
            }
            if (!root.haveSnapshot)
                return;
            // A complete load is the change event. A partially written config
            // fails this parse and the next change brings another complete
            // read; the debounce below only covers a missed notification.
            let parsed = null;
            try { parsed = JSON.parse(String(text()).replace(/^\uFEFF/, "")); }
            catch (error) { parsed = null; }
            if (!parsed || typeof parsed !== "object")
                return;
            root.configScanRequested = true;
            console.debug("CAELESTIA_PALETTE_TIMING stage=config_loaded ts=" + Date.now());
            root.refreshActive();
        }
    }
    // Fallback for a config change whose complete-read notification was
    // missed. It is not on the palette path: onLoaded starts the status scan.
    Timer { id: debounce; interval: 300; onTriggered: { if (!root.configScanRequested) root.refreshActive(); } }
    // Catches WE starting/stopping and selection changes the config watcher
    // misses, including atomic replacement of config.json. Idle ticks run the
    // cheap status mode (#125). Discovery never launches Wallpaper Engine.
    // Poll at 15 s only while WE is present and running; absent, stopped or
    // failed scans back off to 60 s, still noticing a start within a minute.
    // Disabled integration stops polling, except while a WE process is still
    // known to run: ownership must still be handed back when it quits.
    readonly property int pollInterval: detected && running && status !== "error" ? 15000 : 60000
    Timer {
        id: pollTimer
        interval: root.pollInterval
        running: (root.enabled || root.running) && root.python !== ""
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
            if (root.activeScan) {
                root.activeScan = false;
                console.debug("CAELESTIA_PALETTE_TIMING stage=active_scan_done ts=" + Date.now() + " elapsed_ms=" + (Date.now() - root.scanStartedAt));
            }
            if (!timedOut) {
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
                    root.scanFailed(String(error));
                }
            }
            if (root.activeScanPending) {
                root.activeScanPending = false;
                Qt.callLater(() => root.refreshActive());
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
