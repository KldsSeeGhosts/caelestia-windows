pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components.containers

// Windows stand-in for modules/drawers/Exclusions.qml, staged only by the
// combined and installed shell. Preserve upstream's four per-edge exclusions:
// the left edge reserves the bar, the other edges reserve the border. Each
// PanelWindow maps to the existing tracked native AppBar registration, including
// normal removal and watchdog/stale-registration recovery after a crash.
// Fullscreen hides the visible frame separately. Keeping the empty AppBars
// registered avoids changing the Windows work area while applications save
// and restore their window placement. Their z-order is native: the panel stack
// drops Top-layer panels below a fullscreen application on ABN_FULLSCREENAPP
// and raises them again on exit, so these windows must stay visible here;
// hiding them would remove the reservation instead of only lowering it.
Scope {
    id: root

    required property ShellScreen screen
    required property int zone
    property bool active: true
    property bool fullscreen: false
    // Optional deterministic border reservation for the isolated frame
    // fixture. The staged shell keeps the configured border thickness.
    property int borderZone: -1

    ExclusionZone {
        exclusiveZone: root.zone
        anchors.left: true
    }

    ExclusionZone { anchors.top: true }
    ExclusionZone { anchors.right: true }
    ExclusionZone { anchors.bottom: true }

    component ExclusionZone: StyledWindow {
        screen: root.screen
        name: "border-exclusion"
        exclusiveZone: root.borderZone >= 0
            ? root.borderZone : contentItem.Config.border.thickness
        visible: root.active
        exclusionMode: ExclusionMode.Normal
        mask: Region {}
        implicitWidth: 1
        implicitHeight: 1
    }
}
