pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// One Priority entry: the account that runs out, with its provider mark, above
// a bar that shares the % and reset columns of every other entry. Two lines,
// because a label column narrow enough for the grid could not name an account.
ColumnLayout {
    id: root
    objectName: "quotaPriorityRow"

    required property var entry
    required property double nowMs
    // { bar, pct, reset, gap } in dp, from Content.
    required property var grid
    property url logo
    property string providerLabel: ""
    property string accountLabel: ""
    property string family: ""
    readonly property var limit: entry.limit
    readonly property var remaining: entry.remaining
    readonly property string reset: Logic.resetShort(limit.resetsAt, nowMs)

    spacing: 6
    Accessible.role: Accessible.StaticText
    Accessible.name: [providerLabel, accountLabel, Logic.title(limit), qsTr("%1 percent left").arg(Math.round(remaining * 100)),
        reset ? qsTr("resets in %1").arg(Logic.resetSpoken(limit.resetsAt, nowMs)) : ""].filter(s => s).join(", ")

    RowLayout {
        Layout.fillWidth: true
        spacing: root.grid.gap
        QuotaLogo {
            implicitWidth: 16
            implicitHeight: 16
            source: root.logo
            fallback: root.providerLabel
        }
        StyledText {
            objectName: "quotaPriorityAccount"
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.accountLabel
            elide: Text.ElideRight
            font.family: root.family
            font.pixelSize: 13
            font.weight: Font.DemiBold
        }
        StyledText {
            Layout.maximumWidth: root.width * 0.5
            text: Logic.title(root.limit)
            elide: Text.ElideRight
            color: Colours.palette.m3onSurfaceVariant
            font.family: root.family
            font.pixelSize: 12
        }
    }
    RowLayout {
        Layout.fillWidth: true
        spacing: root.grid.gap
        QuotaBar {
            objectName: "quotaBar"
            Layout.fillWidth: true
            fraction: root.remaining
        }
        StyledText {
            objectName: "quotaMeterLeft"
            Layout.preferredWidth: root.grid.pct
            horizontalAlignment: Text.AlignRight
            text: Math.round(root.remaining * 100) + "%"
            color: Logic.isLow(root.remaining) ? Colours.palette.m3error : Colours.palette.m3onSurface
            font.family: root.family
            font.pixelSize: 13
            font.features: ({"tnum": 1})
        }
        StyledText {
            Layout.preferredWidth: root.grid.reset
            horizontalAlignment: Text.AlignRight
            text: root.reset
            color: Colours.palette.m3onSurfaceVariant
            elide: Text.ElideRight
            font.family: root.family
            font.pixelSize: 13
            font.features: ({"tnum": 1})
        }
    }
}
