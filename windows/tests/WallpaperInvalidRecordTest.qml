import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// A truncated record cannot be read as a set of picks. It must stay on disk
// untouched, the fresh profile must show the bundled asset (never the Windows
// wallpaper), and only an explicit Caelestia pick may replace it with a valid
// record.
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
            const malformed = '{"version":1,"wallpaper":"C:/walls/primary.jpg"';
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/walls/picked.jpg"];
            // Seed before the singleton exists; sourcing its properties here
            // would create it and read an empty profile.
            Files.contents[root.recordPath] = malformed;
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/primary.jpg",
                secondary: "C:/walls/secondary.jpg"};
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(Wallpapers.sourceInitialized, "the invalid record blocked startup");
            check(Wallpapers.sourceFresh, "the record changed the profile classification");
            check(Wallpapers.sourceRecordHealth === "invalid", "the truncated record was accepted");
            check(Wallpapers.profilePick === "", "a truncated record supplied a pick");
            check(Files.contents[root.recordPath] === malformed,
                "the truncated record was overwritten on load");
            check(Wallpapers.fileCurrent === Wallpapers.fallback,
                "a truncated record let the Windows wallpaper through");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback
                && Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "a truncated record changed a display");
            Wallpapers.persistPicks(false);
            check(Files.contents[root.recordPath] === malformed,
                "loading replaced the truncated record");

            // An explicit pick is a new decision and may replace the damaged
            // file with a valid record.
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg"), "the explicit pick was rejected");
            check(Wallpapers.profilePick === "C:/walls/picked.jpg", "the pick was not stored");
            const saved = JSON.parse(Files.contents[root.recordPath]);
            check(saved.version === 1 && saved.wallpaper === "C:/walls/picked.jpg",
                "the pick did not write a valid record");
            check(Wallpapers.current === "C:/walls/picked.jpg", "the pick is not visible");
            check(Wallpapers.currentImage === "C:/walls/picked.jpg",
                "the pick did not become the palette source");

            console.log("CAELESTIA_WALLPAPER_INVALID_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_INVALID_FAIL " + error);
            Qt.exit(1);
        }
    }
}
