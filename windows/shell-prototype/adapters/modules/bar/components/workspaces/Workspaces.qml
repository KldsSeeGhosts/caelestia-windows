import QtQuick
import Quickshell

// A static type required by Bar's disabled delegate branch.
Item {
    required property ShellScreen screen
    required property bool fullscreen
    readonly property bool available: false
    visible: false
    width: 0
    height: 0
    implicitWidth: 0
    implicitHeight: 0
    Component.onCompleted: console.error("M1: Disabled bar entry Workspaces was instantiated.")
}
