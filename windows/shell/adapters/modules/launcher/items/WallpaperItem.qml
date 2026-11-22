import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.utils

Item {
    id: root

    required property var modelData
    required property bool highlighted
    signal pointed()
    signal unpointed()
    signal clicked()

    objectName: "launcherWallpaperTile"
    Accessible.role: Accessible.ListItem
    Accessible.selectable: true
    Accessible.selected: highlighted
    Accessible.name: root.modelData?.relativePath ?? ""
    Accessible.onPressAction: root.clicked()

    Rectangle {
        anchors.fill: parent
        anchors.margins: Tokens.spacing.extraSmall
        radius: Tokens.rounding.large
        color: root.highlighted ? Colours.palette.m3surfaceContainerHigh : "transparent"
        border.width: root.highlighted ? 2 : 0
        border.color: Colours.palette.m3primary
    }

    Rectangle {
        id: image

        anchors.horizontalCenter: parent.horizontalCenter
        y: Math.max(Tokens.padding.medium,
            (parent.height - height - label.implicitHeight - Tokens.spacing.extraSmall) / 2)
        color: Colours.tPalette.m3surfaceContainer
        clip: true

        width: Math.max(0, parent.width - Tokens.padding.medium * 2)
        height: Math.max(0, Math.min(width * 9 / 16,
            parent.height - label.implicitHeight - Tokens.spacing.extraSmall - Tokens.padding.medium * 2))

        MaterialIcon {
            anchors.centerIn: parent
            text: "image"
            color: Colours.tPalette.m3outline
            fontStyle: Tokens.font.icon.builders.extraLarge.scale(2).weight(Font.DemiBold).build()
        }

        Image {
            objectName: "launcherWallpaperThumbnail"
            anchors.fill: parent
            // Paths.absolutePath percent-encodes each segment, so '#' and '%'
            // in a wallpaper name cannot truncate or corrupt the file URL.
            // A cloud placeholder is listed, but decoding it would fetch its
            // content; leave the generic tile until the user opens it.
            source: root.modelData.onDisk === false ? ""
                : root.modelData.engine && !root.modelData.preview ? ""
                : Paths.absolutePath(root.modelData.preview || root.modelData.path)
            asynchronous: true
            sourceSize: {
                const dpr = (QsWindow.window as QsWindow)?.devicePixelRatio ?? 1;
                return Qt.size(width * dpr, height * dpr);
            }
            fillMode: Image.PreserveAspectCrop
        }
    }

    StyledText {
        id: label

        anchors.top: image.bottom
        anchors.topMargin: Tokens.spacing.extraSmall
        anchors.horizontalCenter: parent.horizontalCenter

        width: image.width - Tokens.padding.medium * 2
        horizontalAlignment: Text.AlignHCenter
        elide: Text.ElideRight
        renderType: Text.QtRendering
        text: root.modelData.relativePath
        color: root.highlighted ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
        font: Tokens.font.label.medium
    }

    MouseArea {
        anchors.fill: parent
        hoverEnabled: true
        cursorShape: Qt.PointingHandCursor
        onEntered: root.pointed()
        onPositionChanged: root.pointed()
        onExited: root.unpointed()
        onClicked: root.clicked()
    }
}
