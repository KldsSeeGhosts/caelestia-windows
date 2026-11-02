import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.services

// Regression fixture for #215. The runner splices the production
// ContentWindow screen-state binding, its teardown-sensitive expressions and
// the drawer wrappers' `shouldBeActive` lines into the per-screen window
// below. Removing the screen from the model tears the window down exactly
// like a display hot-unplug: the model drops the window's ScreenState before
// the deferred window deletion runs, so its bindings still evaluate.
// Any null read is a TypeError and fails the run before the fix.
Item {
    id: root

    property int assertions: 0
    property bool windowCreated: false

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Variants {
        id: windows

        model: Screens.screens

        Item {
            id: win

            required property ShellScreen modelData

            readonly property ShellScreen screen: modelData
            // The production expressions reference these. The fixture only
            // needs the shapes; no drawer is opened.
            readonly property bool interactionEnabled: true
            readonly property QtObject panels: QtObject {
                property QtObject popouts: QtObject {
                    property string detachedMode: ""
                }
            }

            // CONTENT_WINDOW_STATE

            // CONTENT_WINDOW_EXPRESSIONS

            // WRAPPER_BINDINGS

            Component.onCompleted: root.windowCreated = true
        }
    }

    Timer {
        interval: 400
        running: true

        onTriggered: {
            try {
                check(root.windowCreated, "the per-screen window was never created");
                check(Screens.screens.length === 1, "the staged graph must expose one screen");
                check(windows.instances.length === 1, "the per-screen window must exist before removal");

                const screenWindow = windows.instances[0];
                check(screenWindow.screenState !== null, "the screen state is null before removal");

                // Hot-unplug. Variants erases the window from its model
                // immediately, but its deletion is deferred, so the teardown
                // bindings evaluate against the removed screen.
                Screens.screens = [];

                check(screenWindow.screenState !== null, "the screen state went null during teardown");
                check(screenWindow.sidebarActive === false, "the sidebar wrapper did not evaluate");
                check(screenWindow.utilitiesActive === false, "the utilities wrapper did not evaluate");
                check(screenWindow.dashboardActive === false, "the dashboard wrapper did not evaluate");
                check(screenWindow.launcherActive === false, "the launcher wrapper did not evaluate");
                check(screenWindow.sessionActive === false, "the session wrapper did not evaluate");
                check(screenWindow.osdActive === false, "the osd wrapper did not evaluate");
                check(screenWindow.quotaActive === false, "the quota wrapper did not evaluate");
                check(screenWindow.keyboardFocusWanted === false, "the drawer keyboard focus did not evaluate");
                check(screenWindow.scrimOpacity === 0, "the drawer scrim did not evaluate");

                console.log("CAELESTIA_HOTPLUG_TEARDOWN_PASS " + root.assertions);
                Qt.quit();
            } catch (e) {
                console.error("CAELESTIA_HOTPLUG_TEARDOWN_FAIL " + e);
                Qt.exit(1);
            }
        }
    }
}
