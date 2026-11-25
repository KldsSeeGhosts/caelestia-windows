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

    readonly property var floatingHarnessClient: ({
        address: "def",
        title: "Capability harness client",
        monitor: null,
        workspace: { id: 1 },
        wayland: null,
        lastIpcObject: { floating: true, pinned: false, mapped: true },
        elevated: false
    })

    QtObject {
        id: capabilityBackend

        property bool initialized: true
        property bool pinSupported: false
        property bool tilingActive: false
        property var monitors: ({ values: [] })
        property var workspaces: ({ values: [] })
        property var toplevels: ({ values: [] })
        property var activeToplevel: null
        property var focusedWorkspace: null
        property var focusedMonitor: null
        function dispatch(): void {
        }
    }

    // A direct Buttons instance lets the fixture toggle the singleton facade's
    // injected backend and observe both capability-gated controls. The window
    // lifecycle test above still exercises the same component in production.
    Item {
        id: capabilityHarness

        width: 360
        height: 180

        Buttons {
            anchors.fill: parent
            client: root.floatingHarnessClient
        }
    }

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
        property bool capabilitiesDone: false
        property int capabilityAttempts: 0

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

            if (!capabilitiesDone) {
                const floatButton = findObject(capabilityHarness, "windowInfoFloatTileButton");
                const pinButton = findObject(capabilityHarness, "windowInfoPinButton");
                if (!floatButton || !pinButton) {
                    if (++capabilityAttempts < 10)
                        return;
                    root.check(false, "capability-gated WindowInfo buttons are created");
                }
                root.check(floatButton.disabled === true && pinButton.disabled === true,
                    "missing Hypr capabilities disable float/tile and pin");

                capabilityBackend.pinSupported = false;
                capabilityBackend.tilingActive = false;
                Hypr.enabled = true;
                Hypr.backend = capabilityBackend;
                root.check(Hypr.pinSupported === false && Hypr.tilingActive === false,
                    "false backend capabilities propagate through the facade");
                root.check(floatButton.disabled === true && pinButton.disabled === true,
                    "false backend capabilities keep both buttons disabled");

                capabilityBackend.pinSupported = true;
                capabilityBackend.tilingActive = true;
                root.check(Hypr.pinSupported === true && Hypr.tilingActive === true,
                    "true backend capabilities propagate through the facade");
                root.check(floatButton.disabled === false && pinButton.disabled === false,
                    "true backend capabilities enable both buttons");
                // The fixture-owned backend must not outlive the test root while
                // the singleton facade is torn down later in engine shutdown.
                Hypr.backend = null;
                Hypr.enabled = false;
                capabilitiesDone = true;
            }

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
