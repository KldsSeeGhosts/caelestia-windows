import QtQuick
import Quickshell
import Caelestia
import qs.services as Services
import qs.modules.bar.components.workspaces as BarWorkspaces

ShellRoot {
    id: root
    property int assertions: 0
    property int phase: 0
    property var fixtures: []

    Component {
        id: fixture
        QtObject {
            property string address
            property string title: "Fixture window"
            property bool activated: false
            property string appId
            property bool mapped: true
            property var lastIpcObject: ({ class: appId, mapped: mapped })
            property var workspace: ({ id: 1 })
            property QtObject wayland: QtObject {
                property bool minimized: false
                property int activations: 0
                property int closes: 0
                function activate(): void { activations++; minimized = false; }
                function close(): void { closes++; }
            }
        }
    }

    FloatingWindow {
        visible: true
        implicitWidth: 360
        implicitHeight: 480
        BarWorkspaces.RunningApps {
            id: pill
            rowSize: 32
            maximumHeight: 136
        }
    }

    function check(ok, message): void {
        assertions++;
        if (!ok)
            throw new Error(message);
    }

    Timer {
        interval: 40
        repeat: true
        running: true
        onTriggered: {
            try {
                if (root.phase === 0) {
                    for (let i = 0; i < 9; i++)
                        root.fixtures.push(fixture.createObject(root, {
                            address: String(i + 1), appId: i < 2 ? "fixture-app" : "fixture-" + i
                        }));
                    Services.RunningApps.source = root.fixtures;
                    Services.RunningApps.actionsEnabled = false;
                } else if (root.phase === 1) {
                    check(Services.RunningApps.groupIds.length === 8, "per-app grouping");
                    check(pill.implicitHeight > 0 && pill.implicitHeight <= 136, "overflow stays bounded");
                    root.fixtures[0].wayland.minimized = true;
                    root.fixtures[1].wayland.minimized = true;
                    check(Services.RunningApps.groups["fixture-app"].allMinimized, "reactive minimized state");
                    check(Services.RunningApps.groupIds.length === 8, "minimize does not remove app");
                    Services.RunningApps.request("1", "activate");
                } else if (root.phase === 2) {
                    check(root.fixtures[0].wayland.activations === 0, "read-only gate");
                    Services.RunningApps.actionsEnabled = true;
                    Services.RunningApps.request("1", "activate");
                    Services.RunningApps.request("3", "activate");
                    root.fixtures[2].mapped = false;
                } else if (root.phase === 3) {
                    check(root.fixtures[0].wayland.activations === 1, "explicit activation");
                    check(!root.fixtures[0].wayland.minimized, "activation restores fixture");
                    check(root.fixtures[2].wayland.activations === 0, "closed/hidden target not dispatched");
                    Services.RunningApps.request("1", "close");
                    pill.selectApp("fixture-app", pill);
                } else if (root.phase === 4) {
                    // CUtils searches visual items only; PopupWindow is a
                    // non-visual child with its own separate content tree.
                    const popup = Array.from(pill.data).find(child => child.objectName === "runningAppsChooser");
                    check(popup?.visible, "multi-window chooser opens");
                    check(CUtils.findChild(popup.contentItem, "runningAppsWindowList")?.count === 2,
                        "chooser instantiates both window rows");
                    popup.visible = false;
                    check(!popup.visible, "chooser can dismiss");
                    check(root.fixtures[0].wayland.closes === 1, "graceful close request");
                    check(Services.RunningApps.windows["1"] !== undefined, "no optimistic close removal");
                    for (const window of root.fixtures)
                        window.wayland.minimized = true;
                    check(Services.RunningApps.groupIds.length === 7, "all-minimized list retained");
                    Services.RunningApps.request("1", "minimize");
                    Services.RunningApps.actionsEnabled = false;
                    Services.RunningApps.source = [];
                } else if (root.phase === 5) {
                    check(Services.RunningApps.groupIds.length === 0, "empty model");
                    interval = 700;
                } else {
                    check(pill.implicitHeight === 0, "empty pill disappears after its close animation");
                    console.log("CAELESTIA_RUNNING_APPS_PASS " + root.assertions);
                    Qt.quit();
                }
                root.phase++;
            } catch (error) {
                console.error("CAELESTIA_RUNNING_APPS_FAIL " + error);
                Qt.exit(1);
            }
        }
    }
}
