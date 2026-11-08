import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// Upgrade migration without colour-generation history. The profile has the
// theme-token export every earlier build wrote but no wallpaper record and no
// scheme.json or wallpaper/path.txt, which is a user without the optional
// colour runtime. The migration must keep the saved Windows wallpaper and
// per-display images and record that decision; it must not save the bundled
// default over them.
QtObject {
    id: root

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function record(): var {
        return JSON.parse(Files.contents[Wallpapers.sourceRecordPath] ?? "{}");
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/fixture/state/theme-tokens.json"];
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(Wallpapers.sourceInitialized, "the upgrade source resolved");
            check(Wallpapers.sourceRecordHealth === "valid", "the migration record was not written");
            check(Wallpapers.sourceChosen, "the upgrade was treated as a fresh install");
            check(Wallpapers.fileCurrent === "C:/walls/windows-default.jpg",
                "the upgrade replaced the saved Windows wallpaper");
            check(Wallpapers.current === "C:/walls/windows-default.jpg",
                "the upgraded desktop did not show the saved wallpaper");
            check(Wallpapers.lastGoodFile === "C:/walls/windows-default.jpg",
                "the saved wallpaper was not remembered for a handback");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/primary.jpg",
                "the saved primary wallpaper was replaced");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary.jpg",
                "the saved secondary wallpaper was replaced");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "the migration wrote a Windows wallpaper");
            const saved = record();
            check(saved.version === 1 && saved.source === "user",
                "the migration did not record the user source");
            check(saved.seen === undefined, "the upgrade baselined images that were already chosen");
            check(saved.path === undefined, "the record stored a wallpaper path");

            console.log("CAELESTIA_WALLPAPER_UPGRADE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_UPGRADE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
