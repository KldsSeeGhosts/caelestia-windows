import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// All I/O is recording fakes. In particular play/stop never reach WE and the
// native acknowledgement below never touches the owner's desktop.
QtObject {
    id: root

    readonly property string configPath: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json"
    property int assertions: 0
    property var scan
    property var control
    property bool seeded: {
        Quickshell.environment = {CAELESTIA_COMBINED_LIVE: "1",
            CAELESTIA_WE_PYTHON: "C:/fake/python.exe"};
        Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp", configPath];
        Files.contents[configPath] = JSON.stringify({windows: {wallpaperEngine: {enabled: false}}});
        return true;
    }
    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }
    function guard(step): void {
        try { step(); }
        catch (error) {
            console.error("CAELESTIA_WALLPAPER_ENGINE_TOGGLE_FAIL " + error);
            Qt.exit(1);
        }
    }
    function later(step): void {
        Qt.callLater(() => guard(step));
    }
    function childNamed(parent, name) {
        for (const child of (parent.data ?? parent.children ?? [])) {
            if (child.objectName === name)
                return child;
            const found = childNamed(child, name);
            if (found)
                return found;
        }
        return null;
    }
    function snapshot(): var {
        return {ok: true, detected: true, running: true, items: [
            {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}],
            monitors: {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}}};
    }
    function finishScan(): void {
        scan.stdout.text = JSON.stringify(snapshot());
        scan.running = false;
        scan.exited(0);
    }
    function finishControl(): void {
        control.running = false;
        control.exited(0);
    }

    Component.onCompleted: later(run)
    function run(): void {
        check(!WallpaperEngine.enabled, "the fixture did not start disabled");
        check(Wallpapers.sourceFresh, "the fixture did not start with a fresh profile");
        control = childNamed(WallpaperEngine, "wallpaperEngineDesktopControl");
        for (const child of WallpaperEngine.data)
            if (child.command?.[2] === "snapshot")
                scan = child;
        check(scan && scan.running, "startup discovery did not run");
        finishScan();
        later(function() {
            check(control.running && control.command[2] === "stop", "disabled startup did not stop playback");
            finishControl();
            Native.DesktopLayer.enabled = true;
            Native.DesktopLayer.active = true;
            Native.DesktopLayer.underlayActive = true;
            Native.DesktopLayer.underlayActive = false;
            check(WallpaperEngine.desktopHandedBack, "disabled playback did not hand back");
            check(!Wallpapers.externalWallpaperActive, "disabled playback kept the external source");
            check(Wallpapers.currentImage === Wallpapers.fallback, "disabled playback kept the engine palette");

            // Disabled-era polling retains the old snapshot. Leave a full
            // scan in flight while Nexus saves ON. Its completion clears
            // fullScanNeeded and must not consume the enable's fresh scan.
            WallpaperEngine.refresh(false);
            check(scan.statusOnly, "the established snapshot did not use cheap polling");
            finishScan();
            WallpaperEngine.refresh(true);
            check(!scan.statusOnly, "the disabled-era full scan did not start");
            WallpaperEngine.setEnabled(true);
            later(enabled);
        });
    }
    function enabled(): void {
        check(WallpaperEngine.enabled, "the verified ON save did not enable integration");
        check(JSON.parse(Files.contents[configPath]).windows.wallpaperEngine.enabled === true,
            "ON did not persist the setting");
        check(!WallpaperEngine.desktopHandedBack, "ON retained the disabled-era handback until reload");
        check(WallpaperEngine.ownsDesktop, "ON did not restore the fresh-start ownership guard");
        check(Wallpapers.externalWallpaperActive, "ON did not restore the fresh-start external source");
        check(Wallpapers.currentImage === "C:/we/preview.jpg", "ON did not restore the fresh-start palette source");
        check(control.running && control.command[2] === "play", "ON did not dispatch play");
        finishControl();
        finishScan();
        later(function() {
            check(scan.running && !scan.statusOnly, "ON lost its full refresh behind the in-flight snapshot");
            finishScan();
            check(WallpaperEngine.status === "ready", "ON did not reach the fresh-start ready state");
            Native.DesktopLayer.underlayActive = true;
            check(WallpaperEngine.desktopClaimed, "ON did not accept a fresh native acknowledgement");
            WallpaperEngine.setEnabled(false);
            later(disabled);
        });
    }
    function disabled(): void {
        check(!WallpaperEngine.enabled, "the verified OFF save did not disable integration");
        check(JSON.parse(Files.contents[configPath]).windows.wallpaperEngine.enabled === false,
            "OFF did not persist the setting");
        check(WallpaperEngine.status === "disabled", "OFF kept the enabled status until another poll");
        check(!Wallpapers.externalWallpaperActive, "OFF kept the external source");
        check(Wallpapers.current === Wallpapers.fallback, "OFF did not restore the Caelestia wallpaper");
        check(Wallpapers.currentImage === Wallpapers.fallback, "OFF did not restore the Caelestia palette");
        check(control.running && control.command[2] === "stop", "OFF did not dispatch stop");
        finishControl();
        Native.DesktopLayer.underlayActive = false;
        check(WallpaperEngine.desktopHandedBack, "OFF did not accept the native handback");
        check(!WallpaperEngine.ownsDesktop, "OFF retained the external ownership claim after handback");
        console.log("CAELESTIA_WALLPAPER_ENGINE_TOGGLE_PASS " + assertions);
        Qt.quit();
    }
}
