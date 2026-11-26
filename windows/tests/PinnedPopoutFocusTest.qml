import QtQuick
import QtTest
import Quickshell
import Quickshell.Wayland
import Caelestia
import qs.services as Services
import qs.modules.drawers
import qs.modules.nexus as Nexus
import qs.modules.windowinfo as WindowInfoModule

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
    property var fixtureWindowB
    property var pill
    property var keys
    property var nativeGeometry: null

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

    QtObject {
        id: hyprBackend

        property bool initialized: true
        property bool foregroundValidated: true
        property var monitors: ({ values: [] })
        property var workspaces: ({ values: [] })
        property var toplevels: ({ values: [] })
        property var activeToplevel: null
        property var focusedWorkspace: null
        property var focusedMonitor: null
        property bool capsLock: false
        property bool numLock: false
        property string kbLayout: "us"
        property string kbLayoutFull: "US"
        function dispatch(): void {
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

    function captureNativeGeometry(): var {
        return {
            left: focusWindow.margins.left,
            top: focusWindow.margins.top,
            width: focusWindow.implicitWidth,
            height: focusWindow.implicitHeight
        };
    }

    function checkNativeGeometryStable(label): void {
        check(nativeGeometry !== null, label + ": native geometry baseline exists");
        check(focusWindow.margins.left === nativeGeometry.left
            && focusWindow.margins.top === nativeGeometry.top
            && focusWindow.implicitWidth === nativeGeometry.width
            && focusWindow.implicitHeight === nativeGeometry.height,
            label + ": native margins and implicit size remain stable");
        check(focusWindow.implicitWidth <= win.width - focusWindow.fullscreenWidthClearance,
            label + ": companion keeps the fullscreen width clearance");
        check(focusWindow.implicitHeight <= win.height,
            label + ": companion height stays within the monitor");
    }

    function itemBoundsInHost(item, host): rect {
        const points = [
            item.mapToItem(host, 0, 0),
            item.mapToItem(host, item.width, 0),
            item.mapToItem(host, 0, item.height),
            item.mapToItem(host, item.width, item.height)
        ];
        let left = Infinity, top = Infinity, right = -Infinity, bottom = -Infinity;
        for (const point of points) {
            left = Math.min(left, point.x);
            top = Math.min(top, point.y);
            right = Math.max(right, point.x);
            bottom = Math.max(bottom, point.y);
        }
        return right <= left || bottom <= top ? Qt.rect(0, 0, 0, 0)
            : Qt.rect(left, top, right - left, bottom - top);
    }

    function intersectBounds(first, second): rect {
        const left = Math.max(first.x, second.x);
        const top = Math.max(first.y, second.y);
        const right = Math.min(first.x + first.width, second.x + second.width);
        const bottom = Math.min(first.y + first.height, second.y + second.height);
        return right <= left || bottom <= top ? Qt.rect(0, 0, 0, 0)
            : Qt.rect(left, top, right - left, bottom - top);
    }

    function integerBounds(bounds): rect {
        if (!bounds || bounds.width <= 0 || bounds.height <= 0)
            return Qt.rect(0, 0, 0, 0);
        const left = Math.floor(bounds.x);
        const top = Math.floor(bounds.y);
        return Qt.rect(left, top, Math.ceil(bounds.x + bounds.width) - left,
            Math.ceil(bounds.y + bounds.height) - top);
    }

    function rectText(bounds): string {
        return "(" + bounds.x + "," + bounds.y + " " + bounds.width + "x" + bounds.height + ")";
    }

    function checkInputTracking(label): void {
        const proxy = focusWindow.inputItem;
        check(proxy !== null, label + ": input region uses the popout viewport");
        if (!proxy || !proxy.contentItem)
            return;
        const transformed = itemBoundsInHost(proxy.contentItem, focusWindow.contentHost);
        const expected = proxy.clip
            ? intersectBounds(transformed, Qt.rect(proxy.x, proxy.y, proxy.width, proxy.height))
            : transformed;
        check(Math.abs(focusWindow.inputBounds.x - expected.x) <= 0.76
            && Math.abs(focusWindow.inputBounds.y - expected.y) <= 0.76
            && Math.abs(focusWindow.inputBounds.width - expected.width) <= 0.76
            && Math.abs(focusWindow.inputBounds.height - expected.height) <= 0.76,
            label + ": input bounds " + rectText(focusWindow.inputBounds)
            + " track the transformed clipped card " + rectText(expected));
        const region = integerBounds(expected);
        check(Math.abs(focusWindow.inputRegion.x - region.x) <= 1
            && Math.abs(focusWindow.inputRegion.y - region.y) <= 1
            && Math.abs(focusWindow.inputRegion.width - region.width) <= 1
            && Math.abs(focusWindow.inputRegion.height - region.height) <= 1,
            label + ": native mask follows the transformed clipped card");
    }

    function list(): var {
        const current = popouts.current;
        return current ? CUtils.findChild(current, "activeWindowWindowList") : null;
    }

    Component.onCompleted: {
        fixtureWindow = fixture.createObject(root, {
            address: "1",
            title: "Foreground fixture window"
        });
        fixtureWindowB = fixture.createObject(root, {
            address: "2",
            title: "Previewed fixture window"
        });
        hyprBackend.toplevels = ({ values: [fixtureWindow, fixtureWindowB] });
        hyprBackend.activeToplevel = fixtureWindow;
        Services.Hypr.enabled = true;
        Services.Hypr.backend = hyprBackend;
        Services.RunningApps.source = [fixtureWindow, fixtureWindowB];
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
            check(focusWindow.width > 0 && focusWindow.width <= win.width - focusWindow.fullscreenWidthClearance,
                "pinned: companion keeps the fullscreen width clearance");
            check(focusWindow.height > 0 && focusWindow.height <= win.height,
                "pinned: companion height stays within the monitor");
            check(focusWindow.margins.left === focusWindow.bandX && focusWindow.margins.top === 0
                && focusWindow.implicitWidth === focusWindow.bandWidth,
                "pinned: native geometry matches the stable popout band");
            check(list().activeFocus, "pinned: the window list has active focus");
            check(list().Window.window === focusWindow.contentHost.Window.window,
                "pinned: the popout list lives in the companion");
            check(popouts.pinned === true, "pinned: the popouts wrapper holds the pin");
            checkGrabTarget(focusWindow, "pinned");
            check(focusWindow.inputItem !== null, "pinned: input region uses the popout viewport");
            check(focusWindow.inputItem.clip === true, "pinned: popout viewport clips the transformed card");
            checkInputTracking("pinned");
            nativeGeometry = captureNativeGeometry();
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
                checkNativeGeometryStable("closing");
                checkInputTracking("closing");
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

            // Reopen the popout for the non-foreground window after the focus
            // lifecycle assertions. The next timer pass activates the real
            // chevron once the popout content exists.
            Services.RunningApps.previewGroupId = "fixture-app";
            Services.RunningApps.previewWindowId = "2";
            popouts.currentName = "activewindow";
            popouts.hasCurrent = true;
            step = 4;
        } else if (step === 4) {
            if (!list())
                return;
            const state = popouts.current?.popouts ?? null;
            check(state !== null, "detach: active window popout exposes its state");
            check(Services.Hypr.activeToplevel === fixtureWindow,
                "detach precondition: foreground remains the first window");

            hyprBackend.toplevels = ({ values: [fixtureWindow] });
            check(popouts.current.previewClient === null,
                "missing preview: the tracked client lookup is empty");
            state.detachRequested("winfo");
            check(WindowInfoModule.WindowInfoFactory.windowCount === 0,
                "missing preview: detach opens no WindowInfo window");
            check(popouts.hasCurrent === true,
                "missing preview: detach leaves the popout unchanged");

            hyprBackend.toplevels = ({ values: [fixtureWindow, fixtureWindowB] });
            check(popouts.current.previewClient === fixtureWindowB,
                "detach target: the previewed non-foreground window resolves");
            state.detachRequested("winfo");
            check(WindowInfoModule.WindowInfoFactory.windowCount === 1,
                "detach opens one WindowInfo window");
            check(WindowInfoModule.WindowInfoFactory.windows[0].client === fixtureWindowB,
                "detach inspects the previewed non-foreground window");
            check(WindowInfoModule.WindowInfoFactory.windows[0].client !== fixtureWindow,
                "detach never falls back to the foreground window");
            WindowInfoModule.WindowInfoFactory.closeAll();
            check(WindowInfoModule.WindowInfoFactory.windowCount === 0,
                "detach test releases the WindowInfo window");

            state.detachRequested("audio");
            check(Nexus.WindowFactory.windowCount === 1,
                "one-argument audio detach opens Nexus without an argument error");
            Nexus.WindowFactory.closeAll();
            attempts = 0;
            step = 5;
        } else if (step === 5) {
            if (Nexus.WindowFactory.windowCount !== 0 && ++attempts < 10)
                return;
            check(Nexus.WindowFactory.windowCount === 0,
                "audio detach test releases Nexus");
            Services.Hypr.backend = null;
            Services.Hypr.enabled = false;
            console.log("CAELESTIA_PINNED_FOCUS_PASS " + assertions);
            Qt.quit();
        }
    }
}
