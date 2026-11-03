// Nexus keyboard focus check (#210).
//
// Staged into the production graph by windows/scripts/Test-Nexus.ps1 -Suite
// Keyboard, with the same isolated profile and disabled service facades as the
// smoke. It covers:
//
//   1. RowButton: Tab focus, the state-layer focus indicator, exactly one
//      activation per Return, keypad Enter and Space, pointer activation, and
//      disabled, faded and hidden rows leaving the tab chain;
//   2. every Nexus page and every sub-page: Tab walks a closed cycle that never
//      stalls or lands on a hidden or disabled item, reaches every visible,
//      enabled row, and scrolls the focused row into view.
//
// It types into the offscreen window only. It never activates a real page row
// (several open ms-settings: links), takes no screenshots and does not touch
// the live profile.
import QtQuick
import QtQuick.Layouts
import QtTest
import Quickshell
import Caelestia.Config
import qs.modules.nexus
import qs.modules.nexus.common

ShellRoot {
    id: root

    settings.watchFiles: false

    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    property var win: null
    property var nexusItem: null
    property var pagesItem: null
    property var input: null
    property var fixture: null
    property var queue: []
    property int waits: 0
    property int pagesWalked: 0
    property int rowsReached: 0

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
    }

    function describe(item): string {
        if (!item)
            return "null";
        const text = item.text ?? item.label ?? item.title ?? item.icon ?? "";
        return String(item).split("(")[0] + (text ? ` "${text}"` : "");
    }

    function findPages(item): var {
        for (const child of item?.children ?? []) {
            if (child && child.currentItem !== undefined && child.nState !== undefined)
                return child;
            const found = root.findPages(child);
            if (found)
                return found;
        }
        return null;
    }

    // The Quickshell window wrapper does not expose the QQuickWindow's focus.
    function focusItem(): var {
        return root.win.contentItem.Window.activeFocusItem;
    }

    function isRow(item): bool {
        return !!item && typeof item.activate === "function" && item.trailingIcon !== undefined
            && item.subLabel !== undefined;
    }

    function stateLayerOf(row): var {
        return row.children.find(child => child && typeof child.press === "function"
            && child.stateOpacity !== undefined) ?? null;
    }

    // Visible on screen: every ancestor up to the window is visible and not
    // faded out, and the item is enabled.
    function shown(item): bool {
        if (!item || !item.visible || !item.enabled)
            return false;
        for (let p = item; p && p !== root.win.contentItem; p = p.parent) {
            if (!p.visible || p.opacity <= 0.01)
                return false;
        }
        return true;
    }

    function collectRows(item, out): void {
        for (const child of item?.children ?? []) {
            if (root.isRow(child))
                out.push(child);
            root.collectRows(child, out);
        }
        // Flickable/StackView content lives under contentItem, which is a child.
    }

    // Current top content of a page: a StackPage shows only its top item.
    function topOf(page): var {
        return page && page.pages !== undefined && page.depth !== undefined ? page.currentItem : page;
    }

    function flickableOf(item): var {
        for (let p = item?.parent; p; p = p.parent) {
            if (p.contentY !== undefined && p.contentItem !== undefined && p.flickableDirection !== undefined)
                return p;
        }
        return null;
    }

    function walk(label): void {
        const page = root.topOf(root.pagesItem.currentItem);
        root.check(page !== null, `${label}: no page content`);
        root.win.contentItem.forceActiveFocus();
        const seen = [];
        let previous = root.focusItem();
        for (let i = 0; i < 400; i++) {
            root.input.keyClick(Qt.Key_Tab);
            const item = root.focusItem();
            root.check(item !== null, `${label}: Tab cleared focus after ${root.describe(previous)}`);
            root.check(root.shown(item), `${label}: Tab landed on hidden or disabled ${root.describe(item)}`);
            if (item === seen[0])
                break; // closed cycle (a single stop cycles onto itself)
            root.check(item !== previous, `${label}: Tab trapped on ${root.describe(item)}`);
            seen.push(item);
            previous = item;
        }
        root.check(root.focusItem() === seen[0], `${label}: Tab did not return to the start`);

        const rows = [];
        root.collectRows(page, rows);
        const reachable = rows.filter(row => root.shown(row) && !row.disabled && row.opacity > 0);
        for (const row of reachable)
            root.check(seen.includes(row), `${label}: Tab skipped ${root.describe(row)}`);
        for (const row of rows.filter(row => !reachable.includes(row)))
            root.check(!seen.includes(row), `${label}: Tab reached unavailable ${root.describe(row)}`);

        // Shift+Tab walks the same cycle in reverse.
        seen[0].forceActiveFocus(Qt.TabFocusReason);
        root.input.keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        root.check(root.focusItem() === seen[seen.length - 1], `${label}: Shift+Tab did not reverse the cycle`);

        console.log(`CAELESTIA_NEXUS_KEYBOARD_WALK ${label}: ${seen.length} stops, ${reachable.length} rows`);
        root.rowsReached += reachable.length;
        root.pagesWalked++;
        root.lastRow = reachable[reachable.length - 1] ?? null;
        if (root.lastRow)
            root.lastRow.forceActiveFocus(Qt.TabFocusReason);
    }

    property var lastRow: null

    // The last row of the page was focused at the end of walk(); after the
    // reveal animation it must lie inside its flickable's viewport.
    function checkRevealed(label): void {
        const row = root.lastRow;
        root.lastRow = null;
        if (!row)
            return;
        const flick = root.flickableOf(row);
        if (!flick)
            return;
        const pos = row.mapToItem(flick, 0, 0);
        root.check(pos.y >= -1 && pos.y + row.height <= flick.height + 1,
            `${label}: focused ${root.describe(row)} is outside the viewport (y ${Math.round(pos.y)}, view ${Math.round(flick.height)}, contentY ${Math.round(flick.contentY)})`);
    }

    readonly property Component inputComponent: Component {
        TestCase { when: false }
    }

    readonly property Component fixtureComponent: Component {
        ColumnLayout {
            z: 100
            width: 360

            property int clicks
            property int disabledClicks
            readonly property alias first: first
            readonly property alias disabledRow: disabledRow
            readonly property alias fadedRow: fadedRow
            readonly property alias hiddenRow: hiddenRow
            readonly property alias last: last

            RowButton { id: first; first: true; text: "First"; onClicked: parent.clicks++ }
            RowButton { id: disabledRow; text: "Disabled"; disabled: true; onClicked: parent.disabledClicks++ }
            RowButton { id: fadedRow; text: "Faded"; opacity: 0; onClicked: parent.disabledClicks++ }
            RowButton { id: hiddenRow; text: "Hidden"; visible: false; onClicked: parent.disabledClicks++ }
            NavRow { id: last; last: true; text: "Last"; onClicked: parent.clicks += 10 }
        }
    }

    // Let the event loop run until condition holds, at most two seconds.
    function settle(condition): void {
        for (let i = 0; i < 40 && !condition(); i++)
            root.input.wait(50);
    }

    function rowChecks(): void {
        const f = root.fixture;
        const layer = root.stateLayerOf(f.first);
        root.check(layer !== null, "RowButton has no state layer");
        f.first.forceActiveFocus(Qt.TabFocusReason);
        root.check(f.first.activeFocus, "RowButton did not take focus");
        root.check(f.first.activeFocusOnTab, "RowButton is not in the tab chain");
        root.settle(() => Math.abs(layer.stateOpacity - 0.1) < 0.001); // opacity Behavior
        root.check(Math.abs(layer.stateOpacity - 0.1) < 0.001, `focus indicator opacity ${layer.stateOpacity}`);
        for (const key of [Qt.Key_Return, Qt.Key_Enter, Qt.Key_Space])
            root.input.keyClick(key);
        root.check(f.clicks === 3, `Return, Enter and Space gave ${f.clicks} activations`);
        root.check(f.first.activeFocus, "activation dropped focus");

        root.input.keyClick(Qt.Key_Tab);
        root.check(f.last.activeFocus, `Tab from the first row went to ${root.describe(root.focusItem())}`);
        // Back to the pointer's own state (the offscreen cursor may hover).
        const resting = layer.containsMouse ? 0.08 : 0;
        root.settle(() => Math.abs(layer.stateOpacity - resting) < 0.001);
        root.check(Math.abs(layer.stateOpacity - resting) < 0.001, "focus indicator stayed after focus left");
        root.input.keyClick(Qt.Key_Space);
        root.check(f.clicks === 13, "NavRow did not activate on Space");
        root.input.keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        root.check(f.first.activeFocus, "Shift+Tab did not return to the first row");

        for (const row of [f.disabledRow, f.fadedRow, f.hiddenRow])
            root.check(!row.activeFocusOnTab || !row.visible, `${row.text} row is in the tab chain`);
        f.disabledRow.forceActiveFocus();
        root.input.keyClick(Qt.Key_Return);
        root.check(f.disabledClicks === 0, "a disabled row activated from the keyboard");

        root.win.contentItem.forceActiveFocus();
        root.input.mouseClick(f.first);
        root.check(f.clicks === 14, "pointer activation changed");
        root.check(!f.first.activeFocus, "pointer click took keyboard focus");
    }

    // Each entry: [label, action, ready?]. ready is polled until true.
    function buildQueue(): void {
        const q = [];
        q.push(["row fixture", () => {
            root.fixture = root.fixtureComponent.createObject(root.win.contentItem);
            root.rowChecks();
            root.fixture.destroy();
            root.fixture = null;
        }, null]);
        for (let i = 0; i < PageRegistry.pages.length; i++) {
            const index = i;
            const name = PageRegistry.pages[i]?.label ?? `page ${i}`;
            q.push([name + " load", () => {
                root.nexusItem.nState.currentPageIdx = index;
            }, () => root.pagesItem.currentItem !== null && root.nexusItem.nState.activePage === root.pagesItem.currentItem
                && !root.nexusItem.nState.animatingContainer]);
            q.push([name, () => root.walk(name), null]);
            q.push([name + " reveal", () => root.checkRevealed(name), null]);
            q.push([name + " sub-pages", () => {
                const page = root.pagesItem.currentItem;
                const count = page.pages?.length ?? 0;
                // Sub-pages are queued now that the page (and its count) exists.
                const extra = [];
                for (let k = 1; k < count; k++) {
                    const sub = k;
                    // App details needs nState.selectedApp, and app enumeration
                    // stays off in this isolated run.
                    if (name === "Apps" && sub === 2)
                        continue;
                    const subName = `${name} / ${sub}`;
                    extra.push([subName + " open", () => root.nexusItem.nState.openSubPage(sub),
                        () => !page.busy && page.depth === 2]);
                    extra.push([subName, () => root.walk(subName), null]);
                    extra.push([subName + " reveal", () => root.checkRevealed(subName), null]);
                    extra.push([subName + " close", () => root.nexusItem.nState.closeSubPage(),
                        () => !page.busy && page.depth === 1]);
                }
                root.queue = extra.concat(root.queue);
            }, null]);
        }
        root.queue = q;
    }

    Timer {
        id: driver

        interval: 150
        repeat: true
        running: true
        onTriggered: root.advance()
    }

    property int step: 0
    property var current: null

    function advance(): void {
        try {
            if (root.step === 0) {
                root.win = WindowFactory.create();
                root.check(!!root.win, "WindowFactory.create returned nothing");
                root.step = 1;
                return;
            }
            if (root.step === 1) {
                root.nexusItem = root.win.contentItem.children.find(child => child && child.nState?.isWindow === true) ?? null;
                root.pagesItem = root.findPages(root.nexusItem);
                if ((!root.pagesItem || !root.pagesItem.currentItem) && root.waits++ < 40)
                    return;
                root.check(root.pagesItem?.currentItem, "first Nexus page did not load");
                root.input = root.inputComponent.createObject(root.win.contentItem);
                root.buildQueue();
                root.waits = 0;
                root.step = 2;
                return;
            }
            if (root.step === 2) {
                if (root.current) {
                    const ready = root.current[2];
                    if (ready && !ready()) {
                        root.check(root.waits++ < 60, `${root.current[0]}: timed out`);
                        return;
                    }
                    root.current = null;
                    root.waits = 0;
                    return; // one settle tick after ready
                }
                if (root.queue.length === 0) {
                    root.input.destroy();
                    root.input = null;
                    WindowFactory.closeAll();
                    root.step = 3;
                    driver.interval = 1200;
                    return;
                }
                const next = root.queue.shift();
                next[1]();
                // A reveal check runs after the walk's reveal animation.
                if (root.queue[0]?.[0].endsWith(" reveal"))
                    driver.interval = 700;
                else
                    driver.interval = 150;
                if (next[2])
                    root.current = next;
                return;
            }
            root.check(WindowFactory.windowCount === 0, "Nexus windows are still open before PASS");
            driver.stop();
            console.log(`CAELESTIA_NEXUS_KEYBOARD_PAGES ${root.pagesWalked} rows=${root.rowsReached}`);
            console.log("CAELESTIA_NEXUS_KEYBOARD_PASS");
            Qt.quit();
        } catch (error) {
            driver.stop();
            console.error("CAELESTIA_NEXUS_KEYBOARD_FAIL " + error.message);
            Qt.exit(1);
        }
    }
}
