import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// Upgrade migration without any of the optional state files older builds
// wrote. The only signal is the Caelestia state directory every earlier build
// created. An existing profile loads the saved Windows wallpaper and follows
// Windows edits, but switching desktops must preserve Caelestia picks. A
// Caelestia pick still changes Windows without writing a fresh-profile record.
QtObject {
    id: root

    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function marker(): var {
        return JSON.parse(Files.contents[WallpaperProvenance.markerPath] ?? "{}");
    }

    Component.onCompleted: Qt.callLater(run)

    property Timer switchBroadcast: Timer {
        interval: 500
        onTriggered: root.checkSwitchBroadcast()
    }

    property Timer delayedSwitchBroadcast: Timer {
        interval: 900
        onTriggered: root.checkDelayedSwitchBroadcast()
    }

    property Timer settingsAfterSwitch: Timer {
        interval: 800
        onTriggered: root.checkSettingsAfterSwitch()
    }

    function run(): void {
        try {
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/walls/new-primary.jpg",
                "C:/walls/new-secondary.jpg", "C:/walls/picked.jpg",
                "C:/walls/picked2.jpg"];
            // No theme-tokens.json, scheme.json, wallpaper/path.txt or
            // recordings.json. The existing state directory alone is the
            // evidence an earlier Caelestia run left behind.
            Native.FsUtils.existingDirs = [Paths.state];
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];

            check(WallpaperProvenance.ready && WallpaperProvenance.existing,
                "the existing profile was not classified from its state directory");
            check(marker().version === 1 && marker().profile === "existing",
                "the existing provenance marker was not written");
            check(!Wallpapers.sourceFresh, "the existing profile was treated as fresh");
            check(Wallpapers.sourceInitialized, "the upgrade source resolved");
            check(Wallpapers.fileCurrent === "C:/walls/windows-default.jpg",
                "the upgrade replaced the saved Windows wallpaper");
            check(Wallpapers.current === Native.Wallpaper.currentWallpaper().replace(/\\/g, "/"),
                "the upgraded desktop did not show the saved wallpaper");
            check(Wallpapers.lastGoodFile === "C:/walls/windows-default.jpg",
                "the saved wallpaper was not remembered for a handback");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/primary.jpg",
                "the saved primary wallpaper was replaced");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary.jpg",
                "the saved secondary wallpaper was replaced");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "the migration wrote a Windows wallpaper");
            check(Files.contents[root.recordPath] === undefined,
                "the existing profile wrote a fresh-profile pick record");

            // The released build follows a Windows wallpaper change.
            Native.Wallpaper.currentPath = "C:/walls/new-primary.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/new-primary.jpg",
                secondary: "C:/walls/new-secondary.jpg"};
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/new-primary.jpg",
                "the existing profile stopped following Windows");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/new-secondary.jpg",
                "the existing profile stopped following per-display Windows images");

            // An explicit display pick is applied to Windows and kept for that
            // display, exactly as before. No pick record appears.
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg", {name: "secondary"}),
                "the existing profile rejected a display pick");
            check(Native.Wallpaper.screenCalls.length === 1, "the display pick was not applied once");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "the display pick was not shown");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/new-primary.jpg",
                "the display pick changed the untouched display");
            check(Files.contents[root.recordPath] === undefined,
                "the existing profile recorded a fresh-profile pick");

            // A global pick changes the saved Windows wallpaper source.
            check(Wallpapers.setWallpaper("C:/walls/picked2.jpg"),
                "the existing profile rejected a global pick");
            check(Native.Wallpaper.calls.length === 1, "the global pick was not applied once");
            check(Wallpapers.fileCurrent === "C:/walls/picked2.jpg",
                "the global pick did not become the source");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/picked2.jpg",
                "the global pick did not become the visible wallpaper");
            check(Files.contents[root.recordPath] === undefined,
                "the global pick wrote a fresh-profile pick record");

            check(Wallpapers.setWallpaper("C:/walls/picked.jpg", {name: "secondary"}),
                "the existing profile rejected a display pick after the global pick");
            Native.Wallpaper.currentDesktop = "desktop-b";
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/windows-default.jpg",
                secondary: "C:/walls/windows-default.jpg"};
            switchBroadcast.start();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_UPGRADE_FAIL " + error);
            Qt.exit(1);
        }
    }

    function checkSwitchBroadcast(): void {
        try {
            Native.DesktopLayer.wallpaperChanged();
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/picked2.jpg",
                "a virtual desktop switch replaced the global pick");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "a virtual desktop switch replaced the display pick");
            delayedSwitchBroadcast.start();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_UPGRADE_FAIL " + error);
            Qt.exit(1);
        }
    }

    function checkDelayedSwitchBroadcast(): void {
        try {
            // 1400 ms after the switch (simulating a re-armed 500 ms native debounce).
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/picked2.jpg",
                "a delayed virtual desktop switch broadcast replaced the global pick");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "a delayed virtual desktop switch broadcast replaced the display pick");
            settingsAfterSwitch.start();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_UPGRADE_FAIL " + error);
            Qt.exit(1);
        }
    }

    function checkSettingsAfterSwitch(): void {
        try {
            check(Wallpapers.fileCurrent === "C:/walls/picked2.jpg"
                && Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "the switch wallpaper was adopted after settling");
            Native.Wallpaper.currentPath = "C:/walls/new-primary.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/new-primary.jpg",
                secondary: "C:/walls/new-secondary.jpg"};
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/new-primary.jpg"
                && Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/new-secondary.jpg",
                "a later Settings change did not replace the picks");
            console.log("CAELESTIA_WALLPAPER_UPGRADE_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_UPGRADE_FAIL " + error);
            Qt.exit(1);
        }
    }
}
