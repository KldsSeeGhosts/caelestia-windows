pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// One window on the drawer grid: label, bar, % left, reset. Every row takes its
// column widths from the same `grid`, so the columns line up down the whole
// drawer.
RowLayout {
    id: root
    objectName: "quotaMeter"

    required property var limit
    required property double nowMs
    // { bar, pct, reset, gap } in dp, from Content.
    required property var grid
    property string provider: ""
    property string family: ""
    readonly property var remaining: Logic.remaining(limit)
    readonly property string label: Logic.title(limit)
    readonly property string reset: Logic.resetShort(limit.resetsAt, nowMs)
    readonly property color muted: Colours.palette.m3onSurfaceVariant

    spacing: grid.gap
    Accessible.role: Accessible.StaticText
    Accessible.name: [provider, label,
        remaining === null ? qsTr("not reported") : qsTr("%1 percent left").arg(Math.round(remaining * 100)),
        reset ? qsTr("resets in %1").arg(Logic.resetSpoken(limit.resetsAt, nowMs)) : ""].filter(s => s).join(", ")

    function resetClock(resetAt: string): string {
        const d = new Date(resetAt);
        if (!Number.isFinite(d.getTime()))
            return "";
        return Qt.formatDateTime(d, "ddd") + " " + (d.getHours() % 12 || 12)
            + ":" + String(d.getMinutes()).padStart(2, "0") + (d.getHours() >= 12 ? " PM" : " AM");
    }

    StyledText {
        id: meterLabel
        objectName: "quotaMeterLabel"
        Layout.fillWidth: true
        Layout.minimumWidth: 0
        text: root.label
        elide: Text.ElideRight
        font.family: root.family
        font.pixelSize: 13
        HoverHandler { id: labelHover }
        QuotaToolTip {
            visible: labelHover.hovered && meterLabel.truncated
            text: root.label
            boundsItem: root
            family: root.family
        }
    }
    QuotaBar {
        objectName: "quotaBar"
        Layout.preferredWidth: root.grid.bar
        Layout.alignment: Qt.AlignVCenter
        fraction: root.remaining
    }
    StyledText {
        objectName: "quotaMeterLeft"
        Layout.preferredWidth: root.grid.pct
        horizontalAlignment: Text.AlignRight
        text: root.remaining === null ? "—" : Math.round(root.remaining * 100) + "%"
        color: Logic.isLow(root.remaining) ? Colours.palette.m3error : Colours.palette.m3onSurface
        font.family: root.family
        font.pixelSize: 13
        font.features: ({"tnum": 1})
    }
    StyledText {
        objectName: "quotaMeterReset"
        Layout.preferredWidth: root.grid.reset
        horizontalAlignment: Text.AlignRight
        text: root.reset
        color: root.muted
        elide: Text.ElideRight
        font.family: root.family
        font.pixelSize: 13
        font.features: ({"tnum": 1})
    }
    HoverHandler { id: meterHover }
    QuotaToolTip {
        visible: meterHover.hovered && !!root.limit.resetsAt && !labelHover.hovered
        text: qsTr("Resets %1").arg(root.resetClock(root.limit.resetsAt || ""))
        boundsItem: root
        family: root.family
    }
}
