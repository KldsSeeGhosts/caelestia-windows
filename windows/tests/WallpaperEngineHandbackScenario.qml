import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// Differential regression for the enabled-dependent source policy. One
// scenario runs under two entry fixtures: WallpaperEngineHandbackExistingTest
// and WallpaperEngineHandbackFreshTest. The existing profile saved
// enabled:false and must give the released build's results exactly: the
// bundled underlay while the running engine owns the desktop, the engine
// preview as the palette source, then the bundled wallpaper after the backend
// acknowledges the handback. The fresh profile must ignore the engine's output
// whether or not the integration is enabled, so the handback changes nothing.
QtObject {
    id: root

    // Set by the entry fixture before run() is called.
    property bool existingProfile: false
    readonly property string markerPath: Paths.state + "/wallpaper/profile.json"
    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"
    readonly property string configPath: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json"

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function guard(step): void {
        try {
            step();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_ENGINE_HANDBACK_FAIL " + error);
            Qt.exit(1);
        }
    }
    function finish(): void {
        console.log("CAELESTIA_WALLPAPER_ENGINE_HANDBACK_PASS " + assertions);
        Qt.quit();
    }
    function marker(): var {
        return JSON.parse(Files.contents[root.markerPath] ?? "{}");
    }

    Component.onCompleted: Qt.callLater(run)

    function engineRunning(): void {
        WallpaperEngine.detected = true;
        WallpaperEngine.running = true;
        WallpaperEngine.snapshotReady = true;
        WallpaperEngine.items = [{path: "C:/we/project.json", preview: "C:/we/preview.jpg"}];
        WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json",
            preview: "C:/we/preview.jpg"}};
    }

    function run(): void {
        guard(function() {
            // Seed before any production singleton exists. The saved
            // enabled:false is read through the real windows.json path.
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/we/project.json", "C:/we/preview.jpg",
                root.configPath];
            if (root.existingProfile)
                Native.FsUtils.existingDirs = [Paths.state];
            Files.contents[root.configPath] = JSON.stringify({
                windows: {wallpaperEngine: {enabled: false}}
            });
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/primary.jpg",
                secondary: "C:/walls/secondary.jpg"};
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            // The engine was already running when the shell started. Its
            // visible claim therefore exists before Wallpapers resolves, which
            // is the startup order the released build read.
            engineRunning();

            check(WallpaperProvenance.ready, "the profile was not classified");
            check(WallpaperProvenance.existing === root.existingProfile,
                "the fixture profile did not classify as expected");
            check(Wallpapers.sourceFresh === !root.existingProfile,
                "the wallpaper source took the wrong profile branch");
            check(Wallpapers.sourceInitialized, "the wallpaper source did not resolve");
            check(!WallpaperEngine.enabled, "the saved enabled:false was not loaded");
            check(marker().profile === (root.existingProfile ? "existing" : "fresh"),
                "the provenance marker does not name the fixture profile");
            check(WallpaperEngine.ownsDesktop, "the running engine lost its physical claim");

            if (root.existingProfile) {
                // The released build. enabled:false is not a saved wallpaper
                // choice and does not change what a running engine shows.
                check(Wallpapers.externalWallpaperActive,
                    "a saved enabled:false disabled the released engine source");
                check(Wallpapers.fileCurrent === "C:/walls/windows-default.jpg",
                    "the saved Windows wallpaper was not the startup source");
                check(Wallpapers.current === Wallpapers.fallback,
                    "the underlay left the bundled asset");
                check(Wallpapers.currentImage === "C:/we/preview.jpg",
                    "the engine preview is not the palette source");
                check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                    "the primary display left the bundled underlay");
                check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                    "the secondary display left the bundled underlay");
                check(Wallpapers.lastGoodFile === Wallpapers.fallback,
                    "the engine wallpaper became the remembered handback source");
                check(Object.keys(Wallpapers.screenFiles).length === 0,
                    "the engine desktop read the per-monitor Windows images");
            } else {
                // The fresh-profile policy. The engine keeps its physical
                // claim, but its output is not the visible source.
                check(!Wallpapers.externalWallpaperActive,
                    "a disabled engine claimed the fresh desktop");
                check(Wallpapers.fileCurrent === Wallpapers.fallback,
                    "the Windows wallpaper became the fresh source");
                check(Wallpapers.current === Wallpapers.fallback,
                    "the fresh underlay left the bundled asset");
                check(Wallpapers.currentImage === Wallpapers.fallback,
                    "the engine preview became the fresh palette source");
                check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                    "the primary display left the fresh bundled asset");
                check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                    "the secondary display left the fresh bundled asset");
                check(Wallpapers.lastGoodFile === Wallpapers.fallback,
                    "the engine wallpaper became the fresh handback source");
                check(Files.contents[root.recordPath] === undefined,
                    "the fresh profile wrote a pick record");
            }

            // The backend acknowledges the engine wallpaper and then its
            // window closes while wallpaper64.exe keeps running.
            Native.DesktopLayer.enabled = true;
            Native.DesktopLayer.active = true;
            Native.DesktopLayer.underlayActive = true;
            check(WallpaperEngine.desktopClaimed, "the underlay acknowledgement was not claimed");
            check(!WallpaperEngine.desktopHandedBack, "the underlay acknowledgement handed back early");
            check(WallpaperEngine.ownsDesktop, "the acknowledged engine lost its physical claim");

            if (root.existingProfile) {
                check(Wallpapers.current === Wallpapers.fallback,
                    "the underlay changed while the acknowledged engine ran");
                check(Wallpapers.currentImage === "C:/we/preview.jpg",
                    "the acknowledged engine lost the palette preview");
            } else {
                check(Wallpapers.current === Wallpapers.fallback,
                    "the fresh underlay changed while the engine ran");
                check(Wallpapers.currentImage === Wallpapers.fallback,
                    "the fresh palette followed the acknowledged engine");
            }

            Native.DesktopLayer.underlayActive = false;
            check(WallpaperEngine.desktopHandedBack, "the closed engine wallpaper did not hand back");
            check(!WallpaperEngine.ownsDesktop, "the handed-back engine kept the physical claim");
            check(!Wallpapers.externalWallpaperActive,
                "the handed-back engine stayed the visible source");
            check(Wallpapers.current === Wallpapers.fallback,
                "the handed-back desktop left the bundled wallpaper");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "the handed-back palette left the bundled wallpaper");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the handed-back primary display left the bundled wallpaper");
            check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "the handed-back secondary display left the bundled wallpaper");
            check(Wallpapers.lastGoodFile === Wallpapers.fallback,
                "the handback remembered the engine wallpaper");
            check(Wallpapers.fileCurrent === Wallpapers.fallback,
                "the handback source is not the bundled wallpaper");
            if (root.existingProfile) {
                check(Object.keys(Wallpapers.screenFiles).length === 0,
                    "the handback imported the per-monitor Windows images");
            } else {
                check(Files.contents[root.recordPath] === undefined,
                    "the fresh handback wrote a pick record");
            }

            root.finish();
        });
    }
}
