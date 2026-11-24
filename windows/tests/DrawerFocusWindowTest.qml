import QtQuick
import QtTest
import Quickshell
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.modules.drawers

// The launcher and session use the production ContentWindow and its card-sized
// focus companion. The monitor-sized window must stay non-activating while the
// companion owns keyboard focus, then both must return to None on Escape.
ShellRoot {
    id: root

    settings.watchFiles: false

    property int assertions: 0
    property int step: 0
    property int attempts: 0
    property var input

    readonly property var win: content
    readonly property var focusWindow: content.focusWindow
    readonly property var grab: content.focusGrab

    ContentWindow {
        id: content
        screen: Quickshell.screens[0]
        visible: true
        interactionEnabled: true
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

    function checkClosed(label): void {
        check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
            label + ": monitor-sized window keyboardFocus is None");
        check(!win.focusable, label + ": monitor-sized window is not focusable");
        check(focusWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
            label + ": companion keyboardFocus is None");
        check(!focusWindow.focusable, label + ": companion is not focusable");
        check(grab.windows.length === 1 && grab.windows[0] === focusWindow,
            label + ": focus grab targets the companion");
    }

    function checkOpen(surface, label): void {
        check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
            label + ": monitor-sized window keyboardFocus stays None");
        check(!win.focusable, label + ": monitor-sized window stays unfocusable");
        check(focusWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.OnDemand,
            label + ": companion keyboardFocus is OnDemand");
        check(focusWindow.focusable, label + ": companion is focusable");
        check(focusWindow.visible, label + ": companion is visible");
        check(focusWindow.WlrLayershell.layer === WlrLayer.Overlay,
            label + ": companion uses the overlay layer");
        check(focusWindow.color.a === 0, label + ": companion background is transparent");
        check(focusWindow.surface === surface,
            label + ": companion targets " + surface);
        check(focusWindow.width > 0 && focusWindow.width < win.width,
            label + ": companion is narrower than the monitor");
        check(focusWindow.height > 0 && focusWindow.height < win.height,
            label + ": companion is shorter than the monitor");
        check(grab.windows.length === 1 && grab.windows[0] === focusWindow,
            label + ": focus grab targets the companion");
    }

    function checkGeometry(panel, label): void {
        const panels = content.interactionWrapper.panels;
        const expectedX = Math.round(panels.x + panel.x);
        const expectedY = Math.round(panels.y + panel.y);
        check(Math.abs(focusWindow.margins.left - expectedX) <= 1,
            label + ": companion x " + focusWindow.margins.left + " follows panel x " + expectedX);
        check(Math.abs(focusWindow.margins.top - expectedY) <= 1,
            label + ": companion y " + focusWindow.margins.top + " follows panel y " + expectedY);
        check(Math.abs(focusWindow.width - Math.round(panel.width)) <= 1,
            label + ": companion width " + focusWindow.width + " matches panel width " + panel.width);
        check(Math.abs(focusWindow.height - Math.round(panel.height)) <= 1,
            label + ": companion height " + focusWindow.height + " matches panel height " + panel.height);
    }

    Component.onCompleted: {
        GlobalConfig.launcher.enabled = true;
        GlobalConfig.session.enabled = true;
        content.screenState.bar = true;
        input = keyComponent.createObject(content.contentItem);
    }

    Timer {
        interval: 100
        repeat: true
        running: true

        onTriggered: {
            try {
                root.advance();
            } catch (error) {
                console.error("CAELESTIA_DRAWER_FOCUS_FAIL " + error);
                Qt.exit(1);
            }
        }
    }

    function advance(): void {
        if (++attempts > 120)
            throw new Error("timed out at step " + step);

        if (step === 0) {
            checkClosed("closed");
            content.screenState.launcher = true;
            step = 1;
        } else if (step === 1) {
            const search = CUtils.findChild(focusWindow.contentHost, "launcherSearch");
            const launcher = content.interactionWrapper.panels.launcher;
            if (!search || !search.activeFocus || launcher.offsetScale > 0.001)
                return;
            checkOpen("launcher", "launcher");
            checkGeometry(launcher, "launcher");
            check(search.Window.window === focusWindow.contentHost.Window.window,
                "launcher: search lives in the companion");
            input.parent = focusWindow.contentHost;
            input.keyClick(Qt.Key_A);
            check(search.text.length === 1, "launcher: typing reaches the companion search field");
            input.keyClick(Qt.Key_Escape);
            step = 2;
        } else if (step === 2) {
            if (content.screenState.launcher || focusWindow.surface !== "")
                return;
            checkClosed("launcher closed");
            content.screenState.session = true;
            step = 3;
        } else if (step === 3) {
            const logout = CUtils.findChild(focusWindow.contentHost, "logoutButton");
            const session = content.interactionWrapper.panels.session;
            if (!logout || !logout.activeFocus || session.offsetScale > 0.001)
                return;
            checkOpen("session", "session");
            checkGeometry(content.interactionWrapper.panels.sessionWrapper, "session");
            check(logout.Window.window === focusWindow.contentHost.Window.window,
                "session: controls live in the companion");
            input.keyClick(Qt.Key_Escape);
            step = 4;
        } else if (step === 4) {
            if (content.screenState.session || focusWindow.surface !== "")
                return;
            checkClosed("session closed");
            console.log("CAELESTIA_DRAWER_FOCUS_PASS " + assertions);
            Qt.quit();
        }
    }
}
