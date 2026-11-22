pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import Caelestia.Multimedia
import qs.components
import qs.components.controls
import qs.services

Item {
    id: root

    // Windows: allow WallpaperSelect to cull offscreen thumbnail decodes.
    property string source: ""
    property bool thumbnailActive: true
    property alias text: label.text
    property alias radius: imgWrapper.radius
    property alias imgHeight: imgWrapper.implicitHeight
    property bool fillLabel: true
    property bool interactivePreview: false
    readonly property bool previewHighlighted: interactivePreview && visible && enabled
        && (stateLayer.containsMouse || activeFocus)

    signal clicked
    signal previewRequested
    signal previewEnded

    onPreviewHighlightedChanged: {
        if (previewHighlighted)
            previewRequested();
        else
            previewEnded();
    }
    activeFocusOnTab: interactivePreview
    Keys.onReturnPressed: if (interactivePreview) clicked()
    Keys.onEnterPressed: if (interactivePreview) clicked()
    Keys.onSpacePressed: if (interactivePreview) clicked()

    Layout.fillWidth: true
    implicitHeight: layout.implicitHeight

    ColumnLayout {
        id: layout

        anchors.fill: parent
        spacing: Tokens.spacing.small

        ClipRect {
            id: imgWrapper

            Layout.fillWidth: true
            implicitHeight: width
            radius: Tokens.rounding.largeIncreased
            color: Colours.tPalette.m3surfaceContainer

            Loader {
                anchors.centerIn: parent

                opacity: img.ready ? 0 : 1
                active: opacity > 0 && root.thumbnailActive && root.source !== ""

                sourceComponent: StyledRect {
                    implicitWidth: loadingIndicator.implicitSize + Tokens.padding.large * 2
                    implicitHeight: loadingIndicator.implicitSize + Tokens.padding.large * 2

                    color: Colours.palette.m3primaryContainer
                    radius: Tokens.rounding.full

                    LoadingIndicator {
                        id: loadingIndicator

                        anchors.centerIn: parent
                        containsIcon: true
                        implicitSize: Math.min(imgWrapper.width, imgWrapper.height) * 0.3
                    }
                }

                Behavior on opacity {
                    Anim {
                        type: Anim.DefaultEffects
                    }
                }
            }

            Visual {
                id: img

                anchors.fill: parent
                source: root.thumbnailActive ? root.source : ""
                playing: root.thumbnailActive && stateLayer.containsMouse
            }

            Rectangle {
                anchors.fill: parent
                visible: root.previewHighlighted
                color: "transparent"
                border.width: 2
                border.color: Colours.palette.m3primary
                radius: imgWrapper.radius
            }
        }

        StyledText {
            id: label

            Layout.bottomMargin: Tokens.padding.small
            Layout.fillWidth: true
            color: Colours.palette.m3onSurfaceVariant
            font: Tokens.font.label.builders.small.weight(Font.Medium).build()
            horizontalAlignment: Text.AlignHCenter
            elide: Text.ElideRight
        }
    }

    StateLayer {
        id: stateLayer

        anchors.bottomMargin: root.fillLabel ? 0 : layout.implicitHeight - imgWrapper.implicitHeight
        onClicked: root.clicked()
    }
}
