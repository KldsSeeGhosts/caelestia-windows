import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// A record from a newer schema version is not ours to interpret. It must stay
// on disk untouched and the fresh profile must show the bundled asset, even
// when its body looks like a pick this build understands.
QtObject {
    id: root

    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            const future = JSON.stringify({
                version: 2,
                wallpaper: "C:/walls/primary.jpg",
                monitors: {"primary-id": "C:/walls/secondary.jpg"}
            });
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg"];
            // Seed before the singleton exists; sourcing its properties here
            // would create it and read an empty profile.
            Files.contents[root.recordPath] = future;
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(Wallpapers.sourceInitialized, "the future record blocked startup");
            check(Wallpapers.sourceFresh, "the record changed the profile classification");
            check(Wallpapers.sourceRecordHealth === "invalid", "a version 2 record was interpreted");
            check(Wallpapers.profilePick === "", "a version 2 pick was trusted");
            check(Files.contents[root.recordPath] === future, "the version 2 record was rewritten");
            check(Wallpapers.fileCurrent === Wallpapers.fallback,
                "a version 2 record let the Windows wallpaper through");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "a version 2 monitor pick was applied");

            console.log("CAELESTIA_WALLPAPER_FUTURE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_FUTURE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
