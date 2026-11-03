import QtQuick

// Offscreen regression for #267 and #270. Test-WallpaperColours.ps1 splices
// the real currentImage binding, applyPalette(), the scheme state loaders and
// their handlers out of Wallpapers.qml into this fixture, so drift in the
// adapter fails the run instead of passing against a copy. The fast status
// scan and the catalogue snapshot both move currentImage, and must dedupe to
// one generation. The mock generator writes
// the scheme name and its source image into `files` like the bridge writes
// scheme.json and state/caelestia/wallpaper/path.txt, then reports
// schemeChanged. No file watch is modelled: a fresh profile has none, so the
// state is only ever read at startup and after that signal.
QtObject {
    id: root

    property string fileCurrent: "C:/walls/windows-default.jpg"
    property string schemeName: ""
    property string schemeSource: ""
    property bool schemeNameLoaded: false
    property bool schemeSourceLoaded: false
    property int assertions: 0
    property var calls: []
    property int runs: 0
    // Empty until the generator writes it, like a fresh profile.
    property var files: ({})

    property QtObject engine: QtObject {
        property bool enabled: true
        property bool running: false
        property bool snapshotReady: false
        // The production ownership guard releases this on a handback while
        // the process keeps running (#214).
        property bool handedBack: false
        property bool ownsDesktop: running && !handedBack
        property var current: null
    }
    // The ownership claim, not the bare process, selects the visible image.
    property bool externalWallpaperActive: root.engine.ownsDesktop
    property QtObject schemeGenerator: QtObject {
        property bool available: true
        signal schemeChanged()
        signal schemeListChanged()

        function write(name: string, image: string): void {
            root.runs++;
            root.files = {
                scheme: JSON.stringify({ name: name }),
                source: image
            };
            schemeChanged();
        }
        function applyWallpaper(path, smart): void {
            root.calls.push({
                path: path,
                smart: smart
            });
            write("dynamic", path);
        }
        // The launcher's scheme row: also writes the source image.
        function setScheme(name: string, image: string): void {
            write(name, image);
        }
    }
    property QtObject services: QtObject {
        property bool smartScheme: true
    }

    // WALLPAPER_CURRENT_IMAGE
    // WALLPAPER_APPLY
    // WALLPAPER_HANDLER
    // WALLPAPER_READY
    // WALLPAPER_READY_HANDLER
    // WALLPAPER_SET_NAME
    // WALLPAPER_SET_SOURCE
    // WALLPAPER_RELOAD

    // Stand-ins for the two FileViews: a missing file reads like loadFailed.
    property QtObject nameFile: QtObject {
        function reload(): void {
            root.setSchemeName(root.files.scheme ?? "");
        }
    }
    property QtObject sourceFile: QtObject {
        function reload(): void {
            root.setSchemeSource(root.files.source ?? "");
        }
    }

    property Connections smartConnection: Connections {
        target: root.services
        // WALLPAPER_SMART_CHANGED
    }
    property Connections snapshotConnection: Connections {
        target: root.engine
        // WALLPAPER_SNAPSHOT_SETTLED
    }
    property Connections generatorConnection: Connections {
        target: root.schemeGenerator
        // WALLPAPER_GENERATOR_SCHEME_CHANGED
        // WALLPAPER_GENERATOR_LIST_CHANGED
    }

    function samePath(a, b): bool {
        return String(a ?? "").replace(/\\/g, "/").toLowerCase() === String(b ?? "").replace(/\\/g, "/").toLowerCase();
    }

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    function lastCall(): var {
        return root.calls.length === 0 ? null : root.calls[root.calls.length - 1];
    }

    function run(): void {
        try {
            // 1. Startup with Wallpaper Engine already running. The persisted
            // scheme came from the preview, the state files and WE discovery all
            // land late, and none may regenerate.
            check(root.schemeStateReady === false, "state ready before it was read");
            root.files = {
                scheme: JSON.stringify({ name: "dynamic" }),
                source: "C:/we/preview.jpg"
            };
            root.reloadSchemeState();
            check(root.calls.length === 0, "loading the persisted state regenerated");
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.running = true;
            root.engine.snapshotReady = true;
            check(root.calls.length === 0, "the async WE snapshot regenerated the same image");

            // 2. Wallpaper Engine quits: the Windows wallpaper takes over.
            root.engine.running = false;
            check(root.calls.length === 1, "Wallpaper Engine quitting did not regenerate");
            check(root.lastCall().path === "C:/walls/windows-default.jpg", "the Windows wallpaper was not applied");
            check(root.runs === 1, "one image change ran the generator more than once");

            // 3. Windows Settings changes the wallpaper while WE is stopped.
            root.fileCurrent = "C:/walls/new-windows.jpg";
            check(root.calls.length === 2, "a Windows wallpaper change did not regenerate");
            check(root.lastCall().path === "C:/walls/new-windows.jpg", "the changed Windows wallpaper was not applied");

            // 3b. Wallpaper Engine starts and the config watcher's status scan
            // applies the selection before the catalogue snapshot arrives.
            // That snapshot carries the same project and must not run the
            // generator a second time.
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview-2.jpg" };
            root.engine.running = true;
            check(root.calls.length === 3, "the fast status selection did not regenerate");
            root.engine.snapshotReady = false;
            root.engine.snapshotReady = true;
            check(root.calls.length === 3, "the full snapshot after the fast status scan regenerated");
            check(root.lastCall().path === "C:/we/preview-2.jpg", "the fast status selection used the wrong preview");

            // 4. A repeated call for the same image is deduplicated.
            root.applyPalette(false);
            check(root.calls.length === 3, "the same image regenerated twice");

            // 5. Wallpaper Engine switches to another project.
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            check(root.calls.length === 4, "Wallpaper Engine switching project did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the other project's preview was not applied");

            // 6. The smart-scheme toggle regenerates the same image.
            root.services.smartScheme = false;
            check(root.calls.length === 5, "the smart-scheme toggle did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the toggled palette used the wrong image");
            check(root.lastCall().smart === false, "the current smart-scheme setting was not passed");

            // 7. A fixed scheme is never overwritten.
            root.schemeGenerator.setScheme("catppuccin", root.currentImage);
            check(root.schemeName === "catppuccin", "the fixed scheme was not picked up");
            root.engine.running = false;
            check(root.calls.length === 5, "a fixed scheme was overwritten");

            // 8. Fixed -> dynamic -> an earlier image. The picker's dynamic
            // generation records the image it used, so the earlier preview is
            // no longer considered already applied.
            root.schemeGenerator.setScheme("dynamic", root.currentImage);
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.running = true;
            check(root.calls.length === 6, "returning to an earlier image did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the earlier preview was not applied");

            // 9. No generator: the fixed palette stays and nothing runs.
            root.schemeGenerator.available = false;
            root.engine.running = false;
            check(root.calls.length === 6, "colours were generated without a generator");

            // 10. Fresh profile, as a new process: neither scheme.json nor
            // path.txt exists, so their directories do not either and nothing
            // can be watched. The startup read finds nothing and settles the
            // state without regenerating (the default scheme is not dynamic).
            root.schemeGenerator.available = true;
            root.engine.running = false;
            root.files = {};
            root.schemeName = "";
            root.schemeSource = "";
            root.schemeNameLoaded = false;
            root.schemeSourceLoaded = false;
            const before = root.runs;
            root.reloadSchemeState();
            check(root.schemeStateReady === true, "a missing profile left the state unsettled");
            check(root.schemeName === "" && root.schemeSource === "", "a missing profile reported state");
            check(root.runs === before, "the startup read regenerated");

            // The first dynamic selection creates the files. Only the
            // generator's report can pick them up: the source is recorded and
            // the write must not loop.
            root.schemeGenerator.setScheme("dynamic", root.currentImage);
            check(root.schemeName === "dynamic", "the first dynamic scheme was not picked up");
            check(root.schemeSource === "C:/walls/new-windows.jpg", "the first generation did not record its source");
            check(root.runs === before + 1, "the first dynamic generation looped: " + (root.runs - before));

            // A later wallpaper change regenerates exactly once.
            root.fileCurrent = "C:/walls/second.jpg";
            check(root.runs === before + 2, "the wallpaper change after a fresh profile did not regenerate once: " + (root.runs - before));
            check(root.schemeSource === "C:/walls/second.jpg", "the regeneration did not record its source");

            // #214: a process-still-running handback releases the external
            // claim. The visible desktop and its palette must switch to the
            // shell's own wallpaper instead of the external preview.
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.handedBack = false;
            root.engine.running = true;
            check(root.currentImage === "C:/we/preview.jpg", "the acknowledged underlay did not use the external preview");
            check(root.lastCall().path === "C:/we/preview.jpg", "the acknowledged underlay did not regenerate from the preview");
            const handbackCalls = root.calls.length;
            root.engine.handedBack = true;
            check(root.currentImage === root.fileCurrent, "the handback did not switch to the shell's own wallpaper");
            check(root.calls.length === handbackCalls + 1, "the handback did not regenerate exactly once");
            check(root.lastCall().path === root.fileCurrent, "the handback palette used the external preview");

            console.log("CAELESTIA_WALLPAPER_COLOURS_PASS " + root.assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_WALLPAPER_COLOURS_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: run()
}
