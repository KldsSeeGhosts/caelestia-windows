import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native
import qs.services
import qs.utils

// Fresh-install wallpaper defaults. The complete production Wallpapers,
// WallpaperProvenance and WallpaperEngine singletons own the decision; only
// native I/O, the sidecar and the scheme generator are faked. There is no
// profile marker and no earlier Caelestia state in the fixture profile, which
// is the fresh-install state.
//
// A fresh profile shows the bundled asset until the user picks a wallpaper in
// Caelestia. Windows Settings and Wallpaper Engine changes are never followed;
// a picker or Nexus pick, profile-wide or per display, is recorded so a later
// start keeps it. The Nexus toggle must outlive an onLoaded callback and an
// asynchronous write, so the toggle and colour stages advance through the
// event loop.
QtObject {
    id: root

    readonly property string markerPath: Paths.state + "/wallpaper/profile.json"
    readonly property string recordPath: Paths.state + "/wallpaper/desktop.json"

    property int assertions: 0
    property var nextStep: null
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function record(): var {
        return JSON.parse(Files.contents[root.recordPath] ?? "{}");
    }
    function marker(): var {
        return JSON.parse(Files.contents[root.markerPath] ?? "{}");
    }
    function reloadConfig(document): void {
        Files.contents[WallpaperEngine.settingsPath] = JSON.stringify(document);
        Files.changed(WallpaperEngine.settingsPath);
    }
    function later(step): void {
        root.nextStep = step;
        tick.restart();
    }
    function guard(step): void {
        try {
            step();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_DEFAULTS_FAIL " + error);
            Qt.exit(1);
        }
    }
    function finish(): void {
        console.log("CAELESTIA_WALLPAPER_DEFAULTS_PASS " + assertions);
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

    function run(): void {
        guard(function() {
            // Seed the profile before the singletons exist. Two displays so a
            // per-display pick can prove it leaves the other one alone.
            Native.FsUtils.existingFiles = ["C:/fixture/assets/wallpaper.webp",
                "C:/walls/windows-default.jpg", "C:/walls/primary.jpg",
                "C:/walls/secondary.jpg", "C:/walls/picked.jpg",
                "C:/walls/picked2.jpg", "C:/walls/settings-primary.jpg",
                "C:/walls/settings-secondary.jpg"];
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
            WallpaperEngine.options = {};

            // 1. A fresh profile shows the bundled asset on every display. It
            // records provenance, writes no wallpaper record before a pick and
            // never writes the Windows wallpaper.
            check(WallpaperProvenance.ready && !WallpaperProvenance.existing,
                "the fresh profile was not classified before startup writers");
            check(marker().version === 1 && marker().profile === "fresh",
                "the fresh provenance marker was not written");
            check(Wallpapers.sourceFresh, "the fresh profile did not resolve as fresh");
            check(Wallpapers.sourceInitialized, "the fresh wallpaper source resolved");
            check(Wallpapers.sourceRecordHealth === "missing", "the fresh profile found a record");
            check(Wallpapers.profilePick === "", "a fresh profile has a profile-wide pick");
            check(Wallpapers.fileCurrent === Wallpapers.fallback, "fresh fileCurrent is the bundled asset");
            check(Wallpapers.current === Wallpapers.fallback, "fresh current is the bundled asset");
            check(Wallpapers.currentImage === Wallpapers.fallback, "fresh palette source is the bundled asset");
            check(Wallpapers.lastGoodFile === Wallpapers.fallback, "fresh good file is the bundled asset");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the primary display did not start on the bundled asset");
            check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "the secondary display did not start on the bundled asset");
            check(Native.Wallpaper.calls.length === 0 && Native.Wallpaper.screenCalls.length === 0,
                "a fresh profile wrote the Windows wallpaper");
            check(Files.contents[root.recordPath] === undefined,
                "a fresh profile wrote a wallpaper record before a pick");
            check(Native.FsUtils.makePathCalls === 0,
                "a fresh profile created the record directory before a pick");

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

            // 4. A Windows Settings change on a fresh profile is not followed.
            // The bundled asset stays even though Windows now names another
            // image, and no record is created.
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/settings-primary.jpg",
                secondary: "C:/walls/settings-secondary.jpg"};
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === Wallpapers.fallback,
                "a Windows Settings change replaced the fresh source");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "a Windows Settings change supplied the palette source");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "a Windows Settings change reached the primary display");
            check(Wallpapers.currentForScreen({name: "secondary"}) === Wallpapers.fallback,
                "a Windows Settings change reached the secondary display");
            check(Files.contents[root.recordPath] === undefined,
                "a Windows Settings change created a wallpaper record");

            // A Caelestia pick does switch to its image, and is recorded. The
            // per-display pick records only that display.
            check(Wallpapers.setWallpaper("C:/walls/picked.jpg", {name: "secondary"}),
                "the secondary display pick was rejected");
            check(Native.Wallpaper.calls.length === 0, "the display pick used the global setter");
            check(Native.Wallpaper.screenCalls.length === 1, "the display pick was not applied once");
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the first display pick changed the untouched display");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "the picked display did not show its image");
            Native.Wallpaper.screenPaths = {primary: "C:/walls/settings-primary.jpg",
                secondary: "C:/walls/picked.jpg"};
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the native notification imported the untouched display's Windows image");
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "the native notification lost the picked display");
            let saved = record();
            check(saved.version === 1, "the display pick wrote an unversioned record");
            check(saved.wallpaper === undefined, "a display pick set the profile-wide pick");
            check(saved.monitors["secondary-id"] === "C:/walls/picked.jpg",
                "the display pick was not recorded");
            check(saved.monitors["primary-id"] === undefined, "the display pick recorded another display");

            // The palette source must not keep naming a display that has
            // disconnected. The remaining display shows the bundled default.
            Quickshell.screens = [{name: "primary"}];
            check(Wallpapers.currentForScreen({name: "primary"}) === Wallpapers.fallback,
                "the disconnected pick stayed as the visible source");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "the disconnected pick stayed as the palette source");
            Quickshell.screens = [{name: "primary"}, {name: "secondary"}];
            check(Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked.jpg",
                "reconnecting the picked display lost its image");
            check(Wallpapers.currentImage === "C:/walls/picked.jpg",
                "the reconnected pick did not return as the palette source");

            // 5. A profile-wide pick applies to every display and supersedes
            // per-display picks. A later Windows Settings change still cannot
            // replace it.
            check(Wallpapers.setWallpaper("C:/walls/picked2.jpg"), "the global pick was rejected");
            check(Native.Wallpaper.calls.length === 1, "the global pick was not applied once");
            check(Wallpapers.profilePick === "C:/walls/picked2.jpg", "the global pick was not stored");
            check(Wallpapers.current === "C:/walls/picked2.jpg", "the global pick is not visible");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/picked2.jpg",
                "the global pick did not reach the primary display");
            checkedGlobalRecord(saved);
            Native.Wallpaper.currentPath = "C:/walls/windows-default.jpg";
            Native.Wallpaper.screenPaths = {primary: "C:/walls/settings-primary.jpg",
                secondary: "C:/walls/settings-secondary.jpg"};
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/picked2.jpg"
                && Wallpapers.currentForScreen({name: "secondary"}) === "C:/walls/picked2.jpg",
                "a later Windows Settings change replaced the Caelestia pick");
            check(Wallpapers.currentImage === "C:/walls/picked2.jpg",
                "a later Windows Settings change supplied the palette source");
            check(record().wallpaper === "C:/walls/picked2.jpg",
                "a later Windows Settings change rewrote the record");

            // An enabled but unavailable engine keeps the saved pick; a
            // handed-back running engine also shows it again.
            WallpaperEngine.options = {enabled: true};
            WallpaperEngine.snapshotReady = true;
            WallpaperEngine.running = false;
            WallpaperEngine.detected = false;
            WallpaperEngine.desktopHandedBack = false;
            check(!WallpaperEngine.ownsDesktop, "an unavailable engine claimed the desktop");
            check(!Wallpapers.externalWallpaperActive, "an unavailable engine became the external owner");
            check(Wallpapers.current === "C:/walls/picked2.jpg",
                "enabled-but-unavailable did not keep the saved wallpaper");
            check(Wallpapers.currentForScreen({name: "primary"}) === "C:/walls/picked2.jpg",
                "enabled-but-unavailable changed the saved display");
            WallpaperEngine.detected = true;
            check(WallpaperEngine.picker === "files",
                "an installed but stopped engine took over the picker");
            WallpaperEngine.running = true;
            WallpaperEngine.desktopHandedBack = true;
            check(!WallpaperEngine.ownsDesktop, "a handed-back engine kept the desktop claim");
            check(Wallpapers.current === "C:/walls/picked2.jpg",
                "a handed-back engine did not keep the saved wallpaper");
            WallpaperEngine.running = false;
            WallpaperEngine.desktopHandedBack = false;
            WallpaperEngine.detected = false;
            WallpaperEngine.options = {};
            root.later(runToggle);
        });
    }

    function checkedGlobalRecord(previous): void {
        const saved = record();
        check(saved.version === 1, "the global pick wrote an unversioned record");
        check(saved.wallpaper === "C:/walls/picked2.jpg", "the global pick was not recorded");
        check(!saved.monitors || Object.keys(saved.monitors).length === 0,
            "the global pick kept a per-display pick");
        check(saved !== previous, "the global pick reused the display record");
    }

    function runToggle(): void {
        guard(function() {
            // 6. The Nexus toggle merges only after the reload completes. The
            // view's cached document is stale here: the file gained
            // hideTaskbar and a new unrelated key after the last load, exactly
            // as a merge by another process would leave it. A read-then-text
            // merge would revert hideTaskbar and drop the new key.
            Files.asyncWrites = true;
            reloadConfig({
                windows: {
                    hideTaskbar: false,
                    wallpaperEngine: {enabled: "auto", picker: "both", monitor: "Monitor1"}
                }
            });
            check(WallpaperEngine.enabled, "the saved auto value was not loaded before the toggle");
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
            root.later(checkToggleMerge);
        });
    }

    function checkToggleMerge(): void {
        guard(function() {
            // The deferred setText queued an asynchronous write. Deliver it
            // before reading the applied facade value.
            Files.flushWrites();
            Files.deferReloads = false;
            Files.flushReloads();
            const saved = JSON.parse(Files.contents[WallpaperEngine.settingsPath]);
            check(saved.windows.hideTaskbar === true, "the toggle dropped hideTaskbar");
            check(saved.windows.notifications.replaceSystemBanners === false,
                "the toggle dropped notification settings");
            check(saved.windows.wallpaperEngine.enabled === false, "the toggle did not save off");
            check(saved.windows.wallpaperEngine.picker === "both", "the toggle dropped the picker");
            check(saved.windows.wallpaperEngine.monitor === "Monitor1", "the toggle dropped the monitor");
            check(saved.windows.newSection.keep === "me", "the toggle dropped an unrelated new key");
            check(!WallpaperEngine.enabled, "the toggle did not apply off");
            check(WallpaperEngine.lastError === "", "the toggle reported an error: " + WallpaperEngine.lastError);
            check(!WallpaperEngine.configSavePending, "the toggle kept a pending save");
            check(Files.droppedWrites === 0, "a write issued inside a FileView callback was dropped");

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

            // A save failure must not apply the new value and must remain
            // visible. The document on disk is unchanged.
            const beforeFailure = JSON.stringify({
                windows: {hideTaskbar: true, wallpaperEngine: {enabled: false}}
            });
            Files.contents[WallpaperEngine.settingsPath] = beforeFailure;
            Files.changed(WallpaperEngine.settingsPath);
            check(!WallpaperEngine.enabled, "the save-failure fixture did not start off");
            Files.saveFailures[WallpaperEngine.settingsPath] = 3;
            Files.pendingReloads = [];
            Files.deferReloads = true;
            WallpaperEngine.setEnabled(true);
            Files.flushReloads();
            root.later(checkToggleFailure);
            check(beforeFailure === Files.contents[WallpaperEngine.settingsPath],
                "a save failure changed the document");
        });
    }

    function checkToggleFailure(): void {
        guard(function() {
            Files.flushWrites();
            Files.deferReloads = false;
            delete Files.saveFailures[WallpaperEngine.settingsPath];
            check(!WallpaperEngine.enabled, "a failed save applied the new value");
            check(WallpaperEngine.lastError !== "", "a failed save was not reported");
            check(!WallpaperEngine.configSavePending, "a failed save kept a pending write");
            WallpaperEngine.lastError = "";

            // A profile without the sidecar can still opt in: a missing file
            // is a fresh install, so the write creates it.
            delete Files.contents[WallpaperEngine.settingsPath];
            Files.changed(WallpaperEngine.settingsPath);
            check(!WallpaperEngine.enabled, "a removed sidecar did not return to off");
            Files.pendingReloads = [];
            Files.deferReloads = true;
            WallpaperEngine.setEnabled(true);
            Files.flushReloads();
            root.later(checkToggleCreated);
        });
    }

    function checkToggleCreated(): void {
        guard(function() {
            Files.flushWrites();
            Files.deferReloads = false;
            Files.flushReloads();
            Files.asyncWrites = false;
            const created = JSON.parse(Files.contents[WallpaperEngine.settingsPath]);
            check(created.windows.wallpaperEngine.enabled === true, "the toggle did not create the sidecar");
            check(WallpaperEngine.enabled, "the created sidecar was not applied");
            check(Files.droppedWrites === 0, "the create path issued a write inside a callback");
            root.later(runCommitFailure);
        });
    }

    function runCommitFailure(): void {
        guard(function() {
            // A failed atomic commit still emits saved() on the pinned backend
            // (issue #28). The read-back must reject it instead of applying
            // the value that never reached the file.
            const off = {windows: {wallpaperEngine: {enabled: false}}};
            Files.contents[WallpaperEngine.settingsPath] = JSON.stringify(off);
            Files.changed(WallpaperEngine.settingsPath);
            check(!WallpaperEngine.enabled, "the commit-failure fixture did not start off");
            Files.asyncWrites = true;
            Files.commitFailures[WallpaperEngine.settingsPath] = true;
            Files.pendingReloads = [];
            Files.deferReloads = true;
            WallpaperEngine.setEnabled(true);
            Files.flushReloads();
            root.later(deliverCommitFailure);
        });
    }

    function deliverCommitFailure(): void {
        guard(function() {
            Files.flushWrites();
            Files.deferReloads = false;
            delete Files.commitFailures[WallpaperEngine.settingsPath];
            root.later(checkCommitFailure);
        });
    }

    function checkCommitFailure(): void {
        guard(function() {
            Files.flushReloads();
            Files.flushWrites();
            check(!WallpaperEngine.enabled, "a failed commit applied the new value");
            check(WallpaperEngine.lastError !== "", "a failed commit was not reported");
            check(!WallpaperEngine.configSavePending, "a failed commit kept a pending save");
            check(!WallpaperEngine.configSaveVerifying, "a failed commit stayed in verification");
            WallpaperEngine.lastError = "";
            Files.asyncWrites = false;
            root.later(runNoOpToggle);
        });
    }

    function runNoOpToggle(): void {
        guard(function() {
            // A toggle that lands back on the saved document must complete
            // immediately. FileView drops an identical setText(), so leaving
            // it pending would block every later toggle (issue #28).
            const savedOff = {windows: {wallpaperEngine: {enabled: false}}};
            Files.contents[WallpaperEngine.settingsPath] = JSON.stringify(savedOff, null, 2) + "\n";
            Files.changed(WallpaperEngine.settingsPath);
            check(!WallpaperEngine.enabled, "the no-op fixture did not start off");
            const writes = Files.writeRequests;
            Files.pendingReloads = [];
            Files.deferReloads = true;
            WallpaperEngine.setEnabled(true);
            WallpaperEngine.setEnabled(false);
            Files.flushReloads();
            check(!WallpaperEngine.configSavePending, "a no-op toggle kept a pending save");
            check(!WallpaperEngine.enabled, "a no-op toggle changed the saved value");
            check(Files.writeRequests === writes, "a no-op toggle wrote the unchanged document");
            check(WallpaperEngine.lastError === "", "a no-op toggle reported an error");
            Files.deferReloads = false;
            root.later(runNoOpRetry);
        });
    }

    function runNoOpRetry(): void {
        guard(function() {
            // A later toggle must still work after the no-op completed.
            Files.pendingReloads = [];
            Files.deferReloads = true;
            WallpaperEngine.setEnabled(true);
            Files.flushReloads();
            root.later(checkNoOpRetry);
        });
    }

    function checkNoOpRetry(): void {
        guard(function() {
            Files.deferReloads = false;
            Files.flushReloads();
            Files.flushWrites();
            check(WallpaperEngine.enabled, "a later toggle stayed blocked");
            check(!WallpaperEngine.configSavePending, "a later toggle kept a pending save");
            check(WallpaperEngine.lastError === "",
                "a later toggle reported an error: " + WallpaperEngine.lastError);
            root.later(runColours);
        });
    }

    function runColours(): void {
        guard(function() {
            // 7. A real missing-scheme start settles on the documented fixed
            // palette and makes no generator call. Only once scheme state says
            // dynamic does first-run colour derivation use the bundled image.
            delete Files.contents[Wallpapers.schemeStatePath];
            delete Files.contents[Wallpapers.schemeSourcePath];
            Wallpapers.schemeNameLoaded = false;
            Wallpapers.schemeSourceLoaded = false;
            Wallpapers.reloadSchemeState();
            check(Wallpapers.schemeStateReady, "a missing scheme did not settle");
            check(Wallpapers.schemeName === "", "a missing scheme loaded as dynamic");
            const missingCalls = SchemeGenerator.calls.length;
            Wallpapers.applyPalette(false);
            check(SchemeGenerator.calls.length === missingCalls,
                "a missing scheme still generated a palette");

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

            root.finish();
        });
    }
}
