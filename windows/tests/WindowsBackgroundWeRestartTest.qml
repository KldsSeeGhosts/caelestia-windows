import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.modules.background

// A new QML process starts with the saved ON setting and the still-existing
// foreign wallpaper. Its earlier stop/play is not a process start, nor is it
// stored shell ownership state. Every process and native dependency is fake.
Item {
    id: root
    property int assertions: 0
    property Component background: Component { WindowsBackground {} }
    property var subject
    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }
    Component.onCompleted: Qt.callLater(function() {
        try {
            Quickshell.environment = {CAELESTIA_WINDOWS_BACKGROUND: "1",
                CAELESTIA_WINDOWS_DESKTOP_ICONS: "Replace",
                CAELESTIA_COMBINED_LIVE: "1", CAELESTIA_WE_PYTHON: "C:/fake/python.exe"};
            const configPath = Quickshell.env("CAELESTIA_CONFIG_DIR") + "/windows.json";
            Native.FsUtils.existingFiles = [configPath, "C:/fixture/assets/wallpaper.webp"];
            Files.contents[configPath] = JSON.stringify({windows: {wallpaperEngine: {enabled: true}}});
            Native.DesktopLayer.active = true;
            Native.DesktopLayer.coveredByForeign = true;
            WallpaperEngine.applySnapshot({detected: true, running: true, items: [], monitors: {}});
            root.subject = background.createObject(root);
            check(subject !== null, "the background did not load");
            check(WallpaperEngine.enabled, "startup did not read the saved ON setting");
            check(Native.DesktopLayer.externalWallpaperEnabled,
                "startup disabled the existing wallpaper's underlay policy");
            check(Native.DesktopLayer.aboveIcons.length === 0,
                "startup covered the existing wallpaper with Replace icons");
            check(subject.underlayActive && WallpaperEngine.desktopClaimed,
                "startup did not acknowledge the already-existing wallpaper");
            check(!WallpaperEngine.desktopHandedBack && subject.externalActive,
                "startup retained a previous process's handback");
            subject.logUnderlayDecision();
            const acknowledged = JSON.parse(subject.lastUnderlayDecision);
            check(acknowledged.integration && acknowledged.policy && acknowledged.running
                && acknowledged.underlay && acknowledged.claimed && !acknowledged.handedBack,
                "the decision log did not explain the acknowledged underlay");
            Native.DesktopLayer.coveredByForeign = false;
            check(WallpaperEngine.desktopHandedBack && !subject.externalActive,
                "a destroyed wallpaper did not hand back");
            WallpaperEngine.applyStatus({detected: true, running: true, monitors: {}});
            check(WallpaperEngine.desktopHandedBack && !subject.underlayActive,
                "status reclaimed a genuinely destroyed wallpaper");
            check(Native.DesktopLayer.externalWallpaperEnabled,
                "handback switched off native underlay discovery");
            subject.logUnderlayDecision();
            const handedBack = JSON.parse(subject.lastUnderlayDecision);
            check(handedBack.policy && handedBack.running && !handedBack.underlay
                && handedBack.handedBack,
                "the decision log did not distinguish handback from disabled integration");
            console.log("CAELESTIA_BACKGROUND_WE_RESTART_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_BACKGROUND_WE_RESTART_FAIL " + error);
            Qt.exit(1);
        }
    })
}
