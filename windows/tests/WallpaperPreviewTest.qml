import QtQuick

// Offscreen regression for #261. Test-WallpaperPreview.ps1 splices the real
// preview functions and the desktop `current` binding out of Wallpapers.qml.
// Focusing a cloud placeholder must stop the previous preview and must not
// hand that path to the desktop renderer. Opening it (onDisk becomes true)
// may preview. An explicit setWallpaper stays outside this path.
QtObject {
    id: root

    property int assertions: 0
    property string currentImage: "C:/walls/current.jpg"
    property bool externalWallpaperActive: false
    property bool showPreview: false
    property string previewPath: ""
    property var list: [
        { path: "C:/walls/local.jpg", onDisk: true },
        { path: "C:/walls/cloud.jpg", onDisk: false }
    ]

    function samePath(a, b): bool {
        return String(a ?? "").replace(/\\/g, "/").toLowerCase() === String(b ?? "").replace(/\\/g, "/").toLowerCase();
    }
    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
        assertions++;
    }

    // WALLPAPER_CURRENT
    // WALLPAPER_PREVIEW
    // WALLPAPER_PREVIEW_ENTRY
    // WALLPAPER_STOP

    function run(): void {
        try {
            previewEntry(list[0]);
            check(showPreview && current === "C:/walls/local.jpg", "focusing a local wallpaper did not preview it");

            previewEntry(list[1]);
            check(showPreview === false, "focusing a placeholder left the preview running");
            check(current === currentImage, "focusing a placeholder changed the desktop wallpaper");
            check(previewPath !== "C:/walls/cloud.jpg", "a placeholder path was stored for the desktop renderer");

            preview("C:/walls/cloud.jpg");
            check(showPreview === false && current !== "C:/walls/cloud.jpg", "preview() hydrated an unopened placeholder");

            list[1].onDisk = true;
            previewEntry(list[1]);
            check(showPreview && current === "C:/walls/cloud.jpg", "an opened placeholder could not preview");

            console.log("CAELESTIA_WALLPAPER_PREVIEW_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.log("CAELESTIA_WALLPAPER_PREVIEW_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: run()
}
