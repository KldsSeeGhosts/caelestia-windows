pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import "DesktopControl.js" as DesktopControl

Singleton {
    id: root

    readonly property string python: Quickshell.env("CAELESTIA_WE_PYTHON") || ""
    readonly property string helper: Quickshell.shellPath("services/wallpaperengine_bridge.py")
    readonly property string settingsPath: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json"
    property var options: ({})
    property var configDocument: ({})
    property bool configLoaded: false
    property bool startupSettingsReady: false
    property bool startupDiscoveryReady: false
    property bool startupControlPending: true
    property string pendingDesktopControl: ""
    property string desktopControlError: ""
    property bool desktopControlAwaitingExit: false
    readonly property bool desktopControlAllowed: python !== ""
        && Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property bool desktopControlPending: desktopControl.running || pendingDesktopControl !== ""

    function startupDesktopControl(): void {
        if (!startupControlPending)
            return;
        const request = DesktopControl.startup(startupSettingsReady, startupDiscoveryReady, enabled, running);
        if (request === null)
            return;
        startupControlPending = false;
        requestDesktopControl(request);
    }
    function requestDesktopControl(request: string): void {
        pendingDesktopControl = request;
        drainDesktopControl();
    }
    function drainDesktopControl(): void {
        if (desktopControl.running || !pendingDesktopControl)
            return;
        const command = DesktopControl.command(python, helper, pendingDesktopControl,
            desktopControlAllowed);
        pendingDesktopControl = "";
        if (command.length === 0)
            return;
        desktopControlError = "";
        desktopControl.command = command;
        desktopControlAwaitingExit = true;
        desktopControl.running = true;
        if (!desktopControl.running) {
            desktopControlAwaitingExit = false;
            desktopControlError = "Wallpaper Engine desktop control failed to start";
        }
    }
    onStartupSettingsReadyChanged: startupDesktopControl()
    onStartupDiscoveryReadyChanged: Qt.callLater(startupDesktopControl)
    // An absent key is an install that has not opted in; a saved "auto" is a
    // value an older build wrote and keeps automatic activation. The old
    // default therefore stays distinguishable from no value at all. Nothing
    // rewrites a saved choice on load.
    readonly property bool enabled: options.enabled === true || options.enabled === "auto"
    readonly property bool controlsEnabled: enabled && running && detected
        && Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    property bool detected: false
    property bool running: false
    property bool snapshotReady: !Boolean(python)
    // Keep the native dependency injectable for offscreen ownership fixtures.
    property var desktopLayer: Native.DesktopLayer
    // This is an ownership guard, NOT rendered-output readiness. The bridge
    // has no first-frame or per-screen presentation acknowledgement.
    // Yield before discovery when a helper is configured, and keep yielding
    // to a known running process even if integration is disabled. Startup
    // scan failure falls back to the shell; it cannot prove WE is absent.
    //
    // a detected process is an ownership claim, not proof of ownership.
    // The backend acknowledges the underlay only while a visible wallpaper
    // window is inside the desktop host. Wallpaper Engine keeps running after
    // its wallpaper is closed, though: the window leaves the host while
    // wallpaper64.exe stays alive, and the process scan alone would keep
    // claiming a desktop nobody owns. Once the backend has acknowledged the
    // underlay, a genuine withdrawal (no refused embed, no above-icons embed,
    // host still active) releases the claim so the shell's own wallpaper is
    // visible again. A new process, a refused embed or a lost host stays
    // fail-closed until a fresh acknowledgement.
    readonly property bool underlaySupported: "underlayActive" in root.desktopLayer
    readonly property bool underlayActive: underlaySupported && root.desktopLayer.underlayActive
    readonly property bool embedRefusedSupported: "embedRefused" in root.desktopLayer
    readonly property bool embedRefused: embedRefusedSupported && root.desktopLayer.embedRefused
    property bool desktopClaimed: false
    property bool desktopHandedBack: false
    readonly property bool ownsDesktop: !snapshotReady || (running && !desktopHandedBack)
    onRunningChanged: {
        // A stop is still engine-era discovery: keep the handback latch so a
        // native wallpaper notification cannot replace the verified source
        // after the claim is gone. A process start clears the latch and has no
        // claim yet: fail closed until the backend finds its wallpaper window
        // in the desktop host.
        desktopClaimed = running && underlayActive;
        if (running)
            desktopHandedBack = false;
    }
    onUnderlayActiveChanged: {
        if (underlayActive) {
            desktopClaimed = true;
            desktopHandedBack = false;
        } else if (embedRefusedSupported && desktopClaimed && !embedRefused
                   && root.desktopLayer.enabled && root.desktopLayer.active
                   && root.desktopLayer.aboveIcons.length === 0) {
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
    property string actionMonitor: ""
    property string actionScreenTarget: ""
    // The bridge's own subprocess timeout is 15 s; this outer watchdog only
    // covers a helper that never returns, so it must outlast the bridge error
    // that is worth showing.
    property int actionTimeout: 20000
    property bool actionPending: false
    property bool actionTimedOut: false
    // Full snapshots parse every workshop project.json, so idle polls run the
    // cheap status mode and escalate only when something changed.
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
            // forever.
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
        // hostage; the poll keeps retrying.
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
        startupDiscoveryReady = true;
    }

    function applyDiscoveryFailure(data): void {
        // A readable process list still establishes start/stop even if the
        // selected-project config is locked/partial. Keep the last catalogue,
        // but never let its stale running flag hold the desktop hostage.
        running = data.running;
        snapshotReady = true;
        startupDiscoveryReady = true;
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
        startupDiscoveryReady = true;
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

    // Nexus writes the opt-in here. reload() is asynchronous once this view
    // has loaded, so the merge happens from onLoaded (or onLoadFailed) with
    // the text that read returned. Reading text() straight after reload()
    // merges the stale document and drops keys written since the last watch
    // event. A malformed or unreadable existing file is never replaced.
    //
    // setText() cannot run from onLoaded: the native view still owns the read
    // operation when it emits loaded(), so a save issued there replaces the
    // live operation and its saved() is dropped. The write is queued after
    // that callback, and the facade value only changes in saved().
    property bool togglePending: false
    property bool toggleValue: false
    property bool configSavePending: false
    // A save has finished and its bytes are being read back. saved() alone
    // does not prove the destination changed on the pinned backend (issue
    // #28), so the toggle is applied only after the file matches.
    property bool configSaveVerifying: false
    property var pendingConfigDocument: null
    property string pendingConfigText: ""

    function setEnabled(on: bool): void {
        // Rapid clicks collapse into one merge with the latest value. A save
        // in flight finishes first; saved() then reruns the latest value.
        root.toggleValue = on === true;
        if (root.configSavePending)
            return;
        root.togglePending = true;
        configFile.reload();
    }
    function commitToggle(content): void {
        const text = String(content ?? "").replace(/^\uFEFF/, "").trim();
        let document = {};
        if (text.length > 0) {
            try {
                const parsed = JSON.parse(text);
                if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
                    throw new Error("the document is not an object");
                document = parsed;
            } catch (error) {
                root.lastError = "Wallpaper Engine settings are not valid JSON: " + String(error);
                return;
            }
        }
        const next = JSON.parse(JSON.stringify(document));
        if (!next.windows || typeof next.windows !== "object" || Array.isArray(next.windows))
            next.windows = {};
        const current = next.windows.wallpaperEngine;
        next.windows.wallpaperEngine = current && typeof current === "object" && !Array.isArray(current)
            ? Object.assign({}, current, {enabled: root.toggleValue}) : {enabled: root.toggleValue};
        const serialized = JSON.stringify(next, null, 2) + "\n";
        root.pendingConfigDocument = next;
        root.pendingConfigText = serialized;
        // FileView drops an identical setText(), so a toggle that returns to
        // the document already on disk would never emit saved(). Complete it
        // here instead of leaving configSavePending set and blocking every
        // later toggle (backend issue #28).
        if (serialized === String(content ?? "").replace(/^\uFEFF/, "")) {
            root.applyToggle();
            return;
        }
        root.configSavePending = true;
        root.lastError = "";
        Qt.callLater(() => {
            if (root.configSavePending)
                configFile.setText(root.pendingConfigText);
        });
    }
    function applyToggle(): void {
        const next = root.pendingConfigDocument;
        root.configSavePending = false;
        root.configSaveVerifying = false;
        root.pendingConfigDocument = null;
        root.pendingConfigText = "";
        root.configDocument = next;
        root.options = next?.windows?.wallpaperEngine ?? {};
        root.configLoaded = true;
        root.lastError = "";
        // Only a verified Nexus save is a user request. Watcher reloads and
        // discovery never send desktop commands.
        root.startupControlPending = false;
        root.requestDesktopControl(DesktopControl.toggle(root.enabled));
        // A click made while the write was in flight keeps only the latest
        // value; merge it against the file that was just saved.
        if (root.toggleValue !== root.enabled)
            Qt.callLater(() => root.setEnabled(root.toggleValue));
    }

    function open(path: string, screen): bool {
        if (!controlsEnabled || action.running || !items.some(item => item.path === path))
            return false;
        // Capture the owning screen's identity now. Config changes, a picker
        // closing, or moving its window cannot retarget the async process.
        const explicit = screen !== undefined;
        const target = explicit && screen ? Native.Wallpaper.screenTargetId(screen.name) : "";
        if ((explicit && (!target || (screen.targetId !== undefined && screen.targetId !== target)))
                || (!explicit && !/^Monitor\d+$/.test(monitor))) {
            lastError = "The wallpaper display is no longer available";
            Toaster.toast("Wallpaper Engine", lastError, "wallpaper");
            return false;
        }
        actionProject = path;
        actionScreenTarget = target;
        actionMonitor = monitor.replace(/^Monitor/, "");
        actionTimedOut = false;
        actionPending = true;
        actionWatchdog.restart();
        action.running = true;
        if (!action.running) {
            // FailedToStart clears running without emitting exited. Clear the
            // claim here so the next selection is not blocked behind it.
            actionPending = false;
            actionWatchdog.stop();
            actionFailed("wallpaper engine helper failed to start");
            return false;
        }
        return true; // Request accepted; config watcher confirms actual selection.
    }
    function actionFailed(message: string): void {
        lastError = message;
        Toaster.toast("Wallpaper Engine", lastError, "wallpaper");
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
        id: configFile
        path: root.settingsPath
        watchChanges: true
        blockLoading: true
        printErrors: false
        onFileChanged: reload()
        onLoaded: {
            const content = text();
            try {
                const parsed = JSON.parse(String(content).replace(/^\uFEFF/, ""));
                if (!parsed || typeof parsed !== "object" || Array.isArray(parsed))
                    throw new Error("windows.json is not an object");
                root.configDocument = parsed;
                root.options = parsed.windows?.wallpaperEngine ?? {};
                root.configLoaded = true;
                root.startupSettingsReady = true;
            } catch (error) {
                // A malformed read can be a writer's partial document. Keep
                // the last successfully loaded settings instead of disabling
                // an integration this profile opted into. A missing key in the
                // document just defaults to off, as before.
                root.configLoaded = true;
                root.lastError = String(error);
            }
            // This load is the fresh read the toggle asked for.
            if (root.togglePending) {
                root.togglePending = false;
                root.commitToggle(content);
            }
        }
        onLoadFailed: error => {
            // The sidecar is seeded with the profile. A missing file is a
            // fresh install, not a reason to enable the integration.
            if (root.togglePending) {
                root.togglePending = false;
                if (error === FileViewError.FileNotFound) {
                    root.commitToggle("");
                    return;
                }
                // The file exists but could not be read. Writing a document
                // built from nothing would drop every key it holds.
                root.lastError = "Wallpaper Engine settings could not be read";
                return;
            }
            // A transient lock is not evidence that the saved setting went
            // away. Keep the last successfully loaded document and options;
            // unlocking the file may not raise another change event. Only a
            // missing file clears them, so an absent key defaults to off.
            if (error === FileViewError.FileNotFound) {
                root.configDocument = {};
                root.options = {};
                root.startupSettingsReady = true;
            }
            root.configLoaded = true;
            if (error !== FileViewError.FileNotFound)
                root.lastError = "Wallpaper Engine settings could not be read";
        }
        onSaved: {
            if (root.configSavePending) {
                // saved() alone does not prove the bytes on this backend
                // (issue #28): a failed QSaveFile::commit() is only logged.
                // Read the file back through a separate view before applying.
                root.configSaveVerifying = true;
                configVerify.path = root.settingsPath;
                configVerify.reload();
            } else {
                root.lastError = "";
            }
        }
        onSaveFailed: error => {
            if (root.configSavePending) {
                // Never apply a value that did not reach disk. The switch
                // stays on the saved state and the error stays visible.
                root.configSavePending = false;
                root.configSaveVerifying = false;
                root.pendingConfigDocument = null;
                root.pendingConfigText = "";
            }
            root.lastError = "Could not save Wallpaper Engine settings: " + String(error);
        }
    }
    // Independent read-back of the settings write. The saving view cannot
    // reload itself from its own saved() callback, and on the pinned backend
    // saved() is emitted even when the atomic commit failed (issue #28). This
    // workaround can go when the backend reports the failure.
    FileView {
        id: configVerify
        // Assigned when a save needs checking. Starting empty avoids a
        // startup read whose completion could race the verification.
        path: ""
        watchChanges: false
        printErrors: false
        onLoaded: {
            if (!root.configSaveVerifying)
                return;
            root.configSaveVerifying = false;
            if (String(text()).replace(/^\uFEFF/, "") === root.pendingConfigText) {
                root.applyToggle();
            } else {
                root.configSavePending = false;
                root.pendingConfigDocument = null;
                root.pendingConfigText = "";
                root.lastError = "Could not save Wallpaper Engine settings: the saved file did not match";
            }
        }
        onLoadFailed: {
            if (!root.configSaveVerifying)
                return;
            root.configSaveVerifying = false;
            root.configSavePending = false;
            root.pendingConfigDocument = null;
            root.pendingConfigText = "";
            root.lastError = "Could not save Wallpaper Engine settings: the saved file could not be read back";
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
    // cheap status mode. Discovery never launches Wallpaper Engine.
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
    // A hung or unspawnable scan must not claim the desktop forever.
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
    // A selection whose helper never returns must not keep action.running true
    // forever; later selections are blocked by that flag. Outlast the bridge's
    // own 15 s dispatch timeout so its error wins when it can report one.
    Timer {
        id: actionWatchdog
        interval: root.actionTimeout
        onTriggered: {
            if (!root.actionPending && !action.running)
                return;
            root.actionTimedOut = true;
            root.actionPending = false;
            if (action.running) {
                action.signal(9);
                action.running = false;
            }
            root.actionFailed("wallpaper engine action timed out");
            debounce.restart();
        }
    }
    Process {
        id: action
        objectName: "wallpaperEngineAction"
        command: [root.python, root.helper, "open", "--project", root.actionProject,
            root.actionScreenTarget ? "--screen-target" : "--monitor",
            root.actionScreenTarget || root.actionMonitor]
        stdout: StdioCollector { id: actionOutput }
        onRunningChanged: {
            if (!action.running && root.actionPending) {
                Qt.callLater(() => {
                    if (!action.running && root.actionPending) {
                        root.actionPending = false;
                        actionWatchdog.stop();
                        root.actionFailed("wallpaper engine helper failed to start");
                    }
                });
            }
        }
        onExited: code => {
            root.actionPending = false;
            actionWatchdog.stop();
            const timedOut = root.actionTimedOut;
            root.actionTimedOut = false;
            if (!timedOut && code !== 0) {
                let message = "Wallpaper change failed";
                try { message = JSON.parse(actionOutput.text).error || message; }
                catch (error) { message = "Wallpaper change failed"; }
                root.actionFailed(message);
            }
            debounce.restart();
        }
    }
    Process {
        id: desktopControl
        objectName: "wallpaperEngineDesktopControl"
        onRunningChanged: {
            if (!running) {
                Qt.callLater(() => {
                    if (!desktopControl.running && root.desktopControlAwaitingExit) {
                        root.desktopControlAwaitingExit = false;
                        root.desktopControlError = "Wallpaper Engine desktop control failed to start";
                    }
                    root.drainDesktopControl();
                });
            }
        }
        onExited: code => {
            root.desktopControlAwaitingExit = false;
            // Dispatch is not visible-output acknowledgement. Keep native
            // ownership/handback detection as the physical desktop authority.
            if (code !== 0) {
                root.desktopControlError = "Wallpaper Engine could not change desktop playback";
                Toaster.toast("Wallpaper Engine", root.desktopControlError, "wallpaper");
            }
        }
    }
}
