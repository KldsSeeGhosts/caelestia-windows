import QtQuick
import Caelestia.Config
import Caelestia.I18n
import qs.components
import qs.services
import qs.utils

// Windows adaptation: the empty-folder explanation shown by the launcher
// wallpaper picker and by Nexus > Wallpapers. Both surfaces otherwise only
// said that nothing was found, without naming the folder or the way to fill it.
Column {
    id: root

    readonly property string folderPath: Paths.wallsdir
    readonly property string folderLabel: folderPath.replace(/\//g, "\\")
    // The facade's `files` is the folder scan; engine entries are not local
    // images. An empty scan is what makes the explanatory state relevant.
    readonly property bool folderEmpty: Wallpapers.files.length === 0

    spacing: Tokens.spacing.extraSmall

    StyledText {
        objectName: "wallpaperEmptyTitle"
        anchors.horizontalCenter: parent.horizontalCenter
        text: Tr.tr("No wallpapers found")
        font: Tokens.font.body.builders.large.weight(Font.Medium).build()
    }

    StyledText {
        objectName: "wallpaperEmptyHint"
        anchors.horizontalCenter: parent.horizontalCenter
        width: root.width > 0 ? root.width : 420
        horizontalAlignment: Text.AlignHCenter
        wrapMode: Text.Wrap
        text: Tr.tr("Use Add wallpaper… to copy an image into %1, or copy PNG, JPEG, BMP or WebP images there yourself.").arg(root.folderLabel)
        color: Colours.palette.m3onSurfaceVariant
        font: Tokens.font.body.medium
    }
}
