import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import Caelestia.Config
import qs.services

// Whole production Wallpapers and WallpaperEngine singletons. Only native I/O,
// configuration and the palette generator are faked. Generator calls, not
// source spelling or call-site counts, are the observable contract.
QtObject {
    id: root
    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value) throw new Error(description);
    }
    function count(expected, description): void { check(SchemeGenerator.calls.length === expected, description); }
    function last(): var { return SchemeGenerator.calls[SchemeGenerator.calls.length - 1]; }
    function select(preview): void { WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview}}; }
    function persist(name, source): void {
        Files.contents = {
            [Wallpapers.schemeStatePath]: JSON.stringify({name}),
            [Wallpapers.schemeSourcePath]: source
        };
        Wallpapers.reloadSchemeState();
    }
    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            Wallpapers.stopPreview();
            // This fixture exercises the enabled engine's palette ownership;
            // the fresh, disabled default is covered by WallpaperDefaultsTest.
            WallpaperEngine.options = {enabled: true};
            // Simulate a profile that already chose its own wallpaper; the
            // fresh default is covered by WallpaperDefaultsTest.
            Wallpapers.sourceInitialized = true;
            Wallpapers.sourceChosen = true;
            Wallpapers.fileCurrent = Native.Wallpaper.currentWallpaper().replace(/\\/g, "/");
            Wallpapers.refreshScreenFiles();
            WallpaperEngine.snapshotReady = false;
            WallpaperEngine.running = true;
            persist("dynamic", "C:/we/preview.jpg");
            count(0, "loading persisted state must not generate");
            select("C:/we/preview.jpg");
            WallpaperEngine.snapshotReady = true;
            count(0, "async snapshot deduplicates persisted preview");
            check(Wallpapers.schemeStateReady, "both state files settled");
            WallpaperEngine.running = false;
            count(1, "engine stop generates once");
            check(last().path === "C:/walls/windows-default.jpg", "stop uses own wallpaper");
            check(SchemeGenerator.runs === 1, "one generator run");
            Native.FsUtils.existingFiles.push("C:/walls/new-windows.jpg");
            Wallpapers.fileCurrent = "C:/walls/new-windows.jpg";
            count(2, "Windows wallpaper change");
            check(last().path === Wallpapers.fileCurrent, "changed Windows source");
            select("C:/we/preview-2.jpg");
            WallpaperEngine.running = true;
            count(3, "fast status selection");
            WallpaperEngine.snapshotReady = false;
            WallpaperEngine.snapshotReady = true;
            count(3, "full snapshot deduplicates fast selection");
            check(last().path === "C:/we/preview-2.jpg", "fast selection preview");
            Wallpapers.applyPalette(false);
            count(3, "explicit duplicate");
            select("C:/we/preview.jpg");
            count(4, "another project");
            check(last().path === "C:/we/preview.jpg", "project preview");
            GlobalConfig.services.smartScheme = false;
            count(5, "smart toggle forces generation");
            check(last().path === "C:/we/preview.jpg", "toggle uses current image");
            check(last().smart === false, "smart setting forwarded");
            SchemeGenerator.setScheme("catppuccin", Wallpapers.currentImage);
            check(Wallpapers.schemeName === "catppuccin", "generator signal reloads scheme state");
            WallpaperEngine.running = false;
            count(5, "fixed palette survives source changes");
            SchemeGenerator.setScheme("dynamic", Wallpapers.currentImage);
            WallpaperEngine.running = true;
            count(6, "return to earlier image after dynamic selection");
            check(last().path === "C:/we/preview.jpg", "earlier preview");
            SchemeGenerator.available = false;
            WallpaperEngine.running = false;
            count(6, "unavailable generator is never called");
            SchemeGenerator.available = true;
            Files.contents = {};
            Wallpapers.schemeNameLoaded = false;
            Wallpapers.schemeSourceLoaded = false;
            Wallpapers.reloadSchemeState();
            check(Wallpapers.schemeStateReady, "missing files settle startup");
            check(Wallpapers.schemeName === "", "fresh profile has no dynamic scheme");
            count(6, "fresh profile does not generate");
            SchemeGenerator.setScheme("dynamic", Wallpapers.currentImage);
            count(6, "scheme reload does not recursively regenerate");
            check(Wallpapers.schemeSource === Wallpapers.currentImage, "generator source persisted");
            WallpaperEngine.running = true;
            check(Wallpapers.currentImage === "C:/we/preview.jpg", "external ownership selects preview");
            check(last().path === "C:/we/preview.jpg", "external preview generated");
            const before = SchemeGenerator.calls.length;
            WallpaperEngine.desktopHandedBack = true;
            check(Wallpapers.currentImage === Wallpapers.fileCurrent, "handback selects own wallpaper");
            count(before + 1, "handback generates exactly once");
            check(last().path === Wallpapers.fileCurrent, "handback generator uses own source");
            Native.FsUtils.existingFiles.push("C:/walls/picked.jpg");
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg"), "explicit pick accepted");
            count(before + 2, "explicit pick has one generation owner");
            check(last().path === "C:/walls/picked.jpg", "picked source forwarded");
            check(Native.Wallpaper.calls.length === 1, "one native wallpaper request");
            console.log("CAELESTIA_WALLPAPER_COLOURS_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_COLOURS_FAIL " + error);
            Qt.exit(1);
        }
    }
}
