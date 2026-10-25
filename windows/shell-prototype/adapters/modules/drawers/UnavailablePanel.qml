import QtQuick

// Geometry and deformation slots read by the original drawer graph.
Item {
    readonly property bool available: false
    readonly property real offsetScale: 1
    property bool hovered: false
    property real horizontalStretch: 1
    property matrix4x4 deformMatrix: Qt.matrix4x4(1, 0, 0, 0,
                                                0, 1, 0, 0,
                                                0, 0, 1, 0,
                                                0, 0, 0, 1)
    readonly property real nonAnimWidth: 0
    readonly property real nonAnimHeight: 0

    visible: false
    width: 0
    height: 0
    implicitWidth: 0
    implicitHeight: 0
}
