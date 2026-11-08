import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// Downgrade, choose a newer static wallpaper in the older build, upgrade
// again while a disabled Wallpaper Engine process is still running. Process
// presence cannot identify who wrote the Windows wallpaper, so the comparison
// baseline must stay untouched. The newer pick is kept as evidence while the
// engine could be the writer and is adopted as soon as the process is gone;
// overwriting the baseline before the comparison is what used to lose it.
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
                "C:/walls/baseline-primary.jpg", "C:/walls/baseline-secondary.jpg",
                "C:/walls/new-primary.jpg", "C:/walls/new-secondary.jpg"];
            // A disabled but running engine, discovered before the adapter
            // resolves this profile.
            WallpaperEngine.options = {enabled: false};
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}};
            Files.contents["C:/fixture/state/wallpaper/desktop.json"] = JSON.stringify({
                version: 1,
                source: "default",
                seen: {
                    "primary-id": "C:/walls/baseline-primary.jpg",
                    "secondary-id": "C:/walls/baseline-secondary.jpg"
                }
            });
            Native.Wallpaper.currentPath = "C:/walls/new-primary.jpg";
            Native.Wallpaper.screenPaths = {
                primary: "C:/walls/new-primary.jpg",
                secondary: "C:/walls/new-secondary.jpg"
            };
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(Wallpapers.sourceInitialized, "the rollback source resolved");
            check(Wallpapers.sourceRecordHealth === "valid", "the valid record was rejected");
            check(!Wallpapers.sourceChosen, "the record's profile baseline changed");
            check(Wallpapers.externalWallpaperActive === false,
                "a disabled engine became the visible owner");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the newer pick became visible while the engine could be its writer");
            check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "the untouched display changed while the engine was running");
            check(Wallpapers.sourceSeen["primary-id"] === "C:/walls/baseline-primary.jpg"
                && Wallpapers.sourceSeen["secondary-id"] === "C:/walls/baseline-secondary.jpg",
                "the comparison evidence was overwritten by the running engine");
            let saved = record();
            check(saved.seen["primary-id"] === "C:/walls/baseline-primary.jpg",
                "the stored comparison baseline moved while the engine ran");
            check(saved.monitors === undefined, "the unresolved pick was recorded early");

            // The process is gone, so the change can be resolved instead of
            // being ignored forever.
            WallpaperEngine.running = false;
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/new-primary.jpg",
                "the newer primary pick was ignored after the engine stopped");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/new-secondary.jpg",
                "the newer secondary pick was ignored after the engine stopped");
            check(Wallpapers.currentImage === "C:/walls/new-primary.jpg",
                "the adopted pick did not become the palette source");
            saved = record();
            check(saved.version === 1 && saved.source === "default",
                "resolving the pick changed the profile baseline");
            check(saved.monitors["primary-id"] === "user" && saved.monitors["secondary-id"] === "user",
                "the resolved picks were not recorded");
            check(saved.seen["primary-id"] === "C:/walls/baseline-primary.jpg",
                "the baseline was rewritten when the pick was adopted");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "rollback resolution wrote a Windows wallpaper");

            console.log("CAELESTIA_WALLPAPER_ROLLBACK_ENGINE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_ROLLBACK_ENGINE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
