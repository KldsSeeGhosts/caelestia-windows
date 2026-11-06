import QtQuick
import Quickshell
import Caelestia
import qs.utils
import "modules/clipboard/ClipboardHistory.js" as ClipboardRows

Item {
    id: root

    readonly property string sourcePath: Quickshell.env("CAELESTIA_FILE_URL_SOURCE_PATH")
    readonly property string targetPath: Quickshell.env("CAELESTIA_FILE_URL_TARGET_PATH")
    property int assertions: 0
    property bool started: false
    property bool finished: false

    Image {
        id: clipboardPreview
        asynchronous: true
    }

    Image {
        id: dashboardPicture
        asynchronous: true
    }

    Image {
        id: wallpaperPreview
        asynchronous: true
    }

    Image {
        id: brokenPreview
        asynchronous: true
    }

    Timer {
        interval: 10
        repeat: true
        running: !root.finished
        onTriggered: root.checkImages()
    }

    Connections {
        target: clipboardPreview
        function onStatusChanged(): void { root.checkImages(); }
    }

    Connections {
        target: dashboardPicture
        function onStatusChanged(): void { root.checkImages(); }
    }

    Connections {
        target: wallpaperPreview
        function onStatusChanged(): void { root.checkImages(); }
    }

    Connections {
        target: brokenPreview
        function onStatusChanged(): void { root.checkImages(); }
    }

    Component.onCompleted: Qt.callLater(start)

    function check(value: bool, message: string): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }

    function start(): void {
        try {
            const sourcePath = String(root.sourcePath).replace(/\\/g, "/");
            const targetPath = String(root.targetPath).replace(/\\/g, "/");
            check(sourcePath.length > 0 && targetPath.length > 0, "fixture paths supplied");

            const fileUrl = Paths.absolutePath(sourcePath);
            const rows = ClipboardRows.displayRows([
                { id: "synthetic-reserved-file", kind: "text", text: fileUrl }
            ], "", 10);
            check(rows.length === 1 && rows[0].path === sourcePath, "clipboard URI decodes to the exact local path");
            check(rows[0].previewImage === fileUrl, "clipboard image preview uses the shared file URL");
            check(CUtils.toLocalFile(Qt.resolvedUrl(fileUrl)).replace(/\\/g, "/") === sourcePath,
                "Qt QUrl round-trips the source path exactly");

            const encodedDirectUrl = "file:///C:/Synthetic%20Data/photo%23draft%25.png";
            check(ClipboardRows.fileUrl(encodedDirectUrl) === encodedDirectUrl,
                "an already-encoded URL remains unchanged");
            check(CUtils.toLocalFile(Qt.resolvedUrl(encodedDirectUrl)) === "C:/Synthetic Data/photo#draft%.png",
                "Qt QUrl decodes an already-encoded URL once");

            const uncPath = "//synthetic-server/synthetic-share/photo#draft %.png";
            const uncUrl = ClipboardRows.fileUrl(uncPath);
            check(uncUrl === "file://synthetic-server/synthetic-share/photo%23draft%20%25.png",
                "UNC paths keep the server and share as URL authority/path");
            check(CUtils.toLocalFile(Qt.resolvedUrl(uncUrl)).replace(/\\/g, "/") === uncPath,
                "Qt QUrl round-trips a synthetic UNC path");

            const rootAsset = Paths.absolutePath("root:/assets/wallpaper.webp");
            check(rootAsset.endsWith("/assets/wallpaper.webp") && !rootAsset.includes("%3A"),
                "root asset URLs retain the existing resolution behavior");

            const sourceUrl = Qt.resolvedUrl(Paths.absolutePath(sourcePath));
            const targetUrl = Qt.resolvedUrl(Paths.absolutePath(targetPath));
            check(CUtils.copyFile(sourceUrl, targetUrl),
                "dashboard-style QUrl copy succeeds for the reserved-character target");
            check(CUtils.toLocalFile(targetUrl).replace(/\\/g, "/") === targetPath,
                "dashboard copy target QUrl round-trips exactly");

            clipboardPreview.source = rows[0].previewImage;
            dashboardPicture.source = Paths.absolutePath(targetPath);
            wallpaperPreview.source = Paths.absolutePath(sourcePath);
            brokenPreview.source = "file:///" + sourcePath;
            started = true;
            Qt.callLater(checkImages);
        } catch (error) {
            finished = true;
            console.error("CAELESTIA_FILE_URL_QT_FAIL " + error);
            Qt.exit(1);
        }
    }

    function checkImages(): void {
        if (!started || finished)
            return;
        if (clipboardPreview.status === Image.Loading || dashboardPicture.status === Image.Loading ||
                wallpaperPreview.status === Image.Loading || brokenPreview.status === Image.Loading)
            return;
        try {
            check(clipboardPreview.status === Image.Ready, "Qt Image loads the clipboard reserved-character preview");
            check(dashboardPicture.status === Image.Ready, "Qt Image reads the dashboard-style copied picture");
            check(wallpaperPreview.status === Image.Ready, "Qt Image loads the helper-routed wallpaper preview");
            check(brokenPreview.status === Image.Error,
                "negative control: unescaped # URL does not load the reserved-character image");
            finished = true;
            console.log("CAELESTIA_FILE_URL_QT_PASS " + JSON.stringify({
                assertions: assertions,
                clipboardPreviewReady: true,
                dashboardCopyReadReady: true,
                wallpaperPreviewReady: true,
                brokenUrlRejected: true
            }));
            Qt.quit();
        } catch (error) {
            finished = true;
            console.error("CAELESTIA_FILE_URL_QT_FAIL " + error);
            Qt.exit(1);
        }
    }
}
