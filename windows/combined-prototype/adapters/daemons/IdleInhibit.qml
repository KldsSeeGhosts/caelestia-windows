import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.State

// Windows adaptation of the upstream idle-inhibit daemon.
//
// Upstream holds a Wayland IdleInhibitor on a zero-sized panel. Windows has no
// equivalent protocol, so the state is held by a PowerShell child that calls
// SetThreadExecutionState(ES_CONTINUOUS | ES_DISPLAY_REQUIRED |
// ES_SYSTEM_REQUIRED) on its own thread for as long as it runs. Toggling off
// stops the child; Quickshell kills the child when the shell exits; and
// helpers/KeepAwake.ps1 also polls the shell PID, so no inhibition outlives the
// shell. The upstream RuntimeState contract, timestamp and IPC surface are kept.
Scope {
    id: root

    // The combined host owns the write gate: the toggle is inert unless Live
    // controls are on and this is not a smoke run.
    readonly property bool permitted: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property bool active: root.permitted && RuntimeState.inhibitIdle
    readonly property bool inhibiting: helper.running
    // Last helper failure, so the card can stop claiming an active inhibition.
    property string failure: ""

    Connections {
        function onInhibitIdleChanged(): void {
            if (RuntimeState.inhibitIdle)
                RuntimeState.inhibitingIdleSince = new Date().getTime();
        }

        target: RuntimeState
    }

    Process {
        id: helper

        running: root.active
        command: [
            "powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden",
            "-ExecutionPolicy", "Bypass", "-File", Quickshell.shellPath("helpers/KeepAwake.ps1")
        ]

        stderr: StdioCollector {
            onStreamFinished: {
                const message = text.trim();
                if (message.length > 0)
                    root.failure = message;
            }
        }

        onExited: code => {
            // Only an exit while the toggle is still on is a failure; stopping
            // the toggle terminates the helper by design.
            if (!root.permitted || !RuntimeState.inhibitIdle)
                return;

            root.failure = root.failure || ("The keep-awake helper exited with code " + code + ".");
            console.log("CAELESTIA_IDLE_INHIBIT_FAILED", code, root.failure);
            RuntimeState.inhibitIdle = false;
        }
    }

    IpcHandler {
        target: "idleInhibitor"

        function isEnabled(): bool {
            return RuntimeState.inhibitIdle;
        }

        function isHeld(): bool {
            return root.inhibiting;
        }

        function toggle(): void {
            RuntimeState.inhibitIdle = !RuntimeState.inhibitIdle;
        }

        function enable(): void {
            RuntimeState.inhibitIdle = true;
        }

        function disable(): void {
            RuntimeState.inhibitIdle = false;
        }
    }
}
