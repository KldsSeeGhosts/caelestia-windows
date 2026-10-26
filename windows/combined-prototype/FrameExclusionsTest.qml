import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import qs.modules.drawers

// Drives the real exclusion component's fullscreen input without creating a
// fullscreen application that would also affect the user's live shell. The
// zones are fixed so the runner can compare the native work area against the
// expected reservation instead of the user's profile configuration.
ShellRoot {
    id: root
    property bool appFullscreen: false
    readonly property int barZone: 60
    readonly property int borderZone: 3
    readonly property var selectedScreen:
        Quickshell.screens[Number(Quickshell.env("CAELESTIA_SHELL_SCREEN"))] ?? null
    settings.watchFiles: false

    Exclusions {
        screen: root.selectedScreen
        zone: root.barZone
        borderZone: root.borderZone
        fullscreen: root.appFullscreen
    }

    IpcHandler {
        target: "frameTest"
        function setFullscreen(on: bool): void { root.appFullscreen = on; }
        // Report the reservation this fixture asks for. The runner compares it
        // with the measured physical work area; the DPI scaling must use the
        // same rounding as the backend, which rounds half away from zero.
        function expected(): string {
            const dpr = root.selectedScreen ? root.selectedScreen.devicePixelRatio : 1;
            return JSON.stringify({
                screen: root.selectedScreen ? root.selectedScreen.name : "",
                dpr: dpr,
                barZone: root.barZone,
                borderZone: root.borderZone,
                left: Math.round(root.barZone * dpr),
                top: Math.round(root.borderZone * dpr),
                right: Math.round(root.borderZone * dpr),
                bottom: Math.round(root.borderZone * dpr)
            });
        }
        function quit(): void { Qt.quit(); }
    }

    // Safety net if the runner is killed: never leave temporary AppBars behind.
    // The runner reports its own failure first; this only covers its death and
    // stays above the runner's own bounded fixture phase.
    Timer {
        running: true
        interval: 35000
        onTriggered: Qt.exit(1)
    }
}
