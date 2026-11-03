import QtQuick

// Offscreen regression for #267. Test-WallpaperColours.ps1 splices the real
// currentImage binding, applyPalette() and its change handler out of
// Wallpapers.qml into this fixture, so drift in the adapter fails the run
// instead of passing against a copy.
QtObject {
    id: root

    property string fileCurrent: "C:/walls/windows-default.jpg"
    property int assertions: 0
    property var calls: []

    property QtObject engine: QtObject {
        property bool enabled: true
        property bool running: false
        property var current: null
    }
    property QtObject schemeGenerator: QtObject {
        property bool available: true
        function applyWallpaper(path, smart): void {
            root.calls.push({
                path: path,
                smart: smart
            });
        }
    }
    property QtObject colours: QtObject {
        property string scheme: "dynamic"
    }
    property QtObject services: QtObject {
        property bool smartScheme: true
    }

    // WALLPAPER_CURRENT_IMAGE
    // WALLPAPER_PALETTE
    // WALLPAPER_APPLY
    // WALLPAPER_HANDLER

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
            // Wallpapers.qml enables regeneration once construction finishes,
            // after the initial currentImage binding has fired and been ignored.
            root.paletteReady = true;

            // 1. Startup: the persisted scheme already matches the image.
            check(root.calls.length === 0, "startup regenerated colours");
            check(root.currentImage === root.fileCurrent, "the file wallpaper is the initial image");

            // 2. Wallpaper Engine running on a project: its preview wins.
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.running = true;
            check(root.calls.length === 1, "the Wallpaper Engine preview did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the preview path was not applied");
            check(root.lastCall().smart === true, "the smart-scheme setting was not passed");

            // 3. A repeated call for the same image is deduplicated.
            root.applyPalette();
            check(root.calls.length === 1, "the same image regenerated twice");

            // 4. Wallpaper Engine quits: the Windows wallpaper takes over.
            root.engine.running = false;
            check(root.calls.length === 2, "Wallpaper Engine quitting did not regenerate");
            check(root.lastCall().path === "C:/walls/windows-default.jpg", "the Windows wallpaper was not applied");

            // 5. Windows Settings changes the wallpaper while WE is stopped.
            root.fileCurrent = "C:/walls/new-windows.jpg";
            check(root.calls.length === 3, "a Windows wallpaper change did not regenerate");
            check(root.lastCall().path === "C:/walls/new-windows.jpg", "the changed Windows wallpaper was not applied");

            // 6. Wallpaper Engine relaunches on the same project.
            root.services.smartScheme = false;
            root.engine.current = { path: "C:/we/project.json", preview: "C:/we/preview.jpg" };
            root.engine.running = true;
            check(root.calls.length === 4, "Wallpaper Engine relaunching did not regenerate");
            check(root.lastCall().path === "C:/we/preview.jpg", "the relaunched preview was not applied");
            check(root.lastCall().smart === false, "the current smart-scheme setting was not passed");

            // 7. A fixed scheme is never overwritten.
            root.colours.scheme = "catppuccin";
            root.engine.running = false;
            check(root.calls.length === 4, "a fixed scheme was overwritten");

            // 8. Returning to dynamic lets the next image change through.
            root.colours.scheme = "dynamic";
            root.engine.current = { path: "C:/we/other.json", preview: "C:/we/other.jpg" };
            root.engine.running = true;
            check(root.calls.length === 5, "the dynamic scheme stopped regenerating");
            check(root.lastCall().path === "C:/we/other.jpg", "the dynamic preview was not applied");

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
