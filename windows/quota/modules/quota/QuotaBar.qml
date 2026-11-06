import QtQuick
import Caelestia.Config
import qs.components
import qs.services

// OpenUsage's level bar (Views/LevelIndicator.swift): a 9 dp slot holding an
// 8 dp capsule, its track the meter-track tint and its fill the severity
// colour, never shorter than 4 dp once anything is used.
Item {
    id: root

    // 0..1 to draw, or null when CPA reported nothing.
    property var fraction: null
    property string severity: "normal"

    implicitHeight: 9

    Rectangle {
        id: track
        anchors.verticalCenter: parent.verticalCenter
        width: parent.width
        height: 8
        radius: height / 2
        color: Qt.alpha(Colours.palette.m3onSurface, Colours.light ? 0.09 : 0.12)

        Rectangle {
            objectName: "quotaBarFill"
            width: root.fraction === null || root.fraction <= 0 ? 0 : Math.max(4, Math.round(track.width * Math.min(1, root.fraction)))
            height: parent.height
            radius: parent.radius
            color: root.severity === "critical" ? Colours.palette.m3error
                : root.severity === "warning" ? Colours.palette.m3tertiary : Colours.palette.m3primary
        }
    }
}
