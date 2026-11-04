// Notification popup action accessibility check (ERM-615).
//
// Runs the staged production notification card with a fixture NotifData whose
// action is recorded in memory; no native notification, clipboard or session
// path is touched. Every audit row is independent, so the before-fix run shows
// every missing name, role and keyboard binding rather than stopping at the
// first.
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
