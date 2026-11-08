import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// A truncated record cannot be read as either decision. It must stay on disk
// untouched, the saved Windows wallpaper must stay visible, and only an
// explicit user pick may replace it with a valid record.
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
            const malformed = '{"version":1,"source":"user"';
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/walls/picked.jpg"];
            // Seed before the singleton exists; sourcing its properties here
            // would create it and read an empty profile.
            Files.contents["C:/fixture/state/wallpaper/desktop.json"] = malformed;
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(Wallpapers.sourceInitialized, "the invalid record blocked startup");
            check(Wallpapers.sourceRecordHealth === "invalid", "the truncated record was accepted");
            check(Wallpapers.sourceChosen, "a truncated user record was normalised to default");
            check(Files.contents[Wallpapers.sourceRecordPath] === malformed,
                "the truncated record was overwritten on load");
            check(Wallpapers.fileCurrent === "C:/walls/windows-default.jpg",
                "the saved Windows wallpaper was replaced");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/primary.jpg"
                && Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary.jpg",
                "the saved per-display wallpapers were replaced");
            Wallpapers.persistSourceChoice(false);
            check(Files.contents[Wallpapers.sourceRecordPath] === malformed,
                "a non-user write replaced the truncated record");

            // An explicit pick is a new decision and may replace the damaged
            // file with a valid record.
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg"), "the explicit pick was rejected");
            check(Wallpapers.sourceChosen, "the pick did not opt the profile in");
            const saved = JSON.parse(Files.contents[Wallpapers.sourceRecordPath]);
            check(saved.version === 1 && saved.source === "user",
                "the pick did not write a valid record");
            check(saved.path === undefined, "the record stored a wallpaper path");
            check(Wallpapers.current === "C:/walls/picked.jpg", "the pick is not visible");

            console.log("CAELESTIA_WALLPAPER_INVALID_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_INVALID_FAIL " + error);
            Qt.exit(1);
        }
    }
}
