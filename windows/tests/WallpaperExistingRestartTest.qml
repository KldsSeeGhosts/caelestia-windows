import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// The prior shell left two local Windows wallpapers and an idle Wallpaper
// Engine process. Restarting Caelestia does not restart Explorer or the engine.
QtObject {
    id: root

    readonly property var primary: ({name: "primary"})
    readonly property var secondary: ({name: "secondary"})
    readonly property string primaryImage: "C:/walls/primary.jpg"
    readonly property string secondaryImage: "C:/walls/secondary.jpg"
    readonly property string paletteCache: "C:/walls/old-palette.jpg"
    readonly property string markerPath: Paths.state + "/wallpaper/profile.json"
    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"
    readonly property string configPath: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json"
    property int assertions: 0

    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }
    function later(step): void {
        Qt.callLater(() => {
            try { step(); }
            catch (error) {
                console.error("CAELESTIA_WALLPAPER_EXISTING_RESTART_FAIL " + error);
                Qt.exit(1);
            }
        });
    }
    function process(name): var {
        return WallpaperEngine.data.find(child => child.objectName === name);
    }

    Component.onCompleted: later(run)

    function run(): void {
        Quickshell.environment = {CAELESTIA_COMBINED_LIVE: "1", CAELESTIA_WE_PYTHON: "C:/fake/python.exe"};
        Quickshell.screens = [primary, secondary];
        Files.contents = {
            [markerPath]: JSON.stringify({version: 1, profile: "existing"}),
            [configPath]: JSON.stringify({windows: {wallpaperEngine: {enabled: false}}}),
            [Paths.state + "/wallpaper/path.txt"]: paletteCache
        };
        Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp", markerPath, configPath,
            primaryImage, secondaryImage, paletteCache];
        Native.Wallpaper.currentPath = primaryImage;
        Native.Wallpaper.screenPaths = {primary: primaryImage, secondary: secondaryImage};
        Native.DesktopLayer.enabled = true;
        Native.DesktopLayer.active = true;
        Native.DesktopLayer.embedRefused = true;
        check(WallpaperProvenance.existing && !Wallpapers.sourceFresh, "the prior marker did not survive restart");
        check(!WallpaperEngine.enabled, "the fixture did not load the saved opt-out");
        check(!Native.DesktopLayer.underlayActive, "the fake engine is already idle");
        check(WallpaperEngine.ownsDesktop, "the shell yielded before discovery");
        process("wallpaperEngineScan").stdout.read(JSON.stringify({
            ok: true, detected: true, running: true, items: [], monitors: {}, displays: {}
        }));
        later(stopCompleted);
    }

    function stopCompleted(): void {
        const control = process("wallpaperEngineDesktopControl");
        check(control.running && control.command[2] === "stop", "disabled startup did not dispatch stop");
        Native.DesktopLayer.embedRefused = false;
        check(WallpaperEngine.ownsDesktop, "the unconfirmed stop released the startup guard");
        Native.DesktopLayer.embedRefused = true;
        control.running = false;
        control.exited(0);
        check(WallpaperEngine.ownsDesktop, "stop alone released a refused desktop host");
        Native.DesktopLayer.active = false;
        Native.DesktopLayer.embedRefused = false;
        check(WallpaperEngine.ownsDesktop, "the shell took ownership without a working host");
        Native.DesktopLayer.active = true;
        check(WallpaperEngine.running, "the fixture stopped the engine process");
        check(Wallpapers.currentForScreen(primary) === primaryImage, "idle engine suppressed the saved primary wallpaper");
        check(Wallpapers.currentForScreen(secondary) === secondaryImage, "idle engine suppressed the saved secondary wallpaper");
        check(!Wallpapers.externalWallpaperActive, "idle engine kept the external selection active");
        check(Wallpapers.currentImage === primaryImage, "the old palette cache replaced the Windows source");
        check(Wallpapers.defaultPickerTarget(secondary)?.targetId === "secondary-id",
            "launcher did not preserve the other display's image after restart");
        check(Files.contents[recordPath] === undefined, "restarting an existing profile wrote a wallpaper record");
        check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
            "restarting wrote to the Windows desktop");

        Native.DesktopLayer.coveredByForeign = true;
        check(Wallpapers.externalWallpaperActive && WallpaperEngine.desktopClaimed,
            "leaving the startup guard disabled a returning engine window");
        check(Wallpapers.currentForScreen(primary) === primaryImage
            && Wallpapers.currentForScreen(secondary) === secondaryImage, "the returning engine erased the underlay");
        Native.DesktopLayer.coveredByForeign = false;
        check(WallpaperEngine.desktopHandedBack && !Wallpapers.externalWallpaperActive,
            "a later native handback did not release the engine");
        check(Wallpapers.currentForScreen(primary) === primaryImage
            && Wallpapers.currentForScreen(secondary) === secondaryImage, "the later handback lost the display choices");
        console.log("CAELESTIA_WALLPAPER_EXISTING_RESTART_PASS " + assertions);
        Qt.quit();
    }
}
