import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// A fresh profile with Wallpaper Engine installed and running, but not opted
// in. Caelestia must show and derive colours from its bundled wallpaper. A
// wallpaper change the engine makes while it runs is engine bookkeeping, not a
// Caelestia pick, so it must not become the profile's source. The physical
// ownership claim (issue #25) must remain observable for handback and
// above-icons protection.
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
                "C:/walls/secondary.jpg", "C:/we/primary.jpg", "C:/we/secondary.jpg"];
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
            WallpaperEngine.options = {enabled: false};

            check(Wallpapers.sourceInitialized, "the fresh source resolved");
            check(!Wallpapers.sourceChosen, "the fresh profile opted in");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the fresh primary did not start on the bundled asset");
            let saved = record();
            check(saved.seen["primary-id"] === "C:/walls/primary.jpg",
                "the fresh profile did not baseline the stock Windows image");

            // An installed, running engine is not an opt-in. It keeps its
            // physical claim, but the adapter shows and colours the bundled
            // wallpaper.
            WallpaperEngine.options = {enabled: false};
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}};
            WallpaperEngine.items = [{path: "C:/we/project.json", preview: "C:/we/preview.jpg"}];
            check(WallpaperEngine.ownsDesktop, "the running engine lost its physical claim");
            check(!Wallpapers.externalWallpaperActive, "a disabled engine claimed the visible desktop");
            check(Wallpapers.current === Wallpapers.fallback, "the bundled wallpaper is not visible");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "the disabled engine supplied the palette source");
            check(WallpaperEngine.picker === "files", "the disabled engine kept the picker");

            // The engine changes the Windows wallpaper itself. That is not a
            // Caelestia choice: the displays stay on the bundled default.
            // Process presence cannot identify the writer, so the comparison
            // baseline is left alone instead of being moved to the engine
            // image; that evidence stays available for when the engine exits.
            Native.Wallpaper.currentPath = "C:/we/primary.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/we/primary.jpg", secondary: "C:/we/secondary.jpg"};
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "an engine-written wallpaper became the primary source");
            check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "an engine-written wallpaper became the secondary source");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "the engine-written wallpaper became the palette source");
            check(!Wallpapers.sourceChosen, "an engine-written wallpaper opted the profile in");
            check(Wallpapers.sourceSeen["primary-id"] === "C:/walls/primary.jpg",
                "the comparison baseline was overwritten while the engine ran");
            saved = record();
            check(saved.seen["primary-id"] === "C:/walls/primary.jpg",
                "the stored comparison baseline moved while the engine ran");
            check(saved.source === "default", "the engine wallpaper changed the profile baseline");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "the disabled engine wrote a Windows wallpaper");

            // Enabling restores the engine view and palette preview. The
            // physical claim was present throughout.
            WallpaperEngine.options = {enabled: true};
            check(Wallpapers.externalWallpaperActive, "the enabled engine did not take the desktop");
            check(Wallpapers.currentImage === "C:/we/preview.jpg",
                "the enabled engine did not supply the palette preview");
            check(Wallpapers.current === Wallpapers.fallback,
                "the underlay left the verified bundled wallpaper");
            WallpaperEngine.options = {enabled: false};
            check(!Wallpapers.externalWallpaperActive, "disabling left the engine as the owner");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "disabling left the engine preview as the palette source");
            check(WallpaperEngine.ownsDesktop, "disabling dropped the physical claim");

            console.log("CAELESTIA_WALLPAPER_ENGINE_OFF_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_ENGINE_OFF_FAIL " + error);
            Qt.exit(1);
        }
    }
}
