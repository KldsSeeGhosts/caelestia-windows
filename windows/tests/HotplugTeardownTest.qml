import QtQuick
import Quickshell
import Quickshell.Wayland
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.drawers

// Regression fixture for #215. The complete production ContentWindow and its
// drawer wrappers run here. Removing the screen from the model tears it down
// like a display hot-unplug: the model drops the window's ScreenState before
// the deferred window deletion runs, so its bindings still evaluate.
// Any null read is a TypeError and fails the run before the fix.
ShellRoot {
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

        ContentWindow {
            id: win

            required property ShellScreen modelData

            screen: modelData
            visible: false
            interactionEnabled: false

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
                const liveState = ShellState.forScreen(screenWindow.screen);
                check(screenWindow.screenState !== null, "the screen state is null before removal");
                check(screenWindow.screenState === liveState, "a live window must use the canonical screen state");

                // An opened panel must reach the window through the canonical
                // state, so a window stuck on its fallback fails here.
                liveState.sidebar = true;
                check(screenWindow.screenState.sidebar === true, "opening the sidebar did not reach the window");
                check(screenWindow.interactionWrapper.panels.sidebar.shouldBeActive === Config.sidebar.enabled,
                    "the real sidebar wrapper ignored the open panel");

                // Hot-unplug. Variants erases the window from its model
                // immediately, but its deletion is deferred, so the teardown
                // bindings evaluate against the removed screen.
                Screens.screens = [];

                check(screenWindow.screenState !== null, "the screen state went null during teardown");
                const panels = screenWindow.interactionWrapper.panels;
                check(panels.sidebar.shouldBeActive === false, "the sidebar wrapper did not evaluate");
                check(panels.utilities.shouldBeActive === false, "the utilities wrapper did not evaluate");
                check(panels.dashboard.shouldBeActive === false, "the dashboard wrapper did not evaluate");
                check(panels.launcher.shouldBeActive === false, "the launcher wrapper did not evaluate");
                check(panels.session.shouldBeActive === false, "the session wrapper did not evaluate");
                check(panels.osd.shouldBeActive === false, "the osd wrapper did not evaluate");
                check(panels.quota.shouldBeActive === false, "the quota wrapper did not evaluate");
                check(screenWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
                    "the real drawer keyboard focus did not evaluate");
                const scrim = screenWindow.contentItem.children.find(child => child instanceof StyledRect);
                check(scrim && scrim.opacity === 0, "the real drawer scrim did not evaluate");
                check(screenWindow.screenState === screenWindow.teardownState, "teardown must use the window's fallback state");

                // Reconnect: the screen comes back and gets a new window.
                root.removedWindow = screenWindow;
                Screens.screens = Quickshell.screens;
                reconnect.start();
            } catch (e) {
                console.error("CAELESTIA_HOTPLUG_TEARDOWN_FAIL " + e);
                Qt.exit(1);
            }
        }
    }

    property var removedWindow: null
    Timer {
        id: reconnect

        interval: 200

        onTriggered: {
            try {
                check(windows.instances.length === 1, "the reconnected screen has no window");
                const screenWindow = windows.instances[0];
                check(screenWindow !== root.removedWindow, "the reconnected screen reused the removed window");
                check(screenWindow.screenState === ShellState.forScreen(screenWindow.screen),
                    "the reconnected window must use the canonical screen state");

                console.log("CAELESTIA_HOTPLUG_TEARDOWN_PASS " + root.assertions);
                Qt.quit();
            } catch (e) {
                console.error("CAELESTIA_HOTPLUG_TEARDOWN_FAIL " + e);
                Qt.exit(1);
            }
        }
    }
}
