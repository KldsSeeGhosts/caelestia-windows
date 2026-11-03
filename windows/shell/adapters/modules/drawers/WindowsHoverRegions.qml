import QtQuick
import Quickshell
import Caelestia.Config
import "WindowsHover.js" as Logic

// The same integer rectangles drive both the native input region and hover.
Region {
    id: root

    required property var screen
    required property var screens
    required property var win
    required property var panels
    required property var bar
    readonly property var rectangles: Logic.triggerRects(
        screen, screens, win.width, win.height, win.contentItem.Config.border.thickness,
        win.contentItem.Config.border.minThickness, win.contentItem.Config.border.rounding,
        panels.osdWrapper.y + win.borderThickness, panels.osdWrapper.height,
        panels.utilities.x + bar.implicitWidth, panels.utilities.width,
        Logic.extraWidth(GlobalConfig.windows?.innerEdgeHoverWidth),
        win.contentItem.Config.osd.enabled, win.contentItem.Config.utilities.enabled)
    property bool ready: false
    property var childrenToDestroy: []
    property Component regionFactory: Component { Region {} }
    intersection: Intersection.Subtract

    function rebuild(): void {
        if (!ready)
            return;
        const next = [];
        for (const r of rectangles.osd.concat(rectangles.utilities))
            next.push(regionFactory.createObject(root, r));
        root.regions = next;
        root.changed();
        for (const child of childrenToDestroy)
            child.destroy();
        childrenToDestroy = next;
    }
    function inOsd(x: real, y: real): bool { return Logic.contains(rectangles.osd, x, y); }
    function inUtilities(x: real, y: real): bool { return Logic.contains(rectangles.utilities, x, y); }
    onRectanglesChanged: rebuild()
    Component.onCompleted: { ready = true; rebuild(); }
}
