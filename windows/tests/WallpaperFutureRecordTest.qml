import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// A record from a newer schema version is not ours to interpret. It must stay
// on disk untouched and the saved Windows wallpaper must stay visible, even
// when its body looks like a default choice this build understands.
QtObject {
    id: root

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
                source: "default",
                monitors: {"primary-id": "default"}
            });
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg"];
            // Seed before the singleton exists; sourcing its properties here
            // would create it and read an empty profile.
            Files.contents["C:/fixture/state/wallpaper/desktop.json"] = future;
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(Wallpapers.sourceInitialized, "the future record blocked startup");
            check(Wallpapers.sourceRecordHealth === "invalid", "a version 2 record was interpreted");
            check(Wallpapers.sourceChosen, "a version 2 default was trusted");
            check(Files.contents[Wallpapers.sourceRecordPath] === future,
                "the version 2 record was rewritten");
            check(Wallpapers.fileCurrent === "C:/walls/windows-default.jpg",
                "a version 2 record replaced the saved wallpaper");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/primary.jpg",
                "a version 2 monitor override was applied");

            console.log("CAELESTIA_WALLPAPER_FUTURE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_FUTURE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
