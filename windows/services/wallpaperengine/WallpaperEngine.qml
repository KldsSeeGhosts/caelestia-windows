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
    property bool snapshotReady: false
    // Fail closed before discovery, and keep yielding even if integration is
    // disabled: a running external desktop owner must never be covered.
    readonly property bool ownsDesktop: !snapshotReady || running
    property string status: "discovering"
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

    function refresh(): void {
        if (python && !scan.running)
            scan.running = true;
        else if (!python)
            status = "unavailable";
    }

    function matchColours(): void {
        if (!enabled || !detected || !running || !current?.preview || !SchemeGenerator.available)
            return;
        const key = current.path + "|" + current.preview + "|" + GlobalConfig.services.smartScheme;
        if (key === lastPaletteKey)
            return;
        lastPaletteKey = key;
        SchemeGenerator.applyWallpaper(current.preview, GlobalConfig.services.smartScheme);
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
    onEnabledChanged: { lastPaletteKey = ""; matchColours(); }
    onRunningChanged: { lastPaletteKey = ""; matchColours(); }
    Component.onCompleted: refresh()

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
    Timer { id: debounce; interval: 300; onTriggered: root.refresh() }
    // Also catches WE starting/stopping and workshop installs, including atomic
    // replacement of config.json. Discovery never launches Wallpaper Engine.
    Timer { interval: 5000; running: true; repeat: true; onTriggered: root.refresh() }
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
        command: [root.python, root.helper, "snapshot"]
        stdout: StdioCollector { id: scanOutput }
        onExited: code => {
            try {
                const data = JSON.parse(scanOutput.text);
                if (code !== 0 || !data.ok)
                    throw new Error(data.error || "discovery failed");
                root.detected = data.detected;
                root.running = data.running;
                root.configPath = data.configPath || "";
                // Preserve carousel delegates and selection across idle polls.
                if (JSON.stringify(root.items) !== JSON.stringify(data.items))
                    root.items = data.items;
                if (JSON.stringify(root.monitors) !== JSON.stringify(data.monitors))
                    root.monitors = data.monitors;
                root.snapshotReady = true;
                root.status = !root.enabled ? "disabled" : root.running && root.detected ? "ready" : "absent";
                root.lastError = "";
                root.matchColours();
            } catch (error) {
                root.status = "error";
                root.lastError = String(error);
                // Retain the last good state during partial/locked JSON writes.
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
