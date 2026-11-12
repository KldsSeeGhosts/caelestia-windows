import QtQuick
import Quickshell

ShellRoot {
    id: root
    property int assertions: 0
    property int reports: 0
    function check(value, message): void {
        assertions++;
        if (!value)
            throw new Error(message);
    }
    component MonitorScope: QtObject {
        property bool firstFrame: false
        property QtObject window: QtObject {
            property bool backingWindowVisible: true
            property bool takeoverOccluded: false
            property int width: 1920
            property int height: 1080
        }
    }
    MonitorScope { id: first }
    MonitorScope { id: second }
    ShellReadiness {
        id: readiness
        screenCount: 0
        scopes: []
        onTakeoverReported: root.reports++
    }
    Component {
        id: reloadedRoot
        ShellReadiness { screenCount: 1; scopes: [first] }
    }
    Timer {
        interval: 1
        running: true
        onTriggered: {
            try {
                root.check(!readiness.ready && root.reports === 0, "empty model reported ready");
                readiness.screenCount = 2;
                readiness.scopes = [first];
                first.firstFrame = true;
                root.check(!readiness.ready, "missing monitor accepted");
                readiness.scopes = [first, second];
                root.check(!readiness.ready, "undrawn monitor accepted");
                second.window.width = 0;
                second.firstFrame = true;
                root.check(!readiness.ready, "zero width accepted");
                second.window.width = 1920;
                second.window.height = 0;
                root.check(!readiness.ready, "zero height accepted");
                second.window.backingWindowVisible = false;
                second.window.height = 1080;
                root.check(!readiness.ready, "invisible backing window accepted");
                second.window.backingWindowVisible = true;
                root.check(readiness.ready && root.reports === 1, "all first frames did not report once");
                second.firstFrame = false;
                root.check(!readiness.ready && root.reports === 1, "readiness loss sent a new report");
                second.firstFrame = true;
                root.check(readiness.ready && root.reports === 1, "readiness recovery reported twice");
                readiness.scopes = [first, null];
                root.check(!readiness.ready, "tearing-down scope accepted");
                const secondWindow = second.window;
                second.window = null;
                readiness.scopes = [first, second];
                root.check(!readiness.ready, "tearing-down window accepted");
                second.window = secondWindow;
                root.check(readiness.ready && root.reports === 1, "teardown recovery reported twice");
                first.firstFrame = false;
                const reloaded = reloadedRoot.createObject(root);
                let reloadReports = 0;
                reloaded.takeoverReported.connect(() => reloadReports++);
                root.check(!reloaded.ready && !reloaded.reported, "new QML root reused readiness");
                first.firstFrame = true;
                root.check(reloaded.ready && reloaded.reported && reloadReports === 1, "reload did not report fresh first frames");
                root.check(root.reports === 1, "old QML root reported twice during reload");
                reloaded.destroy();
                first.firstFrame = false;
                first.window.takeoverOccluded = true;
                root.check(readiness.takeoverReady && !readiness.ready, "fullscreen did not separate takeover from strict IPC readiness");
                const initiallyOccluded = reloadedRoot.createObject(root);
                root.check(initiallyOccluded.takeoverReady && !initiallyOccluded.ready && initiallyOccluded.reported,
                    "starting under fullscreen did not report takeover readiness");
                initiallyOccluded.destroy();
                first.window.width = 0;
                root.check(!readiness.takeoverReady, "fullscreen accepted an unplaced zero-size window");
                first.window.width = 1920;
                first.window.backingWindowVisible = false;
                root.check(!readiness.takeoverReady, "fullscreen accepted a screen-loss hidden window");
                first.window.backingWindowVisible = true;
                first.window.takeoverOccluded = false;
                root.check(!readiness.takeoverReady && !readiness.ready, "uncovered monitor bypassed its missing frame");
                first.firstFrame = true;
                root.check(readiness.ready && readiness.takeoverReady && root.reports === 1, "restored frames changed the per-root report latch");
                console.log("CAELESTIA_SHELL_READINESS_PASS " + JSON.stringify({assertions: root.assertions}));
                Qt.quit();
            } catch (error) {
                console.error("CAELESTIA_SHELL_READINESS_FAIL " + error);
                Qt.exit(1);
            }
        }
    }
}
