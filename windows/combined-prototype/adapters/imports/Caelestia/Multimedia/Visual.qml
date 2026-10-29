import QtQuick

// Static wallpaper route for the portable build, which excludes the upstream
// Multimedia plugin. WallpaperImpl retains the original transition shaders.
Item {
    id: root
    property string source
    property alias fillMode: image.fillMode
    property bool playing: false
    property bool animate: true
    readonly property bool ready: image.status === Image.Ready

    Image {
        id: image
        anchors.fill: parent
        asynchronous: true
        fillMode: Image.PreserveAspectCrop
        // Decode at display size rounded up to 256-px buckets to avoid re-decoding per resize frame.
        sourceSize: root.width > 0 && root.height > 0
            ? Qt.size(Math.ceil(root.width * Screen.devicePixelRatio / 256) * 256,
                      Math.ceil(root.height * Screen.devicePixelRatio / 256) * 256)
            : undefined
        source: !root.source ? "" : /^(file:|qrc:|https?:)/.test(root.source)
            ? root.source
            : "file:///" + encodeURI(root.source.replace(/\\/g, "/")).replace(/#/g, "%23").replace(/\?/g, "%3F")
    }
}
