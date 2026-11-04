// Session drawer accessibility check (ERM-615).
//
// Runs the production session adapter in the staged shell with the test-only
// SessionManager that Test-AccessibilitySession.ps1 stages over the real
// singleton. Every action stays in memory, so nothing can reach a native
// session method. The model is drawn offscreen and driven with real key events:
//
//   a) Return on a focused button dispatches exactly one fake backend call, with
//      no confirmation step and no confirmation UI;
//   b) Tab from the last button wraps to the first, and Shift+Tab from the first
//      wraps back to the last;
//   c) Escape still closes the session drawer after that wrap;
//   d) the same wrap works with vim keybinds on.
//
// A bar entry outside the drawer is in the default Qt tab chain, so on the
// unfixed adapter Tab leaves the menu for it exactly as it did on the desktop;
// that item is what makes rows b and c fail without the wrap.
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
        for (const name of ["Log out", "Shut down", "Hibernate", "Reboot"]) {
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

        // (b) Tab wraps forward from the last button, Shift+Tab wraps back from
        // the first. Vim keybinds are off for this row, so this is the plain
        // KeyNavigation path.
        GlobalConfig.session.vimKeybinds = false;
        root.input.wait(10);
        root.equal(Config.session.vimKeybinds, false, "vim keybinds did not turn off");

        root.focusOn(reboot);
        root.check(reboot.activeFocus, "Reboot is not focused before Tab");
        root.input.keyClick(Qt.Key_Tab);
        root.input.wait(10);
        root.check(logout.activeFocus, "Tab from Reboot did not wrap to Log out");
        root.check(root.outside === null || !root.outside.activeFocus,
            "Tab from Reboot escaped the drawer");

        root.focusOn(logout);
        root.check(logout.activeFocus, "Log out is not focused before Shift+Tab");
        root.input.keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
        root.input.wait(10);
        root.check(reboot.activeFocus, "Shift+Tab from Log out did not wrap to Reboot");
        root.check(root.outside === null || !root.outside.activeFocus,
            "Shift+Tab from Log out escaped the drawer");

        // (c) Escape still closes the drawer after wrapping with Tab: focus is
        // inside the menu, so the button's Escape handler runs.
        screenState.session = true;
        root.focusOn(reboot);
        root.input.keyClick(Qt.Key_Tab);
        root.input.wait(10);
        root.check(logout.activeFocus, "Tab did not wrap before the Escape check");
        root.input.keyClick(Qt.Key_Escape);
        root.input.wait(10);
        root.equal(screenState.session, false, "Escape after the wrap did not close the drawer");
        screenState.session = true;
        root.input.wait(10);

        // (d) The vim Tab path wraps too: its down/up chain ends at the last and
        // first buttons, so it falls back to tab/backtab.
        GlobalConfig.session.vimKeybinds = true;
        root.input.wait(10);
        root.equal(Config.session.vimKeybinds, true, "vim keybinds did not turn on");

        root.focusOn(reboot);
        root.input.keyClick(Qt.Key_Tab);
        root.input.wait(10);
        root.check(logout.activeFocus, "vim Tab from Reboot did not wrap to Log out");
        root.check(root.outside === null || !root.outside.activeFocus,
            "vim Tab from Reboot escaped the drawer");

        root.focusOn(logout);
        root.input.keyClick(Qt.Key_Backtab, Qt.ShiftModifier);
        root.input.wait(10);
        root.check(reboot.activeFocus, "vim Shift+Tab from Log out did not wrap to Reboot");

        // The existing vim down/up chain is unchanged.
        root.focusOn(logout);
        root.input.keyClick(Qt.Key_J, Qt.ControlModifier);
        root.input.wait(10);
        root.check(shutdown.activeFocus, "vim Ctrl+J no longer moves to Shut down");

        GlobalConfig.session.vimKeybinds = false;
    }
}

