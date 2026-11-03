pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Windows
import qs.services
import qs.utils

// Windows: Glazier ships with the shell. The shell resolves the bundled
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
    readonly property string bundledPath: payloadRoot.replace(/\/+$/, "") + "/glazier.exe"
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
    property bool hostStarted: false
    property string statusOutput: ""

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
        }
    }
    function surfacesHidden(): bool {
        for (const screen of screenProvider.screens) {
            const panels = stateProvider.componentsFor(screen)?.panels;
            if (!panels)
                continue;
            for (const name of [...panelNames, "popoutsWrapper"])
                if (panels[name]?.visible)
                    return false;
        }
        return true;
    }
    function watchSurface(item): void {
        if (!item || watchedSurfaces.indexOf(item) !== -1)
            return;
        const changed = item.visibleChanged;
        if (!changed || typeof changed.connect !== "function")
            return;
        watchedSurfaces.push(item);
        changed.connect(surfaceChanged);
    }
    function watchSurfaces(): void {
        for (const screen of screenProvider.screens) {
            const panels = stateProvider.componentsFor(screen)?.panels;
            if (!panels)
                continue;
            for (const name of panelNames)
                watchSurface(panels[name]);
            watchSurface(panels.popoutsWrapper);
        }
    }
    function unwatchSurfaces(): void {
        for (const item of watchedSurfaces) {
            try {
                item.visibleChanged.disconnect(surfaceChanged);
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
        // #81: execDetached redirects stdio to the null device and disowns handles.
        Quickshell.execDetached([path].concat(args));
    }
    function reportNotReady(): void {
        if (!pendingPath)
            return;
        const label = pendingLabel;
        pendingPath = "";
        pendingArgs = [];
        unwatchSurfaces();
        Toaster.toast(label, "Glazier is not ready. The shell is still on screen.", label === "Screenshot" ? "screenshot_region" : "screen_record");
    }
    function begin(label, args, icon): bool {
        if (!ready) {
            Toaster.toast(label, "Glazier is still starting. Try again.", icon);
            return false;
        }
        refresh();
        if (!available) {
            Toaster.toast(label, "Glazier is unavailable.", icon);
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
    function capture(): bool {
        return begin("Screenshot", ["--capture"], "screenshot_region");
    }
    function record(): bool {
        return begin("Record screen", ["--record"], "screen_record");
    }

    // The tray host starts once with the shell. The shell owns the hotkeys
    // (--no-hotkeys) and Glazier follows the profile's theme tokens
    // (--theme-file), both supported by the pinned revision.
    function maybeStartHost(): void {
        if (hostStarted || !permitted || !ready || !available)
            return;
        hostStarted = true;
        statusProbe.running = true;
    }
    // A one-shot timer, not a poll: the binding turns it on exactly once when
    // the payload resolves in a live shell, whichever property settles last.
    Timer {
        interval: 0
        repeat: false
        running: root.permitted && root.ready && root.available && !root.hostStarted
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
    // Never start a second host: the isolated instance would only post its
    // "already running" notification over the live one.
    Process {
        id: statusProbe
        command: [root.executable, "--status"]
        stdout: StdioCollector { onStreamFinished: root.statusOutput = text }
        onExited: code => {
            let running = false;
            try {
                running = JSON.parse(root.statusOutput.trim()).ok === true;
            } catch (_) {}
            if (running)
                return;
            Quickshell.execDetached([root.executable, "--no-hotkeys", "--theme-file", root.themeFile]);
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
