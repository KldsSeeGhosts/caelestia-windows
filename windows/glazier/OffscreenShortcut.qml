import QtQuick

// Test replacement: never registers a Windows hotkey.
QtObject {
    property string name
    property string description
    signal pressed()
    signal released()
}
