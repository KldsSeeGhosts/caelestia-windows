import QtQuick
import Quickshell
import Caelestia.Config
import Caelestia.Windows
import qs.utils

// Offscreen check of the QML contract: Paths reads the Known Folder exposed by
// the plugin, and the wallpaper upgrade rule preserves the old profile folder.
ShellRoot {
    id: root

    property int assertions: 0
    property bool passed: false
    readonly property string fixtures: Quickshell.env("CAELESTIA_KNOWN_FOLDERS_FIXTURE_ROOT") || ""

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

            // With no configured path, wallsdir is the resolver's choice.
            GlobalConfig.paths.wallpaperDir = "";
            check(Paths.wallsdir === Paths.resolveWallpapersDir(Paths.pictures, Paths.home + "/Pictures", "", ""),
                "wallsdir does not use the upgrade resolver");

            // Explicit shell.json override wins over the Known Folder.
            GlobalConfig.paths.wallpaperDir = "C:/caelestia-known-folders-test";
            check(Paths.wallsdir === "C:/caelestia-known-folders-test", "configured wallpaperDir did not win");

            // A documented ~ path expands instead of being treated literally.
            check(Paths.expandPath("~/Pictures/Wallpapers") === Paths.home + "/Pictures/Wallpapers", "~ did not expand");

            check(root.fixtures.length > 0, "fixture root is missing");
            const knownWith = Paths.normalizePath(root.fixtures + "/known-with");
            const knownEmpty = Paths.normalizePath(root.fixtures + "/known-empty");
            const legacyWith = Paths.normalizePath(root.fixtures + "/legacy-with");
            const legacyEmpty = Paths.normalizePath(root.fixtures + "/legacy-empty");

            // 1. Redirected/Known Folder wallpapers win when they exist.
            check(Paths.resolveWallpapersDir(knownWith, legacyWith, "", "") === knownWith + "/Wallpapers",
                "Known Folder wallpapers were not preferred");

            // 2. Empty Known Folder falls back to the old profile folder.
            check(Paths.resolveWallpapersDir(knownEmpty, legacyWith, "", "") === legacyWith + "/Wallpapers",
                "legacy wallpapers were not found after the upgrade");

            // 3. Neither folder has images: use the new default.
            check(Paths.resolveWallpapersDir(knownEmpty, legacyEmpty, "", "") === knownEmpty + "/Wallpapers",
                "new default folder was not used");

            // 4. An explicit path wins even when both defaults have images.
            check(Paths.resolveWallpapersDir(knownWith, legacyWith, "C:/explicit/walls", "") === "C:/explicit/walls",
                "explicit wallpaperDir did not win");

            // 5. The environment override wins over everything.
            check(Paths.resolveWallpapersDir(knownWith, legacyWith, "C:/explicit/walls", "D:/env/walls") === "D:/env/walls",
                "environment wallpaperDir did not win");

            // 6. The old built-in default serialized into shell.json is not an
            // override; the legacy folder still rescues the wallpapers.
            const oldDefault = (knownEmpty + "/Wallpapers").replace(/\//g, "\\").toUpperCase() + "\\";
            check(Paths.resolveWallpapersDir(knownEmpty, legacyWith, oldDefault, "") === legacyWith + "/Wallpapers",
                "old built-in default was treated as an override");

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
