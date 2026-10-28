import QtQuick
import Quickshell
import Caelestia
import qs.services

ShellRoot {
    id: root
    property int attempts: 0
    property bool invoked: false

    Timer {
        interval: 100
        repeat: true
        running: true
        onTriggered: {
            if (++root.attempts > 100) {
                console.error("GLAZIER_TEST_FAIL timeout ready=" + Glazier.ready);
                Qt.exit(1);
                return;
            }
            if (!Glazier.ready)
                return;
            if (!root.invoked) {
                const expected = Quickshell.env("GLAZIER_EXPECTED_PATH").replace(/\\/g, "/");
                if (Glazier.executable.toLowerCase() !== expected.toLowerCase()
                        || Glazier.available !== !!expected) {
                    console.error("GLAZIER_TEST_FAIL resolution " + Glazier.executable);
                    Qt.exit(1);
                    return;
                }
                root.invoked = true;
                if (Glazier.capture() !== !!expected) {
                    console.error("GLAZIER_TEST_FAIL capture");
                    Qt.exit(1);
                    return;
                }
                if (!expected && !Array.from(Toaster.toasts).some(t => t.message === "Glazier not installed.")) {
                    console.error("GLAZIER_TEST_FAIL missing toast");
                    Qt.exit(1);
                    return;
                }
                root.attempts = 90;
            } else if (root.attempts >= 95) {
                console.log("GLAZIER_TEST_PASS");
                Qt.quit();
            }
        }
    }
}
