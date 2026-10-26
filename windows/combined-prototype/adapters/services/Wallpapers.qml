pragma Singleton

import QtQuick
import QtQuick.Dialogs as NativeDialogs
import Quickshell
import Quickshell.Windows as Native
import Caelestia
import Caelestia.Config
import qs.services
import qs.utils

Singleton {
    id: root

    readonly property bool controlsEnabled: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1" && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    property string fileCurrent: Native.Wallpaper.currentWallpaper().replace(/\\/g, "/")
    readonly property string actualCurrent: WallpaperEngine.enabled && WallpaperEngine.running && WallpaperEngine.current?.path
        ? WallpaperEngine.current.path : fileCurrent
    // Image consumers (mode/variant generation and the desktop) need the
    // preview, while launcher selection needs the project.json identity.
    readonly property string currentImage: WallpaperEngine.enabled && WallpaperEngine.running && WallpaperEngine.current?.preview
        ? WallpaperEngine.current.preview : fileCurrent
    readonly property string current: currentImage
    readonly property bool externalWallpaperActive: WallpaperEngine.ownsDesktop
    property var files: []
    readonly property var list: {
        const engine = WallpaperEngine.enabled && WallpaperEngine.detected ? WallpaperEngine.items : [];
        if (WallpaperEngine.picker === "engine")
            return engine;
        if (WallpaperEngine.picker === "both")
            return [...engine, ...files];
        return files;
    }
    property bool previewColourLock: false

    Component.onCompleted: reload()

    function reload(): void {
        files = Native.FsUtils.listDir(Paths.wallsdir).filter(n => /\.(png|jpe?g|bmp|webp)$/i.test(n)).map(n => ({
                    path: Paths.wallsdir + "/" + n,
                    relativePath: n
                }));
    }

    function query(search): var {
        return list.filter(w => w.relativePath.toLowerCase().includes(search.toLowerCase()));
    }

    function preview(path): void {} // Highlighting never changes the desktop or palette.
    function stopPreview(): void {}

    function setWallpaper(path): bool {
        if (!controlsEnabled)
            return false;
        if (WallpaperEngine.items.some(item => item.path === path))
            return WallpaperEngine.open(path);
        const local = String(path).replace(/^file:\/\/\//, "");
        const ok = Native.Wallpaper.setWallpaper(local, false);
        if (ok) {
            fileCurrent = local;
            if (SchemeGenerator.available) {
                // The picker always produces the wallpaper-derived dynamic
                // scheme; the bridge writes scheme.json and Colours reloads it.
                SchemeGenerator.applyWallpaper(local, GlobalConfig.services.smartScheme);
                Toaster.toast("Wallpaper", "Desktop wallpaper changed. Generating colours.", "palette");
            } else {
                Toaster.toast("Wallpaper", "Desktop wallpaper changed. Dynamic colours are unavailable.", "wallpaper");
            }
        } else {
            Toaster.toast("Wallpaper", "Windows could not apply the wallpaper.", "wallpaper");
        }
        return ok;
    }

    function choose(): void {
        if (controlsEnabled)
            picker.open();
    }

    NativeDialogs.FileDialog {
        id: picker

        title: "Choose desktop wallpaper"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.bmp *.webp)"]
        onAccepted: root.setWallpaper(decodeURIComponent(selectedFile.toString()))
    }
}
