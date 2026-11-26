pragma ComponentBehavior: Bound

import QtQuick
import Caelestia.Config
import qs.components

Item {
    id: root

    required property ScreenState screenState
    required property bool sidebarVisible
    property var focusWindow: null
    readonly property matrix4x4 identityFocusTransform: Qt.matrix4x4(1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1)
    property matrix4x4 focusTransformMatrix: identityFocusTransform
    readonly property real nonAnimWidth: content.implicitWidth

    readonly property bool shouldBeActive: screenState.session && Config.session.enabled
    property real offsetScale: shouldBeActive ? 0 : 1
    property real sidebarOffset: sidebarVisible ? 14 : 0
    readonly property real slideOffset: (-implicitWidth - 5 - sidebarOffset) * offsetScale
    // Keep requesting the companion until the animated exit has finished, but
    // only parent into it while this drawer actually owns the companion.
    readonly property bool usesFocusWindow: focusWindow !== null
        && (shouldBeActive || visible)
    readonly property bool inFocusWindow: usesFocusWindow
        && focusWindow?.surface === "session"

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

    FocusCardProxy {
        id: focusProxy

        focusWindow: root.focusWindow
        sourceItem: root
        focusSurface: "session"
        active: root.inFocusWindow

        Loader {
            id: content

            parent: focusProxy
            x: root.inFocusWindow ? focusProxy.contentOffsetX : 0
            y: (root.inFocusWindow ? focusProxy.contentOffsetY : 0) + Math.max(0, (root.height - height) / 2)
            opacity: root.inFocusWindow ? root.opacity : 1

            active: root.shouldBeActive || root.visible
            transform: Matrix4x4 {
                matrix: root.inFocusWindow ? root.focusTransformMatrix : root.identityFocusTransform
            }

            sourceComponent: Content {
                screenState: root.screenState
            }
        }
    }
}
