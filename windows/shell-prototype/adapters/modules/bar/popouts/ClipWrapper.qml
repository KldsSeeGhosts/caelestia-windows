import QtQuick
import Quickshell
import qs.modules.bar.popouts

Item {
    id: root

    required property ShellScreen screen
    required property real borderThickness
    readonly property bool available: false
    readonly property alias content: content
    readonly property real offsetScale: 1

    visible: false
    width: 0
    height: 0
    implicitWidth: 0
    implicitHeight: 0

    Wrapper {
        id: content
        screen: root.screen
        offsetScale: root.offsetScale
    }
}
