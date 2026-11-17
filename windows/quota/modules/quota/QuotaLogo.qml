import QtQuick
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services

// A provider mark. Tinted (the default), it is drawn in one muted colour
// (m3onSurfaceVariant) so it reads as a label rather than a button; Qt Controls
// recolours an SVG through icon.color without a GPU effect, so the tint also
// renders in the offscreen harness. Untinted, the mark keeps its own colours.
// Marks are user-supplied files (see Content.providerIconSource): when
// `source` cannot be read, `altSource` is tried, then the first letters of
// `fallback` are shown. Purely decorative: never focusable, hidden from
// accessibility.
Item {
    id: root

    property url source
    property url altSource
    property string fallback: ""
    property bool tinted: true
    // Set once `source` fails, so the alternative is tried only once.
    property bool useAlt: false
    readonly property url resolved: useAlt ? altSource : source
    readonly property bool hasMark: !!resolved.toString() && probe.status === Image.Ready

    implicitWidth: 20
    implicitHeight: 20
    onSourceChanged: useAlt = false

    // Loads the mark, shows it when untinted and tells whether it exists.
    Image {
        id: probe
        objectName: "quotaLogoImage"
        anchors.fill: parent
        visible: !root.tinted && root.hasMark
        source: root.resolved
        sourceSize.width: Math.ceil(root.width * 2)
        sourceSize.height: Math.ceil(root.height * 2)
        fillMode: Image.PreserveAspectFit
        smooth: true
        mipmap: true
        asynchronous: false
        Accessible.ignored: true
        onStatusChanged: if (status === Image.Error && !root.useAlt && !!root.altSource.toString()) root.useAlt = true
    }
    Button {
        objectName: "quotaLogoMark"
        anchors.fill: parent
        visible: root.tinted && root.hasMark
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
        icon.source: root.hasMark ? root.resolved : ""
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
