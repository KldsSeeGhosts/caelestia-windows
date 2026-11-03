import QtQuick

// Offscreen regression for #267. Test-WallpaperColours.ps1 splices the real
// currentImage binding, applyPalette() and its handlers out of Wallpapers.qml
// into this fixture, so drift in the adapter fails the run instead of passing
// against a copy. The mock generator records its source path like the bridge's
// state/caelestia/wallpaper/path.txt does.
QtObject {
    id: root

    property string fileCurrent: "C:/walls/windows-default.jpg"
    property string schemeSource: ""
    property bool schemeSourceLoaded: false
    property int assertions: 0
    property var calls: []

    property QtObject engine: QtObject {
        property bool enabled: true
        property bool running: false
        property bool snapshotReady: false
        property var current: null
    }
    property QtObject schemeGenerator: QtObject {
        property bool available: true
        function applyWallpaper(path, smart): void {
            root.calls.push({
                path: path,
                smart: smart
            });
            root.schemeSource = path;
        }
    }
    property string schemeName: "dynamic"
    property QtObject services: QtObject {
        property bool smartScheme: true
    }

    // WALLPAPER_CURRENT_IMAGE
    // WALLPAPER_APPLY
    // WALLPAPER_HANDLER

    property Connections smartConnection: Connections {
        target: root.services
        // WALLPAPER_SMART_CHANGED
    }
    property Connections snapshotConnection: Connections {
        target: root.engine
        // WALLPAPER_SNAPSHOT_SETTLED
    }

    function samePath(a, b): bool {
        return String(a ?? "").replace(/\\/g, "/").toLowerCase() === String(b ?? "").replace(/\\/g, "/").toLowerCase();
    }

    // Simulates the scheme picker/variant/mode path, which regenerates through
    // the bridge and updates path.txt without passing through applyPalette().
    function recordOtherGeneration(path): void {
        root.schemeSource = path;
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
            // scheme came from the preview, the source file and WE discovery
            // both land late, and neither may regenerate.
            check(root.calls.length === 0, "startup regenerated before the source was known");
            root.schemeSource = "C:/we/preview.jpg";
            root.schemeSourceLoaded = true;
            root.applyPalette(false);
            check(root.calls.length === 0, "loading the persisted source regenerated");
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.running = true;
            root.engine.snapshotReady = true;
            check(root.calls.length === 0, "the async WE snapshot regenerated the same image");

            // 2. Wallpaper Engine quits: the Windows wallpaper takes over.
            root.engine.running = false;
            check(root.calls.length === 1, "Wallpaper Engine quitting did not regenerate");
            check(root.lastCall().path === "C:/walls/windows-default.jpg", "the Windows wallpaper was not applied");

            // 3. Windows Settings changes the wallpaper while WE is stopped.
            root.fileCurrent = "C:/walls/new-windows.jpg";
            check(root.calls.length === 2, "a Windows wallpaper change did not regenerate");
            check(root.lastCall().path === "C:/walls/new-windows.jpg", "the changed Windows wallpaper was not applied");

            // 4. A repeated call for the same image is deduplicated.
            root.applyPalette(false);
            check(root.calls.length === 2, "the same image regenerated twice");

            // 5. Wallpaper Engine relaunches on the same project.
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.running = true;
            check(root.calls.length === 3, "Wallpaper Engine relaunching did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the relaunched preview was not applied");

            // 6. The smart-scheme toggle regenerates the same image.
            root.services.smartScheme = false;
            check(root.calls.length === 4, "the smart-scheme toggle did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the toggled palette used the wrong image");
            check(root.lastCall().smart === false, "the current smart-scheme setting was not passed");

            // 7. A fixed scheme is never overwritten.
            root.schemeName = "catppuccin";
            root.engine.running = false;
            check(root.calls.length === 4, "a fixed scheme was overwritten");

            // 8. Fixed -> dynamic -> an earlier image. The picker's dynamic
            // generation records the image it used, so the earlier preview is
            // no longer considered already applied.
            root.recordOtherGeneration(root.currentImage);
            root.schemeName = "dynamic";
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.running = true;
            check(root.calls.length === 5, "returning to an earlier image did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the earlier preview was not applied");

            // 9. No generator: the fixed palette stays and nothing runs.
            root.schemeGenerator.available = false;
            root.engine.running = false;
            check(root.calls.length === 5, "colours were generated without a generator");

            console.log("CAELESTIA_WALLPAPER_COLOURS_PASS " + root.assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_WALLPAPER_COLOURS_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: run()
}
