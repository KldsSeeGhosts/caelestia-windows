// Launcher accessibility check (regression).
//
// Runs the staged production launcher with the real Actions service in an
// offscreen window and drives it with key events only. It records one row per
// audit claim: Escape dismisses, the search field holds keyboard focus, the
// selection moves with Up/Down, Return activates the selected action, and the
// result rows and search field expose the roles and names a screen reader
// reads instead of their painted text. A missing name or role fails only its
// row, so the before-fix run shows every gap the audit found.
import QtQuick
import QtTest
import Quickshell
import Caelestia.Config
import qs.components
import qs.services
import qs.modules.launcher

ShellRoot {
    id: root

    settings.watchFiles: false

    Config.screen: screenState.modelData?.name ?? ""
    Tokens.screen: screenState.modelData?.name ?? ""

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

    ScreenState {
        id: screenState

        modelData: Quickshell.screens[0] ?? null
        session: false
    }

    Item {
        id: dummyPanels

        implicitHeight: 800

        property var dashboard: Item {}
    }

    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 630
        implicitHeight: 620
        color: Colours.palette.m3background
        contentItem.Config.screen: screenState.modelData?.name ?? ""

        Content {
            id: content

            screenState: screenState
            panels: dummyPanels
            maxHeight: 600
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

    function byObjectName(item, name): var {
        for (const child of item?.children ?? []) {
            if (child?.objectName === name)
                return child;
            const found = root.byObjectName(child, name);
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
        screenState.launcher = true;
        root.input.wait(120);
        root.input.wait(120);

        const search = root.byObjectName(win.contentItem, "launcherSearch");
        const list = root.byObjectName(win.contentItem, "combinedLauncherAppList");
        root.check(search, "launcher search field is missing");
        root.check(list, "launcher result list is missing");

        root.row("launcher search holds keyboard focus on open", () => {
            root.check(search.activeFocus, "the search field did not take active focus");
        });

        root.row("launcher search exposes a stable accessible name", () => {
            root.check(search.Accessible.name === "Search applications and actions",
                `Accessible.name is "${search.Accessible.name}"`);
        });

        // The action list is the launcher result path that needs no Windows app
        // catalog, so the real Actions service is exercised unchanged.
        search.text = "> ";
        root.input.wait(200);
        root.input.wait(200);

        root.row("launcher result list shows the action provider", () => {
            root.check(list.count > 0, "the action list is empty");
            root.check(list.currentItem, "the action list has no current item");
            root.check(list.currentIndex === 0, `current index is ${list.currentIndex}`);
        });

        root.row("launcher action row exposes role and name", () => {
            const item = list.currentItem;
            root.check(item, "no current action row");
            root.check(item.Accessible.role === Accessible.ListItem,
                `Accessible.role is ${item.Accessible.role}`);
            root.check(item.Accessible.name === "Calculator, Arithmetic and functions",
                `Accessible.name is "${item.Accessible.name}"`);
            root.check(item.Accessible.selectable, "current action row is not selectable");
            root.check(item.Accessible.selected, "current action row lacks selected state");
        });

        root.row("every instantiated launcher result has a name", () => {
            let seen = 0;
            for (let i = 0; i < list.count; i++) {
                const item = list.itemAtIndex(i);
                if (!item)
                    continue;
                seen++;
                root.check(item.Accessible.role === Accessible.ListItem,
                    `row ${i} Accessible.role is ${item.Accessible.role}`);
                root.check(item.Accessible.name.length > 0, `row ${i} has no Accessible.name`);
                root.check(item.Accessible.selected === (i === list.currentIndex),
                    `row ${i} selected state differs from the current index`);
            }
            root.check(seen > 0, "no action delegates were instantiated");
        });

        root.row("Up and Down move the launcher selection without dropping focus", () => {
            const first = list.currentItem;
            root.input.keyClick(Qt.Key_Down);
            root.check(list.currentIndex === 1, `Down left index ${list.currentIndex}`);
            root.check(!first.Accessible.selected, "Down left the previous row selected");
            root.check(list.currentItem.Accessible.selected, "Down did not expose the new selected row");
            root.input.keyClick(Qt.Key_Up);
            root.check(list.currentIndex === 0, `Up left index ${list.currentIndex}`);
            root.check(first.Accessible.selected, "Up did not restore the first row selected state");
            root.check(search.activeFocus, "the search field lost focus during navigation");
        });

        root.row("Return activates the selected launcher result", () => {
            root.input.keyClick(Qt.Key_Return);
            root.check(search.text === ">calc ", `Return left the search text "${search.text}"`);
        });

        root.row("Escape dismisses the launcher", () => {
            root.input.keyClick(Qt.Key_Escape);
            root.check(!screenState.launcher, "Escape left the launcher open");
        });
    }
}
