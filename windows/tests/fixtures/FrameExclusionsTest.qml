import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import qs.modules.drawers

// Drives the real exclusion component's fullscreen input without creating a
// fullscreen application that would also affect the user's live shell. The
// zones are fixed so the runner can compare the native work area against the
// expected reservation instead of the user's profile configuration.
// Reservations start inactive: the runner validates the selected screen over
// IPC first, so a wrong screen index cannot change a work area (and move
// application windows) before the isolation check has passed.
ShellRoot {
    id: root
    property bool appFullscreen: false
    property bool reservations: false
    readonly property int barZone: 60
    readonly property int borderZone: 3
    readonly property var selectedScreen:
        Quickshell.screens[Number(Quickshell.env("CAELESTIA_SHELL_SCREEN"))] ?? null
    // Explicit readiness handshake for the runner. A cold first start can take
    // longer than a fixed poll window, so the runner waits for this instead of
    // treating a missing IPC answer as a failed fixture. A binding also covers
    // Quickshell publishing its screen list after the object tree completes.
    readonly property bool fixtureReady: selectedScreen !== null
    settings.watchFiles: false

    Exclusions {
        screen: root.selectedScreen
        zone: root.barZone
        borderZone: root.borderZone
        active: root.reservations
        fullscreen: root.appFullscreen
    }

    IpcHandler {
        target: "frameTest"
        // The runner polls this until the object tree is complete. It is kept
        // separate from expected() so "still starting" is not a missing reply.
        function ready(): string {
            return JSON.stringify({
                ready: root.fixtureReady,
                screen: root.selectedScreen ? root.selectedScreen.name : ""
            });
        }
        function setFullscreen(on: bool): void { root.appFullscreen = on; }
        function setReservations(on: bool): void { root.reservations = on; }
        // Report the reservation this fixture asks for. The runner compares it
        // with the measured physical work area; the DPI scaling must use the
        // same rounding as the backend, which rounds half away from zero.
        function expected(): string {
            const dpr = root.selectedScreen ? root.selectedScreen.devicePixelRatio : 1;
            return JSON.stringify({
                screen: root.selectedScreen ? root.selectedScreen.name : "",
                // Qt may report a model name instead of a device name, so the
                // runner can also match the monitor by its origin.
                x: root.selectedScreen ? root.selectedScreen.x : 0,
                y: root.selectedScreen ? root.selectedScreen.y : 0,
                dpr: dpr,
                reservations: root.reservations,
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
    // stays above the runner's own bounded fixture phase, including a cold
    // first start. The runner's overall deadline still bounds the whole run.
    Timer {
        running: true
        interval: 90000
        onTriggered: Qt.exit(1)
    }
}
