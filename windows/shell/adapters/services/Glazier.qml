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
    property bool ownedHost: false
    // True only after this shell session's process creates the host. Its journal
    // began after the shell did, so Recorder treats that host's first response as
    // fresh events instead of a pre-restart baseline. Forwarding a command to a
    // host that is already running does not create one, and an adopted host never
    // sets this. Tests replace hostProbe; production uses the real process query.
    property bool launchedHost: false
    property var hostProbe: WindowsProcess
    property string statusOutput: ""
    readonly property string hostWindowClass: "GlazierHost"

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
        // execDetached redirects stdio to the null device and disowns handles.
        // Glazier's single-instance entry point forwards this command when a host
        // is already running, so that does not start a journal. Freshness follows
        // only the process that creates the host.
        const creatingHost = !hostIsRunning();
        ownedHost = true;
        if (creatingHost)
            launchedHost = true;
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
    function hostIsRunning(): bool {
        return hostProbe.windowProcessId(hostWindowClass) !== 0;
    }
    function samePath(a, b): bool {
        return typeof a === "string" && typeof b === "string" && a.length > 0 && b.length > 0
            && a.replace(/\\/g, "/").toLowerCase() === b.replace(/\\/g, "/").toLowerCase();
    }
    function launchHost(): void {
        ownedHost = true;
        launchedHost = true;
        Quickshell.execDetached([executable].concat(hostOptions()));
    }
    // Only a host this payload launched (or adopted after checking its image)
    // may be stopped. A standalone install is never modified or unregistered.
    function stopHost(wait): bool {
        if (!ownedHost)
            return true;
        ownedHost = false;
        if (!samePath(WindowsProcess.windowImagePath(hostWindowClass), executable))
            return true;
        return wait ? WindowsProcess.closeWindowAndWait(hostWindowClass, 2000)
                    : WindowsProcess.closeWindow(hostWindowClass);
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
    // Take ownership of the running host only when its image is the bundled
    // executable of this payload. A standalone Glazier (or a host from an old
    // payload) is asked to exit through its own WM_CLOSE, then replaced; its
    // install and HKCU Run entry are untouched.
    Process {
        id: statusProbe
        command: [root.executable, "--status"]
        stdout: StdioCollector { onStreamFinished: root.statusOutput = text }
        onExited: code => {
            let running = false;
            try {
                running = JSON.parse(root.statusOutput.trim()).ok === true;
            } catch (_) {}
            if (!running)
                running = WindowsProcess.windowProcessId(root.hostWindowClass) !== 0;
            if (!running) {
                root.launchHost();
                return;
            }
            const image = WindowsProcess.windowImagePath(root.hostWindowClass);
            if (!image) {
                // A protocol host without its expected window cannot be
                // identified safely; never start a second one.
                console.warn("CAELESTIA_GLAZIER_HOST could not identify the running host; not starting a second one");
                return;
            }
            if (root.samePath(image, root.executable)) {
                root.ownedHost = true;
                return;
            }
            // One notice, no paths: this is a lifecycle repair, not an error.
            console.log("CAELESTIA_GLAZIER_HOST replacing a host that was not started from this payload");
            if (WindowsProcess.closeWindowAndWait(root.hostWindowClass, 2000))
                root.launchHost();
            else
                console.warn("CAELESTIA_GLAZIER_HOST the previous host did not exit; not starting a second one");
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
