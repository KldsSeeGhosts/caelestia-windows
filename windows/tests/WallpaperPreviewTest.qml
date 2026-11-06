import QtQuick
import Quickshell.Windows as Native
import qs.services

QtObject {
    property int assertions: 0
    function check(value, message): void {
        assertions++;
        if (!value) throw new Error(message);
    }
    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            WallpaperEngine.options = {enabled: false};
            Wallpapers.files = [
                {path: "C:/walls/local.jpg", onDisk: true},
                {path: "C:/walls/cloud.jpg", onDisk: false}
            ];
            Wallpapers.previewEntry(Wallpapers.list[0]);
            check(Wallpapers.showPreview && Wallpapers.current === "C:/walls/local.jpg", "local preview");
            Wallpapers.previewEntry(Wallpapers.list[1]);
            check(!Wallpapers.showPreview, "placeholder stops previous preview");
            check(Wallpapers.current === Wallpapers.currentImage, "placeholder leaves desktop unchanged");
            check(Wallpapers.previewPath !== "C:/walls/cloud.jpg", "placeholder not stored");
            Wallpapers.preview("C:/walls/cloud.jpg");
            check(!Wallpapers.showPreview && Wallpapers.current !== "C:/walls/cloud.jpg", "direct preview cannot hydrate");
            Native.FsUtils.existingFiles.push("C:/walls/cloud.jpg");
            check(Wallpapers.setWallpaper("C:/walls/cloud.jpg"), "explicit open accepted");
            check(Native.Wallpaper.calls.length === 1 && Native.Wallpaper.calls[0] === "C:/walls/cloud.jpg", "native apply recorded");
            check(Wallpapers.list[1].onDisk, "successful open marks placeholder local");
            Wallpapers.previewEntry(Wallpapers.list[1]);
            check(Wallpapers.showPreview && Wallpapers.current === "C:/walls/cloud.jpg", "opened placeholder previews");
            console.log("CAELESTIA_WALLPAPER_PREVIEW_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WALLPAPER_PREVIEW_FAIL " + error);
            Qt.exit(1);
        }
    }
}
