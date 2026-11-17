pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import QtQuick.Shapes
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// One account in All Usage, as a compact summary row: a ring gauge in the
// provider's accent round its mark, the provider over the plan, and up to two
// large figures (% left) with their window under each. Activating the row
// opens the account's meters and its provider's spend below it (Content owns
// that part).
AbstractButton {
    id: root
    objectName: "quotaProviderRow"

    // QuotaLogic.providerSummary
    required property var summary
    required property double nowMs
    property string label: ""
    property string subtitle: ""
    property string provider: ""
    property url logo
    property url logoAlt
    property string notice: ""
    property bool noticeOld: false
    property bool expanded: false
    property string family: ""
    property Item boundsItem: root

    readonly property color muted: Colours.palette.m3onSurfaceVariant
    readonly property int figureWidth: 62
    readonly property color accent: Logic.accent(provider) || Colours.palette.m3primary
    // A figure running low turns amber, as usage widgets commonly show it.
    readonly property color amber: Colours.light ? "#a35f00" : "#f2a93b"

    function levelColour(level: string, normal: color): color {
        return level === "critical" ? Colours.palette.m3error
            : level === "warning" ? root.amber : normal;
    }

    implicitHeight: 64
    height: 64
    hoverEnabled: true
    focusPolicy: Qt.StrongFocus
    padding: 0
    leftPadding: 8
    rightPadding: 8
    Accessible.role: Accessible.Button
    Accessible.name: [label, subtitle].concat(summary.columns.map(c => c.remaining === null
            ? qsTr("%1 not reported").arg(c.title)
            : qsTr("%1 %2 percent left").arg(c.title).arg(Math.round(c.remaining * 100))
              + (Logic.resetShort(c.resetsAt, nowMs) ? ", " + qsTr("resets in %1").arg(Logic.resetSpoken(c.resetsAt, nowMs)) : "")),
        notice, expanded ? qsTr("expanded") : qsTr("collapsed")).filter(s => s).join(", ")
    Keys.onReturnPressed: root.click()
    Keys.onEnterPressed: root.click()

    background: Rectangle {
        radius: Tokens.rounding.small
        color: Qt.alpha(Colours.palette.m3onSurface, root.down ? 0.1 : root.hovered ? 0.06 : 0)
        border.width: root.visualFocus ? 2 : 0
        border.color: Colours.palette.m3primary
        Behavior on color {
            CAnim {}
        }
    }

    contentItem: RowLayout {
        spacing: 12

        // The ring: a track all round, the fill from 12 o'clock with round caps
        // showing the tighter of the two figures, the provider mark inside.
        Item {
            objectName: "quotaProviderGauge"
            Layout.preferredWidth: 48
            Layout.preferredHeight: 48
            Accessible.ignored: true

            Shape {
                anchors.fill: parent
                preferredRendererType: Shape.CurveRenderer
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: Qt.alpha(Colours.palette.m3onSurface, Colours.light ? 0.09 : 0.12)
                    strokeWidth: 4
                    PathAngleArc {
                        centerX: 24
                        centerY: 24
                        radiusX: 22
                        radiusY: 22
                        startAngle: 0
                        sweepAngle: 360
                    }
                }
                ShapePath {
                    fillColor: "transparent"
                    strokeColor: root.accent
                    strokeWidth: root.summary.ring > 0 ? 4 : 0
                    capStyle: ShapePath.RoundCap
                    PathAngleArc {
                        centerX: 24
                        centerY: 24
                        radiusX: 22
                        radiusY: 22
                        startAngle: -90
                        sweepAngle: 360 * Math.max(0, Math.min(1, root.summary.ring ?? 0))
                    }
                }
            }
            // The mark sits on a disc of the accent, like an app icon.
            Rectangle {
                anchors.centerIn: parent
                width: 34
                height: 34
                radius: 17
                color: Qt.alpha(root.accent, Colours.light ? 0.16 : 0.2)
            }
            QuotaLogo {
                objectName: "quotaProviderLogo"
                anchors.centerIn: parent
                implicitWidth: 20
                implicitHeight: 20
                tinted: false
                source: root.logo
                altSource: root.logoAlt
                fallback: root.label
            }
        }

        ColumnLayout {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            spacing: 1
            RowLayout {
                Layout.fillWidth: true
                spacing: 4
                StyledText {
                    objectName: "quotaProviderName"
                    Layout.minimumWidth: 0
                    Layout.fillWidth: !noticeGlyph.visible
                    text: root.label
                    elide: Text.ElideRight
                    color: Colours.palette.m3onSurface
                    font.family: root.family
                    font.pixelSize: 16
                    font.weight: Font.DemiBold
                }
                MaterialIcon {
                    id: noticeGlyph
                    objectName: "quotaNotice"
                    visible: root.notice !== ""
                    text: root.noticeOld ? "schedule" : "warning"
                    fill: root.noticeOld ? 0 : 1
                    color: root.noticeOld ? Qt.alpha(root.muted, 0.6) : Colours.palette.m3tertiary
                    fontStyle: Tokens.font.icon.builders.small.scale(0.6).build()
                    Accessible.ignored: true
                    HoverHandler { id: noticeHover }
                    QuotaToolTip { visible: noticeHover.hovered; text: root.notice; boundsItem: root.boundsItem; family: root.family }
                }
                Item { Layout.fillWidth: noticeGlyph.visible }
            }
            StyledText {
                objectName: "quotaProviderPlan"
                Layout.fillWidth: true
                visible: text !== ""
                text: root.subtitle
                elide: Text.ElideRight
                color: root.muted
                font.family: root.family
                font.pixelSize: 13
            }
        }

        // One slot is kept empty on the left when a provider reports a single
        // window, so its figure lines up with the other rows' second column.
        Item {
            visible: root.summary.columns.length === 1
            Layout.preferredWidth: root.figureWidth
        }
        Repeater {
            model: root.summary.columns
            delegate: ColumnLayout {
                id: figure
                required property var modelData
                readonly property string reset: Logic.resetShort(modelData.resetsAt, root.nowMs)
                objectName: "quotaProviderFigure"
                Layout.preferredWidth: root.figureWidth
                spacing: 0
                StyledText {
                    objectName: "quotaProviderLeft"
                    Layout.alignment: Qt.AlignRight
                    text: figure.modelData.remaining === null ? "—" : Math.round(figure.modelData.remaining * 100) + "%"
                    color: root.levelColour(figure.modelData.severity, Colours.palette.m3onSurface)
                    font.family: root.family
                    font.pixelSize: 20
                    font.weight: Font.DemiBold
                    font.features: ({"tnum": 1})
                }
                StyledText {
                    objectName: "quotaProviderWindow"
                    Layout.alignment: Qt.AlignRight
                    Layout.maximumWidth: root.figureWidth
                    text: figure.modelData.title
                    elide: Text.ElideRight
                    color: root.muted
                    font.family: root.family
                    font.pixelSize: 12
                }
                HoverHandler { id: figureHover }
                QuotaToolTip {
                    visible: figureHover.hovered && figure.modelData.remaining !== null
                    text: qsTr("%1% used").arg(100 - Math.round(figure.modelData.remaining * 100))
                        + (figure.reset ? " · " + (figure.reset === "soon" ? qsTr("resets soon") : qsTr("resets in %1").arg(figure.reset)) : "")
                    boundsItem: root.boundsItem
                    family: root.family
                }
            }
        }
        MaterialIcon {
            objectName: "quotaProviderChevron"
            Layout.preferredWidth: 16
            text: "expand_more"
            rotation: root.expanded ? 180 : 0
            opacity: root.expanded || root.hovered || root.visualFocus ? 1 : 0
            color: root.muted
            fontStyle: Tokens.font.icon.builders.small.scale(0.8).build()
            Accessible.ignored: true
            Behavior on rotation {
                Anim {}
            }
            Behavior on opacity {
                Anim {}
            }
        }
    }
}
