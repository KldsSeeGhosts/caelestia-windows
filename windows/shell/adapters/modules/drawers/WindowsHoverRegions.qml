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
    // Regions in the same order as the rectangles that produced them. They are
    // reused when only their bounds change, so a resize does not destroy and
    // recreate objects.
    property var liveRegions: []
    property Component regionFactory: Component { Region {} }
    intersection: Intersection.Subtract

    function rebuild(): void {
        if (!ready)
            return;
        const desired = [];
        for (const r of rectangles.osd)
            desired.push(r);
        for (const r of rectangles.utilities)
            desired.push(r);

        const live = root.liveRegions.slice();
        const countChanged = live.length !== desired.length;
        const kept = Math.min(live.length, desired.length);
        for (let i = 0; i < kept; ++i) {
            const region = live[i];
            const r = desired[i];
            region.x = r.x;
            region.y = r.y;
            region.width = r.width;
            region.height = r.height;
        }

        const removed = [];
        while (live.length > desired.length)
            removed.push(live.pop());
        for (let i = kept; i < desired.length; ++i)
            live.push(regionFactory.createObject(root, desired[i]));

        root.liveRegions = live;
        // Publish the new set before deleting the removed regions, so the mask
        // never holds a region that is about to be destroyed. The list was
        // already appended by createObject, so a geometry-only change leaves it
        // untouched.
        if (countChanged)
            root.regions = live;
        for (const region of removed)
            region.destroy();
        root.changed();
    }
    function inOsd(x: real, y: real): bool { return Logic.contains(rectangles.osd, x, y); }
    function inUtilities(x: real, y: real): bool { return Logic.contains(rectangles.utilities, x, y); }
    onRectanglesChanged: rebuild()
    Component.onCompleted: { ready = true; rebuild(); }
}
