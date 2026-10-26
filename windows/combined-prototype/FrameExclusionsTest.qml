import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import qs.modules.drawers

// Drives the real exclusion component's fullscreen input without creating a
// fullscreen application that would also affect the user's live shell.
ShellRoot {
    id: root
    property bool appFullscreen: false
    settings.watchFiles: false
    Exclusions {
        screen: Quickshell.screens[Number(Quickshell.env("CAELESTIA_SHELL_SCREEN"))]
        zone: 60
        fullscreen: root.appFullscreen
    }
    IpcHandler {
        target: "frameTest"
        function setFullscreen(on: bool): void { root.appFullscreen = on; }
        function quit(): void { Qt.quit(); }
    }
    Timer {
        running: true
        interval: 15000
        onTriggered: Qt.exit(1)
    }
}
