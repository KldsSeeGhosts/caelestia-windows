import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services

// Fresh-install wallpaper defaults. The complete production Wallpapers and
// WallpaperEngine singletons own the decision; only native I/O, the sidecar
// and the scheme generator are faked. There is no saved record and no earlier
// Caelestia state in the fixture profile, which is the fresh-install state.
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
    function reloadConfig(document): void {
        Files.contents[WallpaperEngine.settingsPath] = JSON.stringify(document);
        Files.changed(WallpaperEngine.settingsPath);
    }

    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            // Seed the profile before the singletons exist. Two displays so a
            // per-display pick can prove it leaves the other one alone.
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/walls/picked.jpg"];
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
            WallpaperEngine.options = {};

            // 1. A fresh profile shows the bundled asset on every display and
            // records that decision. It never writes the Windows wallpaper.
            check(Wallpapers.sourceInitialized, "the fresh wallpaper source resolved");
            check(!Wallpapers.sourceChosen, "a fresh profile is on the bundled default");
            check(Wallpapers.sourceRecordHealth === "valid", "the fresh record was not written");
            check(Wallpapers.fileCurrent === Wallpapers.fallback, "fresh fileCurrent is the bundled asset");
            check(Wallpapers.current === Wallpapers.fallback, "fresh current is the bundled asset");
            check(Wallpapers.currentImage === Wallpapers.fallback, "fresh palette source is the bundled asset");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the primary display did not start on the bundled asset");
            check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "the secondary display did not start on the bundled asset");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "a fresh profile wrote the Windows wallpaper");
            check(Native.FsUtils.madePaths.includes("C:/fixture/state/wallpaper"),
                "the record directory was not created before the write");
            let saved = record();
            check(saved.version === 1 && saved.source === "default", "the fresh record is invalid");
            check(saved.seen["primary-id"] === "C:/walls/primary.jpg"
                && saved.seen["secondary-id"] === "C:/walls/secondary.jpg",
                "the fresh record did not baseline the Windows images");
            check(saved.monitors === undefined, "a fresh profile recorded a monitor override");

            // A detected installation does not override the opt-in.
            check(!WallpaperEngine.enabled, "a missing enabled key enabled the integration");
            WallpaperEngine.detected = true;
            WallpaperEngine.items = [{path: "C:/we/project.json", preview: "C:/we/preview.jpg"}];
            check(!Wallpapers.list.some(w => w.path === "C:/we/project.json"),
                "a detected but disabled engine appeared in the wallpaper list");
            WallpaperEngine.items = [];
            WallpaperEngine.detected = false;

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

            // 3. An installed, running engine the profile has not enabled
            // neither claims the desktop nor supplies the palette. The bundled
            // wallpaper stays visible. Enabling it restores the engine view,
            // and the physical ownership claim itself is unchanged, so #25's
            // handback and above-icons protections still see the process.
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}};
            WallpaperEngine.items = [{path: "C:/we/project.json", preview: "C:/we/preview.jpg"}];
            check(WallpaperEngine.ownsDesktop, "the running engine lost its physical claim");
            check(!Wallpapers.externalWallpaperActive,
                "a disabled integration claimed the visible desktop");
            check(Wallpapers.current === Wallpapers.fallback,
                "a disabled integration did not keep the bundled wallpaper");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "a disabled integration supplied the palette source");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "a disabled integration changed the primary display");
            check(WallpaperEngine.picker === "files", "a disabled integration kept the engine picker");
            WallpaperEngine.options = {enabled: true};
            check(Wallpapers.externalWallpaperActive, "an enabled running engine did not take the desktop");
            check(Wallpapers.currentImage === "C:/we/preview.jpg",
                "an enabled engine did not supply its preview");
            check(Wallpapers.current === Wallpapers.fallback,
                "the underlay left the verified wallpaper");
            WallpaperEngine.options = {enabled: false};
            WallpaperEngine.running = false;
            WallpaperEngine.detected = false;
            WallpaperEngine.monitors = {};
            WallpaperEngine.items = [];
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "disabling the engine changed the display");

            // 4. One display's pick records only that display. The untouched
            // display keeps the bundled asset even after the native change
            // notification that follows a real wallpaper write.
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg", {name: "secondary"}),
                "the secondary display pick was rejected");
            check(Native.Wallpaper.calls.length === 0, "the display pick used the global setter");
            check(Native.Wallpaper.screenCalls.length === 1, "the display pick was not applied once");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the first display pick changed the untouched display");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "the picked display did not show its image");
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the native notification imported the untouched display's Windows image");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "the native notification lost the picked display");
            saved = record();
            check(saved.source === "default", "a display pick changed the profile baseline");
            check(saved.monitors["secondary-id"] === "user", "the display pick was not recorded");
            check(saved.monitors["primary-id"] === undefined, "the display pick recorded another display");
            check(saved.seen["primary-id"] === "C:/walls/primary.jpg",
                "the untouched display lost its baseline");
            check(saved.path === undefined, "the record stored a wallpaper path");

            // 5. A global pick opts the profile in and keeps the saved
            // wallpaper while the engine is enabled but unavailable.
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg"), "the global pick was rejected");
            check(Native.Wallpaper.calls.length === 1, "the global pick was not applied once");
            check(Wallpapers.sourceChosen, "the global pick did not opt the profile in");
            check(Wallpapers.current === "C:/walls/picked.jpg", "the global pick is not visible");
            saved = record();
            check(saved.source === "user", "the global pick did not record the user source");
            WallpaperEngine.options = {enabled: true};
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.running = false;
            WallpaperEngine.detected = false;
            WallpaperEngine.desktopHandedBack = false;
            check(!WallpaperEngine.ownsDesktop, "an unavailable engine claimed the desktop");
            check(!Wallpapers.externalWallpaperActive, "an unavailable engine became the external owner");
            check(Wallpapers.current === "C:/walls/picked.jpg",
                "enabled-but-unavailable did not keep the saved wallpaper");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/picked.jpg",
                "enabled-but-unavailable changed the saved display");
            WallpaperEngine.detected = true;
            check(WallpaperEngine.picker === "files",
                "an installed but stopped engine took over the picker");
            WallpaperEngine.detected = false;

            // A running engine that has handed the desktop back also shows
            // the Caelestia source, not a blank frame.
            WallpaperEngine.detected = true;
            WallpaperEngine.running = true;
            WallpaperEngine.desktopHandedBack = true;
            check(!WallpaperEngine.ownsDesktop, "a handed-back engine kept the desktop claim");
            check(Wallpapers.current === "C:/walls/picked.jpg",
                "a handed-back engine did not keep the saved wallpaper");
            WallpaperEngine.running = false;
            WallpaperEngine.desktopHandedBack = false;
            WallpaperEngine.detected = false;
            WallpaperEngine.options = {};

            // 6. The Nexus toggle merges only after the reload completes. The
            // view's cached document is stale here: the file gained
            // hideTaskbar and a new unrelated key after the last load, exactly
            // as a merge by another process would leave it. A read-then-text
            // merge would revert hideTaskbar and drop the new key.
            reloadConfig({
                windows: {
                    hideTaskbar: false,
                    wallpaperEngine: {enabled: "auto", picker: "both", monitor: "Monitor1"}
                }
            });
            check(WallpaperEngine.enabled, "the saved auto value was not loaded before the toggle");
            // A newer merge lands behind the view's back: the cached text is
            // still the document above.
            let advanced = {
                windows: {
                    hideTaskbar: true,
                    notifications: {replaceSystemBanners: false},
                    wallpaperEngine: {enabled: "auto", picker: "both", monitor: "Monitor1"},
                    newSection: {keep: "me"}
                }
            };
            Files.contents[WallpaperEngine.settingsPath] = JSON.stringify(advanced);
            Files.pendingReloads = [];
            Files.deferReloads = true;
            WallpaperEngine.setEnabled(false);
            check(JSON.parse(Files.contents[WallpaperEngine.settingsPath]).windows.hideTaskbar === true,
                "the toggle wrote before its fresh read completed");
            Files.flushReloads();
            Files.deferReloads = false;
            saved = JSON.parse(Files.contents[WallpaperEngine.settingsPath]);
            check(saved.windows.hideTaskbar === true, "the toggle dropped hideTaskbar");
            check(saved.windows.notifications.replaceSystemBanners === false,
                "the toggle dropped notification settings");
            check(saved.windows.wallpaperEngine.enabled === false, "the toggle did not save off");
            check(saved.windows.wallpaperEngine.picker === "both", "the toggle dropped the picker");
            check(saved.windows.wallpaperEngine.monitor === "Monitor1", "the toggle dropped the monitor");
            check(saved.windows.newSection.keep === "me", "the toggle dropped an unrelated new key");
            check(!WallpaperEngine.enabled, "the toggle did not apply off");
            check(WallpaperEngine.lastError === "", "the toggle reported an error: " + WallpaperEngine.lastError);

            // An existing but unreadable file is rejected instead of replaced
            // with a document built from nothing.
            const unreadable = JSON.stringify({
                windows: {hideTaskbar: true, wallpaperEngine: {enabled: "auto", picker: "both"}}
            });
            Files.contents[WallpaperEngine.settingsPath] = unreadable;
            Files.unreadable[WallpaperEngine.settingsPath] = true;
            Files.pendingReloads = [];
            Files.deferReloads = true;
            WallpaperEngine.setEnabled(true);
            Files.flushReloads();
            Files.deferReloads = false;
            Files.pendingReloads = [];
            delete Files.unreadable[WallpaperEngine.settingsPath];
            check(Files.contents[WallpaperEngine.settingsPath] === unreadable,
                "an unreadable sidecar was replaced");
            check(WallpaperEngine.lastError !== "", "an unreadable sidecar was not reported");
            check(!WallpaperEngine.enabled, "a failed read changed the in-memory value");
            WallpaperEngine.lastError = "";

            // A profile without the sidecar can still opt in: a missing file
            // is a fresh install, so the write creates it.
            delete Files.contents[WallpaperEngine.settingsPath];
            Files.changed(WallpaperEngine.settingsPath);
            check(!WallpaperEngine.enabled, "a removed sidecar did not return to off");
            WallpaperEngine.setEnabled(true);
            const created = JSON.parse(Files.contents[WallpaperEngine.settingsPath]);
            check(created.windows.wallpaperEngine.enabled === true, "the toggle did not create the sidecar");
            check(WallpaperEngine.enabled, "the created sidecar was not applied");

            // 7. First-run colour derivation uses the bundled wallpaper when
            // the optional runtime is available, and makes no call when it is
            // absent. This runs last: the fake generator replaces the whole
            // file map when it reports a palette.
            Files.contents[Wallpapers.schemeStatePath] = JSON.stringify({name: "dynamic"});
            Files.contents[Wallpapers.schemeSourcePath] = "C:/we/other.jpg";
            Wallpapers.reloadSchemeState();
            Wallpapers.fileCurrent = Wallpapers.fallback;
            Wallpapers.screenFiles = {};
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

            console.log("CAELESTIA_WALLPAPER_DEFAULTS_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_DEFAULTS_FAIL " + error);
            Qt.exit(1);
        }
    }
}
