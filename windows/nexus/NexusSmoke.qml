// Windows Nexus smoke host.
//
// Staged into the production graph by windows/scripts/Test-Nexus.ps1, which
// runs it with an isolated profile. It covers the light part of the Nexus
// staging gate:
//
//   1. a settings write through GlobalConfig reaches the isolated
//      config/shell.json and reads back live (Nexus's persistence path);
//   2. modules/nexus/WindowFactory.qml opens a real detached window with the
//      upstream geometry, minimum size and title, and a second request reuses
//      that window instead of creating another one, restoring it when it is
//      minimized without clearing a maximized state;
//   3. every page in PageRegistry loads through PageCompRegistry without a QML
//      diagnostic, and a window destroyed while its first page is still
//      incubating (including after two page replacements) emits nothing;
//   4. every Nexus window is closed before PASS, and the staged
//      caelestia:nexus global shortcut reaches the same window through the
//      backend hotkey manager.
//
// It types into the offscreen window but does not take screenshots, start a
// tiler or touch the live profile. Windows service facades stay disabled unless the caller
// passes Test-Nexus.ps1 -Observe, which sets only observation opt-ins.
import QtQuick
import QtTest
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Config
import Quickshell.Windows as Native
import qs.daemons
import qs.modules.nexus

ShellRoot {
    id: root

    settings.watchFiles: false

    // Same bundled process-local fonts the production entry loads. Without them
    // a real render pass builds QFont values for families that are not
    // installed and Qt logs "Unable to assign [undefined] to QFont".
    FontLoader {
        source: Quickshell.shellPath("assets/google-sans-flex/GoogleSansFlex-VariableFont_GRAD,ROND,opsz,slnt,wdth,wght.ttf")
    }
    FontLoader { source: Quickshell.shellPath("assets/material-symbols-rounded/MaterialSymbolsRounded.ttf") }
    FontLoader { source: Quickshell.shellPath("assets/rubik/Rubik.ttf") }

    readonly property string configPath: Quickshell.env("CAELESTIA_CONFIG_DIR") + "/shell.json"
    readonly property var screens: Quickshell.screens

    property int step: 0
    property int retries: 0
    property int waitRetries: 0
    property int pageIdx: 0
    property int originalDragThreshold: -1
    property var nexusWindow: null
    property var nexusItem: null
    property var pagesItem: null
    property var searchField: null
    property var searchResults: null
    property var inputDriver: null
    // Off-window copy of the Windows-only page, used for its whole-map write.
    property var windowManagementPage: null
    property var windowManagementState: null
    // Token owned by the page container of the early-close window. It must be
    // invalidated by the time the next step runs.
    property var earlyCloseToken: null
    // Steps 10..pageEnd-1 walk every registered page.
    readonly property int pageEnd: 10 + PageRegistry.pages.length
    property var shortcuts: null

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
    }

    function fail(message): void {
        console.error("CAELESTIA_NEXUS_SMOKE_FAIL " + message);
        Qt.exit(1);
    }

    function findPages(item): var {
        if (!item)
            return null;
        for (const child of item.children) {
            if (child && child.currentItem !== undefined && child.nState !== undefined)
                return child;
            const found = root.findPages(child);
            if (found)
                return found;
        }
        return null;
    }

    function findNamed(item, name): var {
        if (!item)
            return null;
        if (item.objectName === name)
            return item;
        for (const child of item.children) {
            const found = root.findNamed(child, name);
            if (found)
                return found;
        }
        return null;
    }

    readonly property Component inputDriverComponent: Component {
        TestCase { when: false }
    }

    function typeQuery(text): void {
        root.searchField.forceActiveFocus();
        root.check(root.searchField.activeFocus, "search field did not receive focus");
        for (const character of text)
            root.inputDriver.keyClick(character);
    }

    // A fresh blocking FileView per read, so the check sees the file the
    // settings writer just replaced rather than a cached snapshot.
    readonly property Component configReader: Component {
        FileView {
            blockLoading: true
            watchChanges: false
        }
    }

    // The staged shortcut daemon, instantiated so caelestia:nexus can be pressed
    // through the real handler. Without a keybinds.json entry the backend binds
    // no OS hotkey, so this registers nothing global.
    readonly property Component shortcutsComponent: Component {
        Shortcuts {}
    }

    function readConfig(): string {
        const view = root.configReader.createObject(root, {
            path: root.configPath
        });
        if (!view)
            return "";
        const text = view.text();
        view.destroy();
        return text;
    }

    Timer {
        id: driver

        interval: 120
        repeat: true
        running: true
        onTriggered: root.advance()
    }

    function advance(): void {
        try {
            if (root.step === 0) {
                root.check(root.screens.length > 0, "no screens reported");
                root.check(root.readConfig().length > 0, "isolated profile has no shell.json");
                root.originalDragThreshold = GlobalConfig.bar.dragThreshold;
                // Nexus writes GlobalConfig (the global layer), never the
                // per-monitor Config overlay, so the value must land in the
                // profile's config/shell.json.
                GlobalConfig.bar.dragThreshold = 37;
            } else if (root.step === 1) {
                root.check(GlobalConfig.bar.dragThreshold === 37, "write did not apply live");
                root.check(root.readConfig().includes("\"dragThreshold\": 37"), "write did not reach config/shell.json");
                GlobalConfig.bar.dragThreshold = root.originalDragThreshold;
                // SettingsFile writes immediately for the first change and then
                // debounces at 500 ms, so the second write lands later.
                root.step++;
                driver.interval = 900;
                return;
            } else if (root.step === 2) {
                root.check(GlobalConfig.bar.dragThreshold === root.originalDragThreshold, "restore did not apply");
                root.check(root.readConfig().includes("\"dragThreshold\": " + root.originalDragThreshold), "restore did not reach config/shell.json");

                // Early-close regression: replace the page of a fresh Nexus
                // window while the first incubation is still outstanding, and
                // destroy it in the same event-loop turn. The page container must
                // invalidate both incubations and dispose of their late results
                // without touching the destroyed window. Any diagnostic it emits
                // fails the run before PASS. This runs before the long-lived
                // window exists because a second WindowFactory request now
                // reuses the live window instead of creating another one.
                const early = WindowFactory.create();
                root.check(early !== null && early !== undefined, "early-close window was not created");
                const earlyNexus = early.contentItem.children.find(child => child && child.nState !== undefined && child.nState.isWindow === true) ?? null;
                root.check(earlyNexus !== null, "early-close nexus content item missing");
                const earlyPages = root.findPages(earlyNexus);
                root.check(earlyPages !== null, "early-close page container missing");
                earlyPages.loadPage(1);
                const replacedToken = earlyPages.pageTokens?.[0];
                root.check(replacedToken !== undefined, "page replacement did not leave an incubation token");
                earlyPages.loadPage(2);
                root.check(replacedToken.alive === false, "page replacement did not invalidate the previous incubation");
                root.earlyCloseToken = earlyPages.pageTokens?.[0];
                root.check(root.earlyCloseToken !== undefined, "early-close page did not leave an incubation token");
                early.destroy();
            } else if (root.step === 3) {
                root.check(root.earlyCloseToken !== null, "early-close token was not recorded");
                if (WindowFactory.windowCount !== 0 && root.waitRetries < 20) {
                    root.waitRetries++;
                    return;
                }
                root.check(WindowFactory.windowCount === 0, "early-close window was not destroyed");
                root.check(root.earlyCloseToken.alive === false, "window destruction did not invalidate the page incubation");
                root.earlyCloseToken = null;
                root.waitRetries = 0;

                root.nexusWindow = WindowFactory.create();
                root.check(root.nexusWindow !== null && root.nexusWindow !== undefined, "WindowFactory.create returned nothing");
                // A re-open must bring the live window forward, not add another.
                const reopened = WindowFactory.create();
                root.check(reopened === root.nexusWindow, "a second request created another Nexus window");
                root.check(WindowFactory.windowCount === 1, "a second request changed the Nexus window count");
                // Minimized windows still report visible, so the reuse path must
                // restore them itself. Maximize first to prove the restore does
                // not clear that state.
                root.nexusWindow.maximized = true;
                root.nexusWindow.minimized = true;
            } else if (root.step === 4) {
                const win = root.nexusWindow;
                root.check(win.minimized === true, "minimize did not apply");
                const restored = WindowFactory.create();
                root.check(restored === win, "a second request created another Nexus window while minimized");
                root.check(WindowFactory.windowCount === 1, "reopening a minimized window changed the count");
                root.check(win.minimized === false, "a second request did not restore the minimized Nexus window");
                root.check(win.maximized === true, "restoring a minimized window cleared maximized");
                win.maximized = false;
                root.check(win.width > 0 && win.height > 0, "nexus window has no geometry");
                root.check(win.minimumSize.width > 0 && win.minimumSize.height > 0, "nexus window has no minimum size");
                root.check(String(win.title).startsWith("Nexus"), "nexus window title: " + win.title);
                root.check(win.contentItem.Config.screen === win.screen.name, "nexus window is not bound to its screen");
                root.nexusItem = win.contentItem.children.find(child => child && child.nState !== undefined && child.nState.isWindow === true) ?? null;
                root.check(root.nexusItem !== null, "nexus content item missing");
                root.pagesItem = root.findPages(root.nexusItem);
                root.check(root.pagesItem !== null, "nexus page container missing");
                // The first page is incubated asynchronously; give it a bounded
                // number of ticks instead of asserting on the frame it was
                // requested.
                if (root.pagesItem.currentItem === null && root.retries < 20) {
                    root.retries++;
                    driver.interval = 120;
                    return;
                }
                root.check(root.pagesItem.currentItem !== null, "default nexus page did not load");

                // The Windows-only page writes GlobalConfig.windows as one map.
                // Instantiate it inside the window so its controls have a scene,
                // then prove that path persists and keeps the seeded keys.
                const pageComp = Qt.createComponent("modules/nexus/pages/WindowManagementPage.qml");
                root.check(pageComp.status === Component.Ready, "window management page failed to compile: " + pageComp.errorString());
                root.windowManagementState = Qt.createQmlObject("import qs.modules.nexus; NexusState {}", root, "windowManagementState");
                root.windowManagementPage = pageComp.createObject(root.nexusWindow.contentItem, { nState: root.windowManagementState });
                root.check(root.windowManagementPage !== null, "window management page did not instantiate");
                root.windowManagementPage.setWindowsOption("tiling", "gapsIn", 17);
                root.windowManagementPage.setWindowsOption("focusFollowsMouse", "delay", 150);
                root.check(GlobalConfig.windows?.tiling?.gapsIn === 17, "windows write did not apply live");
                root.check(GlobalConfig.windows?.focusFollowsMouse?.delay === 150, "windows wrote no new group");
                root.step++;
                driver.interval = 900;
                return;
            } else if (root.step === 5) {
                const config = JSON.parse(root.readConfig());
                root.check(config.windows?.tiling?.gapsIn === 17, "windows write did not reach config/shell.json");
                root.check(config.windows?.focusFollowsMouse?.delay === 150, "windows group write did not reach config/shell.json");
                root.check(config.windows?.tiling?.gapsOut === 14, "windows write dropped tiling.gapsOut");
                root.check(Array.isArray(config.windows?.tiling?.include)
                    && config.windows.tiling.include.length === 1
                    && config.windows.tiling.include[0] === "exe:notepad.exe", "windows write dropped tiling.include");
                root.windowManagementPage.destroy();
                root.windowManagementPage = null;
                root.windowManagementState.destroy();
                root.windowManagementState = null;
                root.searchField = root.findNamed(root.nexusItem, "nexusSearch");
                root.searchResults = root.findNamed(root.nexusItem, "nexusSearchResults");
                root.check(root.searchField !== null && root.searchResults !== null, "search controls missing");
                root.inputDriver = root.inputDriverComponent.createObject(root.nexusWindow.contentItem);
                root.check(root.inputDriver !== null, "input driver missing");
                root.typeQuery("focus");
                root.check(root.searchField.text === "focus", "typing did not update the search field");
                root.check(root.searchResults.results.length === 1
                    && root.searchResults.results[0].label === "Window management", "page keyword filtering failed");
                root.inputDriver.keyClick(Qt.Key_Return);
                root.check(root.nexusItem.nState.currentPageIdx === root.searchResults.results[0].pageIndex, "Enter did not navigate to page");
                root.searchField.clear();
                root.check(root.searchResults.results.length === PageRegistry.pages.length, "clearing search did not restore pages");
                root.typeQuery("clock");
                root.check(root.searchResults.results.length === 1
                    && root.searchResults.results[0].label === "Clock", "sub-page title filtering failed");
                root.inputDriver.keyClick(Qt.Key_Return);
                root.check(root.nexusItem.nState.subPageIdxStack.join(",") === "2,10", "Enter did not select nested sub-page");
                root.step++;
                driver.interval = 900;
                return;
            } else if (root.step === 6) {
                root.check(root.pagesItem.currentItem !== null && root.pagesItem.currentItem.depth === 3,
                    "nested sub-page did not load");
                root.check(root.pagesItem.currentItem.currentItem.title === "Clock", "wrong nested sub-page loaded");
                root.searchField.clear();
                root.typeQuery("tray");
                root.check(root.searchResults.results.length === 1
                    && root.searchResults.results[0].label === "Tray", "second sub-page filtering failed");
                root.inputDriver.keyClick(Qt.Key_Return);
                root.check(root.nexusItem.nState.subPageIdxStack.join(",") === "2,8",
                    "same-page search did not replace sub-page path");
                root.step++;
                driver.interval = 900;
                return;
            } else if (root.step === 7) {
                root.check(root.pagesItem.currentItem.depth === 3, "same-page nested result did not load");
                root.check(root.pagesItem.currentItem.currentItem.title === "Tray", "wrong same-page result loaded");
                root.searchField.clear();
                root.typeQuery("zzzznotfound");
                root.check(root.searchResults.results.length === 0, "unmatched query returned results");
                const previousPage = root.nexusItem.nState.currentPageIdx;
                root.inputDriver.keyClick(Qt.Key_Return);
                root.check(root.nexusItem.nState.currentPageIdx === previousPage, "empty results changed page");
                root.searchField.clear();
                root.check(root.searchResults.results.length === PageRegistry.pages.length, "empty query did not restore pages");
                root.inputDriver.destroy();
                root.inputDriver = null;
                console.log("CAELESTIA_NEXUS_SEARCH_PASS");
            } else if (root.step === 8 || root.step === 9) {
                // Allow any page transition and destroyed sub-pages to settle.
            } else if (root.step < root.pageEnd) {
                const index = root.pageIdx;
                root.nexusItem.nState.currentPageIdx = index;
                root.pageIdx = index + 1;
                // One tick later the switch animation has run its ScriptAction
                // and the new page component exists.
                root.step++;
                driver.interval = 700;
                return;
            } else if (root.step === root.pageEnd) {
                root.check(root.pageIdx === PageRegistry.pages.length, "not every page was visited");
                root.check(root.pagesItem.currentItem !== null, "last nexus page did not load");
                // Public sub-page helpers: open pushes, close pops, and a page
                // change resets the stack.
                const ns = root.nexusItem.nState;
                ns.openSubPage(0);
                root.check(ns.subPageIdxStack.length === 1, "openSubPage did not push onto the sub-page stack");
                ns.closeSubPage();
                root.check(ns.subPageIdxStack.length === 0, "closeSubPage did not pop the sub-page stack");
                ns.openSubPage(0);
                ns.currentPageIdx = 0;
                root.check(ns.subPageIdxStack.length === 0, "page change did not reset the sub-page stack");
                root.nexusWindow.visible = false; // destroys the window (WindowFactory)
                // The utilities card is the second entry point. It has no
                // offscreen-safe host (it needs a real popout wrapper), so this
                // checks that the staged card compiles with the upstream
                // WindowFactory call instead of instantiating it.
                const toggles = Qt.createComponent(Qt.resolvedUrl("modules/utilities/cards/Toggles.qml"));
                root.check(toggles.status === Component.Ready, "utilities Toggles.qml failed to compile: " + toggles.errorString());
                root.shortcuts = root.shortcutsComponent.createObject(root);
                root.check(root.shortcuts !== null, "daemons/Shortcuts.qml did not instantiate");
            } else if (root.step === root.pageEnd + 1) {
                // First entry point: the staged caelestia:nexus global shortcut.
                // Triggering through the backend's hotkey manager is the same
                // path a keybinds.json entry takes; the staged handler logs
                // CAELESTIA_SHORTCUT name=nexus after creating the window, and
                // the test script asserts that marker. The window completes on
                // the next event-loop turns, so let it settle before quitting
                // instead of tearing it down mid-construction.
                root.check(root.shortcuts !== null, "daemons/Shortcuts.qml did not instantiate");
                Native.Hotkeys.trigger("caelestia:nexus");
                root.step++;
                driver.interval = 1500;
                return;
            } else if (root.step === root.pageEnd + 2) {
                // Close every window before the PASS marker so a late
                // incubation or shutdown diagnostic is still part of the run
                // the test evaluates. This also removes the token-singleton race
                // that used to print QFont warnings after the window outlived
                // the quit request.
                WindowFactory.closeAll();
                root.step++;
                driver.interval = 1200;
                return;
            } else {
                root.check(WindowFactory.windowCount === 0, "Nexus windows are still open before PASS");
                root.nexusWindow = null;
                root.nexusItem = null;
                root.pagesItem = null;
                driver.stop();
                console.log("CAELESTIA_NEXUS_SMOKE_PAGES " + PageRegistry.pages.length);
                console.log("CAELESTIA_NEXUS_SMOKE_PASS");
                Qt.quit();
                return;
            }
            root.step++;
            driver.interval = 120;
        } catch (error) {
            driver.stop();
            root.fail(error.message);
        }
    }
}
