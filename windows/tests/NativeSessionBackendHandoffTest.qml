import QtQuick
import Quickshell

// Real NativeSessionBackend with a harmless installed-looking prefix. The
// process launch is replaced with a recording fake that can fail immediately or
// succeed without sending Quit; both are the launcher failures the bounded
// acknowledgement must recover from. No live install or desktop action runs.
ShellRoot {
    id: root

    property var backend: null
    property var launches: []
    property bool started: false
    property int assertions: 0

    readonly property string installRoot: Quickshell.env("CAELESTIA_INSTALL_ROOT")

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function equal(actual, expected, message): void {
        check(actual === expected,
            message + ": " + JSON.stringify(actual) + " != " + JSON.stringify(expected));
    }

    function fakeLaunch(command): bool {
        launches.push(command.join(" "));
        return launches.length !== 1;
    }

    function start(): void {
        if (started)
            return;
        started = true;
        backend = backendLoader.item;
        check(backend !== null, "the real backend loaded");
        equal(typeof backend.launch, "function", "the production launch hook is callable");
        equal(backend.switchBackAckTimeoutMs, 15000, "the default acknowledgement bound is bounded");
        backend.switchBackAckTimeoutMs = 120;
        backend.launch = fakeLaunch;

        check(backend.switchBackSupported, "the disposable prefix is a supported handoff");
        equal(backend.switchBackPending, false, "no handoff is pending before the click");
        equal(backend.switchBackError, "", "no error before the click");

        // Immediate launch failure: report it, clear the guard, allow a retry.
        check(backend.switchBack(false) === false, "an immediate launch failure is reported");
        equal(backend.switchBackDispatched, false, "an immediate failure clears the guard");
        equal(backend.switchBackPending, false, "an immediate failure is not pending");
        check(backend.switchBackError.length > 0, "an immediate failure reports an error");
        check(backend.switchBackSupported, "the action stays supported after an immediate failure");
        equal(launches.length, 1, "the failed launch was attempted once");

        // Retry succeeds at launch but never acknowledges with Quit, so the
        // bounded timer must clear the guard, expose the error and permit a
        // third attempt. The autostart choice reaches the launcher command.
        check(backend.switchBack(false) === true, "the retry is dispatched");
        check(backend.switchBackDispatched, "the retry holds the guard");
        check(backend.switchBackPending, "the retry is visibly pending");
        equal(backend.switchBackError, "", "the retry clears the previous error");
        check(backend.switchBack(false) === false, "a duplicate click cannot start a competing handoff");
        equal(launches.length, 2, "the duplicate click did not launch");
        firstWait.start();
    }

    function afterFirstTimeout(): void {
        equal(backend.switchBackDispatched, false, "the unacknowledged handoff no longer holds the guard");
        equal(backend.switchBackPending, false, "the unacknowledged handoff is no longer pending");
        check(backend.switchBackError.length > 0, "the unacknowledged handoff reports an error");
        check(backend.switchBackSupported, "the action stays supported after the timeout");
        check(launches[1].indexOf("powershell.exe") >= 0, "the handoff uses the inbox Windows PowerShell");
        check(launches[1].indexOf(installRoot + "\\Start-Caelestia.ps1") >= 0,
            "the handoff targets the stable-root launcher entry");
        check(launches[1].indexOf("\\versions\\") < 0, "the handoff never targets a version payload directly");
        check(launches[1].indexOf("-Command Quit") >= 0, "the handoff keeps Quit in the existing launcher");
        check(launches[1].indexOf("-DisableAutostart") < 0, "the first retry keeps autostart");

        // Third attempt with the autostart choice. A later timeout must not
        // disable the action for the rest of the session.
        check(backend.switchBack(true) === true, "the post-timeout retry is dispatched");
        check(backend.switchBackPending, "the post-timeout retry is pending");
        equal(backend.switchBackError, "", "the post-timeout retry clears the timeout error");
        equal(launches.length, 3, "the post-timeout retry launched once");
        check(launches[2].indexOf("-DisableAutostart") >= 0, "the retry passes the autostart choice");
        retryWait.start();
    }

    function afterRetryTimeout(): void {
        equal(backend.switchBackDispatched, false, "the second unacknowledged handoff clears the guard");
        equal(backend.switchBackPending, false, "the second unacknowledged handoff is not pending");
        check(backend.switchBackError.length > 0, "the second unacknowledged handoff reports an error");

        console.log("CAELESTIA_SESSION_HANDOFF_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    function guard(step): void {
        try {
            step();
        } catch (error) {
            console.error("CAELESTIA_SESSION_HANDOFF_FAIL " + error.message);
            Qt.exit(1);
        }
    }

    Loader {
        id: backendLoader

        source: "imports/Caelestia/Services/NativeSessionBackend.qml"
        asynchronous: false

        onLoaded: root.start()
    }

    Timer {
        id: firstWait

        interval: 700
        repeat: false
        onTriggered: root.guard(root.afterFirstTimeout)
    }

    Timer {
        id: retryWait

        interval: 700
        repeat: false
        onTriggered: root.guard(root.afterRetryTimeout)
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            if (backendLoader.status === Loader.Ready)
                root.start();
        } catch (error) {
            console.error("CAELESTIA_SESSION_HANDOFF_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
