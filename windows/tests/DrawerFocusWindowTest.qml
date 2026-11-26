import QtQuick
import QtTest
import Quickshell
import Quickshell.Wayland
import Caelestia
import Caelestia.Config
import qs.components
import qs.modules.drawers
import qs.modules.launcher.services
import qs.services as Services

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
    property int initialLauncherCount: 0
    property int launcherOpenSamples: 0
    property int sessionOpenSamples: 0
    property int filterSamples: 0
    property int intermediateFilterSamples: 0
    property int settledFilterFrames: 0
    property real lastFilterHeight: -1
    property int hoverInsideAttempts: 0
    property int hoverOutsideAttempts: 0
    property int wallpaperSettledFrames: 0
    property real lastWallpaperWidth: -1
    property string selectedAppId: ""

    readonly property var win: content
    readonly property var focusWindow: content.focusWindow
    readonly property var grab: content.focusGrab

    ContentWindow {
        id: content
        screen: Quickshell.screens[0]
        visible: true
        interactionEnabled: true
    }

    Item {
        id: shearHost
        width: 300
        height: 300

        Item {
            id: shearSource
            width: 300
            height: 300
        }

        QtObject {
            id: shearFocusWindow
            property string surface: "shear"
            property Item contentHost: shearHost
            property real contentX: 0
            property real contentY: 0
            property real viewportX: 0
            property real viewportY: 0
            property real viewportWidth: 300
            property real viewportHeight: 300
            property bool viewportClips: true
        }

        FocusCardProxy {
            id: shearProxy
            focusWindow: shearFocusWindow
            sourceItem: shearSource
            focusSurface: "shear"
            inputTransformMatrix: Qt.matrix4x4(1, 0.5, 0, -25,
                0, 1, 0, 0,
                0, 0, 1, 0,
                0, 0, 0, 1)
            contentItem: shearContent
            active: true

            Item {
                id: shearContent
                x: 0
                y: 0
                width: 100
                height: 100
            }
        }
    }

    QtObject {
        id: appCatalog

        property var applications: ({ values: [] })
        property bool scanCompleted: false
        property string scanError: ""
        property var executed: []

        function lookup(appId): var {
            return (applications.values ?? []).find(entry => entry.id === appId) ?? null;
        }
        function execute(entry): bool {
            executed.push(entry?.id ?? "");
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

    function findLauncherAppList(object): var {
        return findObject(object, "combinedLauncherAppList") ?? findObject(object, "launcherAppList");
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
        check(focusWindow.width > 0 && focusWindow.width <= win.width - focusWindow.minimumFullscreenWidthClearance,
            label + ": companion keeps the guaranteed fullscreen width clearance");
        check(focusWindow.height > 0 && focusWindow.height <= win.height,
            label + ": companion height stays within the monitor");
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
        check(focusWindow.margins.left === focusWindow.bandX,
            label + ": companion native x matches the stable surface band");
        check(focusWindow.margins.top === 0,
            label + ": companion native y stays at the monitor top");
        check(focusWindow.implicitWidth === focusWindow.bandWidth,
            label + ": companion native width matches the stable surface band");
        check(focusWindow.implicitWidth <= focusWindow.screen.width - focusWindow.minimumFullscreenWidthClearance,
            label + ": companion native width keeps the guaranteed fullscreen clearance");
        check(focusWindow.implicitHeight === Math.max(1, Math.round(focusWindow.screen.height)),
            label + ": companion native height matches the fixed band height");
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

    function itemBoundsInHost(item, host): rect {
        if (!item || !host)
            return Qt.rect(0, 0, 0, 0);
        const points = [
            item.mapToItem(host, 0, 0),
            item.mapToItem(host, item.width, 0),
            item.mapToItem(host, 0, item.height),
            item.mapToItem(host, item.width, item.height)
        ];
        let left = Infinity;
        let top = Infinity;
        let right = -Infinity;
        let bottom = -Infinity;
        for (const point of points) {
            left = Math.min(left, point.x);
            top = Math.min(top, point.y);
            right = Math.max(right, point.x);
            bottom = Math.max(bottom, point.y);
        }
        if (!isFinite(left) || right <= left || bottom <= top)
            return Qt.rect(0, 0, 0, 0);
        return Qt.rect(left, top, right - left, bottom - top);
    }

    function intersectBounds(first, second): rect {
        const left = Math.max(first.x, second.x);
        const top = Math.max(first.y, second.y);
        const right = Math.min(first.x + first.width, second.x + second.width);
        const bottom = Math.min(first.y + first.height, second.y + second.height);
        if (right <= left || bottom <= top)
            return Qt.rect(0, 0, 0, 0);
        return Qt.rect(left, top, right - left, bottom - top);
    }

    function integerBounds(bounds): rect {
        if (!bounds || bounds.width <= 0 || bounds.height <= 0)
            return Qt.rect(0, 0, 0, 0);
        const left = Math.floor(bounds.x);
        const top = Math.floor(bounds.y);
        const right = Math.ceil(bounds.x + bounds.width);
        const bottom = Math.ceil(bounds.y + bounds.height);
        return Qt.rect(left, top, right - left, bottom - top);
    }

    function rectText(bounds): string {
        return "(" + bounds.x + "," + bounds.y + " " + bounds.width + "x" + bounds.height + ")";
    }

    function checkRectClose(actual, expected, label): void {
        check(Math.abs(actual.x - expected.x) <= 0.76
            && Math.abs(actual.y - expected.y) <= 0.76
            && Math.abs(actual.width - expected.width) <= 0.76
            && Math.abs(actual.height - expected.height) <= 0.76,
            label + ": bounds " + rectText(actual) + " match transformed card " + rectText(expected));
    }

    function checkInputTracking(label): void {
        const proxy = focusWindow.inputItem;
        check(proxy !== null, label + ": input region uses the reparented card");
        if (!proxy || !proxy.contentItem)
            return;
        const transformed = itemBoundsInHost(proxy.contentItem, focusWindow.contentHost);
        const expected = proxy.clip
            ? intersectBounds(transformed, Qt.rect(proxy.x, proxy.y, proxy.width, proxy.height))
            : transformed;
        checkRectClose(focusWindow.inputBounds, expected, label);
        const expectedRegion = integerBounds(expected);
        if (proxy.inputHasShear) {
            check(focusWindow.inputRegion.width === 0 && focusWindow.inputRegion.height === 0
                && proxy.inputMaskSlices.length > 0,
                label + ": sheared input uses banded slices instead of one rectangular mask");
            return;
        }
        check(Math.abs(focusWindow.inputRegion.x - expectedRegion.x) <= 1
            && Math.abs(focusWindow.inputRegion.y - expectedRegion.y) <= 1
            && Math.abs(focusWindow.inputRegion.width - expectedRegion.width) <= 1
            && Math.abs(focusWindow.inputRegion.height - expectedRegion.height) <= 1,
            label + ": native mask " + rectText(Qt.rect(focusWindow.inputRegion.x, focusWindow.inputRegion.y,
                focusWindow.inputRegion.width, focusWindow.inputRegion.height))
            + " follows the transformed clipped card " + rectText(expectedRegion));
    }

    function checkSearchInside(search, label): void {
        const bounds = itemBoundsInHost(search, focusWindow.contentHost);
        check(bounds.width > 0 && bounds.height > 0,
            label + ": search has measurable companion geometry");
        check(bounds.x >= -1 && bounds.y >= -1
            && bounds.x + bounds.width <= focusWindow.width + 1
            && bounds.y + bounds.height <= focusWindow.height + 1,
            label + ": search stays inside the companion instead of clipping off the bottom");
        check(bounds.y + bounds.height <= focusWindow.inputBounds.y + focusWindow.inputBounds.height + 1,
            label + ": search bottom stays inside the animated launcher card");
    }

    function checkLauncherBandContains(bounds, label): void {
        const panels = content.interactionWrapper.panels;
        const bandLeft = focusWindow.margins.left;
        const bandRight = bandLeft + focusWindow.width;
        check(panels.x >= bandLeft - 1 && panels.x + panels.width <= bandRight + 1,
            label + ": companion band contains the settled panels span");
        check(bounds.width >= 700,
            label + ": wallpaper fixture uses a wide launcher card");
        const sceneLeft = bounds.x + bandLeft;
        const sceneRight = sceneLeft + bounds.width;
        const visibleLeft = Math.max(0, sceneLeft);
        const visibleRight = Math.min(focusWindow.screen.width, sceneRight);
        check(visibleLeft >= bandLeft - 1 && visibleRight <= bandRight + 1,
            label + ": visible wide card geometry stays inside the companion band");
    }

    function highlightIsAligned(appList): bool {
        return !!appList && !!appList.currentItem && !!appList.highlightItem
            && Math.abs(appList.highlightItem.y - appList.currentItem.y) <= 1
            && Math.abs(appList.highlightItem.implicitHeight - appList.currentItem.implicitHeight) <= 1;
    }

    function checkHighlightAligned(appList, label): void {
        if (!appList || !appList.currentItem)
            return;
        check(appList.highlightItem !== null && appList.highlightItem !== undefined,
            label + ": app list has a live highlight item");
        if (!appList.highlightItem)
            return;
        check(Math.abs(appList.highlightItem.y - appList.currentItem.y) <= 1,
            label + ": highlight y " + appList.highlightItem.y + " follows current row y " + appList.currentItem.y);
        check(Math.abs(appList.highlightItem.implicitHeight - appList.currentItem.implicitHeight) <= 1,
            label + ": highlight height follows the current row");
    }

    function checkGeometry(panel, label): void {
        const expected = layoutPosition(panel);
        check(Math.abs(focusWindow.contentX - (expected.x - focusWindow.margins.left)) <= 1,
            label + ": content x " + focusWindow.contentX + " tracks panel x " + expected.x);
        check(Math.abs(focusWindow.contentY - (expected.y - focusWindow.margins.top)) <= 1,
            label + ": content y " + focusWindow.contentY + " tracks panel y " + expected.y);
        checkInputTracking(label);
    }

    function resetNativeGeometryBaseline(): void {
        nativeGeometry = null;
    }

    function ensureNativeGeometryBaseline(label): void {
        if (nativeGeometry === null)
            nativeGeometry = captureNativeGeometry();
        else
            checkNativeGeometryStable(label);
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
        Apps.launchEnabledOverride = true;

        check(shearProxy.inputHasShear, "shear fixture: proxy detects off-diagonal transform terms");
        check(shearProxy.inputBounds.width > 100,
            "shear fixture: axis-aligned bounding box is wider than the card");
        check(shearProxy.containsPoint(10, 50),
            "shear fixture: inverse hit-test accepts an interior point near the left edge");
        check(shearProxy.containsPoint(90, 50),
            "shear fixture: inverse hit-test accepts an interior point near the right edge");
        check(!shearProxy.containsPoint(-10, 50),
            "shear fixture: inverse hit-test rejects a point inside the bounds but left of the quad");
        check(!shearProxy.containsPoint(110, 50),
            "shear fixture: inverse hit-test rejects a point inside the bounds but right of the quad");
        check(shearProxy.maskContainsPoint(10, 50),
            "shear fixture: banded input mask accepts an interior point near the left edge");
        check(shearProxy.maskContainsPoint(90, 50),
            "shear fixture: banded input mask accepts an interior point near the right edge");
        check(!shearProxy.maskContainsPoint(-10, 50),
            "shear fixture: banded input mask rejects a point inside the bounds but left of the quad");
        check(!shearProxy.maskContainsPoint(110, 50),
            "shear fixture: banded input mask rejects a point inside the bounds but right of the quad");
        check(shearProxy.inputRegionBounds.width === 0 && shearProxy.inputMaskSlices.length > 0,
            "shear fixture: sheared cards use banded input slices instead of one rectangular mask");

        GlobalConfig.launcher.enabled = true;
        GlobalConfig.session.enabled = true;
        GlobalConfig.sidebar.enabled = true;
        GlobalConfig.dashboard.enabled = true;
        GlobalConfig.dashboard.showOnHover = false;
        content.screenState.bar = true;
        input = keyComponent.createObject(content.contentItem);
    }

    Timer {
        interval: 16
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
        if (++attempts > 900)
            throw new Error("timed out at step " + step);

        if (step === 0) {
            checkClosed("closed");
            resetNativeGeometryBaseline();
            launcherOpenSamples = 0;
            content.screenState.launcher = true;
            step = 1;
        } else if (step === 1) {
            const search = findObject(focusWindow.contentHost, "launcherSearch");
            const appList = findLauncherAppList(focusWindow.contentHost);
            const launcher = content.interactionWrapper.panels.launcher;
            if (focusWindow.surface === "launcher")
                ensureNativeGeometryBaseline("launcher opening");
            if (launcher.offsetScale > 0.001) {
                if (launcher.offsetScale < 1) {
                    launcherOpenSamples++;
                    checkNativeGeometryStable("launcher opening");
                    if (focusWindow.inputItem?.contentItem)
                        checkInputTracking("launcher opening");
                }
                return;
            }
            if (!search || !search.activeFocus || !appList)
                return;
            check(launcherOpenSamples >= 2, "launcher: opening animation was sampled across frames");
            checkOpen("launcher", "launcher");
            checkNativeGeometry("launcher");
            checkGeometry(launcher, "launcher");
            check(search.Window.window === focusWindow.contentHost.Window.window,
                "launcher: search lives in the companion");
            check(appList.count === 7, "launcher: unfiltered result count is seven");
            input.parent = focusWindow.contentHost;
            hoverInsideAttempts = 0;
            step = 2;
        } else if (step === 2) {
            const bounds = focusWindow.inputBounds;
            if (!focusWindow.pointerHovered) {
                check(hoverInsideAttempts < 8, "launcher: hover inside the transformed card reaches the companion");
                hoverInsideAttempts++;
                input.mouseMove(focusWindow.contentHost, bounds.x + bounds.width / 2, bounds.y + bounds.height / 2);
                return;
            }
            check(true, "launcher: hover inside the transformed card is accepted");
            input.mouseMove(focusWindow.contentHost, 1, 1);
            hoverOutsideAttempts = 0;
            step = 3;
        } else if (step === 3) {
            if (focusWindow.pointerHovered) {
                check(hoverOutsideAttempts < 8, "launcher: hover outside the transformed card leaves the companion predicate");
                hoverOutsideAttempts++;
                input.mouseMove(focusWindow.contentHost, 1, 1);
                return;
            }
            check(true, "launcher: hover outside the transformed card is rejected");
            const appList = findLauncherAppList(focusWindow.contentHost);
            const launcher = content.interactionWrapper.panels.launcher;
            check(appList !== null, "launcher: Windows combined app list is present");
            launcherHeightBeforeFilter = launcher.height;
            initialLauncherCount = appList.count;
            const wallpapers = [];
            for (let i = 0; i < 5; i++) {
                wallpapers.push({
                    path: "C:/fixture/wallpaper-" + i + ".webp",
                    relativePath: "wallpaper-" + i + ".webp",
                    name: "wallpaper-" + i + ".webp",
                    parentDir: "C:/fixture",
                    onDisk: false
                });
            }
            Services.Wallpapers.files = wallpapers;
            const search = findObject(focusWindow.contentHost, "launcherSearch");
            check(search !== null, "launcher wallpaper: search field is present");
            search.text = ">wallpaper ";
            wallpaperSettledFrames = 0;
            lastWallpaperWidth = -1;
            step = 30;
        } else if (step === 30) {
            const search = findObject(focusWindow.contentHost, "launcherSearch");
            const wallpaperList = findObject(focusWindow.contentHost, "launcherWallpaperList");
            if (!search || !wallpaperList || search.text !== ">wallpaper " || wallpaperList.count < 2)
                return;
            const bounds = focusWindow.inputBounds;
            const widthDelta = lastWallpaperWidth < 0 ? Infinity : Math.abs(bounds.width - lastWallpaperWidth);
            if (bounds.width >= 700 && widthDelta <= 0.01)
                wallpaperSettledFrames++;
            else
                wallpaperSettledFrames = 0;
            lastWallpaperWidth = bounds.width;
            checkNativeGeometryStable("launcher wallpaper");
            checkInputTracking("launcher wallpaper");
            if (wallpaperSettledFrames < 3)
                return;
            check(wallpaperList.count >= 2, "launcher wallpaper: fixture entries fill the wide picker");
            checkLauncherBandContains(bounds, "launcher wallpaper");
            search.text = "";
            step = 31;
        } else if (step === 31) {
            const search = findObject(focusWindow.contentHost, "launcherSearch");
            const appList = findLauncherAppList(focusWindow.contentHost);
            const launcher = content.interactionWrapper.panels.launcher;
            if (!search || !appList)
                return;
            if (search.text !== "" || appList.count !== initialLauncherCount
                || Math.abs(launcher.height - launcherHeightBeforeFilter) > 1)
                return;
            filterSamples = 0;
            intermediateFilterSamples = 0;
            settledFilterFrames = 0;
            lastFilterHeight = -1;
            input.keyClick(Qt.Key_W);
            check(search.text.length === 1, "launcher: typing reaches the companion search field");
            checkNativeGeometryStable("launcher typing");
            step = 4;
        } else if (step === 4) {
            const search = findObject(focusWindow.contentHost, "launcherSearch");
            const appList = findLauncherAppList(focusWindow.contentHost);
            const launcher = content.interactionWrapper.panels.launcher;
            if (!search || !appList)
                return;
            filterSamples++;
            checkNativeGeometryStable("launcher filtering");
            checkInputTracking("launcher filtering");
            checkSearchInside(search, "launcher filtering");
            checkHighlightAligned(appList, "launcher filtering");

            const height = launcher.height;
            const delta = lastFilterHeight < 0 ? Infinity : Math.abs(height - lastFilterHeight);
            if (height < launcherHeightBeforeFilter - 1 && delta > 0.01)
                intermediateFilterSamples++;
            if (appList.count === 2 && height < launcherHeightBeforeFilter - 1) {
                if (delta <= 0.01)
                    settledFilterFrames++;
                else
                    settledFilterFrames = 0;
            } else {
                settledFilterFrames = 0;
            }
            lastFilterHeight = height;
            if (settledFilterFrames < 3)
                return;

            check(appList.count === 2, "launcher: filtering reaches the two real Window results");
            check(launcher.height < launcherHeightBeforeFilter,
                "launcher: filtering shrinks the card height");
            check(intermediateFilterSamples >= 2,
                "launcher: filtering height animation was sampled across intermediate frames");
            check(filterSamples >= intermediateFilterSamples + 3,
                "launcher: filtering was observed beyond the final settle frames");
            check(appList.currentIndex === 0, "launcher: filtering resets the current row");
            input.keyClick(Qt.Key_Down);
            check(appList.currentIndex === 1, "launcher: Down moves keyboard selection");
            step = 5;
        } else if (step === 5) {
            const appList = findLauncherAppList(focusWindow.contentHost);
            check(appList !== null, "launcher keyboard down: app list remains live");
            if (!highlightIsAligned(appList))
                return;
            checkHighlightAligned(appList, "launcher keyboard down");
            input.keyClick(Qt.Key_Up);
            check(appList.currentIndex === 0, "launcher: Up moves keyboard selection back");
            step = 6;
        } else if (step === 6) {
            const appList = findLauncherAppList(focusWindow.contentHost);
            input.keyClick(Qt.Key_Down);
            check(appList.currentIndex === 1, "launcher: Down selects the second filtered row");
            step = 7;
        } else if (step === 7) {
            const appList = findLauncherAppList(focusWindow.contentHost);
            check(appList !== null, "launcher keyboard selection: app list remains live");
            if (!highlightIsAligned(appList))
                return;
            checkHighlightAligned(appList, "launcher keyboard selection");
            const filtered = Apps.search("W");
            check(filtered.length === 2, "launcher: keyboard selection uses the filtered result model");
            selectedAppId = filtered[appList.currentIndex]?.id ?? "";
            check(selectedAppId.length > 0, "launcher: keyboard selection has an application");
            input.keyClick(Qt.Key_Return);
            check(appCatalog.executed.indexOf(selectedAppId) >= 0,
                "launcher: Enter launches the keyboard-selected application; requests "
                + Apps.launchRequests + " state " + Apps.lastLaunchState + " error " + Apps.lastLaunchError);
            check(!content.screenState.launcher, "launcher: confirmed selection closes the drawer");
            step = 8;
        } else if (step === 8) {
            if (content.screenState.launcher || focusWindow.surface !== "")
                return;
            checkClosed("launcher closed");
            resetNativeGeometryBaseline();
            sessionOpenSamples = 0;
            content.screenState.session = true;
            step = 9;
        } else if (step === 9) {
            const logout = findObject(focusWindow.contentHost, "logoutButton");
            const session = content.interactionWrapper.panels.session;
            if (focusWindow.surface === "session")
                ensureNativeGeometryBaseline("session opening");
            if (session.offsetScale > 0.001) {
                if (session.offsetScale < 1) {
                    sessionOpenSamples++;
                    checkNativeGeometryStable("session opening");
                    if (focusWindow.inputItem?.contentItem)
                        checkInputTracking("session opening");
                }
                return;
            }
            if (!logout || !logout.activeFocus)
                return;
            check(sessionOpenSamples >= 2, "session: opening animation was sampled across frames");
            checkOpen("session", "session");
            checkNativeGeometry("session");
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
            step = 10;
        } else if (step === 10) {
            const session = content.interactionWrapper.panels.session;
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
            step = 11;
        } else if (step === 11) {
            const sidebar = content.interactionWrapper.panels.sidebar;
            if (sidebar.offsetScale > 0.001)
                return;
            checkDrawerHostGrab("sidebar");
            content.screenState.sidebar = false;
            step = 12;
        } else if (step === 12) {
            const sidebar = content.interactionWrapper.panels.sidebar;
            if (sidebar.offsetScale < 1)
                return;
            content.screenState.dashboard = true;
            step = 13;
        } else if (step === 13) {
            const dashboard = content.interactionWrapper.panels.dashboard;
            if (dashboard.offsetScale > 0.001)
                return;
            checkDrawerHostGrab("dashboard");
            content.screenState.dashboard = false;
            step = 14;
        } else if (step === 14) {
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
