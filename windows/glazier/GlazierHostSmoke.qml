import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia.Windows
import qs.services

// Offscreen launch contract: the shell starts Glazier once, in the tray, with
// --no-hotkeys and the profile's theme tokens. It never starts a second host.
ShellRoot {
    id: root
    property int ticks: 0
    property string output: Quickshell.env("GLAZIER_HOST_OUTPUT") || ""
    property string probeOutput: Quickshell.env("GLAZIER_PROBE_OUTPUT") || ""
    property bool requested: false
    property bool adopted: false
    property bool stopped: false
    property bool adopt: Quickshell.env("GLAZIER_EXPECT_ADOPT") === "1"
    property bool stopAfterAdopt: Quickshell.env("GLAZIER_STOP_AFTER_ADOPT") === "1"

    // The staged fixture points at its disposable payload explicitly; the
    // installed shell derives the same parent from Quickshell.shellDir.
    Component.onCompleted: {
        const payload = (Quickshell.env("GLAZIER_PAYLOAD_ROOT") || "").replace(/\\/g, "/");
        if (payload) {
            Glazier.payloadRoot = payload;
            Glazier.refresh();
        }
    }

    function fail(message): void {
        console.error("GLAZIER_HOST_FAIL " + message);
        Qt.exit(1);
    }

    FileView {
        id: launch
        path: root.output
        preload: true
        printErrors: false
        onLoaded: {
            const body = launch.text();
            const text = body.replace(/\\/g, "/");
            const theme = (Quickshell.env("GLAZIER_EXPECTED_THEME") || "").replace(/\\/g, "/");
            const lines = text.split(/\r?\n/).filter(line => line.length > 0);
            // First line is the executable; the rest are its arguments.
            if (!lines[0] || lines[0].toLowerCase() !== Glazier.executable.toLowerCase()) {
                root.fail("launched executable " + lines[0]);
                return;
            }
            const args = lines.slice(1);
            if (args.length !== 3 || args[0] !== "--no-hotkeys" || args[1] !== "--theme-file"
                    || args[2].replace(/\\/g, "/") !== theme) {
                root.fail("unexpected launch arguments: " + args.join(" "));
                return;
            }
            console.log("GLAZIER_HOST_PASS");
            Qt.quit();
        }
    }
    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            if (++root.ticks > 200) {
                root.fail("timeout ready=" + Glazier.ready + " started=" + Glazier.hostStarted
                    + " available=" + Glazier.available + " permitted=" + Glazier.permitted
                    + " executable=" + Glazier.executable + " theme=" + Glazier.themeFile
                    + " output=" + root.output + " outputIsFile=" + WindowsFiles.isFile(root.output));
                return;
            }
            if (!Glazier.ready || !Glazier.hostStarted)
                return;
            if (Glazier.themeFile !== (Quickshell.env("GLAZIER_EXPECTED_THEME") || "").replace(/\\/g, "/")) {
                root.fail("theme file " + Glazier.themeFile);
                return;
            }
            if (root.adopt) {
                if (WindowsFiles.isFile(root.output)) {
                    root.fail("an already-owned host was started twice");
                    return;
                }
                if (root.ticks > 40) {
                    if (!root.adopted) {
                        if (Glazier.ownedHost !== true) {
                            root.fail("a host from this payload was not adopted image="
                                + WindowsProcess.windowImagePath("GlazierHost")
                                + " executable=" + Glazier.executable + " owned=" + Glazier.ownedHost);
                            return;
                        }
                        if (!root.samePath(WindowsProcess.windowImagePath("GlazierHost"), Glazier.executable)) {
                            root.fail("the adopted host is not the bundled executable");
                            return;
                        }
                        root.adopted = true;
                    }
                    if (root.stopAfterAdopt && !root.stopped) {
                        root.stopped = true;
                        if (!Glazier.stopHost(true)) {
                            root.fail("the owned host did not exit");
                            return;
                        }
                        return;
                    }
                    // The shell's quit handler calls this before Qt.quit.
                    if (!root.stopped) {
                        root.stopped = true;
                        Glazier.stopHost(false);
                        return;
                    }
                    if (WindowsProcess.windowProcessId("GlazierHost") === 0) {
                        console.log("GLAZIER_HOST_PASS");
                        Qt.quit();
                    }
                }
                return;
            }
            if (WindowsFiles.isFile(root.output)) {
                // Reload once; a repeated reload would cancel the pending load.
                if (!root.requested) {
                    root.requested = true;
                    launch.reload();
                }
                return;
            }
            // The already-running host answers the status probe and is never
            // started again, so no launch file appears.
            if (Quickshell.env("GLAZIER_STUB_RUNNING") === "1" && root.ticks > 40
                    && WindowsFiles.isFile(root.probeOutput)) {
                console.log("GLAZIER_HOST_PASS");
                Qt.quit();
            }
        }
    }
    function samePath(a, b): bool {
        return typeof a === "string" && typeof b === "string" && a.length > 0 && b.length > 0
            && a.replace(/\\/g, "/").toLowerCase() === b.replace(/\\/g, "/").toLowerCase();
    }
}
