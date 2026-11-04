import QtQuick
import Caelestia.Config
import qs.components
import qs.services

// A provider mark, held back so it reads as a label rather than a button. The
// marks are the scheme-aware variants Content picks (light or dark). They are
// not recoloured: a GPU tint renders nothing in the offscreen harness, so it
// could not be verified here. Falls back to the first letters without a mark.
Item {
    id: root

    property url source
    property string fallback: ""
    readonly property bool hasMark: !!source.toString()

    implicitWidth: 20
    implicitHeight: 20

    Image {
        anchors.fill: parent
        visible: root.hasMark
        opacity: 0.85
        source: root.source
        sourceSize: Qt.size(root.width * 2, root.height * 2)
        fillMode: Image.PreserveAspectFit
    }
    StyledText {
        anchors.centerIn: parent
        visible: !root.hasMark
        text: root.fallback.slice(0, 2)
        color: Colours.palette.m3onSurfaceVariant
        font.pixelSize: Math.round(root.height * 0.55)
        font.weight: Font.DemiBold
    }
}
