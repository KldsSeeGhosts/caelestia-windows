pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Windows
import qs.services

// Windows: Glazier owns the picker and editor. Never read the executable as data.
Singleton {
    id: root

    readonly property string configPath: (Quickshell.env("CAELESTIA_CONFIG_DIR") || "").replace(/\\/g, "/") + "/glazier.json"
    readonly property string defaultPath: (Quickshell.env("LOCALAPPDATA") || "").replace(/\\/g, "/") + "/Programs/Glazier/glazier.exe"
    property string configuredPath: ""
    property bool configReady: false
    readonly property bool ready: configReady
    property string executable: ""
    readonly property bool available: executable.length > 0
    // Kept as providers so the exact dismissal path can be tested offscreen.
    property var screenProvider: Screens
    property var stateProvider: ShellState
    property string pendingPath: ""
    property double dismissStarted: 0

    function validPath(path): bool {
        return typeof path === "string" && /^(?:[A-Za-z]:\/|\/\/)/.test(path)
            && !/[*?]/.test(path) && path.lastIndexOf("/") > 1;
    }
    function resolvePath(configured, fallback, exists): string {
        if (validPath(configured) && exists(configured))
            return configured;
        return validPath(fallback) && exists(fallback) ? fallback : "";
    }
    function refresh(): void {
        executable = resolvePath(configuredPath, defaultPath, path => WindowsFiles.isFile(path));
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
                for (const name of ["bar", "osd", "session", "launcher", "dashboard", "quota", "utilities", "sidebar"])
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
            for (const name of ["osd", "session", "launcher", "dashboard", "quota", "utilities", "sidebar", "popoutsWrapper"])
                if (panels[name]?.visible)
                    return false;
        }
        return true;
    }
    function capture(): bool {
        if (!ready) {
            Toaster.toast("Screenshot", "Glazier is still being checked. Try again.", "screenshot_region");
            return false;
        }
        refresh();
        if (!available) {
            Toaster.toast("Screenshot", "Glazier not installed.", "screenshot_region");
            return false;
        }
        if (Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1")
            return false;
        if (pendingPath)
            return false;
        pendingPath = executable;
        dismissStarted = Date.now();
        dismiss();
        dismissTimer.start();
        return true;
    }

    FileView {
        path: root.configPath
        printErrors: false
        watchChanges: true
        onLoaded: root.configure(text())
        onLoadFailed: { root.configuredPath = ""; root.configReady = true; root.refresh(); }
        onFileChanged: reload()
    }
    Timer {
        id: dismissTimer
        interval: 16
        repeat: true
        onTriggered: {
            root.dismiss();
            if (!root.surfacesHidden() && Date.now() - root.dismissStarted < 300)
                return;
            stop();
            const path = root.pendingPath;
            root.pendingPath = "";
            // #81: execDetached redirects stdio to the null device and disowns handles.
            Quickshell.execDetached([path, "--capture"]);
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
