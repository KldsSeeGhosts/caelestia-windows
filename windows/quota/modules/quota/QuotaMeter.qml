pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// OpenUsage meter: name and pace above a thin bar, remaining and reset below.
Column {
    id: root

    required property var limit
    required property double nowMs
    property string quotaState: "ok"
    property string family: ""
    readonly property var remaining: Logic.remaining(limit)
    readonly property real timeLeft: Logic.timeRemaining(limit, nowMs)
    readonly property var pace: quotaState === "ok" ? Logic.pace(limit, nowMs) : null
    readonly property bool low: remaining !== null && remaining <= 0.15
    readonly property color meterColour: quotaState !== "ok" ? Colours.palette.m3outline
        : low ? Colours.palette.m3error : Colours.palette.m3primary
    readonly property color muted: Colours.palette.m3onSurfaceVariant
    readonly property string label: Logic.title(limit)

    spacing: 6
    Accessible.role: Accessible.StaticText
    Accessible.name: label + ": " + (remaining === null ? qsTr("Not reported") : qsTr("%1% remaining").arg(Math.round(remaining * 100)))

    function duration(resetAt: string): string {
        const reset = Date.parse(resetAt);
        if (!Number.isFinite(reset))
            return qsTr("Reset not reported");
        if (reset <= nowMs)
            return quotaState === "ok" ? qsTr("Refresh pending") : qsTr("Reset since this reading");
        const mins = Math.max(1, Math.floor((reset - nowMs) / 60000));
        const hours = Math.floor(mins / 60);
        if (hours >= 24)
            return qsTr("Resets in %1d %2h").arg(Math.floor(hours / 24)).arg(hours % 24);
        if (hours)
            return qsTr("Resets in %1h %2m").arg(hours).arg(mins % 60);
        return qsTr("Resets in %1m").arg(mins);
    }

    function resetClock(resetAt: string): string {
        const d = new Date(resetAt);
        if (!Number.isFinite(d.getTime()))
            return "";
        return Qt.formatDateTime(d, "ddd") + " " + (d.getHours() % 12 || 12)
            + ":" + String(d.getMinutes()).padStart(2, "0") + (d.getHours() >= 12 ? " PM" : " AM");
    }

    RowLayout {
        width: root.width
        spacing: 8

        StyledText {
            id: meterLabel
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.label
            elide: Text.ElideRight
            font.family: root.family
            font.pixelSize: 14
            font.weight: Font.DemiBold
            HoverHandler { id: labelHover }
            QuotaToolTip {
                visible: labelHover.hovered && meterLabel.truncated
                text: root.label
                boundsItem: root
                family: root.family
            }
        }
        // Like OpenUsage, the pace stays muted; a red flame marks a window that runs out early.
        MaterialIcon {
            visible: !!root.pace && !!root.pace.duration
            Layout.rightMargin: -6
            text: "local_fire_department"
            fill: 1
            color: Colours.palette.m3error
            fontStyle: Tokens.font.icon.size(11).build()
        }
        StyledText {
            visible: !!root.pace
            text: !root.pace ? "" : root.pace.duration ? qsTr("Runs out in ~%1").arg(root.pace.duration)
                : qsTr("~%1% left at reset").arg(root.pace.left)
            color: root.muted
            font.family: root.family
            font.pixelSize: 12
            font.features: ({"tnum": 1})
        }
    }

    Rectangle {
        width: root.width
        height: 6
        radius: 3
        color: Qt.alpha(Colours.palette.m3onSurface, 0.1)

        Rectangle {
            width: root.remaining === null || root.remaining <= 0 ? 0 : Math.max(parent.height, parent.width * root.remaining)
            Behavior on width { Anim {} }
            height: parent.height
            radius: parent.radius
            color: root.meterColour
        }
        // Pace tick: where remaining would sit if usage were spread evenly.
        Rectangle {
            visible: root.timeLeft >= 0 && root.quotaState === "ok"
            x: Math.max(0, Math.min(parent.width - width, parent.width * root.timeLeft - width / 2))
            anchors.verticalCenter: parent.verticalCenter
            width: 2
            height: 12
            radius: 1
            color: Colours.palette.m3onSurface
        }
    }

    RowLayout {
        width: root.width
        spacing: 8
        StyledText {
            text: root.remaining === null ? qsTr("Not reported") : qsTr("%1% left").arg(Math.round(root.remaining * 100))
            color: root.quotaState !== "ok" ? root.muted : root.low ? Colours.palette.m3error : Colours.palette.m3onSurface
            font.family: root.family
            font.pixelSize: 13
            font.features: ({"tnum": 1})
        }
        StyledText {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            horizontalAlignment: Text.AlignRight
            text: root.duration(root.limit.resetsAt || "")
            elide: Text.ElideLeft
            font.family: root.family
            font.pixelSize: 13
            color: root.muted
            font.features: ({"tnum": 1})
        }
    }
    HoverHandler { id: meterHover }
    QuotaToolTip {
        visible: meterHover.hovered && !!root.limit.resetsAt && !labelHover.hovered
        text: qsTr("Resets %1").arg(root.resetClock(root.limit.resetsAt || ""))
        boundsItem: root
        family: root.family
    }
}
