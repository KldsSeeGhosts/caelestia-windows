import QtQuick
import Quickshell

// Nonvisual boundary for all disabled bar popouts.
Item {
    required property ShellScreen screen
    property real offsetScale: 1
    readonly property bool available: false
    property string currentName: ""
    property bool hasCurrent: false
    property real currentCenter: 0
    readonly property Item current: null
    readonly property bool isDetached: false
    readonly property string detachedMode: ""
    readonly property real nonAnimWidth: 0
    readonly property real nonAnimHeight: 0

    visible: false
    width: 0
    height: 0
    implicitWidth: 0
    implicitHeight: 0

    function close(): void {
        hasCurrent = false;
        currentName = "";
    }
}
