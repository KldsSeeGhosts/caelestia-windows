import QtQuick
import Quickshell
import qs.services
import qs.modules.tiling

// The tiling drop preview against an injected backend: no window while idle,
// one click-through window on the drag's screen whose plate is the backend's
// landing rectangle, and a hidden window kept for the next drag.
ShellRoot {
    id: root

    property int assertions: 0
    property var win: null
    property QtObject backend: QtObject {
        property bool enabled: true
        property bool dragActive: false
        property string dragMode: ""
        property string dragScreen: ""
        property rect dragLanding: Qt.rect(0, 0, 0, 0)
        property rect dragDisplaced: Qt.rect(0, 0, 0, 0)
    }

    DragPreview {
        id: preview
    }

    Timer {
        id: settle
        interval: 1500
        onTriggered: root.step(root.afterMove)
    }

    Timer {
        id: fade
        interval: 1500
        onTriggered: root.step(root.afterRelease)
    }

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    function sameRect(item, rect): bool {
        return item.x === rect.x && item.y === rect.y && item.width === rect.width && item.height === rect.height;
    }

    function windows(): var {
        return preview.screens.instances.map(scope => scope.window).filter(window => window);
    }

    function find(item, name): var {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of item.children) {
            const found = find(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function step(body): void {
        try {
            body();
        } catch (error) {
            console.error("CAELESTIA_DRAG_PREVIEW_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: Qt.callLater(() => step(run))

    function run(): void {
        Tiling._nativeLoader.active = false;
        Tiling.backend = backend;
        check(preview.supported, "a backend with a drop plan is supported");
        check(preview.screens.instances.length === Quickshell.screens.length, "one scope per screen");
        check(windows().length === 0, "no window while idle");

        const screen = Quickshell.screens[0];
        backend.dragScreen = screen.name;
        backend.dragLanding = Qt.rect(100, 50, 400, 300);
        backend.dragDisplaced = Qt.rect(520, 50, 400, 300);
        backend.dragMode = "swap";
        backend.dragActive = true;

        const list = windows();
        check(list.length === 1, "one window, on the drag's screen");
        win = list[0];
        check(win.screen.name === screen.name, "the window is on the drag's screen");
        check(win.visible, "visible while a swap is planned");
        check(win.mask !== null, "click-through");
        check(win.exclusionMode === ExclusionMode.Ignore, "reserves no space");
        check(win.anchors.left && win.anchors.right && win.anchors.top && win.anchors.bottom, "covers the screen");
        const plate = find(win.contentItem, "tilingDropPlate");
        const ghost = find(win.contentItem, "tilingDropGhost");
        check(plate !== null && ghost !== null, "plate and ghost exist");
        check(sameRect(plate, backend.dragLanding), "the plate is the landing rectangle");
        check(ghost.visible && sameRect(ghost, backend.dragDisplaced), "the ghost is the displaced rectangle");

        // A Super edge insert that moves more than one other tile: no ghost.
        backend.dragMode = "insert";
        backend.dragLanding = Qt.rect(100, 50, 200, 300);
        backend.dragDisplaced = Qt.rect(0, 0, 0, 0);
        check(!ghost.visible, "no ghost without a single displaced tile");
        settle.start();
    }

    function afterMove(): void {
        const plate = find(win.contentItem, "tilingDropPlate");
        check(sameRect(plate, backend.dragLanding), "the plate settles on the new landing");

        // Home draws nothing.
        backend.dragMode = "home";
        backend.dragLanding = Qt.rect(0, 0, 0, 0);
        check(!win.drawing, "home draws nothing");

        // The release holds the last geometry while it fades.
        backend.dragMode = "swap";
        backend.dragLanding = Qt.rect(100, 50, 400, 300);
        backend.dragActive = false;
        backend.dragMode = "";
        backend.dragScreen = "";
        backend.dragLanding = Qt.rect(0, 0, 0, 0);
        check(win.visible, "the release fades instead of vanishing");
        fade.start();
    }

    function afterRelease(): void {
        check(!win.visible, "hidden after the fade");
        check(!win.anchors.left && win.implicitWidth === 1 && win.implicitHeight === 1, "1x1 while hidden");
        check(windows().length === 1, "kept for the next drag");
        // Drop the singleton's reference before the fixture-owned backend goes.
        Tiling.backend = null;
        console.log("CAELESTIA_DRAG_PREVIEW_PASS " + assertions);
        Qt.quit();
    }
}
