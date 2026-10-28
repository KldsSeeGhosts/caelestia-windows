pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Shapes
import QtQuick.Layouts
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services

// OpenUsage's spend card: Today / Yesterday / 30 Days, a cost donut and a
// provider legend.
Rectangle {
    id: root
    objectName: "quotaSpend"

    required property string family
    property string range: "today"
    readonly property var ranges: [
        { key: "today", label: qsTr("Today") },
        { key: "yesterday", label: qsTr("Yesterday") },
        { key: "month", label: qsTr("30 Days") }
    ]
    readonly property var current: Quota.spend[range] || null
    // Until the first analytics reply, Today falls back to the summary's total.
    readonly property var total: current ? current.total : range === "today" ? Quota.todayCostUsd : null
    // Four providers, then the rest folded into Other, as in OpenUsage.
    readonly property var legend: {
        const rows = current ? current.rows : [];
        if (rows.length <= 4)
            return rows;
        const other = rows.slice(3).reduce((sum, row) => sum + row.cost, 0);
        return rows.slice(0, 3).concat([{ provider: "other", cost: other }]);
    }
    readonly property var slices: {
        const sum = legend.reduce((total, row) => total + row.cost, 0);
        const gap = legend.length > 1 ? 2 : 0;
        const out = [];
        let start = -90;
        for (const row of legend) {
            const sweep = sum > 0 ? row.cost / sum * 360 : 0;
            out.push({ provider: row.provider, start: start + gap / 2, sweep: Math.max(0.5, sweep - gap) });
            start += sweep;
        }
        return out;
    }

    function label(provider: string): string {
        if (provider === "other")
            return qsTr("Other");
        const group = Quota.providerGroups.find(g => g.provider === provider);
        return group ? group.label : Quota.providerDisplayName(provider);
    }
    // Brand colours where a provider has one; the rest come from the scheme.
    function colour(provider: string): color {
        switch (provider) {
        case "claude": return "#d97757";
        case "codex": return "#10a37f";
        case "cursor": return Colours.palette.m3onSurface;
        case "antigravity": return "#4285f4";
        case "zai": return "#7c5cff";
        case "opencode-go": return "#f5a623";
        case "other": return Colours.palette.m3outline;
        }
        return Colours.palette.m3tertiary;
    }
    function money(value: real): string {
        return "$" + Number(value).toLocaleString(Qt.locale("en_US"), "f", 2);
    }
    function compactMoney(value: var): string {
        if (value === null || value === undefined)
            return "—";
        if (value >= 1000)
            return "$" + (value / 1000).toFixed(1) + "K";
        return value >= 100 ? "$" + Math.round(value) : "$" + Number(value).toFixed(2);
    }

    implicitHeight: body.implicitHeight + 28
    radius: 14
    color: Qt.alpha(Colours.palette.m3onSurface, 0.05)

    component Label: StyledText {
        font.family: root.family
        font.pixelSize: 13
        font.features: ({"tnum": 1})
    }

    Column {
        id: body
        x: 14; y: 14
        width: parent.width - 28
        spacing: 16

        Rectangle {
            id: tabs
            readonly property real segment: (width - 6) / root.ranges.length
            readonly property int index: Math.max(0, root.ranges.findIndex(r => r.key === root.range))
            width: parent.width
            height: 34
            radius: height / 2
            color: Qt.alpha(Colours.palette.m3onSurface, 0.06)
            Rectangle {
                x: 3 + tabs.segment * tabs.index
                y: 3
                width: tabs.segment
                height: tabs.height - 6
                radius: height / 2
                color: Colours.light ? Colours.palette.m3surfaceContainerLowest : Qt.alpha(Colours.palette.m3onSurface, 0.14)
                Behavior on x { Anim { type: Anim.Emphasized } }
            }
            Row {
                x: 3; y: 3
                Repeater {
                    model: root.ranges
                    delegate: AbstractButton {
                        id: tab
                        required property var modelData
                        readonly property bool selected: root.range === modelData.key
                        width: tabs.segment
                        height: tabs.height - 6
                        hoverEnabled: true
                        onClicked: root.range = modelData.key
                        Accessible.name: modelData.label
                        background: Rectangle {
                            radius: height / 2
                            color: "transparent"
                            border.width: tab.activeFocus ? 1 : 0
                            border.color: Colours.palette.m3primary
                        }
                        contentItem: Label {
                            text: tab.modelData.label
                            horizontalAlignment: Text.AlignHCenter
                            verticalAlignment: Text.AlignVCenter
                            font.weight: tab.selected ? Font.DemiBold : Font.Medium
                            color: tab.selected || tab.hovered ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                        }
                    }
                }
            }
        }

        RowLayout {
            width: parent.width
            spacing: 20

            Item {
                Layout.preferredWidth: 112
                Layout.preferredHeight: 112
                Shape {
                    anchors.fill: parent
                    preferredRendererType: Shape.CurveRenderer
                    ShapePath {
                        strokeWidth: 16
                        strokeColor: Qt.alpha(Colours.palette.m3onSurface, 0.08)
                        fillColor: "transparent"
                        PathAngleArc { centerX: 56; centerY: 56; radiusX: 48; radiusY: 48; startAngle: 0; sweepAngle: 360 }
                    }
                }
                Repeater {
                    model: root.slices
                    delegate: Shape {
                        id: slice
                        required property var modelData
                        anchors.fill: parent
                        preferredRendererType: Shape.CurveRenderer
                        ShapePath {
                            strokeWidth: 16
                            strokeColor: root.colour(slice.modelData.provider)
                            fillColor: "transparent"
                            capStyle: ShapePath.FlatCap
                            PathAngleArc {
                                centerX: 56; centerY: 56; radiusX: 48; radiusY: 48
                                startAngle: slice.modelData.start
                                sweepAngle: slice.modelData.sweep
                            }
                        }
                    }
                }
                Label {
                    objectName: "quotaSpendAmount"
                    anchors.centerIn: parent
                    text: root.compactMoney(root.total)
                    font.pixelSize: 17
                    font.weight: Font.DemiBold
                    HoverHandler { id: totalHover }
                    QuotaToolTip {
                        visible: totalHover.hovered && root.total !== null
                        text: root.money(root.total || 0)
                        boundsItem: root
                        family: root.family
                    }
                }
            }

            Column {
                Layout.fillWidth: true
                Layout.alignment: Qt.AlignVCenter
                spacing: 10
                Label {
                    visible: root.legend.length === 0
                    width: parent.width
                    text: root.current ? qsTr("No spend recorded") : qsTr("Per-provider spend not loaded yet")
                    wrapMode: Text.WordWrap
                    color: Colours.palette.m3onSurfaceVariant
                }
                Repeater {
                    model: root.legend
                    delegate: RowLayout {
                        id: entry
                        required property var modelData
                        width: parent.width
                        spacing: 8
                        Rectangle {
                            implicitWidth: 9; implicitHeight: 9; radius: 4.5
                            color: root.colour(entry.modelData.provider)
                        }
                        Label {
                            Layout.fillWidth: true
                            Layout.minimumWidth: 0
                            text: root.label(entry.modelData.provider)
                            elide: Text.ElideRight
                        }
                        Label {
                            text: root.money(entry.modelData.cost)
                            color: Colours.palette.m3onSurfaceVariant
                        }
                    }
                }
            }
        }
    }
}
