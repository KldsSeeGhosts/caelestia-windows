import QtQuick

// A static type required by Bar's disabled delegate branch.
Item {
    readonly property bool available: false
    visible: false
    width: 0
    height: 0
    implicitWidth: 0
    implicitHeight: 0
    Component.onCompleted: console.error("M1: Disabled bar entry OsIcon was instantiated.")
}
