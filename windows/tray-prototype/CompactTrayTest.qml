//@ pragma AppId org.caelestia.windows-compact-tray-test
import QtQuick
import Quickshell
import Caelestia.Config
import qs.services
import qs.modules.bar.components as BarComponents

// Headless checks of the real Windows adapter, without constructing a native
// tray host or sending requests to another application's windows.
ShellRoot {
    id: root

    property int assertions: 0
    property int phase: 0
    property real expandedHeight: 0

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

    BarComponents.Tray {
        id: tray
        sourceItems: root.makeItems(12)
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
                // Only break the activation binding. Observation stays disabled,
                // so the native Loader cannot construct SystemTray.
                WindowsTray.activationEnabled = true;
                button.clicked(null);
            } else if (root.phase === 1) {
                root.verify(tray.expanded, "button expands tray");
                root.verify(tray.items.itemAt(0).enabled, "expanded icons interactive");
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
