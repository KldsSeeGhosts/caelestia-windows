import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import Caelestia.Services
import Caelestia.State

// Windows adaptation of the upstream idle-inhibit daemon.
//
// Upstream holds a Wayland IdleInhibitor on a zero-sized panel. Windows has no
// equivalent protocol, so the backend's IdleInhibitor owns a PowerCreateRequest
// handle for this shell process and sets PowerRequestDisplayRequired and
// PowerRequestSystemRequired while enabled. Disabling it clears both requests,
// its destructor clears and closes the handle, and Windows drops the process's
// requests when the shell exits, so inhibition cannot outlive the shell. The
// upstream RuntimeState contract, timestamp and IPC surface are kept.
Scope {
    id: root

    // The combined host owns the write gate: the toggle is inert unless Live
    // controls are on and this is not a smoke run.
    readonly property bool permitted: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property bool active: root.permitted && RuntimeState.inhibitIdle
    // held is the request the backend confirmed. enabled is only what was asked.
    readonly property bool inhibiting: inhibitor.held
    readonly property string inhibitError: inhibitor.error

    Connections {
        function onInhibitIdleChanged(): void {
            if (RuntimeState.inhibitIdle)
                RuntimeState.inhibitingIdleSince = new Date().getTime();
        }

        target: RuntimeState
    }

    IdleInhibitor {
        id: inhibitor

        enabled: root.active
    }

    Binding {
        target: IdleHold
        property: "held"
        value: inhibitor.held
    }

    Binding {
        target: IdleHold
        property: "error"
        value: inhibitor.error
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
