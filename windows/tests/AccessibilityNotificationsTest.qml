// Notification popup action accessibility check (ERM-615).
//
// Runs the staged production notification card with a fixture NotifData whose
// action is recorded in memory; no native notification, clipboard or session
// path is touched. Every audit row is independent, so the before-fix run shows
// every missing name, role and keyboard binding rather than stopping at the
// first. The card is also collapsed and expanded again: a collapsed card hides
// its action row with opacity only, so the hidden controls must leave the tab
// chain and must not keep active focus.
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

    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 460
        implicitHeight: 360
        color: Colours.palette.m3background
        contentItem.Config.screen: Quickshell.screens[0]?.name ?? ""

        Notification {
            id: view

            modelData: record
            expanded: true
            implicitWidth: 420
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
        const buttons = [];
        root.collectButtons(win.contentItem, buttons);
        const close = buttons.find(button => button.icon === "close") ?? null;
        const copy = buttons.find(button => button.icon === "content_copy") ?? null;
        const action = buttons.find(button => button.text === "Open") ?? null;
        const expandIcon = root.byIconText(win.contentItem, "expand_more");
        const expand = expandIcon?.parent ?? null;

        root.check(close, "notification close button is missing");
        root.check(copy, "notification copy button is missing");
        root.check(action, "notification action button is missing");
        root.check(expand, "notification expand control is missing");

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
