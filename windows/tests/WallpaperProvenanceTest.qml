import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// A fresh first start wrote its provenance marker and theme tokens, then
// crashed before any wallpaper pick. The next start must still be the same
// fresh profile: the earlier state directory and theme-tokens.json are not
// evidence of an upgrade once the marker exists. It shows the bundled asset
// and writes no pick record.
QtObject {
    id: root

    readonly property string markerPath: Paths.state + "/wallpaper/profile.json"
    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function marker(): var {
        return JSON.parse(Files.contents[root.markerPath] ?? "{}");
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", Paths.state + "/theme-tokens.json",
                root.markerPath];
            // The crashed first start created the state directory and its
            // theme-token export, but no wallpaper picks.
            Native.FsUtils.existingDirs = [Paths.state];
            // Seed the marker before the singletons exist.
            Files.contents[root.markerPath] = JSON.stringify({
                version: 1, profile: "fresh"
            });
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(WallpaperProvenance.ready && !WallpaperProvenance.existing,
                "the marker was ignored in favour of the earlier state files");
            check(Wallpapers.sourceFresh, "the crashed profile did not resolve as fresh");
            check(Wallpapers.sourceInitialized, "the crashed profile did not resolve");
            check(Wallpapers.sourceRecordHealth === "missing", "an empty profile found a pick");
            check(Wallpapers.current === Wallpapers.fallback,
                "the crashed fresh profile adopted the Windows wallpaper");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the crashed fresh profile changed a display");
            check(Files.contents[root.recordPath] === undefined,
                "the crashed fresh profile wrote a pick record");
            check(marker().version === 1 && marker().profile === "fresh",
                "the marker was rewritten");

            console.log("CAELESTIA_WALLPAPER_PROVENANCE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_PROVENANCE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
