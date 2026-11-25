import QtQuick
import Quickshell
import qs.services
import qs.modules.windowinfo

// Offscreen WindowInfo regression. Uses plain facade-shaped clients so null
// monitor/IPC fields, elevation identity and factory lifecycle run against the
// real staged components without native foreground or desktop input.
ShellRoot {
    id: root
    property int assertions: 0
    property int attempts: 0

    ThemeTokens {}

    readonly property var nullSafeClient: ({
        address: "abc",
        title: "Elevated null-safe client",
        monitor: null,
        workspace: null,
        wayland: null,
        lastIpcObject: null,
        elevated: true,
        imagePath: "terminal.exe",
        aumid: "Terminal.Package"
    })

    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }

    function findObject(object, name): var {
        if (!object)
            return null;
        if (object.objectName === name)
            return object;
        for (const child of object.children ?? []) {
            const found = findObject(child, name);
            if (found)
                return found;
        }
        return null;
    }

    Timer {
        interval: 50
        repeat: true
        running: true
        onTriggered: {
            try {
                checkOnce();
            } catch (error) {
                console.error("CAELESTIA_WINDOWINFO_WINDOW_FAIL " + error);
                Qt.exit(1);
            }
        }

        property var first: null
        property bool clientReplaced: false

        function checkOnce(): void {
            if (first === null) {
                root.check(Quickshell.env("QT_QPA_PLATFORM") === "offscreen", "offscreen is required");
                root.check(WindowInfoFactory.openForClient(null) === null,
                    "a missing client opens no window");
                first = WindowInfoFactory.openForClient(root.nullSafeClient);
                root.check(first !== null, "first WindowInfo window exists");
                return;
            }

            const content = findObject(first.contentItem, "windowInfoAdminBadge");
            if (!content) {
                if (++root.attempts < 10)
                    return;
                root.check(false, "WindowInfo content is created after screen attachment");
            }

            root.check(first.visible, "first WindowInfo window is visible");
            root.check(first.implicitWidth > 0 && first.implicitHeight > 0,
                "null-safe content gives the window a nonzero size");
            root.check(content.visible === true, "elevated client shows the Admin badge");
            root.check(findObject(first.contentItem, "windowInfoImagePath") !== null,
                "image path row exists with null IPC");
            root.check(findObject(first.contentItem, "windowInfoAumid") !== null,
                "AUMID row exists with null IPC");
            root.check(WindowInfoFactory.windowCount === 1, "one live WindowInfo window");

            if (!clientReplaced) {
                clientReplaced = true;
                const otherClient = Object.assign({}, root.nullSafeClient, { title: "Replacement client" });
                root.check(WindowInfoFactory.openForClient(otherClient) === first,
                    "reopen reuses the live window");
                root.check(first.client.title === "Replacement client", "reopen replaces the inspected client");
                first.minimized = true;
                root.check(WindowInfoFactory.openForClient(otherClient) === first,
                    "minimized window is reused");
                root.check(!first.minimized, "reopen restores the minimized window");
                stop();
                WindowInfoFactory.closeAll();
                finish.start();
                return;
            }
        }
    }

    Timer {
        id: finish
        interval: 50
        repeat: true
        property int closeAttempts: 0
        onTriggered: {
            try {
                if (WindowInfoFactory.windowCount !== 0 && ++closeAttempts < 10)
                    return;
                root.check(WindowInfoFactory.windowCount === 0, "close releases the factory registry");
                console.log("CAELESTIA_WINDOWINFO_WINDOW_PASS " + root.assertions);
                Qt.quit();
            } catch (error) {
                console.error("CAELESTIA_WINDOWINFO_WINDOW_FAIL " + error);
                Qt.exit(1);
            }
        }
    }
}
