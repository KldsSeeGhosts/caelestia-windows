import QtQuick
import Quickshell
import qs.modules.drawers

// Reuse contract for the Windows shared-edge regions. Synthetic monitors and
// panel geometry drive the real WindowsHoverRegions component offscreen; no
// window, native input, pointer or live desktop state is touched.
Item {
    id: root

    // Border and panel switches are local fixtures, so the test can change the
    // region count without changing any persisted configuration.
    property QtObject config: QtObject {
        property QtObject border: QtObject {
            property int thickness: 10
            property int minThickness: 2
            property int rounding: 25
        }
        property QtObject osd: QtObject {
            property bool enabled: true
        }
        property QtObject utilities: QtObject {
            property bool enabled: true
        }
    }
    property var windowContent: ({ Config: root.config })
    property QtObject win: QtObject {
        property real width: 2560
        property real height: 1440
        property real borderThickness: 12
        property var contentItem: root.windowContent
    }
    property QtObject osdWrapper: QtObject {
        property real y: 200
        property real height: 600
    }
    property QtObject utilitiesPanel: QtObject {
        property real x: 2200
        property real width: 500
    }
    property QtObject panels: QtObject {
        property var osdWrapper: root.osdWrapper
        property var utilities: root.utilitiesPanel
    }
    property QtObject bar: QtObject {
        property real implicitWidth: 80
    }
    property var screen: ({ x: 0, y: 0, width: 2560, height: 1440, devicePixelRatio: 1 })
    property var screens: [root.screen, { x: 2560, y: 0, width: 1920, height: 1440, devicePixelRatio: 1 }]

    property WindowsHoverRegions hover: WindowsHoverRegions {
        screen: root.screen
        screens: root.screens
        win: root.win
        panels: root.panels
        bar: root.bar
    }

    property int assertions: 0
    property int stage: 0
    property var firstOsd: null
    property var firstUtilities: null

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    function regions(): var {
        return Array.from(root.hover.regions);
    }

    // Every live Region must carry the rectangle at the same index.
    function checkBounds(live, description): void {
        const desired = [];
        for (const r of root.hover.rectangles.osd)
            desired.push(r);
        for (const r of root.hover.rectangles.utilities)
            desired.push(r);
        check(live.length === desired.length, description + ": region count");
        for (let i = 0; i < desired.length; ++i) {
            const region = live[i];
            const rect = desired[i];
            check(region.x === rect.x && region.y === rect.y
                && region.width === rect.width && region.height === rect.height,
                description + ": region " + i + " bounds");
        }
    }

    function next(): void {
        root.stage++;
        Qt.callLater(root.advance);
    }

    function advance(): void {
        try {
            switch (root.stage) {
            case 0: {
                const live = root.regions();
                check(live.length === 2, "two zones create two regions");
                root.firstOsd = live[0];
                root.firstUtilities = live[1];
                root.checkBounds(live, "initial");
                check(root.hover.inOsd(2550, 200) && !root.hover.inOsd(2500, 200),
                    "initial OSD hover predicate");
                check(!root.hover.inOsd(2550, 900), "initial OSD zone ends before row 900");
                check(root.hover.inUtilities(2550, 1430) && !root.hover.inUtilities(2550, 1400),
                    "initial utilities hover predicate");
                // Geometry only: grow the OSD panel, so the count is unchanged.
                root.osdWrapper.height = 700;
                root.next();
                break;
            }
            case 1: {
                const live = root.regions();
                check(live.length === 2, "a geometry change keeps two regions");
                check(live[0] === root.firstOsd && live[1] === root.firstUtilities,
                    "a geometry change reuses the same region objects");
                root.checkBounds(live, "after OSD height change");
                check(root.hover.inOsd(2550, 900), "the reused OSD region covers the new height");
                check(!root.hover.inOsd(2550, 950), "the reused OSD region ends at its new height");
                // Another geometry-only change, now moving the OSD zone.
                root.osdWrapper.y = 300;
                root.next();
                break;
            }
            case 2: {
                const live = root.regions();
                check(live.length === 2 && live[0] === root.firstOsd && live[1] === root.firstUtilities,
                    "moving the OSD zone also reuses the regions");
                root.checkBounds(live, "after OSD Y change");
                check(!root.hover.inOsd(2550, 200) && root.hover.inOsd(2550, 300),
                    "the reused OSD region moved to the new top edge");
                // Count change: remove the utilities zone.
                root.config.utilities.enabled = false;
                root.next();
                break;
            }
            case 3: {
                const live = root.regions();
                check(live.length === 1, "removing a zone removes one region");
                check(live[0] === root.firstOsd, "the OSD region survives the count change");
                root.checkBounds(live, "after disabling utilities");
                check(!root.hover.inUtilities(2550, 1430), "the utilities hover predicate is gone");
                // Count change back: the destroyed region is not reused, the
                // surviving one still is.
                root.config.utilities.enabled = true;
                root.next();
                break;
            }
            case 4: {
                const live = root.regions();
                check(live.length === 2, "re-enabling a zone restores two regions");
                check(live[0] === root.firstOsd, "the surviving region is still reused");
                check(live[1] !== root.firstUtilities, "the destroyed region is not reused");
                root.checkBounds(live, "after re-enabling utilities");
                check(root.hover.inUtilities(2550, 1430), "the utilities hover predicate is back");
                // Zone kinds can swap while the count stays the same.
                root.config.osd.enabled = false;
                root.next();
                break;
            }
            case 5: {
                const live = root.regions();
                check(live.length === 1, "swapping zone kinds removes one region");
                check(live[0] === root.firstOsd, "the surviving region is reused for the other zone");
                root.checkBounds(live, "after swapping to utilities only");
                check(!root.hover.inOsd(2550, 300) && root.hover.inUtilities(2550, 1430),
                    "the reused region reports the utilities zone");
                root.config.utilities.enabled = false;
                root.next();
                break;
            }
            case 6: {
                check(root.regions().length === 0, "disabling both zones removes every region");
                check(root.hover.regions.length === 0, "the region list is empty");
                root.config.osd.enabled = true;
                root.config.utilities.enabled = true;
                root.next();
                break;
            }
            case 7: {
                const live = root.regions();
                check(live.length === 2, "re-enabling both zones creates two regions");
                check(live[0] !== root.firstOsd, "the empty list creates a new OSD region");
                root.checkBounds(live, "after re-enabling both zones");
                check(root.hover.inOsd(2550, 300) && root.hover.inUtilities(2550, 1430),
                    "both hover predicates are restored");
                console.log(`CAELESTIA_HOVER_REGIONS_PASS ${root.assertions}`);
                Qt.quit();
                break;
            }
            default:
                throw new Error("unexpected stage " + root.stage);
            }
        } catch (error) {
            console.error("CAELESTIA_HOVER_REGIONS_FAIL " + error);
            Qt.exit(1);
        }
    }

    Component.onCompleted: Qt.callLater(root.advance)
}
