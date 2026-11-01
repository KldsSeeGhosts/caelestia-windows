//@ pragma AppId org.caelestia.windows-compact-tray-test
import QtQuick
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.bar as Bar
import qs.modules.bar.popouts as BarPopouts

// Headless checks of the real Windows adapter, without constructing a native
// tray host or sending requests to another application's windows.
ShellRoot {
    id: root

    property int assertions: 0
    property int phase: 0
    property real expandedHeight: 0
    readonly property var tray: bar.children.find(child => child.entryId === "tray")?.item ?? null

    function verify(condition, message): void {
        if (!condition) {
            console.error("COMPACT_TRAY_FAIL " + message);
            Qt.exit(1);
            throw new Error(message);
        }
        assertions++;
    }

    function makeItems(count): var {
        return Array.from({length: count}, (_, i) => ({
            id: "compact.fixture." + i,
            title: "Test app " + i,
            status: 1,
            icon: Qt.resolvedUrl("fixtures/tray-icon.png"),
            activate: function () {},
            secondaryActivate: function () {}
        }));
    }

    Bar.Bar {
        id: bar
        screen: null
        screenState: ScreenState { modelData: null }
        popouts: BarPopouts.Wrapper { screen: null; offsetScale: 0 }
        fullscreen: false
        width: 60
        height: 800
    }

    Binding {
        target: root.tray
        property: "sourceItems"
        value: root.makeItems(12)
        when: root.tray !== null
    }

    Timer {
        interval: 1000
        repeat: true
        running: true
        onTriggered: {
            const button = tray.children.find(child => child.objectName === "trayExpandButton");
            if (root.phase === 0) {
                root.verify(GlobalConfig.bar.tray.compact, "production compact default");
                root.verify(!GlobalConfig.bar.tray.recolour, "production uses original icon colors");
                root.verify(tray.items.count === 12, "all fixture apps rendered");
                root.verify(!tray.items.itemAt(0).iconItem.layer.enabled, "tray icons are not tinted");
                root.verify(!tray.expanded, "initially collapsed");
                root.verify(!tray.items.itemAt(0).enabled, "collapsed icons cannot intercept clicks");
                root.verify(button && button.enabled, "expand button enabled");
                root.verify(button.acceptedButtons === (Qt.LeftButton | Qt.RightButton),
                    "right-click also expands the collapsed pill");
                // Only break the activation binding. Observation stays disabled,
                // so the native Loader cannot construct SystemTray.
                WindowsTray.activationEnabled = true;
                button.clicked(null);
            } else if (root.phase === 1) {
                root.verify(tray.expanded, "button expands tray");
                root.verify(!tray.autoCollapse, "Windows uses manual expansion");
                bar.closeTray();
                root.verify(tray.expanded, "pointer leave does not collapse manual tray");
                bar.checkPopout(-1);
                root.verify(tray.expanded, "hovering another bar entry does not collapse manual tray");
                root.verify(tray.items.itemAt(0).enabled, "expanded icons interactive");
                // The menu request is refused (observation stays off) but the
                // facade records the coordinates it would hand the backend.
                tray.itemMenuRequested(tray.sourceItems[0], 30, 42);
                const menuPoint = WindowsTray.lastMenuCoordinates;
                root.verify(menuPoint[0] >= tray.mapToItem(null, tray.width, 0).x,
                    "menu opens past the tray's outer edge, not under the bar");
                root.verify(menuPoint[1] === Math.round(42 - Tokens.font.body.small.pointSize),
                    "menu point lifted from the icon centre to its top");
                root.verify(tray.visibleListHeight < tray.layout.implicitHeight, "long list capped");
                root.expandedHeight = tray.implicitHeight;
                const viewport = tray.viewport;
                root.verify(viewport.interactive && viewport.clip, "overflow scrolls inside clip");
                viewport.contentY = viewport.contentHeight - viewport.height;
                root.verify(viewport.contentY > 0, "last icons reachable by scrolling");
                button.clicked(null);
            } else if (root.phase === 2) {
                root.verify(!tray.expanded, "button collapses tray");
                root.verify(!tray.items.itemAt(0).enabled, "hidden icons disabled even with activation allowed");
                root.verify(tray.implicitHeight < root.expandedHeight, "collapsed footprint smaller");
                tray.expanded = true;
                WindowsTray.activationEnabled = false;
            } else if (root.phase === 3) {
                root.verify(!tray.items.itemAt(0).enabled, "observation-only icons disabled");
                tray.autoCollapse = true;
                bar.closeTray();
                root.verify(!tray.expanded, "upstream automatic collapse remains supported");
                tray.autoCollapse = false;
                tray.sourceItems = [];
            } else {
                root.verify(tray.items.count === 0, "removed apps disappear");
                root.verify(tray.implicitHeight === 0, "empty tray takes no space");
                root.verify(!WindowsTray.nativeRequested, "fixture never constructs native tray");
                console.log("COMPACT_TRAY_PASS assertions=" + root.assertions);
                Qt.quit();
            }
            root.phase++;
        }
    }
}
