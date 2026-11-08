import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// A fresh profile that a previous run already classified, restarted after
// Wallpaper Engine wrote the Windows wallpaper. No Caelestia pick exists, so
// the bundled wallpaper must stay: process presence cannot turn an engine
// write into a Caelestia choice. The engine is installed and running, then
// stopped, then restarted; none of those transitions changes the source. Its
// physical claim (issue #25) stays observable throughout.
//
// Seeding the fakes from a property initializer runs before any production
// singleton is created, so this is the profile state a real restart reads.
QtObject {
    id: root

    readonly property string markerPath: Paths.state + "/wallpaper/profile.json"
    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"

    property int assertions: 0
    property var nextStep: null

    // The previous run wrote the fresh marker; the engine then changed the
    // Windows wallpaper. No desktop.json exists.
    property bool seeded: {
        Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
            "C:/walls/primary.jpg", "C:/walls/secondary.jpg",
            "C:/we/primary.jpg", "C:/we/secondary.jpg", root.markerPath];
        Native.FsUtils.existingDirs = [Paths.state + "/wallpaper"];
        Files.contents[root.markerPath] = JSON.stringify({version: 1, profile: "fresh"});
        Native.Wallpaper.currentPath = "C:/we/primary.jpg";
        Native.Wallpaper.screenPaths = {primary: "C:/we/primary.jpg", secondary: "C:/we/secondary.jpg"};
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
    function later(step): void {
        root.nextStep = step;
        tick.restart();
    }
    function guard(step): void {
        try {
            step();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_ENGINE_OFF_FAIL " + error);
            Qt.exit(1);
        }
    }
    function finish(): void {
        console.log("CAELESTIA_WALLPAPER_ENGINE_OFF_PASS " + assertions);
        Qt.quit();
    }

    property Timer tick: Timer {
        interval: 1
        repeat: false
        onTriggered: {
            const step = root.nextStep;
            root.nextStep = null;
            if (step)
                root.guard(step);
        }
    }

    Component.onCompleted: Qt.callLater(run)

    function bundledEverywhere(description): void {
        check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
            description + ": the primary display left the bundled asset");
        check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
            description + ": the secondary display left the bundled asset");
        check(Wallpapers.currentImage === Wallpapers.fallback,
            description + ": the palette source left the bundled asset");
    }

    function run(): void {
        guard(function() {
            // 1. The restarted profile keeps the bundled asset even though
            // Windows now names the engine's image.
            check(WallpaperProvenance.ready && !WallpaperProvenance.existing,
                "the saved fresh marker was not read");
            check(Wallpapers.sourceFresh, "the profile did not resolve as fresh");
            check(Wallpapers.sourceInitialized, "the fresh source resolved");
            check(Wallpapers.sourceRecordHealth === "missing", "the restarted profile found a pick");
            check(Wallpapers.fileCurrent === Wallpapers.fallback,
                "the engine-written Windows wallpaper became the source");
            bundledEverywhere("a restart after an engine write");
            check(Files.contents[root.recordPath] === undefined,
                "the restart wrote a wallpaper record");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "the restart wrote a Windows wallpaper");

            // 2. An installed, running engine is not an opt-in. It keeps its
            // physical claim, but the adapter shows and colours the bundled
            // wallpaper.
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}};
            WallpaperEngine.items = [{path: "C:/we/project.json", preview: "C:/we/preview.jpg"}];
            check(WallpaperEngine.ownsDesktop, "the running engine lost its physical claim");
            check(!Wallpapers.externalWallpaperActive, "a disabled engine claimed the visible desktop");
            check(Wallpapers.current === Wallpapers.fallback, "the bundled wallpaper is not visible");
            bundledEverywhere("a running disabled engine");
            check(WallpaperEngine.picker === "files", "the disabled engine kept the picker");

            // The engine changes the Windows wallpaper itself. Nothing is
            // adopted and nothing is recorded.
            Native.Wallpaper.currentPath = "C:/we/primary-2.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/we/primary-2.jpg", secondary: "C:/we/secondary-2.jpg"};
            Native.FsUtils.existingFiles = Native.FsUtils.existingFiles.concat(
                ["C:/we/primary-2.jpg", "C:/we/secondary-2.jpg"]);
            Native.DesktopLayer.wallpaperChanged();
            bundledEverywhere("an engine write during the run");
            check(Files.contents[root.recordPath] === undefined,
                "an engine write during the run created a record");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "the disabled engine wrote a Windows wallpaper");

            // 3. Enabling restores the engine view and palette preview. The
            // physical claim was present throughout. Disabling returns to the
            // bundled wallpaper.
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

            // 4. Stopping the process does not adopt anything either: under
            // the new rule a fresh profile never follows Windows.
            WallpaperEngine.running = false;
            bundledEverywhere("a stopped engine");
            check(Files.contents[root.recordPath] === undefined,
                "a stopped engine created a record");

            // 5. Restarting the engine and writing another Windows image is
            // still not a Caelestia pick.
            WallpaperEngine.running = true;
            check(WallpaperEngine.ownsDesktop, "the restarted engine lost its physical claim");
            check(!Wallpapers.externalWallpaperActive, "the restarted disabled engine claimed the desktop");
            Native.Wallpaper.currentPath = "C:/we/primary-3.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/we/primary-3.jpg", secondary: "C:/we/secondary-3.jpg"};
            Native.FsUtils.existingFiles = Native.FsUtils.existingFiles.concat(
                ["C:/we/primary-3.jpg", "C:/we/secondary-3.jpg"]);
            Native.DesktopLayer.wallpaperChanged();
            bundledEverywhere("a restarted engine write");
            check(Files.contents[root.recordPath] === undefined,
                "a restarted engine created a record");
            WallpaperEngine.running = false;
            bundledEverywhere("the engine stopped again");
            check(record().version === undefined, "the stopped engine wrote a record");

            root.finish();
        });
    }
}
