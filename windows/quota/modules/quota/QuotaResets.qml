pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// The "Limit Resets" hover detail, after OpenUsage's RateLimitResetsDetail
// (Views/RateLimitResetsDetail.swift): 250 wide, padded 14. A numbered
// timeline, earliest first: an 18 dp dot in the expiry colour on a 1.5 dp
// rail, the reset's time and its countdown in a 30 dp row. Hovering a row
// swaps its countdown for a small "Use" button.
//
// detail: { count: 3, expiries: ["2026-11-06T18:51:00Z", ...], nowMs }
Item {
    id: root
    objectName: "quotaResets"

    property var detail: null
    property string family: Tokens.font.body.small.family
    readonly property double nowMs: detail?.nowMs ?? Date.now()
    readonly property var entries: Logic.resetEntries(detail?.expiries ?? [], nowMs)
    readonly property int count: Number(detail?.count ?? entries.length) || 0
    // The row under the pointer, which shows "Use" in place of its countdown.
    property int hovered: -1

    // TODO(provider-integrations): claim the reset through the provider that
    // reported it (OpenUsage's ResetClaimService, behind a confirm step). Until
    // that lane lands this does nothing: no reset endpoint is ever called.
    function useReset(entry: var): void {
    }

    function dotColour(severity: string): color {
        return severity === "critical" ? Colours.palette.m3error
            : severity === "warning" ? Colours.palette.m3tertiary : Colours.palette.m3primary;
    }
    function dotText(severity: string): color {
        return severity === "critical" ? Colours.palette.m3onError
            : severity === "warning" ? Colours.palette.m3onTertiary : Colours.palette.m3onPrimary;
    }

    implicitWidth: 250
    implicitHeight: column.implicitHeight + 28

    ColumnLayout {
        id: column
        x: 14
        y: 14
        width: parent.width - 28
        spacing: 8

        // The timeline.
        ColumnLayout {
            objectName: "quotaResetTimeline"
            visible: root.entries.length > 0
            Layout.fillWidth: true
            spacing: 0
            Repeater {
                model: root.entries
                delegate: RowLayout {
                    id: entry
                    required property var modelData
                    required property int index
                    readonly property bool isFirst: index === 0
                    readonly property bool isLast: index === root.entries.length - 1
                    objectName: "quotaResetEntry"
                    Layout.fillWidth: true
                    Layout.preferredHeight: 30
                    spacing: 10
                    Accessible.role: Accessible.StaticText
                    Accessible.name: qsTr("Reset %1, %2").arg(modelData.number).arg(modelData.time)
                        + (modelData.countdown ? qsTr(", expires in %1").arg(modelData.countdown) : "")

                    // The rail runs through the dot, hidden above the first and below the last.
                    Item {
                        Layout.preferredWidth: 18
                        Layout.fillHeight: true
                        Accessible.ignored: true
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            width: 1.5
                            height: parent.height / 2
                            visible: !entry.isFirst
                            color: Qt.alpha(Colours.palette.m3onSurface, 0.12)
                        }
                        Rectangle {
                            anchors.horizontalCenter: parent.horizontalCenter
                            y: parent.height / 2
                            width: 1.5
                            height: parent.height / 2
                            visible: !entry.isLast
                            color: Qt.alpha(Colours.palette.m3onSurface, 0.12)
                        }
                        Rectangle {
                            objectName: "quotaResetDot"
                            anchors.centerIn: parent
                            width: 18
                            height: 18
                            radius: 9
                            color: root.dotColour(entry.modelData.severity)
                            StyledText {
                                anchors.centerIn: parent
                                text: entry.modelData.number
                                color: root.dotText(entry.modelData.severity)
                                font.family: root.family
                                font.pixelSize: 11
                                font.weight: Font.Medium
                            }
                        }
                    }
                    StyledText {
                        Layout.fillWidth: true
                        text: entry.modelData.time
                        elide: Text.ElideRight
                        color: Colours.palette.m3onSurface
                        font.family: root.family
                        font.pixelSize: 13
                    }
                    Item {
                        Layout.preferredWidth: Math.max(use.implicitWidth, countdown.implicitWidth)
                        Layout.preferredHeight: 30
                        StyledText {
                            id: countdown
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: !use.visible
                            text: entry.modelData.countdown
                            color: Colours.palette.m3onSurfaceVariant
                            font.family: root.family
                            font.pixelSize: 13
                            font.features: ({"tnum": 1})
                        }
                        AbstractButton {
                            id: use
                            objectName: "quotaResetUse"
                            anchors.right: parent.right
                            anchors.verticalCenter: parent.verticalCenter
                            visible: root.hovered === entry.index
                            implicitWidth: useText.implicitWidth + 20
                            implicitHeight: 20
                            hoverEnabled: true
                            onClicked: root.useReset(entry.modelData)
                            Accessible.name: qsTr("Use reset %1").arg(entry.modelData.number)
                            background: Rectangle {
                                radius: 6
                                color: use.down ? Colours.palette.m3surfaceContainerHighest : Colours.palette.m3surfaceContainerHigh
                            }
                            contentItem: StyledText {
                                id: useText
                                horizontalAlignment: Text.AlignHCenter
                                verticalAlignment: Text.AlignVCenter
                                text: qsTr("Use")
                                color: Colours.palette.m3onSurface
                                font.family: root.family
                                font.pixelSize: 13
                            }
                        }
                    }
                    HoverHandler {
                        onHoveredChanged: {
                            if (hovered)
                                root.hovered = entry.index;
                            else if (root.hovered === entry.index)
                                root.hovered = -1;
                        }
                    }
                }
            }
        }

        // A count with no expiry times, or nothing at all.
        ColumnLayout {
            objectName: "quotaResetEmpty"
            visible: root.entries.length === 0
            Layout.fillWidth: true
            Layout.topMargin: 8
            Layout.bottomMargin: 8
            spacing: 8
            MaterialIcon {
                Layout.alignment: Qt.AlignHCenter
                text: root.count > 0 ? "schedule" : "timer_off"
                color: Colours.palette.m3onSurfaceVariant
                fontStyle: Tokens.font.icon.small
            }
            StyledText {
                Layout.alignment: Qt.AlignHCenter
                text: root.count > 0 ? qsTr("%1 available").arg(root.count) : qsTr("You have no rate limit resets")
                color: root.count > 0 ? Colours.palette.m3onSurface : Colours.palette.m3onSurfaceVariant
                font.family: root.family
                font.pixelSize: 13
            }
            StyledText {
                visible: root.count > 0
                Layout.alignment: Qt.AlignHCenter
                text: qsTr("Expiry times unavailable")
                color: Colours.palette.m3onSurfaceVariant
                font.family: root.family
                font.pixelSize: 11
            }
        }
    }
}
