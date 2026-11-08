import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// Restart of a fresh profile that saved Caelestia picks. The marker and record
// are seeded before the production singletons exist, exactly as a previous run
// left them. The Windows wallpaper was changed in between by an older build
// (rollback) or by Windows Settings; the saved profile-wide and per-display
// picks must stay, because a fresh profile follows only Caelestia picks.
QtObject {
    id: root

    readonly property string markerPath: Paths.state + "/wallpaper/profile.json"
    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"

    property int assertions: 0

    // The previous run recorded a profile-wide pick and a pick on the
    // secondary display. An older build then changed the Windows wallpaper to
    // different images; the next start must ignore them.
    property bool seeded: {
        Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
            "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
            "C:/walls/secondary.jpg", "C:/walls/profile-pick.jpg",
            "C:/walls/secondary-pick.jpg", "C:/walls/new-pick.jpg", root.markerPath];
        Native.FsUtils.existingDirs = [Paths.state + "/wallpaper"];
        Files.contents[root.markerPath] = JSON.stringify({version: 1, profile: "fresh"});
        Files.contents[root.recordPath] = JSON.stringify({
            version: 1,
            wallpaper: "C:/walls/profile-pick.jpg",
            monitors: {"secondary-id": "C:/walls/secondary-pick.jpg"},
            note: "keep"
        });
        Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
        Native.Wallpaper.screenPaths = {primary: "C:/walls/primary.jpg", secondary: "C:/walls/secondary.jpg"};
        Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
        WallpaperEngine.options = {enabled: false};
        return true;
    }

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function record(): var {
        return JSON.parse(Files.contents[root.recordPath] ?? "{}");
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            // 1. The saved picks are applied instead of the Windows images the
            // older build or Windows Settings left behind.
            check(WallpaperProvenance.ready && !WallpaperProvenance.existing,
                "the saved fresh marker was not read");
            check(Wallpapers.sourceFresh, "the restarted profile did not resolve as fresh");
            check(Wallpapers.sourceRecordHealth === "valid", "the saved picks were rejected");
            check(Wallpapers.profilePick === "C:/walls/profile-pick.jpg",
                "the profile-wide pick was not restored");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/profile-pick.jpg",
                "the primary display did not use the profile-wide pick");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary-pick.jpg",
                "the secondary display did not use its own pick");
            check(Wallpapers.fileCurrent === "C:/walls/profile-pick.jpg",
                "the palette source did not follow the first saved pick");
            check(Wallpapers.currentImage === "C:/walls/profile-pick.jpg",
                "the palette source left the saved pick");
            check(Wallpapers.current === "C:/walls/profile-pick.jpg",
                "the desktop left the saved pick");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "restarting a saved pick wrote a Windows wallpaper");

            // A later Windows change is still ignored.
            Native.Wallpaper.currentPath = "C:/walls/settings.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/settings-primary.jpg",
                secondary: "C:/walls/settings-secondary.jpg"};
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/profile-pick.jpg"
                && Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary-pick.jpg",
                "a Windows change replaced the saved picks");
            check(Wallpapers.currentImage === "C:/walls/profile-pick.jpg",
                "a Windows change supplied the palette source");

            // 2. A display without its own pick follows the profile-wide pick.
            Native.Wallpaper.screenIds.tertiary = "tertiary-id";
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}, {name: "tertiary"}];
            check(Wallpapers.currentForScreen({name: "tertiary"}) === "C:/walls/profile-pick.jpg",
                "a new display did not use the profile-wide pick");

            // 3. A new per-display pick is saved beside the older picks. A
            // restart would read both; the rewrite keeps the pick it does not
            // own and an unknown top-level key.
            check(Wallpapers.setWallpaper("C:/walls/new-pick.jpg", {name: "primary"}),
                "the display pick was rejected");
            check(Native.Wallpaper.calls.length === 0, "the display pick used the global setter");
            check(Native.Wallpaper.screenCalls.length === 1, "the display pick was not applied once");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/new-pick.jpg",
                "the picked display did not show its image");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary-pick.jpg",
                "the pick changed the untouched display");
            check(Wallpapers.currentForScreen({name: "tertiary"}) === "C:/walls/profile-pick.jpg",
                "the pick changed a display on the profile-wide default");
            const saved = record();
            check(saved.version === 1, "the saved record lost its version");
            check(saved.wallpaper === "C:/walls/profile-pick.jpg",
                "the per-display pick changed the profile-wide pick");
            check(saved.monitors["primary-id"] === "C:/walls/new-pick.jpg",
                "the new display pick was not recorded");
            check(saved.monitors["secondary-id"] === "C:/walls/secondary-pick.jpg",
                "the rewrite dropped the saved display pick");
            check(saved.note === "keep", "the rewrite dropped an unknown record field");
            check(Wallpapers.sourceRecordConfirmed === Wallpapers.sourceRecordPending,
                "the rewritten record was not confirmed");

            console.log("CAELESTIA_WALLPAPER_RESTART_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_RESTART_FAIL " + error);
            Qt.exit(1);
        }
    }
}
