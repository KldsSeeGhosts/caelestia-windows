pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components

Item {
    id: root

    required property ScreenState screenState
    required property bool sidebarVisible
    property var focusWindow: null
    readonly property real nonAnimWidth: content.implicitWidth

    readonly property bool shouldBeActive: screenState.session && Config.session.enabled
    property real offsetScale: shouldBeActive ? 0 : 1
    property real sidebarOffset: sidebarVisible ? 14 : 0
    readonly property real slideOffset: (-implicitWidth - 5 - sidebarOffset) * offsetScale
    // Keep the loader in the companion until the animated exit has finished.
    // The companion follows this wrapper's slide offset through its geometry.
    readonly property bool usesFocusWindow: focusWindow !== null
        && (shouldBeActive || visible)

    visible: offsetScale < 1
    anchors.rightMargin: slideOffset
    implicitWidth: content.implicitWidth
    implicitHeight: content.implicitHeight || 510 // Hard coded fallback for first open
    width: implicitWidth
    height: implicitHeight
    opacity: 1 - offsetScale

    Behavior on offsetScale {
        Anim {}
    }

    Loader {
        id: content

        parent: root.usesFocusWindow ? root.focusWindow.contentHost : root
        anchors.verticalCenter: parent.verticalCenter
        anchors.left: parent.left
        opacity: root.usesFocusWindow ? root.opacity : 1
        z: root.usesFocusWindow ? 1 : 0

        active: root.shouldBeActive || root.visible

        sourceComponent: Content {
            screenState: root.screenState
        }
    }
}
