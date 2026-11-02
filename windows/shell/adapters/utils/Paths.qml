pragma Singleton

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.Windows as Native
import qs.services

// Resolve the original shell's asset namespace inside the isolated stage.
QtObject {
    readonly property string home: (Quickshell.env("USERPROFILE") || "").replace(/\\/g, "/")

    readonly property string cache: Quickshell.cacheDir.replace(/\\/g, "/")
    readonly property url configFile: "file:///" + (Quickshell.env("CAELESTIA_CONFIG_DIR") || "").replace(/\\/g, "/") + "/shell.json"

    // Profile-local state. The staged shell.qml pins Quickshell.stateDir to
    // <build>/combined-prototype-profile/state, and the scheme bridge writes
    // <profile>/state/caelestia/scheme.json (the upstream CLI's own layout).
    readonly property string state: (Quickshell.stateDir + "/caelestia").replace(/\\/g, "/")

    // Windows may redirect these folders (for example OneDrive folder backup),
    // so ask the shell for their real paths instead of appending to the profile.
    readonly property string pictures: (Native.KnownFolders.pictures || (home + "/Pictures")).replace(/\\/g, "/")
    readonly property string videos: (Native.KnownFolders.videos || (home + "/Videos")).replace(/\\/g, "/")

    readonly property string wallsdir: (Quickshell.env("CAELESTIA_WALLPAPER_DIR") || expandPath(GlobalConfig.paths.wallpaperDir) || (pictures + "/Wallpapers")).replace(/\\/g, "/")
    readonly property string recsdir: Recorder.outputDir
    function expandPath(path: string): string {
        if (!path || !path.trim())
            return "";
        return path.trim().replace(/\\/g, "/").replace(/^(?:~|\$(?:HOME|\{HOME\}))(?=\/|$)/, home);
    }
    function shortenHome(path: string): string { return path.replace(home, "~"); }
    // Use Windows default applications, not upstream's mpv/thunar commands.
    function openRecording(path: string): bool {
        return Qt.openUrlExternally(absolutePath(path));
    }
    function revealRecording(path: string): bool {
        const local = path.replace(/\\/g, "/");
        return Qt.openUrlExternally(absolutePath(local.slice(0, local.lastIndexOf("/"))));
    }
    function deleteRecording(path: string): bool {
        // The list shows every .mp4 in the output folder (upstream); only delete
        // files Glazier reported as finished.
        if (!Recorder.owns(path)) {
            Recorder.lastError = "Only recordings Glazier reported can be deleted here.";
            return false;
        }
        return CUtils.deleteFile(absolutePath(path));
    }
    function absolutePath(path: string): string {
        if (!path || !path.trim())
            return "";
        if (path.startsWith("file:"))
            return path;
        if (path.startsWith("root:/"))
            return Qt.resolvedUrl("../" + path.slice(6)).toString();
        const local = path.replace(/\\/g, "/").replace(/^~(?=\/|$)|^\$(?:HOME|\{HOME\})(?=\/|$)/, home);
        const encoded = local.split("/").map(segment => encodeURIComponent(segment)).join("/");
        if (/^[A-Za-z]:\//.test(local))
            return "file:///" + local.slice(0, 2) + encoded.slice(4);
        if (local.startsWith("//"))
            return "file:" + encoded;
        if (local.startsWith("/"))
            return "file://" + encoded;
        return Qt.resolvedUrl("../" + encoded).toString();
    }
}
