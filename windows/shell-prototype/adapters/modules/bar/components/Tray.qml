import QtQuick

// Bar statically references these members even with this delegate disabled.
Item {
    readonly property bool available: false
    property bool expanded: false
    readonly property bool autoCollapse: true
    readonly property int padding: 0
    readonly property int spacing: 0
    readonly property alias layout: emptyLayout
    readonly property alias items: emptyItems
    readonly property alias expandIcon: emptyIcon

    visible: false
    width: 0
    height: 0
    implicitWidth: 0
    implicitHeight: 0

    Item { id: emptyLayout }
    Item { id: emptyIcon }
    QtObject {
        id: emptyItems
        readonly property int count: 0
        function itemAt(index: int): Item { return null; }
    }

    Component.onCompleted: console.error("M1: Disabled bar entry Tray was instantiated.")
}
