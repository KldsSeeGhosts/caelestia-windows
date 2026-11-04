// Notification popup action accessibility check (ERM-615).
//
// Runs the staged production notification card with a fixture NotifData whose
// action is recorded in memory; no native notification, clipboard or session
// path is touched. Every audit row is independent, so the before-fix run shows
// every missing name, role and keyboard binding rather than stopping at the
// first. The card is also collapsed and expanded again: a collapsed card hides
// its action row with opacity only, so the hidden controls must leave the tab
// chain and must not keep active focus. The collapse-focus guard may only move
// focus when it was inside the collapsing card's action row, so the negative
// rows collapse from another surface, from another card, from an inactive
// window and from a pointer click without row focus.
import QtQuick
import QtTest
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.notifications

ShellRoot {
    id: root

    settings.watchFiles: false

    Config.screen: Quickshell.screens[0]?.name ?? ""
    Tokens.screen: Quickshell.screens[0]?.name ?? ""

    property var input: null
    property int ticks: 0
    property int rows: 0
    property int failures: 0
    property bool busy: false

    WindowsFonts {}

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    QtObject {
        id: fakeService

        property int invoked: 0
        property string lastAction: ""
        property int removed: 0

        function sanitizeBody(value): string {
            return String(value ?? "");
        }

        function validateAppIcon(value): var {
            return { accepted: false, value: "" };
        }

        function invokeHistoricalAction(record, identifier): void {
            fakeService.invoked++;
            fakeService.lastAction = String(identifier);
        }

        function removeRecord(record, dismiss): void {
            fakeService.removed++;
        }
    }

    NotifData {
        id: record

        service: fakeService
        appName: "Fixture app"
        summary: "Fixture summary"
        body: "Fixture body"
        urgency: 1
        historicalActions: [
            {
                identifier: "open",
                text: "Open"
            }
        ]
    }

    NotifData {
        id: otherRecord

        service: fakeService
        appName: "Other fixture app"
        summary: "Other fixture summary"
        body: "Other fixture body"
        urgency: 1
        historicalActions: [
            {
                identifier: "other",
                text: "Other"
            }
        ]
    }

    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 460
        implicitHeight: 360
        color: Colours.palette.m3background
        contentItem.Config.screen: Quickshell.screens[0]?.name ?? ""

        Column {
            spacing: Tokens.spacing.medium

            Notification {
                id: view

                modelData: record
                expanded: true
                implicitWidth: 420
            }

            Notification {
                id: otherView

                modelData: otherRecord
                expanded: true
                implicitWidth: 420
            }
        }

        // Stand-in for a second surface in the same window: focus here is
        // outside every card's action row.
        Item {
            id: otherSurface

            anchors.right: parent.right
            anchors.bottom: parent.bottom
            width: 40
            height: 40

            activeFocusOnTab: true
            Accessible.role: Accessible.Pane
            Accessible.name: "Another surface"
        }
    }

    // A second surface that can take the application focus, making the
    // notification window inactive while its card still holds focus.
    FloatingWindow {
        id: backgroundWindow

        visible: false
        implicitWidth: 200
        implicitHeight: 100
        color: Colours.palette.m3background
        contentItem.Config.screen: Quickshell.screens[0]?.name ?? ""

        Item {
            anchors.fill: parent
            activeFocusOnTab: true
        }
    }

    readonly property Component inputComponent: Component {
        TestCase { when: false }
    }

    Timer {
        id: driver

        interval: 100
        repeat: true
        running: true
        onTriggered: root.advance()
    }

    function collectButtons(item, out): void {
        for (const child of item?.children ?? []) {
            if (child?.stateLayer !== undefined && typeof child.clicked === "function")
                out.push(child);
            root.collectButtons(child, out);
        }
    }

    function byIconText(item, text): var {
        for (const child of item?.children ?? []) {
            if (child?.text === text && child?.font !== undefined)
                return child;
            const found = root.byIconText(child, text);
            if (found)
                return found;
        }
        return null;
    }

    // Resolve one card's controls, so a row never reads the other card's
    // same-named button.
    function cardControls(card, actionText): var {
        const buttons = [];
        root.collectButtons(card, buttons);
        const expandIcon = root.byIconText(card, "expand_more");
        return {
            close: buttons.find(button => button.icon === "close") ?? null,
            copy: buttons.find(button => button.icon === "content_copy") ?? null,
            action: buttons.find(button => button.text === actionText) ?? null,
            expand: expandIcon?.parent ?? null
        };
    }

    // The Quickshell window wrapper does not expose the QQuickWindow's focus.
    function focusItem(): var {
        return win.contentItem.Window.activeFocusItem;
    }

    // Visible on screen: every ancestor up to the window is visible and not
    // faded out.
    function shown(item): bool {
        if (!item || !item.visible)
            return false;
        for (let node = item; node && node !== win.contentItem; node = node.parent) {
            if (!node.visible || node.opacity <= 0.01)
                return false;
        }
        return true;
    }

    function row(name, fn): void {
        root.rows++;
        try {
            fn();
            console.log(`CAELESTIA_A11Y_ROW ${name} PASS`);
        } catch (error) {
            root.failures++;
            console.error(`CAELESTIA_A11Y_ROW ${name} FAIL ${error.message}`);
        }
    }

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
    }

    // Pump the event loop until a state settles, so window activation is not
    // timed by a fixed delay.
    function waitUntil(condition, timeout): bool {
        const deadline = Date.now() + timeout;
        while (Date.now() < deadline) {
            if (condition())
                return true;
            root.input.wait(20);
        }
        return condition();
    }

    function advance(): void {
        if (root.busy)
            return;
        root.busy = true;
        try {
            if (root.ticks++ < 5)
                return;
            root.input = root.inputComponent.createObject(win.contentItem);
            root.run();
            driver.stop();
            console.log(`CAELESTIA_A11Y_CHECKS ${root.rows}`);
            if (root.failures > 0) {
                console.error(`CAELESTIA_A11Y_FAIL ${root.failures} of ${root.rows} rows`);
                Qt.exit(1);
                return;
            }
            console.log(`CAELESTIA_A11Y_PASS ${root.rows}`);
            Qt.quit();
        } catch (error) {
            driver.stop();
            console.error("CAELESTIA_A11Y_HARNESS_FAIL " + error.message);
            Qt.exit(1);
        } finally {
            root.busy = false;
        }
    }

    function run(): void {
        const main = root.cardControls(view, "Open");
        const other = root.cardControls(otherView, "Other");
        const close = main.close;
        const copy = main.copy;
        const action = main.action;
        const expand = main.expand;

        root.check(close, "notification close button is missing");
        root.check(copy, "notification copy button is missing");
        root.check(action, "notification action button is missing");
        root.check(expand, "notification expand control is missing");
        root.check(other.action, "the second notification action button is missing");
        root.check(other.expand, "the second notification expand control is missing");

        root.row("notification action joins the tab chain", () => {
            root.check(action.activeFocusOnTab, "the action button is not in the tab chain");
        });

        root.row("notification action exposes role and name", () => {
            root.check(action.Accessible.role === Accessible.Button, `role is ${action.Accessible.role}`);
            root.check(action.Accessible.name === "Open", `name is "${action.Accessible.name}"`);
        });

        root.row("notification close joins the tab chain with a name", () => {
            root.check(close.activeFocusOnTab, "the close button is not in the tab chain");
            root.check(close.Accessible.role === Accessible.Button, `role is ${close.Accessible.role}`);
            root.check(close.Accessible.name === "Dismiss notification", `name is "${close.Accessible.name}"`);
        });

        root.row("notification copy joins the tab chain with a name", () => {
            root.check(copy.activeFocusOnTab, "the copy button is not in the tab chain");
            root.check(copy.Accessible.role === Accessible.Button, `role is ${copy.Accessible.role}`);
            root.check(copy.Accessible.name === "Copy notification text", `name is "${copy.Accessible.name}"`);
        });

        root.row("notification expand is keyboard reachable and named", () => {
            root.check(expand.activeFocusOnTab, "the expand control is not in the tab chain");
            root.check(expand.Accessible.role === Accessible.Button, `role is ${expand.Accessible.role}`);
            root.check(expand.Accessible.name === "Collapse notification", `name is "${expand.Accessible.name}"`);
        });

        root.row("collapsed notification skips its hidden actions", () => {
            view.expanded = false;
            root.input.wait(80);
            root.check(!close.activeFocusOnTab, "collapsed close is still in the tab chain");
            root.check(!action.activeFocusOnTab, "collapsed action is still in the tab chain");
            root.check(!copy.activeFocusOnTab, "collapsed copy is still in the tab chain");
            expand.forceActiveFocus(Qt.TabFocusReason);
            root.check(expand.activeFocus, "the expand control did not take focus");
            root.input.keyClick(Qt.Key_Tab);
            const focused = root.focusItem();
            root.check(focused !== close && focused !== action && focused !== copy,
                `Tab landed on a hidden action (${focused?.Accessible?.name ?? "unnamed"})`);
            root.check(root.shown(focused), "Tab landed on an invisible item");
        });

        root.row("collapsing moves focus off the hidden action", () => {
            view.expanded = true;
            root.input.wait(80);
            action.forceActiveFocus(Qt.TabFocusReason);
            root.check(action.activeFocus, "the action did not take focus before collapsing");
            view.expanded = false;
            root.input.wait(80);
            root.check(!action.activeFocus && !close.activeFocus && !copy.activeFocus,
                "focus stayed on an action hidden by the collapse");
            const focused = root.focusItem();
            root.check(focused !== null, "the collapse left focus on nothing");
            root.check(root.shown(focused), "the collapse left focus on an invisible item");
            root.check(focused === expand || focused === view,
                `focus moved to ${focused?.Accessible?.name ?? "an unexpected item"}`);
        });

        // Negative guard cases. None of these collapses happen under focus
        // inside this card's action row, so none may move focus.
        root.row("collapsing a card keeps focus on another surface", () => {
            view.expanded = true;
            root.input.wait(80);
            otherSurface.forceActiveFocus(Qt.TabFocusReason);
            root.check(otherSurface.activeFocus, "the other surface did not take focus");
            view.expanded = false;
            root.input.wait(80);
            root.check(!view.expanded, "the card did not collapse");
            root.check(otherSurface.activeFocus, "the collapse stole focus from another surface");
            root.check(!expand.activeFocus && !action.activeFocus,
                "the collapse moved focus into the card");
            root.check(root.focusItem() === otherSurface,
                `focus moved to ${root.focusItem()?.Accessible?.name ?? "an unexpected item"}`);
        });

        root.row("collapsing another card keeps focus in the focused row", () => {
            view.expanded = true;
            otherView.expanded = true;
            root.input.wait(80);
            action.forceActiveFocus(Qt.TabFocusReason);
            root.check(action.activeFocus, "the action did not take focus");
            otherView.expanded = false;
            root.input.wait(80);
            root.check(!otherView.expanded, "the other card did not collapse");
            root.check(!other.action.activeFocusOnTab, "the collapsed card kept its actions in the tab chain");
            root.check(action.activeFocus, "collapsing another card moved focus off the action");
            root.check(root.focusItem() === action,
                `focus moved to ${root.focusItem()?.Accessible?.name ?? "an unexpected item"}`);
        });

        root.row("a pointer collapse without row focus leaves focus alone", () => {
            view.expanded = true;
            root.input.wait(80);
            otherSurface.forceActiveFocus(Qt.TabFocusReason);
            root.check(otherSurface.activeFocus, "the other surface did not take focus");
            // TestCase.mouseClick records its own failure and returns nothing,
            // so the collapsed state below proves the click was delivered.
            root.input.mouseClick(expand, expand.width / 2, expand.height / 2);
            root.input.wait(80);
            root.check(!view.expanded, "the pointer click did not collapse the card");
            root.check(otherSurface.activeFocus, "the pointer collapse stole focus from another surface");
            root.check(!expand.focus && !expand.activeFocus,
                "the pointer collapse moved focus to the expand control");
            root.check(root.focusItem() === otherSurface,
                `focus moved to ${root.focusItem()?.Accessible?.name ?? "an unexpected item"}`);
        });

        // Last, because taking the application focus away and restoring it is
        // the only negative case that touches window activation.
        root.row("collapsing in an inactive window leaves the focus chain alone", () => {
            view.expanded = true;
            root.input.wait(80);
            action.forceActiveFocus(Qt.TabFocusReason);
            root.check(action.activeFocus, "the action did not take focus");
            backgroundWindow.visible = true;
            backgroundWindow.requestActivate();
            root.check(root.waitUntil(() => !win.contentItem.Window.active, 2000),
                "the notification window is still active");
            root.check(action.focus, "the inactive window lost the action focus chain");
            view.expanded = false;
            root.input.wait(80);
            root.check(!view.expanded, "the card did not collapse");
            root.check(!expand.focus && !expand.activeFocus,
                "the background collapse moved the focus chain to the expand control");
            root.check(action.focus, "the background collapse moved the focus chain off the action");
            backgroundWindow.visible = false;
            win.visible = false;
            win.visible = true;
            win.requestActivate();
            root.check(root.waitUntil(() => root.focusItem() === action, 2000),
                `returning to the window focused ${root.focusItem()?.Accessible?.name ?? "an unexpected item"}`);
        });

        root.row("expanding restores action traversal", () => {
            view.expanded = false;
            root.input.wait(80);
            root.check(!close.activeFocusOnTab && !action.activeFocusOnTab && !copy.activeFocusOnTab,
                "a collapsed action stayed in the tab chain before expanding");
            view.expanded = true;
            root.input.wait(80);
            root.check(close.activeFocusOnTab, "expanded close is not in the tab chain");
            root.check(action.activeFocusOnTab, "expanded action is not in the tab chain");
            root.check(copy.activeFocusOnTab, "expanded copy is not in the tab chain");
            expand.forceActiveFocus(Qt.TabFocusReason);
            root.input.keyClick(Qt.Key_Tab);
            root.check(root.focusItem() !== null, "expanding lost the tab chain");
        });

        root.row("Return invokes the focused notification action", () => {
            action.forceActiveFocus(Qt.TabFocusReason);
            root.check(action.activeFocus, "the action did not take focus");
            root.input.keyClick(Qt.Key_Return);
            root.check(fakeService.invoked === 1, `invoked ${fakeService.invoked} time(s)`);
            root.check(fakeService.lastAction === "open", `last action is "${fakeService.lastAction}"`);
        });

        root.row("Space dismisses the focused notification", () => {
            close.forceActiveFocus(Qt.TabFocusReason);
            root.check(close.activeFocus, "close did not take focus");
            root.input.keyClick(Qt.Key_Space);
            root.check(record.closed, "Space left the notification open");
        });
    }
}
