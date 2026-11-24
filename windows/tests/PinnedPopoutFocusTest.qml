import QtQuick
import QtTest
import Quickshell
import Quickshell.Wayland
import Caelestia
import qs.services as Services
import qs.modules.drawers

// The running-apps popout keyboard focus on the production host. The real
// ContentWindow and its popouts wrapper run here, not a FloatingWindow, so the
// computed keyboardFocus and native focusability are the ones the shell ships.
// The monitor-sized drawer host must stay unfocusable throughout; a pinned
// popout moves into the card-sized focus companion and releases it on close.
ShellRoot {
    id: root

    property int assertions: 0
    property int step: 0
    property int attempts: 0
    property var fixtureWindow
    property var pill
    property var keys

    readonly property var win: content
    readonly property var focusWindow: content.focusWindow
    readonly property var grab: content.focusGrab
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

    function checkGrabTarget(target, label): void {
        check(grab.windows.length === 1 && grab.windows[0] === target,
            label + ": focus grab targets " + (target === focusWindow ? "the companion" : "the drawer host"));
        check(grab.windows.every(window => window.visible),
            label + ": every focus grab target is visible");
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
            check(focusWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
                "closed popout: companion keyboardFocus is None");
            check(!focusWindow.focusable, "closed popout: companion is not focusable");
            checkGrabTarget(win, "closed popout");

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
            check(focusWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
                "hover open: companion keyboardFocus is None");
            checkGrabTarget(win, "hover open");
            popouts.hasCurrent = false;
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None, "hover close: keyboardFocus stays None");

            // Right-click pins it through the strip's own handler.
            pill.pin("fixture-app", pill);
            step = 2;
        } else if (step === 2) {
            if (!list())
                return;
            check(popouts.hasCurrent && pill.pinned, "right click pins the popout");
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
                "pinned: the monitor-sized window stays None");
            check(!win.focusable, "pinned: the monitor-sized window stays unfocusable");
            check(focusWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.OnDemand,
                "pinned: companion keyboardFocus is OnDemand");
            check(focusWindow.focusable, "pinned: companion is focusable");
            check(focusWindow.WlrLayershell.layer === WlrLayer.Overlay,
                "pinned: companion uses the overlay layer");
            check(focusWindow.color.a === 0, "pinned: companion background is transparent");
            check(focusWindow.surface === "popouts", "pinned: companion targets the popout");
            check(focusWindow.width > 0 && focusWindow.width <= win.width - 2,
                "pinned: companion is at least 2 px narrower than the monitor");
            check(focusWindow.height > 0 && focusWindow.height <= win.height - 2,
                "pinned: companion is at least 2 px shorter than the monitor");
            check(list().activeFocus, "pinned: the window list has active focus");
            check(list().Window.window === focusWindow.contentHost.Window.window,
                "pinned: the popout list lives in the companion");
            check(popouts.pinned === true, "pinned: the popouts wrapper holds the pin");
            checkGrabTarget(focusWindow, "pinned");
            keys.parent = focusWindow.contentHost;
            keys.keyClick(Qt.Key_Escape, Qt.NoModifier, 0);
            check(!popouts.hasCurrent, "Escape closes the pinned popout");
            check(!popouts.pinned && !pill.pinned, "closing releases the pin");
            check(popouts.usesFocusWindow, "closing: companion stays requested during exit");
            check(focusWindow.surface === "popouts", "closing: companion surface survives close request");
            check(focusWindow.visible, "closing: companion stays visible during exit");
            check(popouts.content.Window.window === focusWindow.contentHost.Window.window,
                "closing: popout content stays parented to the companion");
            step = 3;
        } else if (step === 3) {
            const wrapper = content.interactionWrapper.panels.popoutsWrapper;
            if (wrapper.offsetScale < 1) {
                check(wrapper.offsetScale > 0, "closing: slide animation is progressing");
                check(popouts.usesFocusWindow, "closing: companion remains requested");
                check(focusWindow.surface === "popouts", "closing: companion surface is retained");
                check(focusWindow.visible, "closing: companion remains visible");
                check(popouts.content.Window.window === focusWindow.contentHost.Window.window,
                    "closing: popout content remains in the companion");
                check(Math.abs(popouts.content.x - popouts.slideOffset) <= 1,
                    "closing: popout content preserves the animated slide offset");
                check(Math.abs(popouts.content.width - popouts.nonAnimWidth) <= 1,
                    "closing: popout content keeps its full animated width");
            }
            if (wrapper.offsetScale < 1 || focusWindow.surface !== "")
                return;
            check(!popouts.usesFocusWindow, "closed: companion request released");
            check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
                "after Escape: the monitor-sized window stays None");
            check(!win.focusable, "after Escape: the monitor-sized window stays unfocusable");
            check(focusWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
                "after Escape: companion keyboardFocus is None again");
            check(!focusWindow.focusable, "after Escape: companion is not focusable again");
            check(!focusWindow.visible, "after Escape: companion is hidden again");
            checkGrabTarget(win, "after Escape");
            console.log("CAELESTIA_PINNED_FOCUS_PASS " + assertions);
            Qt.quit();
        }
    }
}
