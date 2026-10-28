import QtQuick
import Quickshell
import Quickshell.Wayland
import qs.components.containers

StyledWindow {
    id: win
    property real indicatorOpacity: 0
    name: "dictation-indicator"
    visible: true
    color: "transparent"
    // A Loader's opacity does not affect a separate native window.
    contentItem.opacity: indicatorOpacity
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.None
    // Windows uses the direct PanelWindow properties.
    exclusionMode: ExclusionMode.Ignore
    focusable: false
    anchors { top: true; bottom: true; left: true; right: true }
    mask: Region { width: 0; height: 0 }

    DictationPill {
        anchors.horizontalCenter: parent.horizontalCenter
        anchors.bottom: parent.bottom
        anchors.bottomMargin: 24
    }
}
