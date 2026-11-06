import QtQuick
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services

// A provider mark in one muted tint (m3onSurfaceVariant), so it reads as a
// label rather than a button. The marks are the scheme-aware variants Content
// picks (light or dark). Qt Controls recolours an SVG through icon.color
// without a GPU effect, so the tint also renders in the offscreen harness. The
// Button is purely decorative: disabled, no background, no padding, never
// focusable, hidden from accessibility, and out of the Tab order. Falls back to
// the first letters without a mark.
Item {
    id: root

    property url source
    property string fallback: ""
    readonly property bool hasMark: !!source.toString()

    implicitWidth: 20
    implicitHeight: 20

    Button {
        objectName: "quotaLogoMark"
        anchors.fill: parent
        visible: root.hasMark
        enabled: false
        hoverEnabled: false
        focusPolicy: Qt.NoFocus
        Accessible.ignored: true
        padding: 0
        topInset: 0
        bottomInset: 0
        leftInset: 0
        rightInset: 0
        background: null
        display: AbstractButton.IconOnly
        icon.source: root.source
        icon.width: root.width
        icon.height: root.height
        icon.color: Colours.palette.m3onSurfaceVariant
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
