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
    property var multiFirst
    property var multiSecond
    property var queueFirst
    property var queueSecond
    property var queueThird
    property var queueReplacement
    property var retryFixture
    property var interactionFirst
    property var interactionSecond
    property var interactionThird
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
            property bool savePromptOpen: false
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
                    // The fake window stays open after WM_CLOSE, like a native
                    // save prompt. The test can cancel it explicitly.
                    target.savePromptOpen = true;
                }
            }
            function cancelSavePrompt(): void {
                savePromptOpen = false;
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

    function chooser(): var {
        return Array.from(pill.data).find(child => child.objectName === "runningAppsChooser") ?? null;
    }

    function chooserList(popup): var {
        return popup ? CUtils.findChild(popup.contentItem, "runningAppsWindowList") : null;
    }

    function appRow(key: string): var {
        const apps = listFor(pill);
        if (!apps)
            return null;
        for (let i = 0; i < apps.count; i++) {
            const item = apps.itemAtIndex(i);
            if (item?.modelData === key)
                return item;
        }
        return null;
    }

    function focusAt(popup): string {
        const list = root.chooserList(popup);
        if (!list)
            return "";
        for (let i = 0; i < list.count; i++) {
            const row = list.itemAtIndex(i);
            if (!row)
                continue;
            for (const name of ["runningAppActivate", "runningAppMinimizeButton", "runningAppCloseButton"]) {
                if (root.rowButton(row, name)?.activeFocus)
                    return "row" + i + ":" + name;
            }
        }
        return list.activeFocus ? "list" : "";
    }

    function rowButton(row, name: string): var {
        return row ? CUtils.findChild(row, name) : null;
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
                    // Simulate an event-loop stall where activation completes
                    // before the first delayed flush callback runs after 2s.
                    root.timeoutFixture.deferActivation = true;
                    root.timeoutFixture.activated = false;
                    root.timeoutFixture.wayland.minimized = true;
                    Services.RunningApps.requestClose("7", root.timeoutFixture.wayland);
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "stalled-callback close starts pending");
                    root.timeoutFixture.wayland.completeActivation();
                    Services.RunningApps.flushCloses(2300);
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "stalled-callback close expires on late flush");
                    check(root.timeoutFixture.counts.closes === 0
                        && root.timeoutFixture.counts.unsafeCloses === 0,
                        "stalled-callback close does not dispatch after deadline");
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
                    root.multiFirst = root.makeFixture("11", "fixture-multi");
                    root.multiSecond = root.makeFixture("12", "fixture-multi");
                    for (const item of [root.multiFirst, root.multiSecond]) {
                        item.deferActivation = true;
                        item.activated = false;
                        item.wayland.minimized = false;
                    }
                    Services.RunningApps.source =
                        Services.RunningApps.source.concat([root.multiFirst, root.multiSecond]);
                } else if (root.phase === 28) {
                    check(Services.RunningApps.windows["11"] !== undefined
                        && Services.RunningApps.windows["12"] !== undefined,
                        "multi-window close fixtures are projected");
                    Services.RunningApps.request("11", "close");
                    Services.RunningApps.request("12", "close");
                } else if (root.phase === 29) {
                    check(root.multiFirst.counts.activations === 1,
                        "first concurrent close activates");
                    check(root.multiSecond.counts.activations === 0,
                        "second concurrent close waits its turn");
                    check(Services.RunningApps.pendingCloses.length === 2,
                        "both concurrent closes are queued");
                    check(root.multiFirst.counts.closes === 0
                        && root.multiSecond.counts.closes === 0,
                        "queued closes wait for observed activation");
                    root.multiFirst.wayland.completeActivation();
                    interval = 250;
                } else if (root.phase === 30) {
                    check(root.multiFirst.counts.closes === 1,
                        "first queued close dispatches after activation");
                    check(root.multiFirst.counts.unsafeCloses === 0,
                        "first queued close was safe");
                    check(root.multiSecond.counts.activations === 1,
                        "second close activates only after the first dispatches");
                    check(root.multiSecond.counts.closes === 0,
                        "second close still waits for its own activation");
                    root.multiSecond.wayland.completeActivation();
                    interval = 250;
                } else if (root.phase === 31) {
                    check(root.multiSecond.counts.closes === 1,
                        "second queued close dispatches after activation");
                    check(root.multiSecond.counts.unsafeCloses === 0,
                        "second queued close was safe");
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "concurrent close queue drains");
                    root.queueFirst = root.makeFixture("20", "fixture-queue");
                    root.queueSecond = root.makeFixture("21", "fixture-queue");
                    root.queueThird = root.makeFixture("22", "fixture-queue");
                    for (const item of [root.queueFirst, root.queueSecond, root.queueThird]) {
                        item.deferActivation = true;
                        item.activated = false;
                        item.wayland.minimized = false;
                    }
                    Services.RunningApps.source = Services.RunningApps.source.concat(
                        [root.queueFirst, root.queueSecond, root.queueThird]);
                } else if (root.phase === 32) {
                    Services.RunningApps.request("20", "close");
                    Services.RunningApps.request("21", "close");
                    Services.RunningApps.request("22", "close");
                } else if (root.phase === 33) {
                    check(root.queueFirst.counts.activations === 1,
                        "timeout head activates first");
                    check(root.queueSecond.counts.activations === 0
                        && root.queueThird.counts.activations === 0,
                        "later close requests do not compete for foreground");
                    check(Services.RunningApps.pendingCloses.length === 3,
                        "three close requests are queued");
                    interval = 2200;
                } else if (root.phase === 34) {
                    interval = 80;
                    check(root.queueFirst.counts.closes === 0
                        && root.queueFirst.counts.unsafeCloses === 0,
                        "timed-out head sends no close");
                    check(root.queueSecond.counts.activations === 1,
                        "next request activates after the head times out");
                    check(root.queueThird.counts.activations === 0,
                        "third request remains queued");
                    check(Services.RunningApps.pendingCloses.length === 2,
                        "timeout leaves later requests queued");
                    root.queueReplacement = root.makeFixture("22", "fixture-queue");
                    root.queueReplacement.deferActivation = true;
                    root.queueReplacement.activated = false;
                    root.queueReplacement.wayland.minimized = false;
                    const next = Services.RunningApps.source.slice();
                    next[next.indexOf(root.queueThird)] = root.queueReplacement;
                    Services.RunningApps.source = next;
                } else if (root.phase === 35) {
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "replaced queued target cancels its request");
                    check(root.queueThird.counts.activations === 0
                        && root.queueThird.counts.closes === 0,
                        "old queued target never activates or closes");
                    check(root.queueReplacement.counts.activations === 0
                        && root.queueReplacement.counts.closes === 0,
                        "replacement target inherits no close");
                    root.queueSecond.wayland.completeActivation();
                    interval = 250;
                } else if (root.phase === 36) {
                    check(root.queueSecond.counts.closes === 1,
                        "promoted close dispatches after activation");
                    check(root.queueSecond.counts.unsafeCloses === 0,
                        "promoted close was safe");
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "close queue drains after identity cancellation");
                    root.retryFixture = root.makeFixture("30", "fixture-retry");
                    root.retryFixture.deferActivation = true;
                    root.retryFixture.activated = false;
                    root.retryFixture.wayland.minimized = false;
                    Services.RunningApps.source =
                        Services.RunningApps.source.concat(root.retryFixture);
                } else if (root.phase === 37) {
                    Services.RunningApps.request("30", "close");
                } else if (root.phase === 38) {
                    check(root.retryFixture.counts.activations === 1,
                        "retry fixture activates before close");
                    check(Services.RunningApps.pendingCloses.length === 1,
                        "retry fixture close is pending");
                    root.retryFixture.wayland.completeActivation();
                    interval = 250;
                } else if (root.phase === 39) {
                    check(root.retryFixture.counts.closes === 1,
                        "first close dispatches once");
                    check(root.retryFixture.savePromptOpen,
                        "first close left the window open like a save prompt");
                    root.retryFixture.cancelSavePrompt();
                    check(!root.retryFixture.savePromptOpen,
                        "cancelled prompt leaves the window open");
                    // A duplicate inside the coalescing window is ignored.
                    Services.RunningApps.request("30", "close");
                    interval = 1100;
                } else if (root.phase === 40) {
                    interval = 80;
                    check(root.retryFixture.counts.closes === 1,
                        "duplicate close inside the coalescing window is ignored");
                    check(root.retryFixture.counts.activations === 1,
                        "coalesced duplicate does not reactivate");
                    check(Services.RunningApps.pendingCloses.length === 0,
                        "coalesced duplicate leaves no pending request");
                    // The user deliberately retries after the prompt was cancelled.
                    Services.RunningApps.request("30", "close");
                } else if (root.phase === 41) {
                    check(root.retryFixture.counts.activations === 2,
                        "deliberate retry activates the still-open target");
                    // The target is still active, so the retry may dispatch in
                    // the same turn instead of waiting for another observation.
                    check(root.retryFixture.counts.closes === 2
                        || Services.RunningApps.pendingCloses.length === 1,
                        "deliberate retry posts one more close");
                    root.retryFixture.wayland.completeActivation();
                    interval = 250;
                } else if (root.phase === 42) {
                    check(root.retryFixture.counts.closes === 2,
                        "deliberate retry posts exactly one more close");
                    check(root.retryFixture.counts.unsafeCloses === 0,
                        "deliberate retry was safe");
                    root.interactionFirst = root.makeFixture("40", "fixture-interaction");
                    root.interactionSecond = root.makeFixture("41", "fixture-interaction");
                    root.interactionThird = root.makeFixture("42", "fixture-interaction");
                    Services.RunningApps.source =
                        [root.interactionFirst, root.interactionSecond, root.interactionThird];
                } else if (root.phase === 43) {
                    check(Services.RunningApps.groupIds.length === 1,
                        "interaction fixtures project one app");
                    check(Services.RunningApps.groups["fixture-interaction"]?.windowIds.length === 3,
                        "interaction app has three windows");
                } else if (root.phase === 44) {
                    const row = root.appRow("fixture-interaction");
                    check(row !== null, "interaction app row is visible");
                    check(input.mouseClick(row, row.width / 2, row.height / 2,
                        Qt.LeftButton, Qt.NoModifier, 0), "interaction click delivered");
                } else if (root.phase === 45) {
                    const popup = root.chooser();
                    check(popup?.visible === true, "interaction chooser opened");
                    check(root.chooserList(popup)?.count === 3, "interaction rows projected");
                    check(root.focusAt(popup) === "list", "chooser starts with list keyboard focus");
                    check(input.keyClick(Qt.Key_Escape, Qt.NoModifier, 0), "Escape event delivered");
                    check(!popup.visible, "Escape dismisses the chooser");
                } else if (root.phase === 46) {
                    const row = root.appRow("fixture-interaction");
                    check(input.mouseClick(row, row.width / 2, row.height / 2,
                        Qt.LeftButton, Qt.NoModifier, 0), "second chooser click delivered");
                } else if (root.phase === 47) {
                    const popup = root.chooser();
                    check(popup?.visible === true, "chooser reopens after Escape");
                    check(root.focusAt(popup) === "list", "reopened chooser takes list focus");
                    input.keyClick(Qt.Key_Tab, Qt.NoModifier, 0);
                    check(root.focusAt(popup) === "row0:runningAppActivate",
                        "Tab reaches the first row's activate action");
                    input.keyClick(Qt.Key_Tab, Qt.NoModifier, 0);
                    check(root.focusAt(popup) === "row0:runningAppMinimizeButton",
                        "Tab reaches the first row's minimize action");
                    input.keyClick(Qt.Key_Tab, Qt.NoModifier, 0);
                    check(root.focusAt(popup) === "row0:runningAppCloseButton",
                        "Tab reaches the first row's close action");
                    input.keyClick(Qt.Key_Tab, Qt.NoModifier, 0);
                    check(root.focusAt(popup) === "row1:runningAppActivate",
                        "Tab crosses to the next window row");
                    check(input.keyClick(Qt.Key_Escape, Qt.NoModifier, 0),
                        "Escape event delivered from a row action");
                    check(!popup.visible, "Escape from a row action dismisses the chooser");
                } else if (root.phase === 48) {
                    const row = root.appRow("fixture-interaction");
                    check(input.mouseClick(row, row.width / 2, row.height / 2,
                        Qt.LeftButton, Qt.NoModifier, 0), "selection chooser click delivered");
                    const popup = root.chooser();
                    check(popup?.visible === true, "selection chooser opens");
                    check(root.chooserList(popup)?.currentIndex === 0,
                        "chooser opens on the first window");
                } else if (root.phase === 49) {
                    const popup = root.chooser();
                    input.keyClick(Qt.Key_Down, Qt.NoModifier, 0);
                    check(root.chooserList(popup)?.currentIndex === 1,
                        "Down selects the second window");
                    check(input.keyClick(Qt.Key_Return, Qt.NoModifier, 0),
                        "Return event delivered to the chooser");
                    check(!popup.visible, "chooser dismisses before activation");
                } else if (root.phase === 50) {
                    check(root.interactionSecond.counts.activations === 1,
                        "Return activates the selected second window");
                    check(root.interactionFirst.counts.activations === 0
                        && root.interactionThird.counts.activations === 0,
                        "Return does not activate another window");
                    const row = root.appRow("fixture-interaction");
                    check(input.mouseClick(row, row.width / 2, row.height / 2,
                        Qt.LeftButton, Qt.NoModifier, 0), "reopen after selection click delivered");
                } else if (root.phase === 51) {
                    const popup = root.chooser();
                    check(popup?.visible === true, "chooser reopens after a selection");
                    check(root.chooserList(popup)?.currentIndex === 0,
                        "reopened chooser resets to the first window");
                    input.keyClick(Qt.Key_Down, Qt.NoModifier, 0);
                    input.keyClick(Qt.Key_Down, Qt.NoModifier, 0);
                    check(root.chooserList(popup)?.currentIndex === 2,
                        "keyboard selection reaches the third window");
                    // A window closes while the chooser is open. Return lands
                    // before the deferred list layout clamps currentIndex, so
                    // activation must clamp the row itself.
                    Services.RunningApps.source = [root.interactionFirst, root.interactionSecond];
                    check(input.keyClick(Qt.Key_Return, Qt.NoModifier, 0),
                        "Return after list shrink delivered");
                    check(!popup.visible, "chooser dismisses on activation after list shrink");
                } else if (root.phase === 52) {
                    check(root.interactionSecond.counts.activations === 2,
                        "activation after list shrink selects the remaining row");
                    check(root.interactionFirst.counts.activations === 0
                        && root.interactionThird.counts.activations === 0,
                        "list-shrink activation sends no stale target");
                    const row = root.appRow("fixture-interaction");
                    check(input.mouseClick(row, row.width / 2, row.height / 2,
                        Qt.LeftButton, Qt.NoModifier, 0), "outside-click chooser click delivered");
                } else if (root.phase === 53) {
                    const popup = root.chooser();
                    check(popup?.visible === true, "outside-click chooser opens");
                    check(root.chooserList(popup)?.count === 2, "shrunk rows are projected");
                    check(input.mouseClick(pill, 5, 470, Qt.LeftButton, Qt.NoModifier, 0),
                        "outside click delivered to the parent window");
                    check(!popup.visible, "outside click dismisses the chooser");
                    check(root.interactionSecond.counts.activations === 2,
                        "outside click activates nothing");
                } else if (root.phase === 54) {
                    Services.RunningApps.source = [];
                } else if (root.phase === 55) {
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
