import QtQuick
import StagedFixture
QtObject {
    property var command: []
    property bool running: false
    property bool stdinEnabled: false
    property QtObject stdout
    property QtObject stderr
    signal started()
    signal exited(int code)
    onRunningChanged: { if (running) Driver.forbiddenCalls++; }
    function write(text): void { Driver.forbiddenCalls++; }
}
