// Windows Nexus smoke host.
//
// Staged into the production graph by windows/scripts/Test-Nexus.ps1, which
// runs it with an isolated profile. It covers the light part of the Nexus
// staging gate:
//
//   1. a settings write through GlobalConfig reaches the isolated
//      config/shell.json and reads back live (Nexus's persistence path);
//   2. modules/nexus/WindowFactory.qml opens a real detached window with the
//      upstream geometry, minimum size and title;
//   3. every page in PageRegistry loads through PageCompRegistry without a QML
//      diagnostic, and a window destroyed while its first page is still
//      incubating (including after two page replacements) emits nothing;
//   4. every Nexus window is closed before PASS, and the staged
//      caelestia:nexus global shortcut reaches the same window through the
//      backend hotkey manager.
//
// It does not type into the window, take screenshots, start a tiler or touch
// the live profile. Windows service facades stay disabled unless the caller
// passes Test-Nexus.ps1 -Observe, which sets only observation opt-ins.
import QtQuick
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
    property int pageIdx: 0
    property int originalDragThreshold: -1
    property var nexusWindow: null
    property var nexusItem: null
    property var pagesItem: null
    // Token owned by the page container of the early-close window. It must be
    // invalidated by the time the next step runs.
    property var earlyCloseToken: null
    // Steps 4..pageEnd-1 walk every registered page.
    readonly property int pageEnd: 4 + PageRegistry.pages.length
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
                root.nexusWindow = WindowFactory.create();
                root.check(root.nexusWindow !== null && root.nexusWindow !== undefined, "WindowFactory.create returned nothing");
            } else if (root.step === 3) {
                const win = root.nexusWindow;
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

                // Early-close regression: create a second Nexus window, replace
                // its page while the first incubation is still outstanding, and
                // destroy it in the same event-loop turn. The page container must
                // invalidate both incubations and dispose of their late results
                // without touching the destroyed window. Any diagnostic it emits
                // fails the run before PASS.
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
            } else if (root.step < root.pageEnd) {
                if (root.earlyCloseToken) {
                    root.check(root.earlyCloseToken.alive === false, "window destruction did not invalidate the page incubation");
                    root.earlyCloseToken = null;
                }
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
