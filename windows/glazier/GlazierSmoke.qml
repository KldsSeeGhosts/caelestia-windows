import QtQuick
import Quickshell
import Caelestia
import Caelestia.Windows
import qs.services

// Offscreen resolution contract: bundled first, explicit config as fallback,
// no machine-wide/%LOCALAPPDATA% default, and an unavailable action only
// reports a toast. The stub is never a real Glazier.
ShellRoot {
    id: root
    property int attempts: 0
    property int phase: 0
    property string expected: (Quickshell.env("GLAZIER_EXPECTED_PATH") || "").replace(/\\/g, "/")
    property string payload: (Quickshell.env("GLAZIER_PAYLOAD_ROOT") || "").replace(/\\/g, "/")
    property string stubOutput: Quickshell.env("GLAZIER_STUB_OUTPUT") || ""

    function fail(message): void {
        console.error("GLAZIER_TEST_FAIL " + message);
        Qt.exit(1);
    }

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            if (++root.attempts > 200) {
                root.fail("timeout phase=" + root.phase + " ready=" + Glazier.ready
                    + " executable=" + Glazier.executable);
                return;
            }
            if (!Glazier.ready)
                return;
            if (root.phase === 0) {
                // The staged shell's parent is the running payload.
                const derived = Quickshell.shellDir.replace(/\\/g, "/").replace(/\/[^/]*$/, "");
                if (Glazier.defaultPayloadRoot !== derived) {
                    root.fail("payload root " + Glazier.defaultPayloadRoot + " != " + derived);
                    return;
                }
                let seen = "";
                if (Glazier.resolvePath("D:/bundled.exe", "D:/configured.exe",
                        path => { seen = path; return true; }) !== "D:/bundled.exe"
                        || seen !== "D:/bundled.exe") {
                    root.fail("bundled path is not preferred");
                    return;
                }
                Glazier.payloadRoot = root.payload;
                // Test providers: no screens means no shell surface to hide.
                Glazier.screenProvider = { screens: [] };
                Glazier.stateProvider = { forScreen: () => null, componentsFor: () => null };
                Glazier.refresh();
                root.phase = 1;
                return;
            }
            if (root.phase === 1) {
                if (Glazier.executable.toLowerCase() !== root.expected.toLowerCase()
                        || Glazier.available !== !!root.expected) {
                    root.fail("resolution " + Glazier.executable + " expected " + root.expected);
                    return;
                }
                if (Glazier.capture() !== !!root.expected) {
                    root.fail("capture result");
                    return;
                }
                if (!root.expected) {
                    if (!Array.from(Toaster.toasts).some(t => t.message === "Glazier is unavailable.")) {
                        root.fail("missing toast");
                        return;
                    }
                    console.log("GLAZIER_TEST_PASS");
                    Qt.quit();
                    return;
                }
                root.phase = 2;
                return;
            }
            if (root.phase === 2 && WindowsFiles.isFile(root.stubOutput)) {
                console.log("GLAZIER_TEST_PASS");
                Qt.quit();
            }
        }
    }
}
