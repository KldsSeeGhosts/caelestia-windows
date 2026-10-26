import QtQuick
import QtQuick.Controls
BusyIndicator {
    property real implicitSize: 38
    property color color
    property bool animated: true
    property bool containsIcon
    implicitWidth: implicitSize
    implicitHeight: implicitSize
    running: animated
}
