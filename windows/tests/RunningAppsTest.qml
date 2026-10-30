import QtQuick
import QtTest
import Quickshell
import Caelestia
import qs.components.controls
import qs.services as Services
import qs.modules.bar as Bar
import qs.modules.bar.popouts as BarPopouts
import qs.modules.bar.components.workspaces as BarWorkspaces

ShellRoot {
    id: root
    property int assertions: 0
    property int phase: 0
    property var fixtures: []
    property var barPill
    property var barWorkspaces
    property int hyprRefusals: 0
    property int dispatcherWheels: 0
    readonly property var screen: Quickshell.screens.length ? Quickshell.screens[0] : null
    readonly property var screenState: screen ? Services.ShellState.forScreen(screen) : null

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

    TestEvent { id: input }

    // Mount the original bar over the same Windows running-app projection.
    // The window-level MouseArea is declared after the bar, exactly as
    // Interactions is above the bar in ContentWindow.
    FloatingWindow {
        id: barHost
        visible: true
        implicitWidth: 480
        implicitHeight: 600

        BarPopouts.Wrapper {
            id: barPopouts
            screen: root.screen
            offsetScale: 0
        }

        // Mount the original bar at its intrinsic width so its centered
        // workspaces entry is reachable by synthetic coordinates. The narrow
        // production bar's own layout is outside this focused wheel check.
        Bar.Bar {
            id: bar
            width: 300
            height: 600
            screen: root.screen
            screenState: root.screenState
            popouts: barPopouts
            fullscreen: false
        }

        CustomMouseArea {
            anchors.fill: parent
            onWheel: event => {
                root.dispatcherWheels++;
                if (event.x < bar.width)
                    bar.handleWheel(event.y, event.angleDelta);
            }
        }
    }

    function check(ok, message): void {
        assertions++;
        if (!ok)
            throw new Error(message);
    }

    function listFor(item): var {
        return item ? Array.from(item.data).find(child => child.contentY !== undefined) : null;
    }

    function refreshBar(): void {
        barPill = CUtils.findChild(bar, "runningAppsPill");
        barWorkspaces = CUtils.findChild(bar, "taskbarWorkspaces");
    }

    function sendPillWheel(): bool {
        return input.mouseWheel(pill, pill.width / 2, pill.height / 2,
            Qt.NoButton, Qt.NoModifier, 0, -120, 0);
    }

    function sendBarPillWheel(): bool {
        return input.mouseWheel(barPill, barPill.width / 2, barPill.height / 2,
            Qt.NoButton, Qt.NoModifier, 0, -120, 0);
    }

    function sendWorkspaceWheel(): bool {
        // The top of the original workspace content, above the running-app pill.
        return input.mouseWheel(barWorkspaces, 10, 10,
            Qt.NoButton, Qt.NoModifier, 0, -120, 0);
    }


    Timer {
        interval: 80
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
                    for (const window of root.fixtures) {
                        window.wayland.minimized = false;
                        window.mapped = true;
                    }
                } else if (root.phase === 5) {
                    root.refreshBar();
                    check(root.barPill !== null && root.barPill.implicitHeight > 0,
                        "bar mounts the bounded running-app pill");
                    check(root.barWorkspaces !== null, "bar mounts its workspaces entry");
                    check(root.sendPillWheel(), "offscreen wheel delivered to the pill");
                } else if (root.phase === 6) {
                    const apps = root.listFor(pill);
                    check(apps?.contentY > 0, "wheel scrolls an overflowing pill");
                    if (apps)
                        apps.contentY = 0;
                    root.refreshBar();
                    root.hyprRefusals = Services.Hypr.refusals;
                    root.dispatcherWheels = 0;
                    check(root.sendBarPillWheel(), "bar-dispatched wheel delivered");
                } else if (root.phase === 7) {
                    const barApps = root.listFor(root.barPill);
                    check(root.dispatcherWheels > 0, "pill wheel reaches the window-level dispatcher");
                    check(barApps?.contentY > 0, "bar dispatcher scrolls the running-app viewport");
                    check(Services.Hypr.refusals === root.hyprRefusals,
                        "pill wheel does not reach the workspace shortcut");
                    if (barApps)
                        barApps.contentY = 0;
                    root.hyprRefusals = Services.Hypr.refusals;
                    check(root.sendWorkspaceWheel(), "workspace wheel delivered");
                } else if (root.phase === 8) {
                    check(root.listFor(root.barPill)?.contentY === 0,
                        "workspace wheel does not scroll the running-app viewport");
                    check(Services.Hypr.refusals > root.hyprRefusals,
                        "workspace wheel still reaches the bar shortcut");
                    // One app group means contentHeight fits the viewport.
                    Services.RunningApps.source = root.fixtures.slice(0, 2);
                } else if (root.phase === 9) {
                    root.refreshBar();
                    const barApps = root.listFor(root.barPill);
                    check(Services.RunningApps.groupIds.length === 1, "short list projected");
                    check(barApps && barApps.contentHeight <= barApps.height,
                        "short list does not overflow");
                    root.hyprRefusals = Services.Hypr.refusals;
                    root.dispatcherWheels = 0;
                    check(root.sendBarPillWheel(), "short-list wheel delivered");
                } else if (root.phase === 10) {
                    check(root.dispatcherWheels > 0, "short-list wheel reaches the window-level dispatcher");
                    check(root.listFor(root.barPill)?.contentY === 0,
                        "short list consumes wheel without moving");
                    check(Services.Hypr.refusals === root.hyprRefusals,
                        "short-list wheel does not reach the workspace shortcut");
                    Services.RunningApps.source = [];
                } else if (root.phase === 11) {
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
