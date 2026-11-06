import QtQuick
import Quickshell
import Caelestia.Config
import Caelestia.State
import qs.components
import qs.components.effects
import qs.services
import qs.utils

Item {
    id: root

    required property var modelData
    required property ScreenState screenState

    scale: 0.5
    opacity: 0
    z: PathView.z ?? 0 // qmllint disable missing-property

    Component.onCompleted: {
        scale = Qt.binding(() => PathView.isCurrentItem ? 1 : PathView.onPath ? 0.8 : 0);
        opacity = Qt.binding(() => PathView.onPath ? 1 : 0);
    }

    implicitWidth: image.width + Tokens.padding.medium * 2
    implicitHeight: image.height + label.height + Tokens.spacing.extraSmall + Tokens.padding.large + Tokens.padding.medium

    // Windows port: the tile's path label is painted, not exposed.
    Accessible.role: Accessible.ListItem
    Accessible.selectable: true
    Accessible.selected: root.PathView.isCurrentItem
    Accessible.name: root.modelData?.relativePath ?? ""

    StateLayer {
        id: stateLayer

        radius: Tokens.rounding.large
        onClicked: {
            Wallpapers.setWallpaper(root.modelData.path, root.QsWindow.window?.screen);
            root.screenState.launcher = false;
        }
    }

    Elevation {
        anchors.fill: image
        radius: image.radius
        opacity: root.PathView.isCurrentItem ? 1 : 0
        level: 4

        Behavior on opacity {
            Anim {
                type: Anim.DefaultEffects
            }
        }
    }

    ClipRect {
        id: image

        anchors.horizontalCenter: parent.horizontalCenter
        y: Tokens.padding.large
        color: Colours.tPalette.m3surfaceContainer
        radius: Tokens.rounding.large

        implicitWidth: Tokens.sizes.launcher.wallpaperWidth
        implicitHeight: implicitWidth / 16 * 9

        MaterialIcon {
            anchors.centerIn: parent
            text: "image"
            color: Colours.tPalette.m3outline
            fontStyle: Tokens.font.icon.builders.extraLarge.scale(2).weight(Font.DemiBold).build()
        }

        Image {
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
        font: Tokens.font.label.medium
    }

    Behavior on scale {
        Anim {}
    }

    Behavior on opacity {
        Anim {
            type: Anim.DefaultEffects
        }
    }
}
