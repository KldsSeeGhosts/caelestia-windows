pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Windows
import qs.services
import qs.utils

// Windows: first-party Caelestia capture ships with the shell. The shell resolves the bundled
// executable, launches its tray host and owns the capture/record hotkeys;
// Glazier owns the picker, editor and recorder. Never read the executable as data.
Singleton {
    id: root

    readonly property string configPath: (Quickshell.env("CAELESTIA_CONFIG_DIR") || "").replace(/\\/g, "/") + "/glazier.json"
    // The running payload is the parent of the staged shell directory, so the
    // bundled tool follows update and rollback. A provider lets offscreen
    // fixtures stage their own payload.
    readonly property string defaultPayloadRoot: Quickshell.shellDir.replace(/\\/g, "/").replace(/\/[^/]*$/, "")
    property string payloadRoot: defaultPayloadRoot
    readonly property string bundledPath: payloadRoot.replace(/\/+$/, "") + "/caelestia-capture.exe"
    readonly property string themeFile: Paths.state + "/theme-tokens.json"
    // Explicit fallback only: the bundled payload wins, and there is no
    // machine-wide or %LOCALAPPDATA% install location.
    property string configuredPath: ""
    property bool configReady: false
    readonly property bool ready: configReady
    property string executable: ""
    readonly property bool available: executable.length > 0
    // Only the installed live shell launches the tray host. Fixtures, the
    // combined development host and smoke profiles must never start a process.
    readonly property bool permitted: Quickshell.env("CAELESTIA_SHELL_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"

    // Kept as providers so the exact dismissal path can be tested offscreen.
    property var screenProvider: Screens
    property var stateProvider: ShellState
    // Dismissal waits for the shell surfaces' own visible signals. The timeout
    // reports "not ready" and never captures over shell UI.
    property int hiddenTimeout: 2000
    property string pendingPath: ""
    property var pendingArgs: []
    property string pendingLabel: "Screenshot"
    property var watchedSurfaces: []
    readonly property bool ownedHost: hostLifecycle.snapshot.owned ?? false
    // True only after this shell session's process creates the host. Its journal
    // began after the shell did, so Recorder treats that host's first response as
    // fresh events instead of a pre-restart baseline. Forwarding a command to a
    // host that is already running does not create one, and an adopted host never
    // sets this. Native identity and launch-generation lease establish this,
    // never the lifetime of a forwarding command client.
    readonly property bool launchedHost: hostLifecycle.snapshot.launched ?? false
    readonly property var hostState: hostLifecycle.snapshot
    property string lifecyclePath: ""
    property var reloadCallback: null
    property bool quitPending: false
    readonly property string hostWindowClass: hostClass(executable)
    function hostClass(path): string {
        // External legacy overrides keep their legacy class AND v1 protocol.
        // The first-party binary uses managed identity even for --status alone.
        return /(?:^|[\\/])caelestia-capture\.exe$/i.test(path) ? "CaelestiaCaptureHost" : "GlazierHost";
    }

    readonly property var panelNames: ["osd", "session", "launcher", "dashboard", "quota", "utilities", "sidebar"]

    function validPath(path): bool {
        return typeof path === "string" && /^(?:[A-Za-z]:\/|\/\/)/.test(path)
            && !/[*?]/.test(path) && path.lastIndexOf("/") > 1;
    }
    function resolvePath(bundled, configured, exists): string {
        if (validPath(bundled) && exists(bundled))
            return bundled;
        return validPath(configured) && exists(configured) ? configured : "";
    }
    function refresh(): void {
        executable = resolvePath(bundledPath, configuredPath, path => WindowsFiles.isFile(path));
    }
    function configure(text): void {
        let path = "";
        try {
            const value = JSON.parse(text.replace(/^\uFEFF/, "")).executable;
            if (typeof value === "string")
                path = value.trim().replace(/\\/g, "/");
        } catch (_) {}
        configuredPath = validPath(path) ? path : "";
        configReady = true;
        refresh();
    }
    function dismiss(): void {
        for (const screen of screenProvider.screens) {
            const state = stateProvider.forScreen(screen);
            if (state) {
                // Not "bar": in non-persistent mode it changes the exclusive zone and reflows windows.
                for (const name of panelNames)
                    state[name] = false;
            }
            const components = stateProvider.componentsFor(screen);
            components?.panels?.popouts?.close();
            components?.bar?.closeTray();
            // The Windows tray uses click-toggle (autoCollapse false), so the
            // normal close path leaves it expanded while the screen freezes.
            components?.bar?.collapseTray();
        }
    }
    function surfacesHidden(): bool {
        for (const screen of screenProvider.screens) {
            const components = stateProvider.componentsFor(screen);
            const panels = components?.panels;
            if (panels) {
                for (const name of [...panelNames, "popoutsWrapper"])
                    if (panels[name]?.visible)
                        return false;
            }
            // The tray's expanded height animates; wait for both the logical
            // collapse and the end of the animation.
            const bar = components?.bar;
            if (bar && (bar.trayExpanded || !bar.traySettled))
                return false;
        }
        return true;
    }
    function watchSignal(item, name): void {
        if (!item)
            return;
        const signal = item[name];
        if (!signal || typeof signal.connect !== "function")
            return;
        for (const entry of watchedSurfaces)
            if (entry.item === item && entry.name === name)
                return;
        watchedSurfaces.push({ item: item, name: name, signal: signal });
        signal.connect(surfaceChanged);
    }
    function watchSurface(item): void {
        watchSignal(item, "visibleChanged");
    }
    function watchSurfaces(): void {
        for (const screen of screenProvider.screens) {
            const components = stateProvider.componentsFor(screen);
            const panels = components?.panels;
            if (panels) {
                for (const name of panelNames)
                    watchSurface(panels[name]);
                watchSurface(panels.popoutsWrapper);
            }
            watchSignal(components?.bar, "trayExpandedChanged");
            watchSignal(components?.bar, "traySettledChanged");
        }
    }
    function unwatchSurfaces(): void {
        for (const entry of watchedSurfaces) {
            try {
                entry.signal.disconnect(surfaceChanged);
            } catch (_) {}
        }
        watchedSurfaces = [];
    }
    function surfaceChanged(): void {
        checkHidden();
    }
    function checkHidden(): void {
        if (pendingPath && surfacesHidden())
            launchPending();
    }
    function launchPending(): void {
        if (!pendingPath)
            return;
        const path = pendingPath;
        const args = pendingArgs;
        pendingPath = "";
        pendingArgs = [];
        hiddenTimer.stop();
        unwatchSurfaces();
        // Native ownership verification gates the detached forwarding client.
        if (!sendHostCommand(args, path))
            Toaster.toast(pendingLabel, "Capture host is not ready. " + (hostState.error || hostState.state), "screenshot_region");
    }
    function reportNotReady(): void {
        if (!pendingPath)
            return;
        const label = pendingLabel;
        pendingPath = "";
        pendingArgs = [];
        unwatchSurfaces();
        Toaster.toast(label, "Caelestia capture is not ready. The shell is still on screen.", label === "Screenshot" ? "screenshot_region" : "screen_record");
    }
    function begin(label, args, icon): bool {
        if (!ready) {
            Toaster.toast(label, "Caelestia capture is still starting. Try again.", icon);
            return false;
        }
        refresh();
        if (!available) {
            Toaster.toast(label, "Caelestia capture is unavailable.", icon);
            return false;
        }
        if (Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1" || pendingPath)
            return false;
        pendingPath = executable;
        pendingArgs = args;
        pendingLabel = label;
        dismiss();
        watchSurfaces();
        // Panels that were already hidden need no signal; surfaceChanged runs
        // the same check when the closing animation actually finishes.
        if (surfacesHidden()) {
            launchPending();
            return true;
        }
        hiddenTimer.restart();
        return true;
    }
    // Every invocation that can cold-start a host carries the shell-owned
    // options, so a host started by a command (e.g. after the user quit Glazier
    // from its tray) never re-registers its own hotkeys or drops the theme.
    function hostOptions(): var {
        return ["--no-hotkeys", "--theme-file", themeFile];
    }
    function capture(): bool {
        return begin("Screenshot", hostOptions().concat(["--capture"]), "screenshot_region");
    }
    function record(): bool {
        return begin("Record screen", hostOptions().concat(["--record"]), "screen_record");
    }
    function ensureLifecycle(path): bool {
        if (!path)
            return false;
        if (lifecyclePath !== path) {
            lifecyclePath = path;
            hostLifecycle.acquire(path, hostClass(path), hostOptions());
        }
        return true;
    }
    function sendHostCommand(args, path = executable): bool {
        return ensureLifecycle(path) && hostLifecycle.command(args);
    }
    // Compatibility entry point: true means accepted, not exited. Completion
    // and failure remain visible in hostState, including a late exit.
    function stopHost(wait): bool {
        if (executable)
            ensureLifecycle(executable);
        return hostLifecycle.close(false);
    }
    function restartHost(): bool {
        if (executable)
            ensureLifecycle(executable);
        return hostLifecycle.close(true);
    }
    function prepareReload(callback): bool {
        if (reloadCallback)
            return false;
        if (executable)
            ensureLifecycle(executable);
        reloadCallback = callback;
        if (hostLifecycle.prepareReload())
            return true;
        reloadCallback = null;
        console.warn("CAELESTIA_CAPTURE_HANDOFF refused:", hostState.error);
        return false;
    }
    function requestQuit(): bool {
        if (quitPending)
            return true; // A repeated request must not cancel an accepted quit.
        if (executable)
            ensureLifecycle(executable);
        if (!hostState.owned && !hostState.closeAttempted) {
            if (!hostLifecycle.quit())
                return false;
            Qt.quit();
            return true;
        }
        // Set before close: it can synchronously publish a refusal.
        quitPending = true;
        const accepted = hostLifecycle.quit();
        if (!accepted)
            quitPending = false;
        return accepted;
    }

    // The tray host starts once with the shell. The shell owns the hotkeys
    // (--no-hotkeys) and Glazier follows the profile's theme tokens
    // (--theme-file), both supported by the pinned revision.
    function maybeStartHost(): void {
        if (!permitted || !ready || !available)
            return;
        ensureLifecycle(executable);
    }
    // Initial graph setup only. Observed process exit and bounded recovery live
    // in the process-global registry, not a QML generation's one-shot latch.
    Timer {
        interval: 0
        repeat: false
        running: root.permitted && root.ready && root.available && root.lifecyclePath !== root.executable
        onTriggered: root.maybeStartHost()
    }

    FileView {
        path: root.configPath
        printErrors: false
        watchChanges: true
        onLoaded: root.configure(text())
        onLoadFailed: {
            root.configuredPath = "";
            root.configReady = true;
            root.refresh();
        }
        onFileChanged: reload()
    }
    Timer {
        id: hiddenTimer
        interval: root.hiddenTimeout
        onTriggered: root.reportNotReady()
    }
    CaptureHost {
        id: hostLifecycle
        onReloadReady: ok => {
            const callback = root.reloadCallback;
            root.reloadCallback = null;
            if (ok && callback)
                callback();
            else
                console.warn("CAELESTIA_CAPTURE_HANDOFF failed:", root.hostState.error);
        }
        onQuitReady: ok => {
            root.quitPending = false;
            if (ok)
                Qt.quit();
            else
                console.warn("CAELESTIA_CAPTURE_CLOSE refused or failed:", root.hostState.error);
        }
    }
    IpcHandler {
        target: "screenshot"
        function capture(): bool { return root.capture(); }
        function isAvailable(): bool { return root.available; }
    }
    IpcHandler {
        target: "picker"
        function open(): void { root.capture(); }
        function openFreeze(): void { root.capture(); }
        function openClip(): void { root.capture(); }
        function openFreezeClip(): void { root.capture(); }
        function isAvailable(): bool { return root.available; }
    }
}
