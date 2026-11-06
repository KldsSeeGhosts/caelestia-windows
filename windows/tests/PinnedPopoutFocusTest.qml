import QtQuick
import QtTest
import Quickshell
import Quickshell.Wayland
import Caelestia
import qs.services as Services
import qs.modules.drawers

// The running-apps popout keyboard focus on the production host. The real
// ContentWindow and its popouts wrapper run here, not a FloatingWindow, so the
// window's computed keyboardFocus and its native focusability are the ones the
// shell ships. A hover-opened popout must leave the window unfocusable; a
// right-click pin must make it focusable and put the window list in focus; and
// closing the pin must hand the window back to None.
ShellRoot {
    id: root

    property int assertions: 0
    property int step: 0
    property int attempts: 0
    property var fixtureWindow
    property var pill
    property var keys

    readonly property var win: content
    readonly property var popouts: content.interactionWrapper.panels.popouts

    ContentWindow {
        id: content
        screen: Quickshell.screens[0]
        visible: true
        interactionEnabled: true
    }

    Component {
        id: fixture
        QtObject {
            property string address: "1"
            property string title: "Fixture window"
            property bool activated: false
            property string appId: "fixture-app"
            property bool mapped: true
            property var lastIpcObject: ({ class: "fixture-app", mapped: true })
            property var workspace: ({ id: 1 })
            property QtObject wayland: QtObject {
                property bool minimized: false
                function activate(): void {}
                function close(): void {}
            }
        }
    }

    Component {
        id: keyComponent
        TestCase { when: false }
    }

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    function list(): var {
        const current = popouts.current;
        return current ? CUtils.findChild(current, "activeWindowWindowList") : null;
    }

    Component.onCompleted: {
        fixtureWindow = fixture.createObject(root);
        Services.RunningApps.source = [fixtureWindow];
        Services.RunningApps.actionsEnabled = true;
        content.screenState.bar = true;
    }

    Timer {
        interval: 150
        repeat: true
        running: true

        onTriggered: {
            try {
                root.advance();
            } catch (error) {
                console.error("CAELESTIA_PINNED_FOCUS_FAIL " + error);
                Qt.exit(1);
            }
        }
    }

    function advance(): void {
        if (++attempts > 100)
            throw new Error("timed out at step " + step);

        if (step === 0) {
            pill = CUtils.findChild(content.bar, "taskbarActiveWindow");
            if (!pill || Services.RunningApps.groupIds.length === 0)
                return;
            keys = keyComponent.createObject(content.contentItem);
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, "closed popout: keyboardFocus is None");
            check(!win.focusable, "closed popout: window is not focusable");

            // Hover opens the shared popout without a pin.
            Services.RunningApps.previewGroupId = "fixture-app";
            popouts.currentName = "activewindow";
            popouts.hasCurrent = true;
            step = 1;
        } else if (step === 1) {
            if (!list())
                return;
            check(!popouts.pinned, "hover open is not pinned");
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, "hover open: keyboardFocus is None");
            check(!win.focusable, "hover open: window is not focusable");
            popouts.hasCurrent = false;
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, "hover close: keyboardFocus stays None");

            // Right-click pins it through the strip's own handler.
            pill.pin("fixture-app", pill);
            step = 2;
        } else if (step === 2) {
            if (!list())
                return;
            check(popouts.hasCurrent && pill.pinned, "right click pins the popout");
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.OnDemand, "pinned: keyboardFocus is OnDemand");
            check(win.focusable, "pinned: window is focusable");
            check(list().activeFocus, "pinned: the window list has active focus");
            check(popouts.pinned === true, "pinned: the popouts wrapper holds the pin");
            keys.keyClick(Qt.Key_Escape, Qt.NoModifier, 0);
            step = 3;
        } else if (step === 3) {
            check(!popouts.hasCurrent, "Escape closes the pinned popout");
            check(!popouts.pinned && !pill.pinned, "closing releases the pin");
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, "after Escape: keyboardFocus is None again");
            check(!win.focusable, "after Escape: window is not focusable again");
            console.log("CAELESTIA_PINNED_FOCUS_PASS " + assertions);
            Qt.quit();
        }
    }
}
