import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// Fresh-install wallpaper defaults. The complete production Wallpapers and
// WallpaperEngine singletons own the decision; only native I/O and the scheme
// generator are faked. There is no saved Wallpaper Engine option in the
// fixture profile, which is the fresh-install state.
QtObject {
    id: root

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function normalized(path): string {
        return String(path ?? "").replace(/\\/g, "/");
    }
    function reloadConfig(document): void {
        Files.contents[WallpaperEngine.settingsPath] = JSON.stringify(document);
        Files.changed(WallpaperEngine.settingsPath);
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/windows-default.jpg",
                "C:/walls/primary.jpg", "C:/walls/secondary.jpg"];
            // 1. A fresh profile has no saved Wallpaper Engine value. The
            // integration is off and the shell shows the bundled asset on
            // every display, not the Windows wallpaper that happened to be
            // there before Caelestia was installed.
            WallpaperEngine.options = {};
            check(!WallpaperEngine.enabled, "a missing enabled key disabled the integration");
            check(Wallpapers.sourceInitialized, "the fresh wallpaper source resolved");
            check(!Wallpapers.sourceChosen, "a fresh profile is on the bundled default");
            check(Wallpapers.fileCurrent === Wallpapers.fallback, "fresh fileCurrent is the bundled asset");
            check(Wallpapers.current === Wallpapers.fallback, "fresh current is the bundled asset");
            check(Wallpapers.currentImage === Wallpapers.fallback, "fresh palette source is the bundled asset");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the primary display did not start on the bundled asset");
            check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "the secondary display did not start on the bundled asset");
            check(WallpaperEngine.picker === "files", "a fresh picker did not start on local files");
            check((Files.contents[Wallpapers.sourceRecordPath] ?? "").indexOf('"default"') !== -1,
                "the fresh profile did not record its default source");
            check(WallpaperEngine.options.enabled === undefined,
                "loading a missing key did not write it into the sidecar");

            // A detected installation does not override the opt-in.
            WallpaperEngine.detected = true;
            WallpaperEngine.items = [{path: "C:/we/project.json", preview: "C:/we/preview.jpg"}];
            check(!Wallpapers.list.some(w => w.path === "C:/we/project.json"),
                "a detected but disabled engine appeared in the wallpaper list");
            WallpaperEngine.items = [];
            WallpaperEngine.detected = false;

            // First-run colour derivation uses the bundled wallpaper when the
            // optional runtime is available, and makes no call when it is
            // absent (the shell then keeps the documented fixed palette).
            Files.contents[Wallpapers.schemeStatePath] = JSON.stringify({name: "dynamic"});
            Files.contents[Wallpapers.schemeSourcePath] = "C:/we/other.jpg";
            Wallpapers.reloadSchemeState();
            Wallpapers.applyPalette(false);
            check(SchemeGenerator.calls.length > 0 &&
                SchemeGenerator.calls[SchemeGenerator.calls.length - 1].path === Wallpapers.fallback,
                "first-run colours did not derive from the bundled wallpaper");
            const colourCalls = SchemeGenerator.calls.length;
            SchemeGenerator.available = false;
            Wallpapers.applyPalette(false);
            check(SchemeGenerator.calls.length === colourCalls,
                "the absent colour runtime still generated a palette");
            SchemeGenerator.available = true;

            // 2. Saved values are kept. The old default "auto" is a saved
            // value, so it stays automatic; only an absent key defaults off.
            Files.contents[WallpaperEngine.settingsPath] = JSON.stringify({
                windows: {wallpaperEngine: {enabled: "auto", monitor: "Monitor1"}}
            });
            Files.changed(WallpaperEngine.settingsPath);
            check(WallpaperEngine.enabled, "a saved auto value was changed to off");
            check(JSON.parse(Files.contents[WallpaperEngine.settingsPath]).windows.wallpaperEngine.enabled === "auto",
                "loading rewrote the saved auto value");
            WallpaperEngine.options = {enabled: true};
            check(WallpaperEngine.enabled, "a saved true value was not on");
            WallpaperEngine.options = {enabled: false};
            check(!WallpaperEngine.enabled, "a saved false value was not off");
            WallpaperEngine.options = {};
            check(!WallpaperEngine.enabled, "an absent value did not default off");

            // An upgrade keeps the user's Windows wallpaper and per-display
            // choices once the profile has opted into them.
            Wallpapers.sourceChosen = true;
            Wallpapers.fileCurrent = "C:/walls/primary.jpg";
            // The fake generator replaces Files.contents wholesale when it
            // reports a palette, so write the record after that synchronous
            // generation; production writes each file separately.
            Wallpapers.persistedSourceRecord = "";
            Wallpapers.persistSourceChoice();
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
            Wallpapers.refreshScreenFiles();
            check(Wallpapers.current === "C:/walls/primary.jpg", "an existing saved wallpaper was replaced");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/primary.jpg",
                "the existing primary wallpaper was replaced");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/secondary.jpg",
                "the existing secondary wallpaper was replaced");
            check((Files.contents[Wallpapers.sourceRecordPath] ?? "").indexOf('"user"') !== -1,
                "the upgrade did not record the user source");
            Quickshell.screens = [];

            // 3. Enabled but unavailable never blanks the desktop and keeps
            // the Caelestia image. A user source stays the saved image; a
            // fresh source stays the bundled asset.
            WallpaperEngine.options = {enabled: true};
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.running = false;
            WallpaperEngine.detected = false;
            WallpaperEngine.desktopHandedBack = false;
            WallpaperEngine.items = [];
            WallpaperEngine.monitors = {};
            check(!WallpaperEngine.ownsDesktop, "an unavailable engine claimed the desktop");
            check(!Wallpapers.externalWallpaperActive, "an unavailable engine became the external owner");
            check(Wallpapers.current === "C:/walls/primary.jpg",
                "enabled-but-unavailable did not keep the saved wallpaper");
            WallpaperEngine.detected = true;
            check(WallpaperEngine.picker === "files",
                "an installed but stopped engine took over the picker");
            WallpaperEngine.detected = false;

            Wallpapers.sourceChosen = false;
            Wallpapers.fileCurrent = Wallpapers.fallback;
            Wallpapers.screenFiles = {};
            Wallpapers.lastGoodFile = Wallpapers.fallback;
            Wallpapers.persistSourceChoice();
            check(Wallpapers.current === Wallpapers.fallback,
                "enabled-but-unavailable did not keep the bundled wallpaper");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "enabled-but-unavailable blanked or changed the primary display");

            // A running engine that has handed the desktop back also shows
            // the Caelestia source, not a blank frame.
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.desktopHandedBack = true;
            check(!WallpaperEngine.ownsDesktop, "a handed-back engine kept the desktop claim");
            check(Wallpapers.current === Wallpapers.fallback,
                "a handed-back engine did not keep the bundled wallpaper");
            WallpaperEngine.running = false;
            WallpaperEngine.desktopHandedBack = false;
            WallpaperEngine.detected = false;

            // The Nexus toggle writes only the opt-in and preserves every
            // other key in the sidecar. Toggling a saved auto normalizes it
            // only because the user changed it here.
            reloadConfig({
                windows: {
                    hideTaskbar: true,
                    notifications: {replaceSystemBanners: false},
                    wallpaperEngine: {enabled: "auto", picker: "both", monitor: "Monitor1"}
                }
            });
            check(WallpaperEngine.enabled, "the saved auto value was not loaded before the toggle");
            WallpaperEngine.setEnabled(false);
            let saved = JSON.parse(Files.contents[WallpaperEngine.settingsPath]);
            check(saved.windows.hideTaskbar === true, "the toggle dropped hideTaskbar");
            check(saved.windows.notifications.replaceSystemBanners === false,
                "the toggle dropped notification settings");
            check(saved.windows.wallpaperEngine.enabled === false, "the toggle did not save off");
            check(saved.windows.wallpaperEngine.picker === "both", "the toggle dropped the picker");
            check(saved.windows.wallpaperEngine.monitor === "Monitor1", "the toggle dropped the monitor");
            check(!WallpaperEngine.enabled, "the toggle did not apply off");
            check(WallpaperEngine.lastError === "", "the toggle reported an error: " + WallpaperEngine.lastError);
            WallpaperEngine.setEnabled(true);
            saved = JSON.parse(Files.contents[WallpaperEngine.settingsPath]);
            check(saved.windows.wallpaperEngine.enabled === true, "the toggle did not save on");
            check(saved.windows.hideTaskbar === true, "the second toggle dropped hideTaskbar");
            check(WallpaperEngine.enabled, "the toggle did not apply on");

            // A profile without the sidecar can still opt in: the write
            // creates the file and does not fail on the missing key.
            delete Files.contents[WallpaperEngine.settingsPath];
            Files.changed(WallpaperEngine.settingsPath);
            check(!WallpaperEngine.enabled, "a removed sidecar did not return to off");
            WallpaperEngine.setEnabled(true);
            const created = JSON.parse(Files.contents[WallpaperEngine.settingsPath]);
            check(created.windows.wallpaperEngine.enabled === true, "the toggle did not create the sidecar");
            check(WallpaperEngine.enabled, "the created sidecar was not applied");

            // The record never stores a path, only the decision. Picks stay
            // where Windows stores them and cannot leak into the record.
            Wallpapers.sourceChosen = false;
            Wallpapers.persistSourceChoice();
            const record = JSON.parse(Files.contents[Wallpapers.sourceRecordPath]);
            check(record.version === 1 && record.source === "default", "the default record is invalid");
            check(record.path === undefined, "the record stored a wallpaper path");

            console.log("CAELESTIA_WALLPAPER_DEFAULTS_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_DEFAULTS_FAIL " + error);
            Qt.exit(1);
        }
    }
}
