import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

// A row of the grid without a bar: the label on the left, its value on the
// right. With no label it is a notice that takes the whole row and wraps.
RowLayout {
    id: root
    objectName: "quotaValueRow"

    property string label: ""
    property string value: ""
    property bool error: false
    property string family: ""
    // Notices and other secondary text read muted; plain values do not.
    property bool muted: false

    spacing: 8
    Accessible.role: Accessible.StaticText
    Accessible.name: label ? label + ", " + value : value

    StyledText {
        visible: root.label !== ""
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: root.label
        elide: Text.ElideRight
        font.family: root.family
        font.pixelSize: 13
    }
    StyledText {
        objectName: "quotaValue"
        Layout.fillWidth: root.label === ""
        Layout.maximumWidth: root.label === "" ? -1 : root.width * 0.6
        horizontalAlignment: root.label === "" ? Text.AlignLeft : Text.AlignRight
        text: root.value
        wrapMode: root.label === "" ? Text.WordWrap : Text.NoWrap
        elide: root.label === "" ? Text.ElideNone : Text.ElideLeft
        color: root.error ? Colours.palette.m3error : root.muted || root.label === "" ? Colours.palette.m3onSurfaceVariant : Colours.palette.m3onSurface
        font.family: root.family
        font.pixelSize: root.label === "" ? 12 : 13
        font.features: ({"tnum": 1})
    }
}
