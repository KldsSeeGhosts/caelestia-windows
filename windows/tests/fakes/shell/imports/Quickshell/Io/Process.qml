import QtQuick
QtObject {
    property var command: []
    property bool running: false
    property QtObject stdout
    property QtObject stderr
    signal exited(int code)
    function signal(number): void { running = false; }
}
