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
// handles (windows/deps/quickshell/src/io/process.cpp lines 240-260), and the
// launcher then owns the existing IPC Quit and supervisor/Restore-Desktop path.
// No session cleanup or restore is implemented here.
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

    // Only the installed live shell can leave. The service gates this call; the
    // guard is defense in depth and keeps a miswired UI from starting a process.
    function switchBack(disableAutostart): void {
        if (!switchBackSupported || switchBackDispatched)
            return;
        switchBackDispatched = true;
        const command = [
            powershell, "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Bypass",
            "-WindowStyle", "Hidden", "-File", launcher,
            "-Prefix", installRoot, "-Command", "Quit"
        ];
        if (disableAutostart === true)
            command.push("-DisableAutostart");
        switchBackProcess.command = command;
        switchBackProcess.startDetached();
    }

    property Process switchBackProcess: Process {
        command: []
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
