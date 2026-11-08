import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// Downgrade, choose a wallpaper in the older build, upgrade again. The record
// still says the profile is on the bundled default, so the old build's pick is
// only visible as a changed Windows wallpaper. The returning build must adopt
// it for that display, keep a per-display choice made here, and preserve the
// record fields it does not own.
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
                "C:/walls/secondary.jpg"];
            // Seed before the singleton exists; sourcing its properties here
            // would create it and read an empty profile.
            Files.contents["C:/fixture/state/wallpaper/desktop.json"] = JSON.stringify({
                version: 1,
                source: "default",
                monitors: {"primary-id": "user"},
                seen: {"secondary-id": "C:/walls/old-secondary.jpg"},
                note: "keep"
            });
            Native.Wallpaper.currentPath = "C:/walls/primary.jpg";
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(Wallpapers.sourceInitialized, "the rollback source resolved");
            check(Wallpapers.sourceRecordHealth === "valid", "the valid record was rejected");
            check(!Wallpapers.sourceChosen, "the record's profile baseline was changed");
            // The display choice made before the downgrade is restored.
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/primary.jpg",
                "the per-display choice was not restored");
            // The older build's pick is an intervening selection: it is
            // adopted for that display instead of being ignored.
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary.jpg",
                "the intervening wallpaper selection was ignored");
            check(Wallpapers.fileCurrent === "C:/walls/primary.jpg",
                "the palette source left the restored display choice");
            let saved = record();
            check(saved.version === 1 && saved.source === "default",
                "rollback detection changed the profile baseline");
            check(saved.monitors["primary-id"] === "user", "the restored display choice was lost");
            check(saved.monitors["secondary-id"] === "user", "the intervening selection was not recorded");
            check(saved.note === "keep", "the rewrite dropped an unknown record field");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "rollback detection wrote a Windows wallpaper");

            console.log("CAELESTIA_WALLPAPER_ROLLBACK_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_ROLLBACK_FAIL " + error);
            Qt.exit(1);
        }
    }
}
