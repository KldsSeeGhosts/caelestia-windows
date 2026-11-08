import QtQuick
import Quickshell.Windows as Native
import qs.services

// Offscreen regression for #214: a genuine Wallpaper Engine handback must show
// a loadable Caelestia image. IDesktopWallpaper often reports an empty, missing
// or system-black path when the engine closes its wallpaper, and an Image with
// that source paints nothing, leaving the background window black.
//
// The complete production Wallpapers and WallpaperEngine singletons own the
// source selection and handback. Only native I/O is replaced.
QtObject {
    id: root

    property int assertions: 0
    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }
    Component.onCompleted: Qt.callLater(run)

    function run(): void {
        try {
            // This fixture emulates an existing profile that follows Windows;
            // the fresh disabled default is covered by WallpaperDefaultsTest.
            WallpaperEngine.options = {enabled: true};
            Wallpapers.sourceInitialized = true;
            Wallpapers.sourceFresh = false;
            WallpaperEngine.running = true;
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview.jpg"}};
            // 1. Fresh profile, engine already running and acknowledged. The
            // fail-closed startup shows the engine preview and must not adopt
            // the system wallpaper it reports as its own good file.
            Wallpapers.fileCurrent = "C:/walls/system-before-we.jpg";
            Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/system-before-we.jpg"];
            check(WallpaperEngine.ownsDesktop, "a running engine claims the desktop at startup");
            check(Wallpapers.currentImage === "C:/we/preview.jpg", "the acknowledged engine shows its preview");
            check(Wallpapers.lastGoodFile === Wallpapers.fallback,
                "the engine-era system path was adopted as the good file");
            check(Wallpapers.current === Wallpapers.fallback,
                "startup underlay must not show an unacknowledged engine preview");

            // 2. The engine hands the desktop back while still running. A
            // launcher preview of the engine image is open: it must be dropped
            // with the handback, not left on the visible desktop.
            Wallpapers.preview("C:/we/preview.jpg");
            check(Wallpapers.current === Wallpapers.fallback,
                "a launcher preview must not replace the external-era fallback");
            WallpaperEngine.desktopHandedBack = true;
            check(!WallpaperEngine.ownsDesktop && !Wallpapers.externalWallpaperActive,
                "the handback releases the external claim");
            check(!Wallpapers.showPreview,
                "the handback kept the launcher preview open");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "a fresh handback did not use the bundled fallback");
            check(Wallpapers.current === Wallpapers.fallback && Wallpapers.current !== Wallpapers.previewPath,
                "the handback desktop kept the engine preview");
            check(Wallpapers.fileCurrent === Wallpapers.fallback,
                "the handback kept the unusable engine-era system path");

            // 3. The engine stops and the own desktop adopts a real local file.
            Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/own.jpg"];
            WallpaperEngine.running = false;
            check(!Wallpapers.externalWallpaperActive, "the stopped engine releases the desktop");
            Wallpapers.fileCurrent = "C:/walls/own.jpg";
            check(Wallpapers.lastGoodFile === "C:/walls/own.jpg",
                "the own desktop did not remember its local wallpaper");
            check(Wallpapers.currentImage === "C:/walls/own.jpg",
                "the own desktop did not show its local wallpaper");

            // 4. The engine starts again and reports a system wallpaper path
            // that no longer exists before the handback. The handback must use
            // the last good own file instead of that missing path.
            WallpaperEngine.running = true;
            check(Wallpapers.externalWallpaperActive, "the restart claims the desktop again");
            check(Wallpapers.current === "C:/walls/own.jpg",
                "an engine start must retain the last own wallpaper underneath");
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/next.json", preview: "C:/we/next.jpg"}};
            check(Wallpapers.currentImage === "C:/we/next.jpg",
                "selection changes still provide the engine preview for palette generation");
            check(Wallpapers.current === "C:/walls/own.jpg",
                "a same-process selection must not transition the fallback to a preview");
            Native.Wallpaper.currentPath = "C:/walls/gone.jpg";
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/gone.jpg",
                "the active engine did not follow the system wallpaper change");
            check(Wallpapers.lastGoodFile === "C:/walls/own.jpg",
                "a system path was adopted while the engine owned the desktop");
            check(Wallpapers.current === "C:/walls/own.jpg",
                "an external-era system notification must not replace the underlay");
            WallpaperEngine.desktopHandedBack = true;
            check(!Wallpapers.externalWallpaperActive, "the second handback releases the claim");
            check(Wallpapers.fileCurrent === "C:/walls/own.jpg",
                "the handback kept a missing system wallpaper path");
            check(Wallpapers.currentImage === "C:/walls/own.jpg" && Wallpapers.current === "C:/walls/own.jpg",
                "the handback did not reuse the last existing local file");

            // 5. While handed back, an empty or missing Wallpaper Engine path
            // is ignored instead of replacing the verified source.
            Native.Wallpaper.currentPath = "";
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/own.jpg",
                "an empty system wallpaper path replaced the verified source");
            Native.Wallpaper.currentPath = "C:/walls/gone-2.jpg";
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/own.jpg",
                "a missing system wallpaper path replaced the verified source");
            check(Wallpapers.currentImage === "C:/walls/own.jpg" && Wallpapers.current === "C:/walls/own.jpg",
                "the handed-back desktop did not keep the verified source");

            // 6. After the handback, a native notification naming an existing
            // system-black image is still engine-era bookkeeping, not a
            // Caelestia pick. File existence is neither proof of a chosen
            // source nor a decoded image: adopting it would replace the
            // verified source and, with the external claim released, become
            // the next handback target.
            Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/own.jpg", "C:/walls/system-black.jpg"];
            Native.Wallpaper.currentPath = "C:/walls/system-black.jpg";
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/own.jpg",
                "an existing engine-era system wallpaper replaced the verified source");
            check(Wallpapers.currentImage === "C:/walls/own.jpg" && Wallpapers.current === "C:/walls/own.jpg",
                "the handed-back desktop showed the engine-era system wallpaper");
            check(Wallpapers.lastGoodFile === "C:/walls/own.jpg",
                "an engine-era system wallpaper became the next handback target");

            // 6b. Process-stop discovery is still engine-era bookkeeping. The
            // handback latch must survive running=false: if it clears, the next
            // native notification reopens adoption after the external claim is
            // gone and replaces both the visible source and the next handback
            // target with the system file the engine left behind.
            WallpaperEngine.running = false;
            check(!WallpaperEngine.ownsDesktop, "the stopped engine still owns the desktop");
            Native.Wallpaper.currentPath = "C:/walls/system-black.jpg";
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/own.jpg",
                "a native system file replaced the verified source after the engine stopped");
            check(Wallpapers.lastGoodFile === "C:/walls/own.jpg",
                "process-stop discovery replaced the next handback target");
            check(Wallpapers.currentImage === "C:/walls/own.jpg" && Wallpapers.current === "C:/walls/own.jpg",
                "the stopped engine showed the engine-era system wallpaper");
            check(WallpaperEngine.desktopHandedBack, "process-stop discovery cleared the handback latch");

            // 6c. A new engine process is a new ownership claim. The old
            // handback must not keep it out of the fail-closed startup: it owns
            // the desktop until the backend acknowledges its wallpaper window.
            WallpaperEngine.running = true;
            check(!WallpaperEngine.desktopHandedBack, "a new engine process kept the old handback latch");
            check(Wallpapers.externalWallpaperActive, "a new engine process does not fail closed");
            check(Wallpapers.currentImage === "C:/we/next.jpg",
                "a new engine process did not retain the palette preview");
            check(Wallpapers.current === "C:/walls/own.jpg",
                "a new engine process replaced the own fallback before acknowledgement");
            check(Wallpapers.lastGoodFile === "C:/walls/own.jpg",
                "a new engine process replaced the verified source before acknowledgement");

            // Restore the handed-back running state the explicit-pick scenario
            // starts from.
            WallpaperEngine.desktopHandedBack = true;
            check(Wallpapers.currentImage === "C:/walls/own.jpg",
                "the handback after the restart did not restore the verified source");

            // 7. An explicit pick is a Caelestia choice even while handed back,
            // and an intentionally black image is valid: no filename decides.
            // The engine-era notification cannot undo that pick.
            Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/own.jpg", "C:/walls/system-black.jpg",
                "C:/walls/intentional-black.jpg"];
            Wallpapers.adoptPickedFile("C:/walls/intentional-black.jpg");
            check(Wallpapers.fileCurrent === "C:/walls/intentional-black.jpg",
                "an explicit black wallpaper pick was not applied");
            check(Wallpapers.lastGoodFile === "C:/walls/intentional-black.jpg",
                "an explicit black wallpaper pick was not remembered");
            check(Wallpapers.currentImage === "C:/walls/intentional-black.jpg" && Wallpapers.current === "C:/walls/intentional-black.jpg",
                "the handed-back desktop did not show the explicit pick");
            Native.Wallpaper.currentPath = "C:/walls/system-black.jpg";
            Native.DesktopLayer.wallpaperChanged();
            check(Wallpapers.fileCurrent === "C:/walls/intentional-black.jpg" &&
                Wallpapers.lastGoodFile === "C:/walls/intentional-black.jpg",
                "an engine-era notification replaced the explicit pick");
            WallpaperEngine.monitors = {Monitor0: {path: "C:/we/project.json", preview: "C:/we/preview-2.jpg"}};
            check(Wallpapers.currentImage === "C:/walls/intentional-black.jpg",
                "the engine preview returned to the handed-back desktop");

            // 8. A second handback whose last good file no longer exists uses
            // the bundled asset, never the missing path.
            WallpaperEngine.desktopHandedBack = false;
            check(Wallpapers.externalWallpaperActive, "the reopened wallpaper reclaims the desktop");
            Native.FsUtils.existingFiles = [Wallpapers.fallback, "C:/walls/own.jpg"];
            WallpaperEngine.desktopHandedBack = true;
            check(!Wallpapers.externalWallpaperActive, "the third handback releases the claim");
            check(Wallpapers.currentImage === Wallpapers.fallback && Wallpapers.current === Wallpapers.fallback,
                "a deleted last good file did not fall back to the bundled asset");
            check(Wallpapers.fileCurrent === Wallpapers.fallback,
                "the deleted last good file stayed as the visible source");

            // 9. On the own desktop a missing or empty update is never adopted
            // as the good file either; the verified fallback stays visible.
            WallpaperEngine.running = false;
            Native.FsUtils.existingFiles = [Wallpapers.fallback];
            Wallpapers.fileCurrent = "C:/walls/gone-3.jpg";
            check(Wallpapers.lastGoodFile === Wallpapers.fallback,
                "a missing own-desktop path was adopted as the good file");
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "a missing own-desktop path did not fall back to the bundled asset");
            Wallpapers.fileCurrent = "";
            check(Wallpapers.currentImage === Wallpapers.fallback,
                "an empty own-desktop path did not fall back to the bundled asset");

            console.log("CAELESTIA_WALLPAPER_HANDBACK_PASS " + root.assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_WALLPAPER_HANDBACK_FAIL " + error);
            Qt.exit(1);
        }
    }
}
