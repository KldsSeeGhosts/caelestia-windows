import QtQuick
import Quickshell.Windows as Native
import qs.services

QtObject {
    id: root
    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            const primary = {name: "primary"};
            const secondary = {name: "secondary"};
            // This fixture exercises targeting, so opt in as a user would and
            // follow Windows as an existing profile does. The fresh default is
            // covered by WallpaperDefaultsTest.
            WallpaperEngine.options = {enabled: true};
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.running = false;
            Wallpapers.sourceFresh = false;
            Wallpapers.sourceInitialized = true;
            Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/walls/picked.jpg", "C:/walls/preview.jpg"];
            // The same fixture can demonstrate the old global-setter defect.
            if (typeof Wallpapers.currentForScreen === "function")
                Wallpapers.screenFiles = {"primary-id": "C:/walls/primary.jpg", "secondary-id": "C:/walls/secondary.jpg"};
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg", secondary), "secondary selection rejected");
            check(Native.Wallpaper.calls.length === 0, "explicit target used global native setter");
            check(Native.Wallpaper.screenCalls.length === 1, "secondary setter not called once");
            check(Native.Wallpaper.screenCalls[0].screen === "secondary", "selection targeted primary");
            check(Wallpapers.currentForScreen(primary) === "C:/walls/primary.jpg", "primary image changed");
            check(Wallpapers.currentForScreen(secondary) === "C:/walls/picked.jpg", "secondary surface did not update");

            Wallpapers.preview("C:/walls/preview.jpg", secondary);
            check(Wallpapers.currentForScreen(primary) === "C:/walls/primary.jpg", "preview leaked to primary");
            check(Wallpapers.currentForScreen(secondary) === "C:/walls/preview.jpg", "secondary preview missing");
            Wallpapers.stopPreview();
            check(Wallpapers.currentForScreen(secondary) === "C:/walls/picked.jpg", "preview changed committed choice");

            const captured = Wallpapers.captureScreen(secondary);
            Native.Wallpaper.screenIds = {primary: "primary-id"};
            check(!Wallpapers.setWallpaper("C:/walls/picked.jpg", captured), "removed display accepted");
            check(!Wallpapers.setWallpaper("C:/walls/picked.jpg", null), "missing explicit display used primary");
            Native.Wallpaper.screenIds = {primary: "primary-id", secondary: "replacement-id"};
            check(!Wallpapers.setWallpaper("C:/walls/picked.jpg", captured), "reused screen name retargeted pending pick");
            check(Native.Wallpaper.screenCalls.length === 1, "invalid target changed a wallpaper");
            Native.Wallpaper.screenIds = {primary: "primary-id", secondary: "secondary-id"};

            WallpaperEngine.running = true;
            check(Wallpapers.currentForScreen(primary) === "C:/walls/primary.jpg", "engine changed primary underlay");
            check(Wallpapers.currentForScreen(secondary) === "C:/walls/picked.jpg", "engine changed secondary underlay");
            WallpaperEngine.desktopHandedBack = true;
            check(Wallpapers.currentForScreen(secondary) === "C:/walls/picked.jpg", "handback lost per-screen choice");
            WallpaperEngine.detected = true;
            WallpaperEngine.items = [{path: "C:/we/project.json"}];
            check(Wallpapers.setWallpaper("C:/we/project.json", secondary), "engine target rejected");
            check(WallpaperEngine.actionScreenTarget === "secondary-id", "engine lost the owning screen");
            WallpaperEngine.options = {monitor: "Monitor9"};
            check(WallpaperEngine.actionScreenTarget === "secondary-id", "config update retargeted in-flight action");
            check(!Wallpapers.setWallpaper("C:/we/project.json", null), "engine missing target used primary");
            console.log("CAELESTIA_WALLPAPER_SCREEN_TARGET_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_WALLPAPER_SCREEN_TARGET_FAIL " + error);
            Qt.exit(1);
        }
    }
}
