pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Shapes
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// One Priority limit as OpenUsage draws it (Views/PriorityDashboardView.swift,
// `limitRow`): a 46 dp row with a 32 dp ring gauge around the provider mark,
// the window (13 medium) over the account (11, muted), and on the right the
// amount (13 medium) over the reset (11, muted).
RowLayout {
    id: root
    objectName: "quotaPriorityRow"

    required property var entry
    required property double nowMs
    property url logo
    property string providerLabel: ""
    property string accountLabel: ""
    property string family: ""
    readonly property var limit: entry.limit
    readonly property var remaining: entry.remaining
    readonly property string reset: Logic.resetShort(limit.resetsAt, nowMs)

    implicitHeight: 46
    height: 46
    spacing: 10
    Accessible.role: Accessible.StaticText
    Accessible.name: [providerLabel, accountLabel, Logic.title(limit), qsTr("%1 percent left").arg(Math.round(remaining * 100)),
        reset ? qsTr("resets in %1").arg(Logic.resetSpoken(limit.resetsAt, nowMs)) : ""].filter(s => s).join(", ")

    // PriorityGauge: a 3 dp ring, the track all round, the fill from 12 o'clock
    // with round caps, the provider mark (16) in the middle.
    Item {
        objectName: "quotaGauge"
        Layout.preferredWidth: 32
        Layout.preferredHeight: 32
        Accessible.ignored: true

        Shape {
            anchors.fill: parent
            ShapePath {
                fillColor: "transparent"
                strokeColor: Qt.alpha(Colours.palette.m3onSurface, Colours.light ? 0.09 : 0.12)
                strokeWidth: 3
                PathAngleArc {
                    centerX: 16
                    centerY: 16
                    radiusX: 14.5
                    radiusY: 14.5
                    startAngle: 0
                    sweepAngle: 360
                }
            }
            ShapePath {
                fillColor: "transparent"
                strokeColor: root.entry.severity === "critical" ? Colours.palette.m3error
                    : root.entry.severity === "warning" ? Colours.palette.m3tertiary : Colours.palette.m3primary
                strokeWidth: root.remaining > 0 ? 3 : 0
                capStyle: ShapePath.RoundCap
                PathAngleArc {
                    centerX: 16
                    centerY: 16
                    radiusX: 14.5
                    radiusY: 14.5
                    startAngle: -90
                    sweepAngle: 360 * Math.max(0, Math.min(1, root.remaining))
                }
            }
        }
        QuotaLogo {
            anchors.centerIn: parent
            implicitWidth: 16
            implicitHeight: 16
            source: root.logo
            fallback: root.providerLabel
        }
    }
    ColumnLayout {
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        spacing: 1
        StyledText {
            objectName: "quotaPriorityTitle"
            Layout.fillWidth: true
            text: Logic.title(root.limit)
            elide: Text.ElideRight
            color: Colours.palette.m3onSurface
            font.family: root.family
            font.pixelSize: 13
            font.weight: Font.Medium
        }
        StyledText {
            objectName: "quotaPriorityAccount"
            Layout.fillWidth: true
            text: root.accountLabel
            elide: Text.ElideMiddle
            color: Colours.palette.m3onSurfaceVariant
            font.family: root.family
            font.pixelSize: 11
        }
    }
    ColumnLayout {
        spacing: 1
        StyledText {
            objectName: "quotaMeterLeft"
            Layout.alignment: Qt.AlignRight
            text: qsTr("%1% left").arg(Math.round(root.remaining * 100))
            color: Colours.palette.m3onSurface
            font.family: root.family
            font.pixelSize: 13
            font.weight: Font.Medium
            font.features: ({"tnum": 1})
        }
        StyledText {
            objectName: "quotaMeterReset"
            Layout.alignment: Qt.AlignRight
            visible: root.reset !== ""
            text: root.reset
            color: Colours.palette.m3onSurfaceVariant
            font.family: root.family
            font.pixelSize: 11
            font.features: ({"tnum": 1})
        }
    }
}
