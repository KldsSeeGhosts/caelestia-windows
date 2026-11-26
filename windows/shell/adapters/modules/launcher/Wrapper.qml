pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.modules.launcher.services

Item {
    id: root

    required property ShellScreen screen
    required property ScreenState screenState
    required property var panels
    property var focusWindow: null
    readonly property matrix4x4 identityFocusTransform: Qt.matrix4x4(1, 0, 0, 0,
        0, 1, 0, 0,
        0, 0, 1, 0,
        0, 0, 0, 1)
    property matrix4x4 focusTransformMatrix: identityFocusTransform

    readonly property bool shouldBeActive: screenState.launcher && Config.launcher.enabled
    readonly property bool usesFocusWindow: focusWindow?.surface === "launcher"

    readonly property real maxHeight: {
        let max = Math.min(screen.height, panels.height) - Config.border.thickness * 2 + Tokens.padding.extraLarge;
        if (screenState.dashboard)
            max -= panels.dashboard.nonAnimHeight;
        return max;
    }

    property real offsetScale: shouldBeActive ? 0 : 1

    onShouldBeActiveChanged: {
        if (shouldBeActive)
            implicitHeight = Qt.binding(() => content.implicitHeight);
        else
            implicitHeight = implicitHeight; // Break binding during close anim
    }

    visible: offsetScale < 1
    anchors.bottomMargin: (-implicitHeight - 5) * offsetScale
    implicitHeight: content.implicitHeight
    implicitWidth: content.implicitWidth || 630 // Hard coded fallback for first open
    width: implicitWidth
    height: implicitHeight
    opacity: 1 - offsetScale

    Component.onCompleted: Qt.callLater(() => Apps) // Load apps on init

    Behavior on offsetScale {
        Anim {}
    }

    FocusCardProxy {
        id: focusProxy

        focusWindow: root.focusWindow
        sourceItem: root
        focusSurface: "launcher"
        active: root.usesFocusWindow

        Loader {
            id: content

            parent: focusProxy
            anchors.top: parent.top
            anchors.horizontalCenter: parent.horizontalCenter
            opacity: root.usesFocusWindow ? root.opacity : 1

            active: root.shouldBeActive || root.visible
            transform: Matrix4x4 {
                matrix: root.usesFocusWindow ? root.focusTransformMatrix : root.identityFocusTransform
            }

            sourceComponent: Content {
                screenState: root.screenState
                panels: root.panels
                maxHeight: root.maxHeight
            }
        }
    }
}
