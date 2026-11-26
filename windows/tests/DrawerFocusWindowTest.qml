import QtQuick
import QtTest
import Quickshell
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.modules.drawers
import qs.modules.launcher.services

// The launcher and session use the production ContentWindow and its card-sized
// focus companion. Drawers without a companion must still provide a visible,
// non-activating target for outside-click dismissal. The monitor-sized window
// must stay non-activating throughout.
ShellRoot {
    id: root

    settings.watchFiles: false

    property int assertions: 0
    property int step: 0
    property int attempts: 0
    property var input
    property real sessionOpenLeft: 0
    property var nativeGeometry: null
    property real launcherHeightBeforeFilter: 0
    property int filterSamples: 0

    readonly property var win: content
    readonly property var focusWindow: content.focusWindow
    readonly property var grab: content.focusGrab

    ContentWindow {
        id: content
        screen: Quickshell.screens[0]
        visible: true
        interactionEnabled: true
    }

    QtObject {
        id: appCatalog

        property var applications: ({ values: [] })
        property bool scanCompleted: false
        property string scanError: ""

        function lookup(appId): var {
            return (applications.values ?? []).find(entry => entry.id === appId) ?? null;
        }
        function execute(entry): bool {
            return true;
        }
    }

    QtObject {
        id: appStore

        property var frequencies: ({})

        function frequencyFor(id): int {
            return 0;
        }
        function increment(id): int {
            return 1;
        }
    }

    readonly property Component entryComponent: Component {
        QtObject {
            property string id
            property string name
            property string comment: ""
            property string execString: ""
            property var command: []
            property string icon: ""
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

    function findObject(object, name, seen): var {
        seen = seen ?? [];
        if (!object || seen.indexOf(object) >= 0)
            return null;
        seen.push(object);
        if (object.objectName === name)
            return object;
        for (const child of object.children ?? []) {
            const found = findObject(child, name, seen);
            if (found)
                return found;
        }
        for (const child of object.data ?? []) {
            const found = findObject(child, name, seen);
            if (found)
                return found;
        }
        for (const child of [object.item, object.contentItem]) {
            const found = child && child !== object ? findObject(child, name, seen) : null;
            if (found)
                return found;
        }
        return null;
    }

    function checkGrabTarget(target, label): void {
        check(grab.windows.length === 1 && grab.windows[0] === target,
            label + ": focus grab targets " + (target === focusWindow ? "the companion" : "the drawer host"));
        check(grab.windows.every(window => window.visible),
            label + ": every focus grab target is visible");
    }

    function checkClosed(label): void {
        check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
            label + ": monitor-sized window keyboardFocus is None");
        check(!win.focusable, label + ": monitor-sized window is not focusable");
        check(focusWindow.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
            label + ": companion keyboardFocus is None");
        check(!focusWindow.focusable, label + ": companion is not focusable");
        checkGrabTarget(win, label);
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
        check(focusWindow.width > 0 && focusWindow.width <= win.width - 2,
            label + ": companion is at least 2 px narrower than the monitor");
        check(focusWindow.height > 0 && focusWindow.height <= win.height - 2,
            label + ": companion is at least 2 px shorter than the monitor");
        checkGrabTarget(focusWindow, label);
    }

    function checkDrawerHostGrab(label): void {
        check(win.visible, label + ": drawer host is visible");
        check(!focusWindow.visible, label + ": companion is hidden");
        check(win.WlrLayershell.keyboardFocus === WlrKeyboardFocus.None,
            label + ": drawer host keyboardFocus stays None");
        check(!win.focusable, label + ": drawer host stays unfocusable");
        checkGrabTarget(win, label);
    }

    function captureNativeGeometry(): var {
        return {
            left: focusWindow.margins.left,
            top: focusWindow.margins.top,
            width: focusWindow.implicitWidth,
            height: focusWindow.implicitHeight
        };
    }

    function checkNativeGeometry(label): void {
        check(focusWindow.margins.left === 1 && focusWindow.margins.top === 1,
            label + ": companion native origin stays at the one-pixel inset");
        check(focusWindow.implicitWidth > 0 && focusWindow.implicitWidth <= win.width - 2,
            label + ": companion native width stays strictly below the monitor");
        check(focusWindow.implicitHeight > 0 && focusWindow.implicitHeight <= win.height - 2,
            label + ": companion native height stays strictly below the monitor");
    }

    function checkNativeGeometryStable(label): void {
        check(nativeGeometry !== null, label + ": native geometry baseline exists");
        check(focusWindow.margins.left === nativeGeometry.left
            && focusWindow.margins.top === nativeGeometry.top
            && focusWindow.implicitWidth === nativeGeometry.width
            && focusWindow.implicitHeight === nativeGeometry.height,
            label + ": native margins and implicit size remain stable");
    }

    function layoutPosition(item): point {
        const panels = content.interactionWrapper.panels;
        let x = item.x;
        let y = item.y;
        let parent = item.parent;
        while (parent && parent !== panels) {
            x += parent.x;
            y += parent.y;
            parent = parent.parent;
        }
        return Qt.point(panels.x + x, panels.y + y);
    }

    function checkGeometry(panel, label): void {
        const expected = layoutPosition(panel);
        check(Math.abs(focusWindow.contentX - (expected.x - focusWindow.margins.left)) <= 1,
            label + ": content x " + focusWindow.contentX + " tracks panel x " + expected.x);
        check(Math.abs(focusWindow.contentY - (expected.y - focusWindow.margins.top)) <= 1,
            label + ": content y " + focusWindow.contentY + " tracks panel y " + expected.y);
        check(focusWindow.inputItem !== null, label + ": input region uses the reparented card");
        if (!focusWindow.inputItem)
            return;
        check(Math.abs(focusWindow.inputItem.width - panel.width) <= 1,
            label + ": input width " + focusWindow.inputItem.width + " matches panel width " + panel.width);
        check(Math.abs(focusWindow.inputItem.height - panel.height) <= 1,
            label + ": input height " + focusWindow.inputItem.height + " matches panel height " + panel.height);
    }

    Component.onCompleted: {
        const entries = [];
        for (let i = 0; i < 5; i++)
            entries.push(entryComponent.createObject(root, { id: "alpha-" + i, name: "Alpha " + i }));
        entries.push(entryComponent.createObject(root, { id: "window-0", name: "Window zero" }));
        entries.push(entryComponent.createObject(root, { id: "window-1", name: "Window one" }));
        appCatalog.applications = ({ values: entries });
        appCatalog.scanCompleted = true;
        Apps.catalogOverride = appCatalog;
        Apps.frequencyStoreOverride = appStore;
        Apps.enabledOverride = true;

        GlobalConfig.launcher.enabled = true;
        GlobalConfig.session.enabled = true;
        GlobalConfig.sidebar.enabled = true;
        GlobalConfig.dashboard.enabled = true;
        GlobalConfig.dashboard.showOnHover = false;
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
            const search = findObject(focusWindow.contentHost, "launcherSearch");
            const appList = findObject(focusWindow.contentHost, "launcherAppList");
            const launcher = content.interactionWrapper.panels.launcher;
            if (!search || !search.activeFocus || launcher.offsetScale > 0.001)
                return;
            checkOpen("launcher", "launcher");
            checkNativeGeometry("launcher");
            checkGeometry(launcher, "launcher");
            check(search.Window.window === focusWindow.contentHost.Window.window,
                "launcher: search lives in the companion");
            input.parent = focusWindow.contentHost;
            nativeGeometry = captureNativeGeometry();
            launcherHeightBeforeFilter = launcher.height;
            input.keyClick(Qt.Key_W);
            check(search.text.length === 1, "launcher: typing reaches the companion search field");
            checkNativeGeometryStable("launcher typing");
            input.keyClick(Qt.Key_Escape);
            step = 2;
        } else if (step === 2) {
            if (content.screenState.launcher || focusWindow.surface !== "")
                return;
            checkClosed("launcher closed");
            content.screenState.session = true;
            step = 3;
        } else if (step === 3) {
            const logout = findObject(focusWindow.contentHost, "logoutButton");
            const session = content.interactionWrapper.panels.session;
            if (!logout || !logout.activeFocus || session.offsetScale > 0.001)
                return;
            checkOpen("session", "session");
            checkNativeGeometryStable("session");
            checkGeometry(session, "session");
            check(logout.Window.window === focusWindow.contentHost.Window.window,
                "session: controls live in the companion");
            sessionOpenLeft = focusWindow.contentX;
            input.keyClick(Qt.Key_Escape);
            check(!content.screenState.session, "session: Escape requests close");
            check(session.usesFocusWindow, "session: companion stays requested during exit");
            check(focusWindow.surface === "session", "session: companion surface survives close request");
            check(focusWindow.visible, "session: companion stays visible during exit");
            check(logout.Window.window === focusWindow.contentHost.Window.window,
                "session: controls stay parented to the companion during exit");
            step = 4;
        } else if (step === 4) {
            const session = content.interactionWrapper.panels.session;
            const wrapper = content.interactionWrapper.panels.sessionWrapper;
            if (session.offsetScale < 1) {
                check(session.offsetScale > 0, "session exiting: slide animation is progressing");
                check(session.usesFocusWindow, "session exiting: companion remains requested");
                check(focusWindow.surface === "session", "session exiting: companion surface is retained");
                check(focusWindow.visible, "session exiting: companion remains visible");
                checkNativeGeometryStable("session exiting");
                check(focusWindow.contentX > sessionOpenLeft,
                    "session exiting: content follows the slide offset");
                checkGeometry(session, "session exiting");
                const logout = findObject(focusWindow.contentHost, "logoutButton");
                check(logout && logout.Window.window === focusWindow.contentHost.Window.window,
                    "session exiting: controls remain parented to the companion");
            }
            if (content.screenState.session || focusWindow.surface !== "")
                return;
            check(!session.usesFocusWindow, "session closed: companion request released");
            checkClosed("session closed");
            content.screenState.sidebar = true;
            step = 5;
        } else if (step === 5) {
            const sidebar = content.interactionWrapper.panels.sidebar;
            if (sidebar.offsetScale > 0.001)
                return;
            checkDrawerHostGrab("sidebar");
            content.screenState.sidebar = false;
            step = 6;
        } else if (step === 6) {
            const sidebar = content.interactionWrapper.panels.sidebar;
            if (sidebar.offsetScale < 1)
                return;
            content.screenState.dashboard = true;
            step = 7;
        } else if (step === 7) {
            const dashboard = content.interactionWrapper.panels.dashboard;
            if (dashboard.offsetScale > 0.001)
                return;
            checkDrawerHostGrab("dashboard");
            content.screenState.dashboard = false;
            step = 8;
        } else if (step === 8) {
            const dashboard = content.interactionWrapper.panels.dashboard;
            if (dashboard.offsetScale < 1)
                return;
            checkDrawerHostGrab("drawers closed");
            Apps.launchEnabledOverride = null;
            Apps.enabledOverride = null;
            Apps.catalogOverride = null;
            Apps.frequencyStoreOverride = null;
            console.log("CAELESTIA_DRAWER_FOCUS_PASS " + assertions);
            Qt.quit();
        }
    }
}


