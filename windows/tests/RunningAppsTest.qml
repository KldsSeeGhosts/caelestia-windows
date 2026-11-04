import QtQuick
import QtTest
import Quickshell
import Caelestia
import qs.components.controls
import qs.services as Services
import qs.modules.bar as Bar
import qs.modules.bar.popouts as BarPopouts

ShellRoot {
    id: root
    property int assertions: 0
    property int phase: 0
    property var fixtures: []
    property var manyFixtures: []
    property var barPill
    property var barWorkspaces
    property var barPopouts
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
    property var singleFixture
    property real hoverAt: 0
    property real waitUntil: 0
    readonly property var screen: Quickshell.screens.length ? Quickshell.screens[0] : null
    readonly property var screenState: screen ? Services.ShellState.forScreen(screen) : null

    // The shell loads this font. Without it the bar entries fall back to
    // literal icon names and widen the bar's layout past its 60px width.
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
                onMinimizedChanged: {
                    if (minimized)
                        target.counts.minimizes++;
                }
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

    TestEvent { id: input }
    property var keyInput: null
    Component { id: keyInputComponent; TestCase { when: false } }

    // Match ContentWindow: the bar is a child of the window-sized Interactions
    // mouse area. Its hover edge opens the shared popout exactly as the
    // production host does, and it only sees wheel input the bar does not
    // consume.
    FloatingWindow {
        id: barHost
        visible: true
        implicitWidth: 480
        implicitHeight: 1000

        CustomMouseArea {
            id: barInteractions
            anchors.fill: parent
            hoverEnabled: true
            function onWheel(event: WheelEvent): void {
                root.dispatcherWheels++;
                if (event.x < bar.implicitWidth)
                    bar.handleWheel(event.y, event.angleDelta);
            }
            // HoverHandler delivers a point for every pointer move; the shared
            // popout follows the bar's hover edge exactly as Interactions does.
            HoverHandler {
                id: barHover
                onPointChanged: {
                    if (barHover.point.position.x < bar.implicitWidth) {
                            bar.checkPopout(barHover.point.position.y);
                    }
                }
            }

            Bar.BarWrapper {
                id: bar
                anchors.top: parent.top
                anchors.bottom: parent.bottom
                screen: root.screen
                screenState: root.screenState
                popouts: popouts
                fullscreen: false
            }
        }

        // The production ClipWrapper places the shared popout beside the bar
        // and above it, following its centre.
        BarPopouts.Wrapper {
            id: popouts
            width: implicitWidth
            height: implicitHeight
            x: bar.contentWidth + 8
            y: Math.max(0, Math.min(barHost.height - height, popouts.currentCenter - height / 2))
            z: 1
            screen: root.screen
            offsetScale: 0
        }
    }

    function check(ok, message): void {
        assertions++;
        if (!ok)
            throw new Error(message);
    }

    function newCounts(): var {
        return { activations: 0, closes: 0, unsafeCloses: 0, minimizes: 0 };
    }

    function makeFixture(address: string, appId: string): var {
        return fixture.createObject(root, { address: address, appId: appId, counts: root.newCounts() });
    }

    function listFor(item): var {
        return item ? Array.from(item.data).find(child => child.contentY !== undefined) : null;
    }

    function refreshBar(): void {
        barPill = CUtils.findChild(bar, "taskbarActiveWindow");
        barWorkspaces = CUtils.findChild(bar, "taskbarWorkspaces");
        barPopouts = popouts;
    }

    function appRow(key: string): var {
        const apps = listFor(barPill);
        if (!apps)
            return null;
        for (let i = 0; i < apps.count; i++) {
            const item = apps.itemAtIndex(i);
            if (item?.modelData === key)
                return item;
        }
        return null;
    }

    // The focusable child of a strip row. Focus lands here, not on the
    // delegate Item, so this is what Tab moves between.
    function appButton(index: int): var {
        const apps = root.listFor(root.barPill);
        const row = apps ? apps.itemAtIndex(index) : null;
        return row ? Array.from(row.children).find(child => child.activeFocusOnTab === true) ?? null : null;
    }

    function popoutList(): var {
        const content = popouts.current;
        return content ? CUtils.findChild(content, "activeWindowWindowList") : null;
    }

    function popoutRow(index: int): var {
        const list = root.popoutList();
        return list ? list.itemAtIndex(index) : null;
    }

    function sendPillWheel(): bool {
        return input.mouseWheel(barPill, barPill.width / 2, barPill.height / 2,
            Qt.NoButton, Qt.NoModifier, 0, -120, 0);
    }

    function sendWorkspaceWheel(): bool {
        // The top of the original workspace content, above the running-app strip.
        return input.mouseWheel(barWorkspaces, 10, 10,
            Qt.NoButton, Qt.NoModifier, 0, -120, 0);
    }

    function clickApp(key: string, button): bool {
        const row = root.appRow(key);
        return row !== null && input.mouseClick(row, row.width / 2, row.height / 2,
            button, Qt.NoModifier, 0);
    }

    Timer {
        interval: 80
        repeat: true
        running: true
        onTriggered: {
            if (root.waitUntil > Date.now())
                return;
            try {
                if (root.phase === 0) {
                    if (materialSymbols.status !== FontLoader.Ready)
                        return;
                    for (let i = 0; i < 9; i++)
                        root.fixtures.push(root.makeFixture(String(i + 1),
                            i < 2 ? "fixture-app" : "fixture-" + i));
                    for (let i = 0; i < 30; i++)
                        root.manyFixtures.push(root.makeFixture(String(100 + i), "many-app-" + i));
                    Services.RunningApps.source = root.fixtures;
                    Services.RunningApps.actionsEnabled = false;
                    root.screenState.bar = true;
                    // Key events go to the window's active focus item; a
                    // TestCase inside the window is the supported sender.
                    root.keyInput = keyInputComponent.createObject(barHost.contentItem);
                } else if (root.phase === 1) {
                    check(Services.RunningApps.groupIds.length === 8, "per-app grouping");
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
                } else if (root.phase === 4) {
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
                            || bar.width < bar.contentWidth - 0.5) {
                        console.log("WAIT5 pill=" + (root.barPill !== null) + " w=" + bar.width + " cw=" + bar.contentWidth + " ids=" + bar.children.map(c => c.entryId).join(",") + " names=" + CUtils.findChildrenMatching(bar, ".*").map(c => c.objectName).filter(n => n).join(","));
                        return;
                    }
                    check(root.barPill !== null && root.barPill.implicitHeight > 0,
                        "bar mounts the running-app strip");
                    // The capsule grows with its rows; wait for the height
                    // animation to settle on whole rows.
                    const rows = (root.barPill.implicitHeight - root.barPill.padding * 2) / root.barPill.rowSize;
                    if (rows < 1 || Math.abs(rows - Math.round(rows)) > 0.01)
                        return;
                    check(root.barWorkspaces !== null, "bar still mounts its workspaces entry");
                    check(bar.width >= bar.contentWidth - 0.5, "bar reaches its production width");
                    const pillX = root.barPill.mapToItem(bar, 0, 0).x;
                    check(pillX >= 0 && pillX + root.barPill.width <= bar.width,
                        "strip layout is inside the production-width bar");
                    check(root.barPill.rowSize === 32, "rows are 32px");
                    check(Math.abs(root.barPill.implicitHeight
                        - (Math.round(rows) * 32 + root.barPill.padding * 2)) < 0.51,
                        "strip height is whole 32px rows plus its capsule padding");
                    // More applications than the bar can show, for overflow.
                    Services.RunningApps.source = root.manyFixtures;
                } else if (root.phase === 6) {
                    check(Services.RunningApps.groupIds.length === 30, "overflow model projected");
                    const apps = root.listFor(root.barPill);
                    check(apps && apps.contentHeight > apps.height, "overflowing strip scrolls");
                    // Tab focus must scroll the focused row into view. Focus
                    // lands on the row's StateLayer, so a handler on the
                    // delegate Item never fires.
                    const first = root.appButton(0);
                    check(first !== null, "the first strip row is focusable");
                    first.forceActiveFocus();
                    let tabs = 0;
                    while (!(root.appButton(20)?.activeFocus ?? false) && tabs < 30) {
                        root.keyInput.keyClick(Qt.Key_Tab, Qt.NoModifier, 0);
                        tabs++;
                    }
                    check(root.appButton(20)?.activeFocus ?? false, "Tab reaches row 20");
                    check(apps.contentY > 0, "Tab scrolls the focused row into view");
                    const row20 = apps.itemAtIndex(20);
                    check(row20 !== null && row20.y >= apps.contentY
                        && row20.y + row20.height <= apps.contentY + apps.height,
                        "the focused row lies inside the viewport");
                    apps.contentY = 0;
                    root.hyprRefusals = Services.Hypr.refusals;
                    root.dispatcherWheels = 0;
                    check(root.sendPillWheel(), "offscreen wheel delivered to the strip");
                } else if (root.phase === 7) {
                    const apps = root.listFor(root.barPill);
                    check(apps?.contentY > 0, "wheel scrolls an overflowing strip");
                    check(root.dispatcherWheels === 0,
                        "overflow wheel is consumed by the strip's Flickable");
                    check(Services.Hypr.refusals === root.hyprRefusals,
                        "overflow wheel does not reach the workspace shortcut");
                    if (apps)
                        apps.contentY = 0;
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
                    const apps = root.listFor(root.barPill);
                    check(Services.RunningApps.groupIds.length === 1, "short list projected");
                    check(apps && apps.contentHeight <= apps.height,
                        "short list does not overflow");
                    root.hyprRefusals = Services.Hypr.refusals;
                    root.dispatcherWheels = 0;
                    check(root.sendPillWheel(), "short-list wheel delivered");
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
                    root.waitUntil = Date.now() + 2200;
                } else if (root.phase === 16) {
                    root.waitUntil = 0;
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
                    root.waitUntil = Date.now() + 250;
                } else if (root.phase === 27) {
                    root.waitUntil = 0;
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
                    root.waitUntil = Date.now() + 250;
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
                    root.waitUntil = Date.now() + 250;
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
                    root.waitUntil = Date.now() + 2200;
                } else if (root.phase === 34) {
                    root.waitUntil = 0;
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
                    root.waitUntil = Date.now() + 250;
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
                    root.waitUntil = Date.now() + 250;
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
                    root.waitUntil = Date.now() + 1100;
                } else if (root.phase === 40) {
                    root.waitUntil = 0;
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
                    root.waitUntil = Date.now() + 250;
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
                    // A retained facade value (the bar was just clicked) is not
                    // the native foreground.
                    root.interactionSecond.activated = true;
                    Services.RunningApps.foregroundAddress = "";
                    check(Services.RunningApps.groups["fixture-interaction"].active === true,
                        "the facade still reports the app active");
                    check(Services.RunningApps.focusedGroupId === "",
                        "a retained facade value is not native foreground");
                    root.singleFixture = root.makeFixture("50", "fixture-single");
                    Services.RunningApps.source =
                        [root.interactionFirst, root.interactionSecond, root.interactionThird,
                            root.singleFixture];
                    Services.RunningApps.actionsEnabled = true;
                } else if (root.phase === 44) {
                    check(root.appRow("fixture-single") !== null, "single-window app row is visible");
                    check(root.clickApp("fixture-single", Qt.LeftButton),
                        "focus click delivered to the strip");
                } else if (root.phase === 45) {
                    check(root.singleFixture.counts.activations === 1,
                        "clicking an unfocused app focuses its window");
                    check(root.singleFixture.counts.minimizes === 0,
                        "clicking an unfocused app does not minimize it");
                    Services.RunningApps.foregroundAddress = "50";
                    check(Services.RunningApps.focusedGroupId === "fixture-single",
                        "the native foreground decides the focused app");
                } else if (root.phase === 46) {
                    check(root.clickApp("fixture-single", Qt.LeftButton),
                        "minimize click delivered to the strip");
                } else if (root.phase === 47) {
                    check(root.singleFixture.wayland.minimized === true,
                        "clicking a focused single-window app minimizes it");
                    check(root.singleFixture.counts.minimizes === 1,
                        "minimize is dispatched exactly once");
                    check(root.singleFixture.counts.activations === 1,
                        "minimize does not reactivate the window");
                    // A focused multi-window app cycles in stable order.
                    root.interactionFirst.activated = true;
                    root.interactionSecond.activated = false;
                    root.interactionThird.activated = false;
                    Services.RunningApps.foregroundAddress = "40";
                    check(root.clickApp("fixture-interaction", Qt.LeftButton),
                        "cycle click delivered to the strip");
                } else if (root.phase === 48) {
                    check(root.interactionSecond.counts.activations === 1,
                        "a focused multi-window app cycles to its next window");
                    Services.RunningApps.foregroundAddress = "41";
                    check(root.clickApp("fixture-interaction", Qt.LeftButton),
                        "second cycle click delivered to the strip");
                } else if (root.phase === 49) {
                    check(root.interactionThird.counts.activations === 1,
                        "the next cycle click advances again");
                    check(root.interactionFirst.counts.activations === 0,
                        "cycling never skips or reuses a window");
                    Services.RunningApps.foregroundAddress = "42";
                    check(root.clickApp("fixture-interaction", Qt.LeftButton),
                        "wrap cycle click delivered to the strip");
                } else if (root.phase === 50) {
                    check(root.interactionFirst.counts.activations === 1,
                        "cycling wraps to the first window in stable order");
                    check(root.interactionSecond.counts.activations === 1
                        && root.interactionThird.counts.activations === 1,
                        "one cycle activates each window once");
                    Services.RunningApps.foregroundAddress = "40";
                    check(root.appRow("fixture-interaction") !== null, "interaction row visible before hover");
                    check(input.mouseMove(barInteractions, 5, 950, Qt.NoButton, Qt.NoModifier, 0),
                        "pointer moved away from the strip");
                } else if (root.phase === 51) {
                    const row = root.appRow("fixture-interaction");
                    check(row !== null, "interaction row visible for hover");
                    check(input.mouseMove(row, row.width / 2, row.height / 2,
                        Qt.NoButton, Qt.NoModifier, 0), "hover move delivered to the strip");
                } else if (root.phase === 52) {
                    check(Services.RunningApps.previewGroupId === "fixture-interaction",
                        "hovering a row previews that application");
                    check(Services.RunningApps.previewWindowId === "40",
                        "the preview starts on the app's last active window");
                    check(popouts.currentName === "activewindow" && popouts.hasCurrent,
                        "hovering the strip opens the shared active-window popout");
                    const rows = root.popoutList();
                    if (rows === null)
                        return;
                    check(rows.count === 3, "the popout lists every window of the app");
                    check(Math.abs(popouts.currentCenter
                        - (barPill.mapToItem(bar, 0, 0).y + barPill.hoverCenter)) < 1.5,
                        "the popout is anchored at the hovered row's centre");
                    check(popouts.current !== null, "the popout content loaded");
                } else if (root.phase === 53) {
                    const second = root.popoutRow(1);
                    check(second !== null, "the second popout row is instantiated");
                    check(input.mouseMove(second, second.width / 2, second.height / 2,
                        Qt.NoButton, Qt.NoModifier, 0), "hover move delivered to a popout row");
                } else if (root.phase === 54) {
                    check(Services.RunningApps.previewWindowId === "41",
                        "hovering a popout row swaps the preview");
                    const first = root.popoutRow(0);
                    check(first !== null, "the first popout row is instantiated");
                    check(input.mouseClick(first, first.width / 2, first.height / 2,
                        Qt.LeftButton, Qt.NoModifier, 0), "popout row click delivered");
                } else if (root.phase === 55) {
                    check(root.interactionFirst.counts.activations === 2,
                        "clicking a popout row activates that window");
                    check(!popouts.hasCurrent, "activating a window closes the popout");
                    const row = root.appRow("fixture-single");
                    check(row !== null && input.mouseClick(row, row.width / 2, row.height / 2,
                        Qt.RightButton, Qt.NoModifier, 0), "right click delivered to the strip");
                } else if (root.phase === 56) {
                    check(barPill.pinned === true, "right click pins the popout");
                    check(popouts.currentName === "activewindow" && popouts.hasCurrent,
                        "right click opens the popout without a hover");
                    check(Services.RunningApps.previewGroupId === "fixture-single",
                        "the pinned popout previews the clicked application");
                    check(root.popoutList()?.count === 1, "the pinned popout lists its only window");
                } else if (root.phase === 57) {
                    root.keyInput.keyClick(Qt.Key_Escape, Qt.NoModifier, 0);
                } else if (root.phase === 58) {
                    check(!popouts.hasCurrent, "Escape closes the pinned popout");
                    check(barPill.pinned === false, "closing the popout releases the pin");
                    const row = root.appRow("fixture-single");
                    check(row !== null && input.mouseClick(row, row.width / 2, row.height / 2,
                        Qt.RightButton, Qt.NoModifier, 0), "right click reopens the pinned popout");
                } else if (root.phase === 59) {
                    check(barPill.pinned === true && popouts.hasCurrent,
                        "the popout is pinned again");
                    check(root.popoutList()?.activeFocus === true,
                        "a pinned popout moves keyboard focus into its window list");
                    const row = root.popoutRow(0);
                    const close = row ? CUtils.findChild(row, "activeWindowWindowClose") : null;
                    check(close !== null, "the popout row has a close button");
                    check(input.mouseClick(close, close.width / 2, close.height / 2,
                        Qt.LeftButton, Qt.NoModifier, 0), "close click delivered to the popout");
                } else if (root.phase === 60) {
                    check(root.singleFixture.counts.unsafeCloses === 0,
                        "the guarded close never closes a hidden window");
                    check(root.singleFixture.counts.activations === 2,
                        "the guarded close restores and activates first");
                    // The single window was minimized by the click test; its
                    // restore is observed before the close is dispatched.
                    root.singleFixture.wayland.completeActivation();
                    root.waitUntil = Date.now() + 250;
                } else if (root.phase === 61) {
                    root.waitUntil = 0;
                    check(root.singleFixture.counts.closes === 1,
                        "the popout close uses the guarded close path");
                    Services.RunningApps.source = [];
                } else if (root.phase === 62) {
                    check(Services.RunningApps.groupIds.length === 0, "empty model");
                    root.waitUntil = Date.now() + 700;
                } else {
                    check(barPill.implicitHeight === 0, "the strip disappears when no app is running");
                    check(barPill.visible === false, "the empty strip is hidden");
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
