pragma Singleton

import QtQuick
import Quickshell

// Only disabled image/asset loaders reference this contract. The ordinary M1
// session GIF and the notification empty-state picture are unavailable; return
// an empty path without logging an error so a bounded host can render its own
// empty state through the original component.
QtObject {
    readonly property string home: Quickshell.env("USERPROFILE").replace(/\\/g, "/")

    readonly property string cache: Quickshell.cacheDir.replace(/\\/g, "/")

    readonly property string wallsdir: (Quickshell.env("CAELESTIA_WALLPAPER_DIR") || (home + "/Pictures/Wallpapers")).replace(/\\/g, "/")
    function shortenHome(path: string): string { return path.replace(home, "~"); }
    function absolutePath(path: string): string {
        return "";
    }
}
