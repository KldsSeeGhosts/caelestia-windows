import QtQuick
import Quickshell
import Quickshell.Wayland
import Caelestia
import Caelestia.Config

// Optional image-cache writer for a local notification image. The original
// NotifData used a hidden native window to rasterise the image at the original
// size and save it under its cache directory. This adaptation keeps that
// bounded technique but takes the destination from
// NotificationsService.imageCachePath(), which is confined to the isolated
// profile cache. It never loads for an icon-provider URL or an image already in
// the confined cache, and a failed save only clears the pending flag.
Item {
    id: root

    property var record: null
    property var service: null

    visible: false

    readonly property string source: String(record?.image ?? "")
    readonly property string target: String(service?.imageCachePath(record) ?? "")
    readonly property bool writerActive: !finished && source !== "" && target !== ""

    property bool finished: false

    Loader {
        id: writer

        active: root.writerActive
        sourceComponent: PanelWindow {
            implicitWidth: TokenConfig.sizes.notifs.image
            implicitHeight: TokenConfig.sizes.notifs.image
            color: "transparent"
            mask: Region {}
            exclusionMode: ExclusionMode.Ignore
            WlrLayershell.layer: WlrLayer.Bottom
            WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
            visible: true

            Image {
                id: image

                anchors.fill: parent
                source: root.source
                fillMode: Image.PreserveAspectCrop
                cache: false
                asynchronous: true

                onStatusChanged: {
                    if (status !== Image.Ready)
                        return;
                    CUtils.saveItem(image, Qt.resolvedUrl(root.target), () => {
                        root.service?.applyCachedImage(root.record, root.target);
                        root.finished = true;
                    }, () => {
                        root.service?.markImageCacheFailed(root.record);
                        root.finished = true;
                    });
                }
            }
        }
    }
}
