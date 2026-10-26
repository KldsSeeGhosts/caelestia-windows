import QtQuick
import QtQuick.Dialogs as Native
Native.FileDialog {
    property string filterLabel
    property var filters: []
    signal selected(string path)
}
