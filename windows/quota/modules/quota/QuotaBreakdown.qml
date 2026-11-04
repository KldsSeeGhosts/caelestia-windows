pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// A usage row's hover detail, after OpenUsage's UsageBreakdownDetail
// (Views/UsageBreakdownDetail.swift): 288 wide, padded 14, sections 14 apart.
// A caption over a large total, then the token mix (a stacked bar and a
// two-column legend), then Top Models. It is data-driven: every section shows
// only when `detail` carries its data, and nothing is filled in here.
//
// detail: {
//   title: "Yesterday",
//   figures: ["348.7M tokens", ...],          // the first is the headline
//   tokenParts: [{ title: "Cache Read", number: 331.4e6 }, ...],
//   fillsTotal: true,                          // the parts add up to the total
//   models: [{ name: "model", value: "55%" }, ...]
// }
Item {
    id: root
    objectName: "quotaBreakdown"

    property var detail: null
    property string family: Tokens.font.body.small.family
    readonly property var figures: detail?.figures ?? []
    readonly property var parts: detail?.tokenParts ?? []
    readonly property var models: detail?.models ?? []
    readonly property real partTotal: parts.reduce((sum, p) => sum + Number(p.number || 0), 0)
    // TokenMix shades: the accent at falling strength.
    readonly property var shades: [1, 0.6, 0.35, 0.2, 0.12]

    function shade(index: int): color {
        return Qt.alpha(Colours.palette.m3primary, shades[Math.min(index, shades.length - 1)]);
    }

    implicitWidth: 288
    implicitHeight: column.implicitHeight + 28

    Accessible.role: Accessible.StaticText
    Accessible.name: [detail?.title ?? ""].concat(figures).join(", ")

    ColumnLayout {
        id: column
        x: 14
        y: 14
        width: parent.width - 28
        spacing: 14

        // UsageSummary
        ColumnLayout {
            Layout.fillWidth: true
            spacing: 2
            StyledText {
                objectName: "quotaBreakdownTitle"
                Layout.fillWidth: true
                text: root.detail?.title ?? ""
                elide: Text.ElideRight
                color: Colours.palette.m3onSurfaceVariant
                font.family: root.family
                font.pixelSize: 11
                font.weight: Font.DemiBold
            }
            StyledText {
                objectName: "quotaBreakdownHeadline"
                visible: root.figures.length > 0
                Layout.fillWidth: true
                text: root.figures[0] ?? ""
                elide: Text.ElideRight
                color: Colours.palette.m3onSurface
                font.family: root.family
                font.pixelSize: 26
                font.weight: Font.DemiBold
                font.letterSpacing: -0.5
                font.features: ({"tnum": 1})
            }
            StyledText {
                visible: root.figures.length > 1
                Layout.fillWidth: true
                text: root.figures.slice(1).join(" · ")
                elide: Text.ElideRight
                color: Colours.palette.m3onSurfaceVariant
                font.family: root.family
                font.pixelSize: 12
                font.features: ({"tnum": 1})
            }
        }

        // TokenMix: a 6 dp capsule bar, 1 dp between parts, and the legend.
        ColumnLayout {
            objectName: "quotaTokenMix"
            visible: root.parts.length > 0
            Layout.fillWidth: true
            spacing: 8
            Item {
                id: mixBar
                visible: root.detail?.fillsTotal === true && root.partTotal > 0
                Layout.fillWidth: true
                Layout.preferredHeight: 6
                Row {
                    spacing: 1
                    Repeater {
                        model: mixBar.visible ? root.parts : []
                        delegate: Rectangle {
                            required property var modelData
                            required property int index
                            readonly property real room: mixBar.width - (root.parts.length - 1)
                            objectName: "quotaTokenPart"
                            width: Math.max(1, room * Number(modelData.number || 0) / root.partTotal)
                            height: 6
                            // The capsule's ends are the first and last parts.
                            radius: index === 0 || index === root.parts.length - 1 ? 3 : 0
                            color: root.shade(index)
                        }
                    }
                }
            }
            RowLayout {
                Layout.fillWidth: true
                spacing: 8
                Repeater {
                    // Two columns: the first holds the larger half.
                    model: root.parts.length > 1 ? [0, 1] : [0]
                    delegate: ColumnLayout {
                        id: legend
                        required property int modelData
                        readonly property int split: Math.ceil(root.parts.length / 2)
                        readonly property var range: modelData === 0 ? [0, split] : [split, root.parts.length]
                        Layout.alignment: Qt.AlignTop
                        Layout.fillWidth: modelData === 0
                        spacing: 2
                        Repeater {
                            model: root.parts.slice(legend.range[0], legend.range[1])
                            delegate: RowLayout {
                                id: part
                                required property var modelData
                                required property int index
                                spacing: 0
                                Accessible.role: Accessible.StaticText
                                Accessible.name: modelData.title + ", " + Logic.count(modelData.number)
                                Rectangle {
                                    Layout.rightMargin: 6
                                    width: 6
                                    height: 6
                                    radius: 3
                                    color: root.shade(legend.range[0] + part.index)
                                }
                                StyledText {
                                    text: part.modelData.title
                                    color: Colours.palette.m3onSurfaceVariant
                                    font.family: root.family
                                    font.pixelSize: 11
                                }
                                Item { Layout.minimumWidth: 6; Layout.fillWidth: true }
                                StyledText {
                                    text: Logic.count(part.modelData.number)
                                    color: Colours.palette.m3onSurface
                                    font.family: root.family
                                    font.pixelSize: 11
                                    font.features: ({"tnum": 1})
                                }
                            }
                        }
                    }
                }
            }
        }

        // Top Models
        ColumnLayout {
            objectName: "quotaTopModels"
            visible: root.models.length > 0
            Layout.fillWidth: true
            spacing: 6
            StyledText {
                text: qsTr("Top Models")
                color: Colours.palette.m3onSurfaceVariant
                font.family: root.family
                font.pixelSize: 11
                font.weight: Font.DemiBold
                Accessible.role: Accessible.Heading
                Accessible.name: text
            }
            ColumnLayout {
                Layout.fillWidth: true
                spacing: 2
                Repeater {
                    model: root.models
                    delegate: RowLayout {
                        id: model
                        required property var modelData
                        Layout.fillWidth: true
                        Layout.minimumHeight: 18
                        spacing: 8
                        Accessible.role: Accessible.StaticText
                        Accessible.name: modelData.name + ", " + modelData.value
                        StyledText {
                            Layout.fillWidth: true
                            text: model.modelData.name
                            elide: Text.ElideRight
                            color: Colours.palette.m3onSurface
                            font.family: root.family
                            font.pixelSize: 12
                        }
                        StyledText {
                            text: model.modelData.value
                            color: Colours.palette.m3onSurface
                            font.family: root.family
                            font.pixelSize: 12
                            font.features: ({"tnum": 1})
                        }
                    }
                }
            }
        }
    }
}
