import QtQuick
import Quickshell
import Caelestia.State
import "daemons"

// Offscreen fixture for the Windows idle-inhibit daemon. The daemon must drive
// the backend's native IdleInhibitor with the Live gate, and toggling the
// RuntimeState contract must hold and release that one request repeatedly.
// This does not read or change the live profile or operate a live shell.
ShellRoot {
    id: root

    property int assertions: 0
    property int failures: 0

    function check(ok, message) {
        root.assertions++;
        if (!ok) {
            root.failures++;
            console.error("CAELESTIA_IDLEINHIBIT_FAIL " + message);
        }
    }

    IdleInhibit {
        id: daemon
    }

    Timer {
        interval: 100
        running: true
        repeat: false

        onTriggered: {
            RuntimeState.inhibitIdle = false;
            root.check(daemon.permitted, "Live controls are permitted");
            root.check(!daemon.active, "inactive before the toggle");
            root.check(!daemon.inhibiting, "no native request before the toggle");

            RuntimeState.inhibitIdle = true;
            root.check(daemon.active, "active after enabling");
            root.check(daemon.inhibiting, "native request held after enabling");
            root.check(RuntimeState.inhibitingIdleSince > 0, "activation timestamp recorded");

            RuntimeState.inhibitIdle = false;
            root.check(!daemon.inhibiting, "native request cleared after disabling");

            // A one-shot implementation or a stale handle would fail this.
            RuntimeState.inhibitIdle = true;
            root.check(daemon.inhibiting, "native request held again");
            RuntimeState.inhibitIdle = false;
            root.check(!daemon.inhibiting, "native request cleared again");

            if (root.failures === 0)
                console.log("CAELESTIA_IDLEINHIBIT_PASS " + root.assertions);
            else
                console.log("CAELESTIA_IDLEINHIBIT_FAIL " + root.failures);
            Qt.quit();
        }
    }
}
