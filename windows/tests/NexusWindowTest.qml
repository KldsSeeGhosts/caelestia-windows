import QtQuick
import Quickshell
import qs.modules.nexus

// Offscreen only. Exercises real dynamic creation and the factory, never native
// foreground, input, or a window on the owner's desktop.
ShellRoot {
    id: root
    property int assertions: 0

    Image {
        id: appIcon
        source: "qrc:/quickshell/caelestia.ico"
        sourceSize.width: 32
        sourceSize.height: 32
    }

    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }

    Timer {
        interval: 50
        running: true
        onTriggered: {
            try {
                check(Quickshell.env("QT_QPA_PLATFORM") === "offscreen", "offscreen is required");
                check(appIcon.status === Image.Ready, "executable embeds the Caelestia icon for Qt windows");
                const first = WindowFactory.create();
                check(first !== null, "first window exists");
                check(first.backingWindowVisible, "first show completes before create returns");
                check(first.frameless, "Nexus retains its custom frame");
                check(WindowFactory.windowCount === 1, "one live window");
                check(WindowFactory.create() === first, "reopen reuses the live window");
                check(first.backingWindowVisible, "reused backer remains visible");
                first.minimized = true;
                check(WindowFactory.create() === first, "minimized window is reused");
                check(!first.minimized, "reopen restores the minimized window");
                WindowFactory.openPage(3);
                check(WindowFactory.windowCount === 1, "page open does not create a second window");
                WindowFactory.closeAll();
                finish.start();
            } catch (error) {
                console.error("CAELESTIA_NEXUS_WINDOW_FAIL " + error);
                Qt.exit(1);
            }
        }
    }

    Timer {
        id: finish
        interval: 50
        onTriggered: {
            try {
                root.check(WindowFactory.windowCount === 0, "close releases the factory registry");
                console.log("CAELESTIA_NEXUS_WINDOW_PASS " + root.assertions);
                Qt.quit();
            } catch (error) {
                console.error("CAELESTIA_NEXUS_WINDOW_FAIL " + error);
                Qt.exit(1);
            }
        }
    }
}
