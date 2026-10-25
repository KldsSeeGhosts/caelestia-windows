import QtQuick

// Bar statically references the icon container for its disabled popouts.
Item {
    readonly property bool available: false
    readonly property alias items: emptyItems
    visible: false
    width: 0
    height: 0
    implicitWidth: 0
    implicitHeight: 0

    Item { id: emptyItems }

    Component.onCompleted: console.error("M1: Disabled bar entry StatusIcons was instantiated.")
}
