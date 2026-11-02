import QtQuick
import Quickshell
import Caelestia.Config
import Caelestia.Windows
import qs.utils

// Offscreen check of the QML contract: Paths reads the Known Folder exposed by
// the plugin, and an explicit paths.wallpaperDir from shell.json still wins.
ShellRoot {
    id: root

    property int assertions: 0
    property bool passed: false

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Component.onCompleted: {
        try {
            check(KnownFolders.pictures.length > 0, "Pictures Known Folder is empty");
            check(Paths.pictures === KnownFolders.pictures, "Paths.pictures does not use the Known Folder");
            check(Paths.videos === KnownFolders.videos, "Paths.videos does not use the Known Folder");

            // No configured path: wallpapers stay under the resolved Pictures
            // folder, wherever Windows put it.
            GlobalConfig.paths.wallpaperDir = "";
            check(Paths.wallsdir === Paths.pictures + "/Wallpapers", "default wallsdir is not under the Known Folder");

            // Explicit shell.json override wins over the Known Folder.
            GlobalConfig.paths.wallpaperDir = "C:/caelestia-known-folders-test";
            check(Paths.wallsdir === "C:/caelestia-known-folders-test", "configured wallpaperDir did not win");

            // A documented ~ path expands instead of being treated literally.
            GlobalConfig.paths.wallpaperDir = "~/Pictures/Wallpapers";
            check(Paths.wallsdir === Paths.home + "/Pictures/Wallpapers", "~ did not expand");

            console.log("CAELESTIA_KNOWN_FOLDERS_PASS " + assertions);
            passed = true;
        } catch (e) {
            console.log("CAELESTIA_KNOWN_FOLDERS_FAIL " + e.message);
        }
    }

    // Quit after the current event-loop turn; a direct call runs before the
    // shell host connects the QQmlEngine quit signal.
    Timer {
        interval: 1
        running: true
        onTriggered: root.passed ? Qt.quit() : Qt.exit(1)
    }
}
