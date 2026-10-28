import QtQuick
import QtQuick.Window
import Quickshell
import qs.modules.dictation

// Test-only window boundary. Offscreen QPA has no PanelWindow backend.
// Exercises the real pill and Loader animation/lifetime, not native AppBar,
// focus, input masking, placement, mixed-DPI or compositor behaviour.
QtObject {
    id: root
    property ShellScreen screen
    property real indicatorOpacity: 0
    readonly property alias contentItem: surface.contentItem
    readonly property Window surface: Window {
        id: surface
        width: 800
        height: 600
        visible: true
        contentItem.opacity: root.indicatorOpacity
        DictationPill {
            id: pill
            anchors.horizontalCenter: parent.horizontalCenter
            anchors.bottom: parent.bottom
            anchors.bottomMargin: 24
        }
    }
    readonly property alias pillWidth: pill.width
    readonly property alias pillHeight: pill.height
    readonly property alias pill: pill
}
