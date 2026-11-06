pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// One window as an OpenUsage metric row (Views/DashboardMetricRow.swift): a
// 22 dp row of label (12), bar, value (12, secondary unless it warns) and
// reset (11), on the columns `grid` gives every row so they line up.
RowLayout {
    id: root
    objectName: "quotaMeter"

    required property var limit
    required property double nowMs
    // { label, bar, value, reset, gap } in dp, from QuotaLogic.grid.
    required property var grid
    property string provider: ""
    property string family: ""
    readonly property var remaining: Logic.remaining(limit)
    readonly property string label: Logic.title(limit)
    readonly property string reset: Logic.resetShort(limit.resetsAt, nowMs)
    readonly property string severity: Logic.severity(remaining)
    readonly property bool usedUp: Logic.isUsedUp(remaining)

    implicitHeight: 22
    height: 22
    spacing: grid.gap
    // A used-up window with nothing left to draw fades (Models/DashboardRowModel.swift).
    opacity: usedUp ? 0.5 : 1
    Accessible.role: Accessible.StaticText
    Accessible.name: [provider, label,
        remaining === null ? qsTr("not reported") : qsTr("%1 percent left").arg(Math.round(remaining * 100)),
        reset ? qsTr("resets in %1").arg(Logic.resetSpoken(limit.resetsAt, nowMs)) : ""].filter(s => s).join(", ")

    function severityText(level: string): color {
        return level === "critical" ? Colours.palette.m3error
            : level === "warning" ? Colours.palette.m3tertiary : Colours.palette.m3onSurfaceVariant;
    }
    // The other reading of the reset, as OpenUsage's tooltip gives it: a clock
    // time today, a weekday and hour within a week, else the date.
    function resetClock(resetAt: string): string {
        const d = new Date(resetAt);
        if (!Number.isFinite(d.getTime()))
            return "";
        const now = new Date(root.nowMs);
        const days = Math.round((new Date(d.getFullYear(), d.getMonth(), d.getDate()) - new Date(now.getFullYear(), now.getMonth(), now.getDate())) / 86400000);
        if (days <= 0)
            return Qt.formatTime(d, "h:mm AP");
        if (days < 7)
            return Qt.formatDateTime(d, "ddd h AP");
        return Qt.formatDate(d, "MMM d");
    }

    StyledText {
        id: meterLabel
        objectName: "quotaMeterLabel"
        Layout.preferredWidth: root.grid.label
        Layout.maximumWidth: root.grid.label
        text: root.label
        elide: Text.ElideRight
        color: Colours.palette.m3onSurface
        font.family: root.family
        font.pixelSize: 12
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
        Layout.fillWidth: true
        Layout.preferredWidth: root.grid.bar
        Layout.alignment: Qt.AlignVCenter
        fraction: root.remaining
        severity: root.severity
    }
    // OpenUsage in its default remaining mode ("Left"): the bar and the figure
    // show what is left; hovering the figure gives the other reading, "N% used".
    StyledText {
        id: valueText
        objectName: "quotaMeterLeft"
        HoverHandler { id: valueHover }
        QuotaToolTip {
            visible: valueHover.hovered && root.remaining !== null
            text: qsTr("%1% used").arg(100 - Math.round(root.remaining * 100))
            boundsItem: root
            family: root.family
        }
        Layout.preferredWidth: root.grid.value
        horizontalAlignment: Text.AlignRight
        text: root.remaining === null ? "—" : Math.round(root.remaining * 100) + "%"
        color: root.severityText(root.severity)
        font.family: root.family
        font.pixelSize: 12
        font.features: ({"tnum": 1})
    }
    StyledText {
        objectName: "quotaMeterReset"
        Layout.preferredWidth: root.grid.reset
        horizontalAlignment: Text.AlignRight
        text: root.reset
        color: root.severityText(root.usedUp ? "critical" : "normal")
        elide: Text.ElideRight
        font.family: root.family
        font.pixelSize: 11
        font.features: ({"tnum": 1})
    }
    HoverHandler { id: meterHover }
    QuotaToolTip {
        visible: meterHover.hovered && root.reset !== "" && root.reset !== "soon" && !labelHover.hovered && !valueHover.hovered
        text: root.resetClock(root.limit.resetsAt || "")
        boundsItem: root
        family: root.family
    }
}
