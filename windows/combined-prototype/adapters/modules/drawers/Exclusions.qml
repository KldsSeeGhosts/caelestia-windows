pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import qs.components.containers

// Windows stand-in for modules/drawers/Exclusions.qml, staged only by the
// combined prototype. Upstream reserves the bar strip through four Wayland
// layer-shell exclusion windows; the Windows backend instead maps a
// PanelWindow's exclusionMode/exclusiveZone to a native AppBar
// (ABM_NEW/ABM_SETPOS, src/windows/appbar.cpp), so one left-anchored,
// input-transparent window reserves the bar's width and maximized and tiled
// windows stop at it. The host keeps this opt-in: the window is visible only
// while the control window's Full screen is on, and hiding or destroying it
// removes the AppBar and restores the work area.
Scope {
    id: root

    required property ShellScreen screen
    required property int zone
    property bool active: true

    ExclusionZone {
        screen: root.screen
        exclusiveZone: root.zone
        visible: root.active
        anchors.left: true
    }

    component ExclusionZone: StyledWindow {
        name: "combined-bar-reservation"
        exclusionMode: ExclusionMode.Normal
        mask: Region {}
        implicitWidth: 1
        implicitHeight: 1
    }
}
