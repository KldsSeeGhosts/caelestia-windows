import QtQuick
import Quickshell
import Caelestia.Config
import qs.modules.drawers

ShellRoot {
    id: root

    property int assertions: 0
    property var sourceScreen: ({x: -3840, y: 0, width: 2194, height: 1234, devicePixelRatio: 1.75})
    property var neighbour: ({x: 0, y: 0, width: 2560, height: 1440, devicePixelRatio: 1.5})
    property var screens: [sourceScreen, neighbour]
    property QtObject fakeWin: QtObject {
        property int width: 2194
        property int height: 1234
        property int borderThickness: 10
        property Item contentItem: Item {}
    }
    property QtObject fakePanels: QtObject {
        property Item osdWrapper: Item { y: 90; height: 600 }
        property Item utilities: Item { x: 1600; width: 594 }
    }
    property QtObject fakeBar: QtObject { property int implicitWidth: 0 }
    property Region hover: WindowsHoverRegions {
        screen: root.sourceScreen
        screens: root.screens
        win: root.fakeWin
        panels: root.fakePanels
        bar: root.fakeBar
    }

    function check(ok, message): void {
        assertions++;
        if (!ok)
            throw new Error(message);
    }
    function runTest(): void {
        try {
            check(hover.regions.length === 2, "two shared right regions: " + hover.regions.length + " ready=" + hover.ready + " rects=" + JSON.stringify(hover.rectangles));
            check(hover.regions[0].x === 2172 && hover.regions[0].width === 22, "OSD mask baseline");
            check(hover.inOsd(2172, 200) && !hover.inOsd(2171, 200), "OSD predicate matches mask");
            check(hover.inUtilities(2172, 1233), "utilities predicate matches mask");
            screens = [sourceScreen, {x: 0, y: 175, width: 2560, height: 400, devicePixelRatio: 1.5}];
            check(hover.regions.length === 1, "partial neighbour removes corner region");
            check(hover.regions[0].y === 100 && hover.regions[0].height === 342, "partial mask clipped");
            check(hover.inOsd(2172, 100) && !hover.inOsd(2172, 99) && !hover.inOsd(2172, 442), "partial predicate clipped");
            screens = [sourceScreen];
            check(hover.regions.length === 0 && !hover.inOsd(2172, 200), "disconnect clears mask and hover");
            screens = [sourceScreen, neighbour];
            check(hover.regions.length === 2 && hover.inOsd(2172, 200), "reconnect restores regions");
            GlobalConfig.border.thickness = 30;
            check(hover.regions[0].x === 2152 && hover.inOsd(2152, 200)
                && !hover.inOsd(2151, 200), "custom border mask and hover update together");
            sourceScreen = {x: -1200, y: -1800, width: 800, height: 1200, devicePixelRatio: 1.5};
            screens = [sourceScreen, {x: -900, y: 0, width: 240, height: 720, devicePixelRatio: 1.25}];
            fakeWin.width = 800;
            fakeWin.height = 1200;
            fakePanels.utilities.x = 100;
            fakePanels.utilities.width = 600;
            check(hover.regions.length === 1, "partial bottom region exists");
            check(hover.regions[0].x === 200 && hover.regions[0].width === 200, "partial bottom mask clipped");
            check(hover.inUtilities(200, 1133) && !hover.inUtilities(199, 1133)
                && !hover.inUtilities(400, 1133), "partial bottom predicate clipped");
            console.log("CAELESTIA_WINDOWS_HOVER_REGIONS_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_WINDOWS_HOVER_REGIONS_FAIL " + error);
            Qt.exit(1);
        }
    }
    Component.onCompleted: Qt.callLater(runTest)
}
