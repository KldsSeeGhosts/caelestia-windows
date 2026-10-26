pragma Singleton

import QtQuick
import Quickshell

// Resolve the original shell's asset namespace inside the isolated stage.
QtObject {
    readonly property string home: Quickshell.env("USERPROFILE").replace(/\\/g, "/")

    readonly property string cache: Quickshell.cacheDir.replace(/\\/g, "/")
    readonly property url configFile: "file:///" + Quickshell.env("CAELESTIA_CONFIG_DIR").replace(/\\/g, "/") + "/shell.json"

    readonly property string wallsdir: (Quickshell.env("CAELESTIA_WALLPAPER_DIR") || (home + "/Pictures/Wallpapers")).replace(/\\/g, "/")
    function shortenHome(path: string): string { return path.replace(home, "~"); }
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
