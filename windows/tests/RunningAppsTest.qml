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
    property var deferredFixture
    property var timeoutFixture
    property var removedFixture
    property var reusedFixture
    property var replacedFixture
    property var destroyedFixture
    readonly property var screen: Quickshell.screens.length ? Quickshell.screens[0] : null
    readonly property var screenState: screen ? Services.ShellState.forScreen(screen) : null

    // The shell loads this font. Without it the ActiveWindow entry falls back
    // to literal icon names and widens the bar's layout past its 60px width.
    FontLoader {
        id: materialSymbols
        source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf")
    }

    Component {
        id: fixture
        QtObject {
            id: target
            property string address
            property string title: "Fixture window " + address
            property bool activated: false
            property string appId
            property bool mapped: true
            property bool deferActivation: false
            property var counts: null
            property var lastIpcObject: ({ class: appId, mapped: mapped })
            property var workspace: ({ id: 1 })
            property QtObject wayland: QtObject {
                property bool minimized: false
                function completeActivation(): void {
                    target.activated = true;
                    minimized = false;
                }
                function activate(): void {
                    target.counts.activations++;
                    if (!target.deferActivation)
                        completeActivation();
                }
                function close(): void {
                    // A close before the fixture is observably restored and
                    // active is the native hidden-prompt failure this guards.
                    if (!target.activated || minimized) {
                        target.counts.unsafeCloses++;
                        throw new Error("close preceded observed activation/restore");
                    }
                    target.counts.closes++;
                }
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

    // Match ContentWindow: the bar is a child of the window-sized Interactions
    // mouse area, which only sees wheel input that the bar does not consume.
    // Panels is omitted because this fixture only exercises the wheel path.
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

        CustomMouseArea {
            id: barInteractions
            anchors.fill: parent
            function onWheel(event: WheelEvent): void {
                root.dispatcherWheels++;
                if (event.x < bar.implicitWidth)
                    bar.handleWheel(event.y, event.angleDelta);
            }

            Bar.BarWrapper {
                id: bar
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                screen: root.screen
                screenState: root.screenState
                popouts: barPopouts
                fullscreen: false
            }
        }
    }

    function check(ok, message): void {
        assertions++;
        if (!ok)
            throw new Error(message);
    }

    function newCounts(): var {
        return { activations: 0, closes: 0, unsafeCloses: 0 };
    }

    function makeFixture(address: string, appId: string): var {
        return fixture.createObject(root, { address: address, appId: appId, counts: root.newCounts() });
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
                    if (materialSymbols.status !== FontLoader.Ready)
                        return;
                    for (let i = 0; i < 9; i++)
                        root.fixtures.push(root.makeFixture(String(i + 1),
                            i < 2 ? "fixture-app" : "fixture-" + i));
                    Services.RunningApps.source = root.fixtures;
                    Services.RunningApps.actionsEnabled = false;
                    root.screenState.bar = true;
                } else if (root.phase === 1) {
                    check(Services.RunningApps.groupIds.length === 8, "per-app grouping");
                    check(pill.implicitHeight > 0 && pill.implicitHeight <= 136, "overflow stays bounded");
                    root.fixtures[0].wayland.minimized = true;
                    root.fixtures[1].wayland.minimized = true;
                    check(Services.RunningApps.groups["fixture-app"].allMinimized, "reactive minimized state");
                    check(Services.RunningApps.groupIds.length === 8, "minimize does not remove app");
                    Services.RunningApps.request("1", "activate");
                    Services.RunningApps.request("1", "close");
                } else if (root.phase === 2) {
                    check(root.fixtures[0].counts.activations === 0, "read-only gate");
                    check(root.fixtures[0].counts.closes === 0
                        && root.fixtures[0].counts.unsafeCloses === 0,
                        "disabled controls cannot close");
                    Services.RunningApps.actionsEnabled = true;
                    Services.RunningApps.request("1", "activate");
                    Services.RunningApps.request("3", "activate");
                    root.fixtures[2].mapped = false;
                } else if (root.phase === 3) {
                    check(root.fixtures[0].counts.activations === 1, "explicit activation");
                    check(!root.fixtures[0].wayland.minimized, "activation restores fixture");
                    check(root.fixtures[2].counts.activations === 0, "closed/hidden target not dispatched");
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
                    check(root.fixtures[0].counts.closes === 1, "graceful close request");
                    check(root.fixtures[0].counts.unsafeCloses === 0, "direct close was safe");
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
                    if (!root.barPill || root.barPill.implicitHeight <= 0
                            || bar.width < bar.contentWidth - 0.5)
                        return;
                    check(root.barPill !== null && root.barPill.implicitHeight > 0,
                        "bar mounts the bounded running-app pill");
                    check(root.barWorkspaces !== null, "bar mounts its workspaces entry");
                    check(bar.width >= bar.contentWidth - 0.5, "bar reaches its production width");
                    const pillX = root.barPill.mapToItem(bar, 0, 0).x;
                    check(pillX >= 0 && pillX + root.barPill.width <= bar.width,
                        "pill layout is inside the production-width bar");
                    root.hyprRefusals = Services.Hypr.refusals;
                    root.dispatcherWheels = 0;
                    check(root.sendPillWheel(), "offscreen wheel delivered to the pill");
                } else if (root.phase === 6) {
                    const apps = root.listFor(pill);
                    check(apps?.contentY > 0, "wheel scrolls an overflowing pill");
                    if (apps)
                        apps.contentY = 0;
                    root.refreshBar();
                    root.hyprRefusals = Services.Hypr.refusals;
                    root.dispatcherWheels = 0;
                    check(root.sendBarPillWheel(), "bar-mounted pill wheel delivered");
                } else if (root.phase === 7) {
                    const barApps = root.listFor(root.barPill);
                    check(root.dispatcherWheels === 0,
                        "overflow wheel is consumed by the pill's Flickable");
                    check(barApps?.contentY > 0, "production overflow wheel scrolls natively");
                    check(Services.Hypr.refusals === root.hyprRefusals,
                        "overflow wheel does not reach the workspace shortcut");
                    if (barApps)
                        barApps.contentY = 0;
                    root.hyprRefusals = Services.Hypr.refusals;
                    root.dispatcherWheels = 0;
                    check(root.sendWorkspaceWheel(), "workspace wheel delivered");
                } else if (root.phase === 8) {
                    check(root.dispatcherWheels > 0,
                        "workspace wheel reaches the window-level mouse area");
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
                    check(root.dispatcherWheels === 0,
                        "short list consumes wheel before the window-level mouse area");
                    check(root.listFor(root.barPill)?.contentY === 0,
                        "short list consumes wheel without moving");
                    check(Services.Hypr.refusals === root.hyprRefusals,
                        "short-list wheel does not reach the workspace shortcut");
                    Services.RunningApps.source = root.fixtures;
                    Services.RunningApps.actionsEnabled = true;
                } else if (root.phase === 11) {
                    root.deferredFixture = root.fixtures[5];
                    root.deferredFixture.deferActivation = true;
                    root.deferredFixture.activated = false;
                    root.deferredFixture.wayland.minimized = false;
                    Services.RunningApps.request("6", "close");
                    Services.RunningApps.request("6", "close");
                } else if (root.phase === 12) {
                    check(root.deferredFixture.counts.activations === 1,
                        "duplicate pending close is coalesced");
                    check(root.deferredFixture.counts.closes === 0,
                        "deferred activation sends no early close");
                    check(root.deferredFixture.counts.unsafeCloses === 0,
                        "no close while activation is unconfirmed");
                    check(Services.RunningApps.pendingCloses.length === 1, "close is pending activation");
                    root.deferredFixture.wayland.completeActivation();
                } else if (root.phase === 13) {
                    check(root.deferredFixture.counts.closes === 1,
                        "exactly one close after confirmed activation");
                    check(root.deferredFixture.counts.unsafeCloses === 0,
                        "confirmed close was safe");
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "confirmed close leaves no pending request");
                    Services.RunningApps.request("6", "close");
                } else if (root.phase === 14) {
                    check(root.deferredFixture.counts.closes === 1
                        && root.deferredFixture.counts.activations === 1,
                        "duplicate close after dispatch is not repeated");
                    root.timeoutFixture = root.fixtures[6];
                    root.timeoutFixture.deferActivation = true;
                    // A minimized window can still carry a stale active flag;
                    // the minimized observation alone must block the close.
                    root.timeoutFixture.activated = true;
                    root.timeoutFixture.wayland.minimized = true;
                    Services.RunningApps.request("7", "close");
                } else if (root.phase === 15) {
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "unconfirmed restore is pending");
                    check(root.timeoutFixture.counts.activations === 1
                        && root.timeoutFixture.counts.closes === 0
                        && root.timeoutFixture.counts.unsafeCloses === 0,
                        "minimized target sends no close");
                    interval = 2200;
                } else if (root.phase === 16) {
                    interval = 80;
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "unconfirmed close times out");
                    check(root.timeoutFixture.counts.closes === 0
                        && root.timeoutFixture.counts.unsafeCloses === 0,
                        "timeout sends no close");
                    root.timeoutFixture.wayland.completeActivation();
                } else if (root.phase === 17) {
                    check(root.timeoutFixture.counts.closes === 0
                        && root.timeoutFixture.counts.unsafeCloses === 0,
                        "late restore cannot revive an expired close");
                    root.removedFixture = root.fixtures[7];
                    root.removedFixture.deferActivation = true;
                    root.removedFixture.activated = false;
                    root.removedFixture.wayland.minimized = true;
                    Services.RunningApps.request("8", "close");
                } else if (root.phase === 18) {
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "disappearing target starts pending");
                    Services.RunningApps.source = root.fixtures.filter(item => item !== root.removedFixture);
                } else if (root.phase === 19) {
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "disappearing target cancels pending close");
                    check(root.removedFixture.counts.closes === 0
                        && root.removedFixture.counts.unsafeCloses === 0,
                        "disappearing target receives no close");
                    root.reusedFixture = root.fixtures[8];
                    root.reusedFixture.deferActivation = true;
                    root.reusedFixture.activated = false;
                    root.reusedFixture.wayland.minimized = true;
                    Services.RunningApps.request("9", "close");
                } else if (root.phase === 20) {
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "reused-id target starts pending");
                    root.replacedFixture = root.makeFixture("9", "fixture-8");
                    const next = Services.RunningApps.source.slice();
                    next[next.indexOf(root.reusedFixture)] = root.replacedFixture;
                    Services.RunningApps.source = next;
                } else if (root.phase === 21) {
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "replaced target cancels pending close");
                    check(root.reusedFixture.counts.activations === 1
                        && root.reusedFixture.counts.closes === 0,
                        "old target for a reused id receives no close");
                    check(root.replacedFixture.counts.activations === 0
                        && root.replacedFixture.counts.closes === 0,
                        "replacement target receives no queued action");
                    root.reusedFixture.wayland.completeActivation();
                    root.replacedFixture.wayland.completeActivation();
                } else if (root.phase === 22) {
                    check(root.reusedFixture.counts.closes === 0
                        && root.replacedFixture.counts.closes === 0,
                        "late activation of a reused id sends no close");
                    root.replacedFixture.deferActivation = true;
                    root.replacedFixture.activated = false;
                    root.replacedFixture.wayland.minimized = true;
                    root.replacedFixture.counts.activations = 0;
                    root.replacedFixture.counts.closes = 0;
                    root.replacedFixture.counts.unsafeCloses = 0;
                    Services.RunningApps.request("9", "close");
                } else if (root.phase === 23) {
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "disabled-control close is pending");
                    Services.RunningApps.actionsEnabled = false;
                    root.replacedFixture.wayland.completeActivation();
                } else if (root.phase === 24) {
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "disabling controls cancels pending close");
                    check(root.replacedFixture.counts.closes === 0
                        && root.replacedFixture.counts.unsafeCloses === 0,
                        "disabled controls send no close");
                    Services.RunningApps.actionsEnabled = true;
                    root.destroyedFixture = root.makeFixture("10", "fixture-destroyed");
                    Services.RunningApps.source = Services.RunningApps.source.concat(root.destroyedFixture);
                } else if (root.phase === 25) {
                    check(Services.RunningApps.windows["10"] !== undefined,
                        "destroyed-target fixture is projected");
                    root.destroyedFixture.deferActivation = true;
                    Services.RunningApps.request("10", "close");
                } else if (root.phase === 26) {
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "destroyed-target close is pending");
                    root.destroyedFixture.wayland.destroy();
                    interval = 250;
                } else if (root.phase === 27) {
                    interval = 80;
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "destroyed target cancels pending close");
                    check(root.destroyedFixture.counts.closes === 0
                        && root.destroyedFixture.counts.unsafeCloses === 0,
                        "destroyed target receives no close");
                    Services.RunningApps.source = [];
                } else if (root.phase === 28) {
                    check(Services.RunningApps.groupIds.length === 0, "empty model");
                    interval = 700;
                } else {
                    check(pill.implicitHeight === 0, "empty pill disappears after its close animation");
                    console.log("CAELESTIA_RUNNING_APPS_PASS " + root.assertions);
                    Qt.quit();
                }
                root.phase++;
            } catch (error) {
                console.error("CAELESTIA_RUNNING_APPS_FAIL phase=" + root.phase + " " + error);
                Qt.exit(1);
            }
        }
    }
}
