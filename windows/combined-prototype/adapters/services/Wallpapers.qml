pragma Singleton
import QtQuick
import QtQuick.Dialogs as NativeDialogs
import Quickshell
import Quickshell.Windows as Native
import Caelestia
import qs.utils
Singleton {
    id: root
    readonly property bool controlsEnabled: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1" && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    property string actualCurrent: Native.Wallpaper.currentWallpaper().replace(/\\/g, "/")
    property var list: []
    property bool previewColourLock: false
    Component.onCompleted: reload()
    function reload(): void {
        list = Native.FsUtils.listDir(Paths.wallsdir).filter(n => /\.(png|jpe?g|bmp|webp)$/i.test(n)).map(n => ({ path: Paths.wallsdir + "/" + n, relativePath: n }));
    }
    function query(search): var { return list.filter(w => w.relativePath.toLowerCase().includes(search.toLowerCase())); }
    function preview(path): void {} // Selection never changes the desktop.
    function stopPreview(): void {}
    function setWallpaper(path): bool {
        if (!controlsEnabled) return false;
        const local = String(path).replace(/^file:\/\/\//, "");
        const ok = Native.Wallpaper.setWallpaper(local, false);
        if (ok) actualCurrent = local;
        Toaster.toast("Wallpaper", ok ? "Desktop wallpaper changed. Dynamic colours are unavailable." : "Windows could not apply the wallpaper.", "wallpaper");
        return ok;
    }
    function choose(): void { if (controlsEnabled) picker.open(); }
    NativeDialogs.FileDialog {
        id: picker
        title: "Choose desktop wallpaper"
        nameFilters: ["Images (*.png *.jpg *.jpeg *.bmp *.webp)"]
        onAccepted: root.setWallpaper(decodeURIComponent(selectedFile.toString()))
    }
}
