import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows
import Caelestia.Windows

// Thin facade over the pinned Quickshell.Windows.Session singleton. It is
// loaded by URL only after the observation opt-in, so the default-off host
// resolves no native Session singleton.
//
// Every native session action is a void call. The pinned backend logs failures
// and exposes no result (windows/deps/quickshell/src/windows/system/session.cpp
// lines 45-115). canHibernate is the singleton's CONSTANT property backed by
// GetPwrCapabilities().HiberFilePresent (lines 117-121).
//
// `switchBack` is not a native Session call. The shell cannot run its own Quit
// and restore after it exits, so it starts the installed Start-Caelestia
// launcher as a detached process. Process.startDetached() disowns the child
// handles (windows/deps/quickshell/src/io/process.cpp lines 240-260) but returns
// no result and emits no completion signal. The launcher then owns the existing
// IPC Quit and supervisor/Restore-Desktop path. No session cleanup or restore is
// implemented here.
//
// A successful handoff is acknowledged by this shell exiting. If the shell is
// still alive when the bounded acknowledgement timer fires, process creation
// failed or the launcher exited before it asked the shell to quit. The pending
// flag then clears, an error is exposed to the UI, and a later click can retry.
QtObject {
    id: root

    readonly property string installRoot: {
        const value = String(Quickshell.env("CAELESTIA_INSTALL_ROOT") ?? "");
        return value.replace(/[\\/]+$/, "");
    }
    readonly property string systemRoot: {
        const value = String(Quickshell.env("SystemRoot") ?? "");
        return value.replace(/[\\/]+$/, "");
    }
    // CAELESTIA_INSTALL_ROOT is the stable install root, never a version
    // payload. Start-Caelestia.ps1 there is the installed copy of
    // Start-CaelestiaEntry.ps1, which owns the Run entry and routes to the
    // selected runtime after consuming -Command Quit -DisableAutostart.
    readonly property string launcher: installRoot ? installRoot + "\\Start-Caelestia.ps1" : ""
    readonly property string powershell: systemRoot
        ? systemRoot + "\\System32\\WindowsPowerShell\\v1.0\\powershell.exe" : ""
    readonly property bool live: Quickshell.env("CAELESTIA_SHELL_LIVE") === "1"
    readonly property bool smoke: Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1"

    // A development or smoke session has no installed launcher to hand Quit to.
    // Start-Caelestia requires the install manifest, so the action does too.
    readonly property bool switchBackSupported: live && !smoke
        && launcher !== "" && powershell !== ""
        && WindowsFiles.isFile(launcher) && WindowsFiles.isFile(powershell)
        && WindowsFiles.isFile(installRoot + "\\install.json")

    readonly property bool canHibernate: Session.canHibernate

    // One detached handoff per shell generation. A second click cannot start a
    // competing Quit while the first launcher is already leaving.
    property bool switchBackDispatched: false

    // Observable handoff state. Both are read by the session UI through
    // SessionService.
    property bool switchBackPending: false
    property string switchBackError: ""

    // A launcher normally sends Quit within a few seconds. The shell exiting is
    // the success acknowledgement; this bound only decides when to stop waiting.
    // Tests lower it through this writable property.
    property int switchBackAckTimeoutMs: 15000

    // Test seam: production starts the detached launcher directly. Process
    // returns no launch result, so a fixture can replace this to exercise the
    // retry state machine without creating a process. It returns false when the
    // caller knows the launch failed.
    property var launch: function(command) {
        switchBackProcess.command = command;
        switchBackProcess.startDetached();
        return true;
    }

    function failHandoff(message): void {
        switchBackTimer.stop();
        switchBackDispatched = false;
        switchBackPending = false;
        switchBackError = message;
    }

    // Only the installed live shell can leave. The service gates this call; the
    // guard is defense in depth and keeps a miswired UI from starting a process.
    // Returns true only when a new detached handoff was started.
    function switchBack(disableAutostart): bool {
        if (!switchBackSupported) {
            switchBackError = "Switching back to Windows needs an installed Caelestia launcher.";
            return false;
        }
        if (switchBackDispatched)
            return false;
        switchBackDispatched = true;
        switchBackPending = true;
        switchBackError = "";
        const command = [
            powershell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-WindowStyle", "Hidden", "-File", launcher,
            "-Prefix", installRoot, "-Command", "Quit"
        ];
        if (disableAutostart === true)
            command.push("-DisableAutostart");

        let launched = false;
        try {
            launched = root.launch(command) !== false;
        } catch (error) {
            root.failHandoff("Could not start the Caelestia switch-back launcher: " + error);
            return false;
        }
        if (!launched) {
            root.failHandoff("Could not start the Caelestia switch-back launcher. You can try again.");
            return false;
        }

        switchBackTimer.restart();
        return true;
    }

    property Process switchBackProcess: Process {
        command: []
    }

    property Timer switchBackTimer: Timer {
        interval: root.switchBackAckTimeoutMs
        repeat: false

        onTriggered: {
            if (!root.switchBackDispatched)
                return;
            // Reaching this timer means this process is still running. The
            // launcher never returned a launch result and never acknowledged
            // with Quit, so clear the guard instead of disabling switch-back
            // for the rest of the session.
            root.failHandoff("Caelestia did not quit after the switch-back request. "
                + "The launcher could not start or exited before asking the shell to quit. "
                + "You can try again.");
        }
    }

    function lock(): void {
        Session.lock();
    }

    function logout(): void {
        Session.logout();
    }

    function shutdown(): void {
        Session.shutdown();
    }

    function reboot(): void {
        Session.reboot();
    }

    function suspend(): void {
        Session.suspend();
    }

    function hibernate(): void {
        Session.hibernate();
    }

    function rebootToFirmware(): void {
        Session.rebootToFirmware();
    }
}
