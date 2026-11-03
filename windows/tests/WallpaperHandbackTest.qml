import QtQuick

// Offscreen regression for #214: a genuine Wallpaper Engine handback must show
// a loadable Caelestia image. IDesktopWallpaper often reports an empty, missing
// or system-black path when the engine closes its wallpaper, and an Image with
// that source paints nothing, leaving the background window black.
//
// Test-WallpaperHandback.ps1 splices the real source selection, last-good
// bookkeeping, handback adoption, file verification and wallpaperChanged guard
// out of windows/shell/adapters/services/Wallpapers.qml, so drift in the
// adapter fails this run instead of passing against a copy. The mocks only
// provide the native wallpaper/attribute reads and the engine claim.
QtObject {
    id: root

    property int assertions: 0
    property string fallback: "C:/shell/assets/wallpaper.webp"
    property string fileCurrent: ""
    property bool showPreview: false
    property string previewPath: ""
    property int stopPreviewCalls: 0
    // Paths whose classify() reports a file. Everything else is missing.
    property var existingFiles: [root.fallback]

    property QtObject engine: QtObject {
        property bool running: true
        property bool snapshotReady: true
        property bool desktopHandedBack: false
        property bool ownsDesktop: !snapshotReady || (running && !desktopHandedBack)
        property var current: ({ path: "C:/we/project.json", preview: "C:/we/preview.jpg" })
        // WallpaperEngine.onRunningChanged clears the handback latch whenever
        // the process start/stop state changes.
        onRunningChanged: desktopHandedBack = false
    }
    // The production external claim is exactly this binding.
    property bool externalWallpaperActive: root.engine.ownsDesktop

    property QtObject nativeHost: QtObject {
        property string currentPath: ""
        property QtObject wallpaper: QtObject {
            function currentWallpaper(): string { return root.nativeHost.currentPath; }
        }
        property QtObject fsUtils: QtObject {
            function classify(path): string {
                const value = String(path ?? "").replace(/\\/g, "/");
                return root.existingFiles.indexOf(value) === -1 ? "invalid" : "file";
            }
        }
    }
    property QtObject desktopLayer: QtObject {
        signal wallpaperChanged()
    }
    property Connections desktopConnection: Connections {
        target: root.desktopLayer
        // WALLPAPER_CHANGED
    }
    property Connections engineConnection: Connections {
        target: root.engine
        // WALLPAPER_HANDBACK_ADOPT
    }

    // WALLPAPER_LAST_GOOD
    // WALLPAPER_HANDBACK_WALLPAPER
    // WALLPAPER_CURRENT_VISIBLE
    // WALLPAPER_CURRENT_IMAGE
    // WALLPAPER_VISIBLE_OWN
    // WALLPAPER_USABLE_FILE
    // WALLPAPER_NOTE_GOOD
    // WALLPAPER_ADOPT_HANDBACK
    // WALLPAPER_FILE_CHANGED
    // WALLPAPER_EXTERNAL_CHANGED

    function samePath(a, b): bool {
        return String(a ?? "").replace(/\\/g, "/").toLowerCase() === String(b ?? "").replace(/\\/g, "/").toLowerCase();
    }
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    function preview(path): void {
        previewPath = path;
        showPreview = true;
    }
    function stopPreview(): void {
        stopPreviewCalls++;
        showPreview = false;
    }

    Component.onCompleted: run()

    function run(): void {
        try {
            // 1. Fresh profile, engine already running and acknowledged. The
            // fail-closed startup shows the engine preview and must not adopt
            // the system wallpaper it reports as its own good file.
            root.fileCurrent = "C:/walls/system-before-we.jpg";
            root.existingFiles = [root.fallback, "C:/walls/system-before-we.jpg"];
            check(root.engine.ownsDesktop, "a running engine claims the desktop at startup");
            check(root.currentImage === "C:/we/preview.jpg", "the acknowledged engine shows its preview");
            check(root.lastGoodFile === root.fallback,
                "the engine-era system path was adopted as the good file");

            // 2. The engine hands the desktop back while still running. A
            // launcher preview of the engine image is open: it must be dropped
            // with the handback, not left on the visible desktop.
            root.preview("C:/we/preview.jpg");
            check(root.current === "C:/we/preview.jpg", "the open preview was not visible");
            root.engine.desktopHandedBack = true;
            check(!root.engine.ownsDesktop && !root.externalWallpaperActive,
                "the handback releases the external claim");
            check(root.stopPreviewCalls === 1 && !root.showPreview,
                "the handback kept the launcher preview open");
            check(root.currentImage === root.fallback,
                "a fresh handback did not use the bundled fallback");
            check(root.current === root.fallback && root.current !== root.previewPath,
                "the handback desktop kept the engine preview");
            check(root.fileCurrent === root.fallback,
                "the handback kept the unusable engine-era system path");

            // 3. The engine stops and the own desktop adopts a real local file.
            root.existingFiles = [root.fallback, "C:/walls/own.jpg"];
            root.engine.running = false;
            check(!root.externalWallpaperActive, "the stopped engine releases the desktop");
            root.fileCurrent = "C:/walls/own.jpg";
            check(root.lastGoodFile === "C:/walls/own.jpg",
                "the own desktop did not remember its local wallpaper");
            check(root.currentImage === "C:/walls/own.jpg",
                "the own desktop did not show its local wallpaper");

            // 4. The engine starts again and reports a system wallpaper path
            // that no longer exists before the handback. The handback must use
            // the last good own file instead of that missing path.
            root.engine.running = true;
            check(root.externalWallpaperActive, "the restart claims the desktop again");
            root.nativeHost.currentPath = "C:/walls/gone.jpg";
            root.desktopLayer.wallpaperChanged();
            check(root.fileCurrent === "C:/walls/gone.jpg",
                "the active engine did not follow the system wallpaper change");
            check(root.lastGoodFile === "C:/walls/own.jpg",
                "a system path was adopted while the engine owned the desktop");
            root.engine.desktopHandedBack = true;
            check(!root.externalWallpaperActive, "the second handback releases the claim");
            check(root.fileCurrent === "C:/walls/own.jpg",
                "the handback kept a missing system wallpaper path");
            check(root.currentImage === "C:/walls/own.jpg" && root.current === "C:/walls/own.jpg",
                "the handback did not reuse the last existing local file");

            // 5. While handed back, an empty or missing Wallpaper Engine path
            // is ignored instead of replacing the verified source.
            root.nativeHost.currentPath = "";
            root.desktopLayer.wallpaperChanged();
            check(root.fileCurrent === "C:/walls/own.jpg",
                "an empty system wallpaper path replaced the verified source");
            root.nativeHost.currentPath = "C:/walls/gone-2.jpg";
            root.desktopLayer.wallpaperChanged();
            check(root.fileCurrent === "C:/walls/own.jpg",
                "a missing system wallpaper path replaced the verified source");
            check(root.currentImage === "C:/walls/own.jpg" && root.current === "C:/walls/own.jpg",
                "the handed-back desktop did not keep the verified source");

            // 6. A usable wallpaper set while handed back still applies, and
            // the engine preview cannot come back through currentImage.
            root.existingFiles = [root.fallback, "C:/walls/own.jpg", "C:/walls/new.jpg"];
            root.nativeHost.currentPath = "C:/walls/new.jpg";
            root.desktopLayer.wallpaperChanged();
            check(root.fileCurrent === "C:/walls/new.jpg",
                "a usable system wallpaper was not applied while handed back");
            check(root.currentImage === "C:/walls/new.jpg" && root.current === "C:/walls/new.jpg",
                "the handed-back desktop did not show the usable wallpaper");
            check(root.lastGoodFile === "C:/walls/new.jpg",
                "the usable handed-back wallpaper was not remembered");
            root.engine.current = ({ path: "C:/we/project.json", preview: "C:/we/preview-2.jpg" });
            check(root.currentImage === "C:/walls/new.jpg",
                "the engine preview returned to the handed-back desktop");

            // 7. A second handback whose last good file no longer exists uses
            // the bundled asset, never the missing path.
            root.engine.desktopHandedBack = false;
            check(root.externalWallpaperActive, "the reopened wallpaper reclaims the desktop");
            root.existingFiles = [root.fallback, "C:/walls/own.jpg"];
            root.engine.desktopHandedBack = true;
            check(!root.externalWallpaperActive, "the third handback releases the claim");
            check(root.currentImage === root.fallback && root.current === root.fallback,
                "a deleted last good file did not fall back to the bundled asset");
            check(root.fileCurrent === root.fallback,
                "the deleted last good file stayed as the visible source");

            // 8. On the own desktop a missing or empty update is never adopted
            // as the good file either; the verified fallback stays visible.
            root.engine.running = false;
            root.existingFiles = [root.fallback];
            root.fileCurrent = "C:/walls/gone-3.jpg";
            check(root.lastGoodFile === root.fallback,
                "a missing own-desktop path was adopted as the good file");
            check(root.currentImage === root.fallback,
                "a missing own-desktop path did not fall back to the bundled asset");
            root.fileCurrent = "";
            check(root.currentImage === root.fallback,
                "an empty own-desktop path did not fall back to the bundled asset");

            console.log("CAELESTIA_WALLPAPER_HANDBACK_PASS " + root.assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_WALLPAPER_HANDBACK_FAIL " + error);
            Qt.exit(1);
        }
    }
}
