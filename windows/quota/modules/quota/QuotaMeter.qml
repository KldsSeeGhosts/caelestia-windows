pragma ComponentBehavior: Bound

import QtQuick
import QtQuick.Layouts
import QtQuick.Controls
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

Column {
    id: root

    required property var limit
    required property double nowMs
    property string quotaState: "ok"
    property bool compact: false
    property string family: ""
    readonly property var remaining: Logic.remaining(limit)
    readonly property real timeLeft: Logic.timeRemaining(limit, nowMs)
    readonly property var pace: quotaState === "ok" ? Logic.pace(limit, nowMs) : null
    readonly property color meterColour: quotaState !== "ok" ? Colours.palette.m3outline
        : remaining !== null && remaining <= 0.15 ? Colours.palette.m3error
        : Logic.windowCategory(Logic.windowKey(limit)) === "primary" ? Colours.palette.m3primary
        : Logic.windowCategory(Logic.windowKey(limit)) === "tertiary" ? Colours.palette.m3tertiary : Colours.palette.m3secondary
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
            font.pixelSize: root.compact ? 12 : 13
            HoverHandler { id: labelHover }
            QuotaToolTip {
                visible: labelHover.hovered && meterLabel.truncated
                text: root.label
                boundsItem: root
                family: root.family
            }
        }
        StyledText {
            text: root.remaining === null ? "—" : qsTr("%1% left").arg(Math.round(root.remaining * 100))
            color: root.meterColour
            font.family: root.family
            font.pixelSize: root.compact ? 12 : 13
            font.weight: Font.DemiBold
            font.features: ({"tnum": 1})
        }
    }

    Rectangle {
        width: root.width
        height: root.compact ? 4 : 6
        radius: height / 2
        color: Qt.alpha(Colours.palette.m3onSurface, 0.09)

        Rectangle {
            width: root.remaining === null || root.remaining <= 0 ? 0 : Math.max(parent.height, parent.width * root.remaining)
            Behavior on width { Anim {} }
            height: parent.height
            radius: parent.radius
            color: root.meterColour
        }
        Rectangle {
            visible: root.timeLeft >= 0 && root.quotaState === "ok"
            x: Math.max(0, Math.min(parent.width - width, parent.width * root.timeLeft))
            anchors.verticalCenter: parent.verticalCenter
            width: 2
            height: root.compact ? 9 : 12
            radius: 1
            color: Qt.alpha(Colours.palette.m3onSurface, 0.5)
        }
    }

    RowLayout {
        width: root.width
        spacing: 8
        StyledText {
            Layout.fillWidth: true
            Layout.minimumWidth: 0
            text: root.duration(root.limit.resetsAt || "")
            elide: Text.ElideRight
            font.family: root.family
            font.pixelSize: 11
            color: Qt.alpha(Colours.palette.m3onSurfaceVariant, 0.7)
            font.features: ({"tnum": 1})
        }
        StyledText {
            visible: !!root.limit.resetsAt
            text: root.pace ? (root.pace.duration ? qsTr("Runs out in about %1").arg(root.pace.duration)
                : qsTr("About %1% left at reset").arg(root.pace.left)) : root.resetClock(root.limit.resetsAt || "")
            font.family: root.family
            font.pixelSize: 11
            color: root.pace && root.pace.duration ? Colours.palette.m3error : Qt.alpha(Colours.palette.m3onSurfaceVariant, 0.7)
            font.features: ({"tnum": 1})
        }
    }
    HoverHandler { id: meterHover }
    QuotaToolTip {
        visible: meterHover.hovered && !!root.pace && !!root.limit.resetsAt
        text: qsTr("Resets %1").arg(root.resetClock(root.limit.resetsAt || ""))
        boundsItem: root
        family: root.family
    }
}
