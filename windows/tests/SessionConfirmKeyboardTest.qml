// Session confirmation keyboard check.
//
// Runs the production session adapter in the staged shell with the test-only
// SessionManager that Test-SessionConfirmKeyboard.ps1 stages over the real
// singleton. Every action stays in memory, so nothing can reach a native
// session method. The model is drawn offscreen and driven with real key events:
// Shut down opens the confirmation, Cancel takes focus, arrows stay inside the
// two buttons, Return/Enter/Space activate, Escape cancels, and every exit
// returns focus to the SessionButton that started the confirmation. A launcher
// opened over an open confirmation must hand focus back to Cancel when it
// closes, not leave the confirmation unreachable.
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
    property int checks: 0
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

    // Stands in for the launcher window taking active focus away from the
    // drawer without closing the confirmation.
    readonly property Component focusTaker: Component {
        Item { focus: true }
    }

    Timer {
        id: driver

        interval: 100
        repeat: true
        running: true
        onTriggered: root.advance()
    }

    function check(condition, message): void {
        if (!condition)
            throw new Error(message);
        root.checks++;
    }

    function equal(actual, expected, message): void {
        if (actual !== expected)
            throw new Error(`${message}: expected ${expected}, got ${actual}`);
        root.checks++;
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
            console.log(`CAELESTIA_SESSION_KEYBOARD_CHECKS ${root.checks}`);
            console.log("CAELESTIA_SESSION_KEYBOARD_PASS");
            Qt.quit();
        } catch (error) {
            driver.stop();
            console.error("CAELESTIA_SESSION_KEYBOARD_FAIL " + error.message);
            Qt.exit(1);
        } finally {
            root.busy = false;
        }
    }

    function run(): void {
        const logout = root.sessionButton("Log out");
        const shutdown = root.sessionButton("Shut down");

        root.check(logout, "Log out button is missing");
        root.check(shutdown, "Shut down button is missing");

        logout.forceActiveFocus(Qt.TabFocusReason);
        root.input.wait(20);
        root.check(logout.activeFocus, "Log out did not take focus");

        // Every session button draws the keyboard indicator and exposes one
        // accessible button whose name is its action.
        for (const name of ["Log out", "Shut down", "Hibernate", "Reboot"]) {
            const button = root.sessionButton(name);
            root.check(button, `${name} button is missing`);
            root.equal(button.Accessible.role, Accessible.Button, `${name} accessible role`);
            root.equal(button.Accessible.name, name, `${name} accessible name`);
            button.forceActiveFocus(Qt.TabFocusReason);
            root.input.wait(10);
            root.check(button.activeFocus, `${name} did not take focus`);
            root.check(root.ringOf(button) !== null, `${name} shows no focus ring`);
        }

        // The real Shut down button opens confirmation with the configured
        // command. The Cancel button must be the safe default.
        logout.forceActiveFocus(Qt.TabFocusReason);
        root.input.keyClick(Qt.Key_Down);
        root.check(shutdown.activeFocus, "Down did not move focus to Shut down");
        const execBefore = SessionManager.execCount;
        root.input.keyClick(Qt.Key_Return);
        root.equal(SessionManager.execCount, execBefore + 1, "Return on Shut down did not exec once");
        root.equal(String(SessionManager.lastCommand[0]), String(Config.session.commands.shutdown[0]),
            "Shut down passed the wrong command");
        root.check(SessionManager.confirmationPending, "Return on Shut down did not open confirmation");
        const cancel = root.byName(content, "Cancel");
        const confirm = root.byName(content, "Confirm shutdown");
        root.check(cancel, "Cancel button is missing");
        root.check(confirm, "Confirm button is missing");
        root.check(cancel.activeFocus, "Cancel did not take focus when confirmation opened");
        root.check(root.ringOf(cancel) !== null, "Cancel shows no focus ring");
        root.check(root.ringOf(confirm) === null, "Confirm shows a focus ring before it has focus");
        root.equal(cancel.Accessible.role, Accessible.Button, "Cancel accessible role");
        root.equal(cancel.Accessible.name, "Cancel", "Cancel accessible name");
        root.equal(confirm.Accessible.role, Accessible.Button, "Confirm accessible role");
        root.equal(confirm.Accessible.name, "Confirm shutdown", "Confirm accessible name");

        // Right then Return confirms through the button, and focus returns to
        // the button that started the confirmation.
        root.input.keyClick(Qt.Key_Right);
        root.check(confirm.activeFocus, "Right did not move focus to Confirm");
        root.check(root.ringOf(confirm) !== null, "Confirm shows no focus ring");
        root.check(root.ringOf(cancel) === null, "Cancel kept its focus ring");
        const confirmBefore = SessionManager.confirmCount;
        root.input.keyClick(Qt.Key_Return);
        root.equal(SessionManager.confirmCount, confirmBefore + 1, "Return on Confirm did not call confirm()");
        root.check(!SessionManager.confirmationPending, "confirm() left the confirmation pending");
        root.check(shutdown.activeFocus, "confirm() did not return focus to Shut down");

        // Space and Enter activate Cancel; Escape cancels. Each returns focus.
        root.input.keyClick(Qt.Key_Return);
        root.check(SessionManager.confirmationPending, "Return did not reopen the confirmation");
        root.check(cancel.activeFocus, "Cancel did not take focus on the second confirmation");
        let cancelBefore = SessionManager.cancelCount;
        root.input.keyClick(Qt.Key_Space);
        root.equal(SessionManager.cancelCount, cancelBefore + 1, "Space on Cancel did not cancel");
        root.check(!SessionManager.confirmationPending, "Space left the confirmation pending");
        root.check(shutdown.activeFocus, "Space did not return focus to Shut down");

        root.input.keyClick(Qt.Key_Return);
        cancelBefore = SessionManager.cancelCount;
        root.input.keyClick(Qt.Key_Enter);
        root.equal(SessionManager.cancelCount, cancelBefore + 1, "Enter on Cancel did not cancel");
        root.check(shutdown.activeFocus, "Enter did not return focus to Shut down");

        root.input.keyClick(Qt.Key_Return);
        root.check(cancel.activeFocus, "Cancel is not focused before Escape");
        cancelBefore = SessionManager.cancelCount;
        root.input.keyClick(Qt.Key_Escape);
        root.equal(SessionManager.cancelCount, cancelBefore + 1, "Escape did not cancel the confirmation");
        root.check(!SessionManager.confirmationPending, "Escape left the confirmation pending");
        root.check(shutdown.activeFocus, "Escape did not return focus to Shut down");

        // Arrows never leave the two confirmation buttons while it is open.
        root.input.keyClick(Qt.Key_Return);
        root.input.keyClick(Qt.Key_Up);
        root.check(confirm.activeFocus, "Up did not move focus to Confirm");
        root.input.keyClick(Qt.Key_Left);
        root.check(cancel.activeFocus, "Left did not move focus to Cancel");
        root.input.keyClick(Qt.Key_Down);
        root.check(confirm.activeFocus, "Down did not move focus to Confirm");
        root.input.keyClick(Qt.Key_Right);
        root.check(cancel.activeFocus, "Right did not move focus to Cancel");
        cancelBefore = SessionManager.cancelCount;
        root.input.keyClick(Qt.Key_Escape);
        root.equal(SessionManager.cancelCount, cancelBefore + 1, "Escape after arrow navigation did not cancel");
        root.check(shutdown.activeFocus, "arrow navigation lost the origin focus");

        // The launcher opens over the drawer without closing an open
        // confirmation and takes active focus. Closing it must hand focus back
        // to Cancel, so the confirmation stays keyboard-reachable.
        root.input.keyClick(Qt.Key_Return);
        root.check(cancel.activeFocus, "Cancel is not focused before the launcher opens");
        screenState.launcher = true;
        const launcherFocus = root.focusTaker.createObject(win.contentItem);
        launcherFocus.forceActiveFocus();
        root.input.wait(10);
        root.check(launcherFocus.activeFocus, "the launcher stand-in did not take focus");
        root.check(!cancel.activeFocus, "Cancel kept focus while the launcher was open");
        screenState.launcher = false;
        root.input.wait(10);
        root.check(cancel.activeFocus, "closing the launcher did not restore focus to Cancel");
        launcherFocus.destroy();

        cancelBefore = SessionManager.cancelCount;
        root.input.keyClick(Qt.Key_Return);
        root.equal(SessionManager.cancelCount, cancelBefore + 1, "Return did not cancel after the launcher closed");
        root.check(!SessionManager.confirmationPending, "Return left the confirmation pending after the launcher closed");
        root.check(shutdown.activeFocus, "the launcher check lost the origin focus");
    }
}
