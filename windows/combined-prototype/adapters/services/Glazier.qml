pragma Singleton

import QtQuick
import Qt.labs.folderlistmodel
import Quickshell
import Quickshell.Io
import Caelestia
import qs.utils

// Windows: Glazier owns the picker and editor. Never read the executable as data.
Singleton {
    id: root

    readonly property string configPath: (Quickshell.env("CAELESTIA_CONFIG_DIR") || "").replace(/\\/g, "/") + "/glazier.json"
    readonly property string defaultPath: (Quickshell.env("LOCALAPPDATA") || "").replace(/\\/g, "/") + "/Programs/Glazier/glazier.exe"
    property string configuredPath: ""
    property bool configReady: false
    property bool probesSettled: false
    readonly property bool ready: configReady && probesSettled
        && defaultProbe.status !== FolderListModel.Loading
        && (!configuredPath || configuredProbe.status !== FolderListModel.Loading)
    readonly property string executable: !ready ? "" : hasFile(configuredProbe, configuredPath)
        ? configuredPath : hasFile(defaultProbe, defaultPath) ? defaultPath : ""
    readonly property bool available: executable.length > 0

    function validPath(path): bool {
        return typeof path === "string" && /^(?:[A-Za-z]:\/|\/\/)/.test(path)
            && !/[*?]/.test(path) && path.lastIndexOf("/") > 1;
    }
    function directory(path): string {
        return validPath(path) ? path.slice(0, path.lastIndexOf("/")) : "";
    }
    function filename(path): string {
        return validPath(path) ? path.slice(path.lastIndexOf("/") + 1) : "";
    }
    function hasFile(model, path): bool {
        return validPath(path) && model.status === FolderListModel.Ready
            && model.count === 1 && model.get(0, "fileName").toLowerCase() === filename(path).toLowerCase();
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
        probeChanged();
    }
    function probeChanged(): void {
        probesSettled = false;
        settleTimer.restart();
    }
    function capture(): bool {
        if (!ready) {
            Toaster.toast("Screenshot", "Glazier is still being checked. Try again.", "screenshot_region");
            return false;
        }
        if (!available) {
            Toaster.toast("Screenshot", "Glazier not installed.", "screenshot_region");
            return false;
        }
        if (Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1")
            return false;
        // #81: execDetached redirects stdio to the null device and disowns handles.
        Quickshell.execDetached([executable, "--capture"]);
        return true;
    }

    FileView {
        path: root.configPath
        printErrors: false
        watchChanges: true
        onLoaded: root.configure(text())
        onLoadFailed: { root.configuredPath = ""; root.configReady = true; root.probeChanged(); }
        onFileChanged: reload()
    }
    FolderListModel {
        id: configuredProbe
        folder: root.configuredPath ? Paths.absolutePath(root.directory(root.configuredPath)) : ""
        nameFilters: [root.filename(root.configuredPath)]
        showDirs: false
        showFiles: true
        onStatusChanged: root.probeChanged()
        onCountChanged: root.probeChanged()
    }
    FolderListModel {
        id: defaultProbe
        folder: Paths.absolutePath(root.directory(root.defaultPath))
        nameFilters: [root.filename(root.defaultPath)]
        showDirs: false
        showFiles: true
        onStatusChanged: root.probeChanged()
        onCountChanged: root.probeChanged()
    }
    Timer {
        id: settleTimer
        interval: 250
        onTriggered: root.probesSettled = true
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
