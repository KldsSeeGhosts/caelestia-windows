import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// A fresh first start wrote its provenance marker and theme tokens, then
// crashed before the wallpaper record was saved. The next start must still be
// the same fresh profile: the earlier state directory and theme-tokens.json
// are not evidence of an upgrade once the marker exists.
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
                "C:/walls/secondary.jpg", "C:/fixture/state/theme-tokens.json",
                "C:/fixture/state/wallpaper/profile.json"];
            // The crashed first start created the state directory and its
            // theme-token export, but no wallpaper record.
            Native.FsUtils.existingDirs = ["C:/fixture/state"];
            // Seed the marker before the singletons exist.
            Files.contents["C:/fixture/state/wallpaper/profile.json"] = JSON.stringify({
                version: 1, profile: "fresh"
            });
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(WallpaperProvenance.ready && !WallpaperProvenance.existing,
                "the marker was ignored in favour of the earlier state files");
            check(Wallpapers.sourceInitialized, "the crashed profile did not resolve");
            check(!Wallpapers.sourceChosen, "the crashed fresh profile became an upgrade");
            check(Wallpapers.current === Wallpapers.fallback,
                "the crashed fresh profile adopted the Windows wallpaper");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the crashed fresh profile changed a display");
            const saved = record();
            check(saved.version === 1 && saved.source === "default",
                "the fresh decision was not recorded after the crashed start");
            check(saved.seen["primary-id"] === "C:/walls/primary.jpg",
                "the fresh profile did not baseline the display");
            check(Files.contents["C:/fixture/state/wallpaper/profile.json"].includes('"fresh"'),
                "the marker was rewritten");

            console.log("CAELESTIA_WALLPAPER_PROVENANCE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_PROVENANCE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
