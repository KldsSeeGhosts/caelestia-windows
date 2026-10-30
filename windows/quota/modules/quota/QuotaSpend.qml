pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services

// Spend is secondary to the provider limits above it: one quiet row (range and
// total) that opens into the range tabs and a per-provider breakdown. It starts
// collapsed on Today whenever the drawer opens; nothing is persisted.
Rectangle {
    id: root
    objectName: "quotaSpend"

    required property string family
    property bool expanded: false
    property string range: "today"
    readonly property var ranges: [
        { key: "today", label: qsTr("Today") },
        { key: "yesterday", label: qsTr("Yesterday") },
        { key: "month", label: qsTr("30 Days") }
    ]
    readonly property var current: Quota.spend[range] || null
    readonly property string rangeLabel: ranges[Math.max(0, ranges.findIndex(r => r.key === range))].label
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
    readonly property real legendSum: legend.reduce((sum, row) => sum + row.cost, 0)

    function reset(): void {
        root.expanded = false;
        root.range = "today";
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

    implicitHeight: body.implicitHeight
    radius: 14
    color: Qt.alpha(Colours.palette.m3onSurface, 0.05)

    component Label: StyledText {
        font.family: root.family
        font.pixelSize: 13
        font.features: ({"tnum": 1})
    }

    Column {
        id: body
        width: parent.width

        AbstractButton {
            id: header
            objectName: "quotaSpendToggle"
            width: parent.width
            height: 40
            hoverEnabled: true
            onClicked: root.expanded = !root.expanded
            Accessible.name: qsTr("Spend, %1, %2, %3").arg(root.rangeLabel).arg(root.compactMoney(root.total))
                .arg(root.expanded ? qsTr("expanded") : qsTr("collapsed"))
            background: Rectangle {
                radius: root.radius
                color: header.hovered || header.down ? Qt.alpha(Colours.palette.m3onSurface, header.down ? 0.08 : 0.04) : "transparent"
                border.width: header.activeFocus ? 1 : 0
                border.color: Colours.palette.m3primary
            }
            contentItem: RowLayout {
                spacing: 8
                Label {
                    Layout.leftMargin: 14
                    text: qsTr("Spend")
                    font.weight: Font.DemiBold
                }
                Label {
                    text: root.rangeLabel
                    color: Colours.palette.m3onSurfaceVariant
                }
                Item { Layout.fillWidth: true }
                Label {
                    objectName: "quotaSpendAmount"
                    text: root.compactMoney(root.total)
                    font.weight: Font.DemiBold
                    HoverHandler { id: totalHover }
                    QuotaToolTip {
                        visible: totalHover.hovered && root.total !== null
                        text: root.money(root.total || 0)
                        boundsItem: root
                        family: root.family
                    }
                }
                MaterialIcon {
                    Layout.rightMargin: 10
                    text: "expand_more"
                    color: Colours.palette.m3onSurfaceVariant
                    fontStyle: Tokens.font.icon.size(16).build()
                    rotation: root.expanded ? 180 : 0
                    Behavior on rotation { Anim {} }
                }
            }
        }

        Column {
            id: details
            objectName: "quotaSpendDetails"
            visible: root.expanded
            x: 14
            width: parent.width - 28
            spacing: 12
            bottomPadding: 14

            Rectangle {
                id: tabs
                readonly property real segment: (width - 6) / root.ranges.length
                readonly property int index: Math.max(0, root.ranges.findIndex(r => r.key === root.range))
                width: parent.width
                height: 30
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
                            objectName: "quotaSpendRange"
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
                                elide: Text.ElideRight
                                font.weight: tab.selected ? Font.DemiBold : Font.Medium
                                color: tab.selected || tab.hovered ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                            }
                        }
                    }
                }
            }

            Label {
                visible: root.legend.length === 0
                width: parent.width
                text: root.current ? qsTr("No spend recorded") : qsTr("Per-provider spend not loaded yet")
                wrapMode: Text.WordWrap
                color: Colours.palette.m3onSurfaceVariant
            }

            Repeater {
                model: root.legend
                delegate: Column {
                    id: entry
                    required property var modelData
                    readonly property real share: root.legendSum > 0 ? entry.modelData.cost / root.legendSum : 0
                    width: details.width
                    spacing: 5
                    RowLayout {
                        width: parent.width
                        spacing: 8
                        Rectangle {
                            implicitWidth: 8; implicitHeight: 8; radius: 4
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
                    Rectangle {
                        width: parent.width
                        height: 3
                        radius: 1.5
                        color: Qt.alpha(Colours.palette.m3onSurface, 0.08)
                        Rectangle {
                            width: entry.share > 0 ? Math.max(parent.height, parent.width * entry.share) : 0
                            height: parent.height
                            radius: parent.radius
                            color: root.colour(entry.modelData.provider)
                            Behavior on width { Anim {} }
                        }
                    }
                }
            }

            Label {
                width: parent.width
                text: qsTr("API-equivalent cost from CPA Manager's usage analytics.")
                wrapMode: Text.WordWrap
                color: Colours.palette.m3onSurfaceVariant
                font.pixelSize: 11
            }
        }
    }
}
