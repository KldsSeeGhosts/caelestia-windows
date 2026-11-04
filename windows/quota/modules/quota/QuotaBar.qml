import QtQuick
import Caelestia.Config
import qs.components
import qs.services
import "QuotaLogic.js" as Logic

// The share of a window still left: a thick, fully rounded track with a fill
// that turns to the error colour when it is nearly spent.
Rectangle {
    id: root

    // 0..1, or null when CPA reported nothing.
    property var fraction: null

    implicitHeight: 8
    radius: height / 2
    color: Colours.palette.m3surfaceContainerHighest

    Rectangle {
        objectName: "quotaBarFill"
        width: root.fraction === null || root.fraction <= 0 ? 0 : Math.max(parent.height, parent.width * root.fraction)
        height: parent.height
        radius: parent.radius
        color: Logic.isLow(root.fraction) ? Colours.palette.m3error : Colours.palette.m3primary

        Behavior on width {
            Anim {}
        }
    }
}
