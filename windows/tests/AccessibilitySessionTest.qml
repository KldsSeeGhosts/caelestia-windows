// Session drawer accessibility check (ERM-615).
//
// Runs the production session adapter in the staged shell with the test-only
// SessionManager that Test-AccessibilitySession.ps1 stages over the real
// singleton. Every action stays in memory, so nothing can reach a native
// session method. The model is drawn offscreen and driven with real key events:
//
//   a) Return on a focused button dispatches exactly one fake backend call, with
//      no confirmation step and no confirmation UI;
//   b) from the drawer's initial focus, Tab visits all four buttons in order and
//      Shift+Tab visits them in reverse, with focus inside the drawer after
//      every hop;
//   c) Escape still closes the session drawer after that walk;
//   d) the same walk runs with vim keybinds off and on, and with the session GIF
//      Loader inactive and active.
//
// A bar entry outside the drawer is in the default Qt tab chain, so on an
// adapter that only links the endpoints Tab leaves the menu for it exactly as it
// did on the desktop; that item is what makes row b fail without a full cycle.
import QtQuick
import QtTest
import Quickshell
import Caelestia.Config
import Caelestia.Services
import qs.components
import qs.modules.session
import qs.services

ShellRoot {
    id: root

    settings.watchFiles: false

    // The drawer's Config and Tokens resolve per screen. Set them before any
    // child evaluates a Config or Tokens binding, as the production window does.
    Config.screen: screenState.modelData?.name ?? ""
    Tokens.screen: screenState.modelData?.name ?? ""

    readonly property var buttonNames: ["Log out", "Shut down", "Hibernate", "Reboot"]
    readonly property var tabOrder: ["Shut down", "Hibernate", "Reboot", "Log out"]
    readonly property var backtabOrder: ["Reboot", "Hibernate", "Shut down", "Log out"]

    property var input: null
    property var outside: null
    property int checks: 0
    property var failures: []
    property int ticks: 0
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
        session: true
    }

    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 420
        implicitHeight: 720
        color: Colours.palette.m3background
        // The production drawer window binds this, so Config.session resolves
        // for the screen instead of falling back to the global config.
        contentItem.Config.screen: screenState.modelData?.name ?? ""

        Content {
            id: content

            screenState: screenState
        }
    }

    readonly property Component inputComponent: Component {
        TestCase { when: false }
    }

    // Stands in for the bar entries behind the drawer: the default Qt tab chain
    // leaves the session buttons for this item, which is how focus used to
    // escape the menu (ERM-615).
    readonly property Component outsideTabItem: Component {
        Item {
            activeFocusOnTab: true

            Accessible.role: Accessible.Button
            Accessible.name: "Bar entry"
        }
    }

    Timer {
        id: driver

        interval: 100
        repeat: true
        running: true
        onTriggered: root.advance()
    }

    function check(condition, message): void {
        root.checks++;
        if (!condition)
            root.failures.push(message);
    }

    function equal(actual, expected, message): void {
        root.checks++;
        if (actual !== expected)
            root.failures.push(`${message}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
    }

    function byName(item, name): var {
        for (const child of item?.children ?? []) {
            if (child?.accessibleName === name)
                return child;
            const found = root.byName(child, name);
            if (found)
                return found;
        }
        return null;
    }

    function ringOf(item): var {
        for (const child of item?.children ?? []) {
            if (child?.isFocusRing === true && child.showing)
                return child;
            const found = root.ringOf(child);
            if (found)
                return found;
        }
        return null;
    }

    function sessionButton(name): var {
        return root.byName(content, name);
    }

    // The drawer's focused button, or "" when focus is anywhere else.
    function focusedButtonName(): string {
        for (const name of root.buttonNames) {
            const button = root.sessionButton(name);
            if (button && button.activeFocus)
                return name;
        }
        return "";
    }

    function gifLoader(): var {
        for (const child of content.children ?? []) {
            if (child?.sourceComponent !== undefined && child?.active !== undefined)
                return child;
        }
        return null;
    }

    function focusOn(item): void {
        item.forceActiveFocus(Qt.TabFocusReason);
        root.input.wait(20);
    }

    function advance(): void {
        if (root.busy)
            return;
        root.busy = true;
        try {
            if (root.ticks++ < 5)
                return;
            root.input = root.inputComponent.createObject(win.contentItem);
            root.outside = root.outsideTabItem.createObject(win.contentItem);
            root.run();
            driver.stop();
            root.finish();
        } catch (error) {
            driver.stop();
            root.failures.push("exception: " + error.message);
            console.error("CAELESTIA_SESSION_KEYBOARD_FAIL " + JSON.stringify(root.failures));
            Qt.exit(1);
        } finally {
            root.busy = false;
        }
    }

    function finish(): void {
        if (root.failures.length > 0) {
            console.error("CAELESTIA_SESSION_KEYBOARD_FAIL " + JSON.stringify(root.failures));
            Qt.exit(1);
            return;
        }
        console.log(`CAELESTIA_SESSION_KEYBOARD_CHECKS ${root.checks}`);
        console.log("CAELESTIA_SESSION_KEYBOARD_PASS");
        Qt.quit();
    }

    // One full keyboard walk from the drawer's initial focus: Tab over every
    // button, Shift+Tab back, then Escape. Focus must stay inside the drawer
    // after every hop, not only at the endpoints.
    function walk(name, vim, gif): void {
        GlobalConfig.session.vimKeybinds = vim;
        GlobalConfig.paths.sessionGif = gif;
        root.input.wait(50);
        root.equal(Config.session.vimKeybinds, vim, `${name}: vim keybinds are not ${vim}`);
        root.equal(Config.paths.sessionGif.trim() !== "", gif !== "", `${name}: session GIF is not ${gif !== "" ? "set" : "empty"}`);
        const loader = root.gifLoader();
        root.check(loader !== null, `${name}: the session GIF Loader is missing`);
        if (loader)
            root.equal(loader.active, gif !== "", `${name}: the session GIF Loader active state is wrong`);

        const logout = root.sessionButton("Log out");
        screenState.session = true;
        root.focusOn(logout);
        root.equal(root.focusedButtonName(), "Log out", `${name}: the drawer did not start on Log out`);

        for (let index = 0; index < root.tabOrder.length; ++index) {
            root.input.keyClick(Qt.Key_Tab);
            root.input.wait(10);
            root.equal(root.focusedButtonName(), root.tabOrder[index],
                `${name}: Tab hop ${index + 1}`);
            root.check(root.focusedButtonName() !== "",
                `${name}: Tab hop ${index + 1} left the drawer`);
        }

        for (let index = 0; index < root.backtabOrder.length; ++index) {
            root.input.keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
            root.input.wait(10);
            root.equal(root.focusedButtonName(), root.backtabOrder[index],
                `${name}: Shift+Tab hop ${index + 1}`);
            root.check(root.focusedButtonName() !== "",
                `${name}: Shift+Tab hop ${index + 1} left the drawer`);
        }

        root.input.keyClick(Qt.Key_Escape);
        root.input.wait(10);
        root.equal(screenState.session, false, `${name}: Escape after the walk did not close the drawer`);
        screenState.session = true;
        root.input.wait(10);
    }

    function run(): void {
        const logout = root.sessionButton("Log out");
        const shutdown = root.sessionButton("Shut down");
        const hibernate = root.sessionButton("Hibernate");
        const reboot = root.sessionButton("Reboot");

        root.check(logout, "Log out button is missing");
        root.check(shutdown, "Shut down button is missing");
        root.check(hibernate, "Hibernate button is missing");
        root.check(reboot, "Reboot button is missing");
        if (!logout || !shutdown || !hibernate || !reboot)
            return;

        // Every session button draws the keyboard indicator and exposes one
        // accessible button whose name is its action.
        for (const name of root.buttonNames) {
            const button = root.sessionButton(name);
            root.check(button, `${name} button is missing`);
            if (!button)
                continue;
            root.equal(button.Accessible.role, Accessible.Button, `${name} accessible role`);
            root.equal(button.Accessible.name, name, `${name} accessible name`);
            root.focusOn(button);
            root.check(button.activeFocus, `${name} did not take focus`);
            root.check(root.ringOf(button) !== null, `${name} shows no focus ring`);
        }

        // (a) Return dispatches immediately: one fake backend call, the drawer
        // stays open, and no confirmation UI appears.
        for (const row of [
            {name: "Log out", action: "logout"},
            {name: "Shut down", action: "shutdown"},
            {name: "Hibernate", action: "hibernate"},
            {name: "Reboot", action: "reboot"}
        ]) {
            const button = root.sessionButton(row.name);
            root.focusOn(button);
            const before = SessionManager.execCount;
            root.input.keyClick(Qt.Key_Return);
            root.input.wait(10);
            root.equal(SessionManager.execCount, before + 1,
                `Return on ${row.name} did not dispatch exactly once`);
            root.equal(String(SessionManager.lastCommand[0]),
                String(Config.session.commands[row.action][0]),
                `${row.name} passed the wrong command`);
            root.check(screenState.session, `${row.name} closed the drawer`);
            root.check(root.byName(content, "Cancel") === null,
                `${row.name} opened a confirmation UI`);
            root.check(root.byName(content, "Confirm shutdown") === null,
                `${row.name} left a confirmation button in the drawer`);
        }

        // (b)-(d) The whole cycle, for both keybind modes and both GIF Loader
        // states. The Loader sits between Shut down and Hibernate in the drawer,
        // so its presence must not change traversal either.
        root.walk("vim off, gif off", false, "");
        root.walk("vim off, gif on", false, "root:/assets/dino.png");
        root.walk("vim on, gif off", true, "");
        root.walk("vim on, gif on", true, "root:/assets/dino.png");

        // The existing vim down/up chain is unchanged.
        GlobalConfig.session.vimKeybinds = true;
        root.input.wait(10);
        root.focusOn(logout);
        root.input.keyClick(Qt.Key_J, Qt.ControlModifier);
        root.input.wait(10);
        root.equal(root.focusedButtonName(), "Shut down", "vim Ctrl+J no longer moves to Shut down");

        GlobalConfig.session.vimKeybinds = false;
        GlobalConfig.paths.sessionGif = "";
    }
}
