import QtQuick
QtObject {
    property var command: []
    property bool running: false
    property bool stdinEnabled: false
    property var environment: ({})
    property var writes: []
    property QtObject stdout
    property QtObject stderr
    signal started()
    signal exited(int code)
    onRunningChanged: { if (running) started(); }
    function write(data: string): void { writes.push(data); }
    function signal(number): void { running = false; }
}
