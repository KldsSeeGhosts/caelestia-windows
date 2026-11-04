import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services

// An OpenUsage value row (Views/DashboardMetricRow.swift, `.value`): a 22 dp
// row with the label on the left and its figure on the right, both 12 dp, the
// figure in the primary text colour (or its severity colour) and any detail
// after it muted. A row with a hover detail lights its figure with OpenUsage's
// hover chip (Views/HoverHighlight.swift) and reports hover and clicks, so the
// drawer can open the detail.
RowLayout {
    id: root
    objectName: "quotaValueRow"

    property string label: ""
    property string value: ""
    property string detail: ""
    property string family: ""
    property string severity: "normal"
    property bool hasDetail: false
    // True while this row's detail is open.
    property bool lit: false
    readonly property Item figure: figureText

    signal detailHover(Item anchor, bool active)
    signal detailClicked(Item anchor)

    implicitHeight: 22
    height: 22
    spacing: 8
    Accessible.role: Accessible.StaticText
    Accessible.name: [label, value, detail].filter(s => s).join(", ")

    StyledText {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: root.label
        elide: Text.ElideRight
        color: Colours.palette.m3onSurface
        font.family: root.family
        font.pixelSize: 12
    }
    StyledText {
        id: figureText
        objectName: "quotaValue"
        Layout.maximumWidth: root.width * 0.6
        horizontalAlignment: Text.AlignRight
        text: root.detail ? root.value + " <font color=\"" + Colours.palette.m3onSurfaceVariant + "\">· " + root.detail + "</font>" : root.value
        textFormat: root.detail ? Text.StyledText : Text.PlainText
        elide: Text.ElideLeft
        color: root.severity === "critical" ? Colours.palette.m3error
            : root.severity === "warning" ? Colours.palette.m3tertiary : Colours.palette.m3onSurface
        font.family: root.family
        font.pixelSize: 12
        font.features: ({"tnum": 1})

        Rectangle {
            objectName: "quotaHoverChip"
            z: -1
            x: figureText.width - figureText.contentWidth - 6
            y: -2
            width: figureText.contentWidth + 12
            height: figureText.height + 4
            radius: 6
            color: Qt.alpha(Colours.palette.m3onSurface, 0.08)
            opacity: root.hasDetail && (figureHover.hovered || root.lit) ? 1 : 0
            Behavior on opacity {
                NumberAnimation {
                    duration: 120
                    easing.type: Easing.OutQuad
                }
            }
        }
        HoverHandler {
            id: figureHover
            enabled: root.hasDetail
            onHoveredChanged: root.detailHover(figureText, hovered)
        }
        TapHandler {
            enabled: root.hasDetail
            onTapped: root.detailClicked(figureText)
        }
    }
}
