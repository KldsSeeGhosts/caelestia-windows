import QtQuick
import Quickshell.Io
import Caelestia

// Confined image-cache writer. Upstream rasterised a remote image through a
// hidden native window and saved it under its cache directory; this adaptation
// keeps the cache but not the surface.
//
// A native writer probe showed that a PanelWindow-based writer saves a blank
// transparent PNG in the Windows backend for a zero-opacity, 1x1, clipped or
// off-screen surface (grabToImage renders through the window pass), so a hidden
// surface cannot both hide itself and produce the image. The source is already
// validated and confined by NotificationsService, so the writer instead makes a
// single synchronous byte copy into the service's hash-named cache file. There
// is no window, no input region and nothing to show, and the notification card
// still crops the image at display time.
//
// The copy is used only with a destination from imageCachePath(), which returns
// "" for a rejected source or an image already inside the confined cache.
Item {
    id: root

    visible: false
    implicitWidth: 0
    implicitHeight: 0

    property var record: null
    property var service: null
    property bool started: false
    property bool finished: false

    // CUtils.copyFile copies bytes but does not create the cache directory.
    // This marker write is the only directory creation available from QML:
    // FileView creates missing parent directories before writing. It holds no
    // notification data and is never passed to a notification card.
    FileView {
        id: directoryMarker

        path: ""
        blockWrites: true
        blockLoading: true
        atomicWrites: false
        printErrors: false
    }

    function ensureCacheDirectory(): bool {
        const directory = String(root.service?.imageCacheDirectory ?? "");
        if (directory === "")
            return false;
        if (directoryMarker.path !== directory + "/.keep")
            directoryMarker.path = directory + "/.keep";
        directoryMarker.setText(".");
        return true;
    }

    function process(): void {
        if (root.started || root.finished || !root.record || !root.service)
            return;

        const saving = root.record;
        const source = String(saving.image ?? "");
        const target = String(root.service.imageCachePath(saving) ?? "");
        // imageCachePath() re-validates the source and returns nothing for a
        // provider URL, a rejected path or an already-cached image.
        if (source === "" || target === "")
            return;

        root.started = true;
        if (!root.ensureCacheDirectory()) {
            root.finished = true;
            root.service.abortImageCache(saving, "The confined notification image cache is not available.");
            return;
        }

        const copied = CUtils.copyFile(Qt.resolvedUrl(source), Qt.resolvedUrl(target), true);
        if (!copied) {
            root.finished = true;
            root.service.abortImageCache(saving, "The notification image could not be copied into the confined cache.");
            return;
        }

        root.finished = true;
        if (!(root.service.applyCachedImage(saving, target) ?? false))
            root.service.abortImageCache(saving, "The copied notification image was rejected by the confined cache.");
    }

    onRecordChanged: {
        // A writer slot can be reassigned to the next queued record. Defer the
        // next copy so a busy queue does not recurse through the slot handoff.
        root.finished = false;
        root.started = false;
        Qt.callLater(() => root.process());
    }

    Component.onCompleted: Qt.callLater(() => root.process())
}

