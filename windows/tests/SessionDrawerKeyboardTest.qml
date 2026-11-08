import QtQuick
import QtTest
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.Services
import qs.components
import qs.services
import qs.modules.session as SessionDrawer

// Drives the real staged session drawer. The environment points at a
// disposable installed-looking prefix, so the real SessionManager backend
// advertises switch-back without touching the live desktop. No switch-back
// action is dispatched here; the separate handoff fixture covers dispatch.
ShellRoot {
    id: root

    settings.watchFiles: false

    Config.screen: screenState.modelData?.name ?? ""
    Tokens.screen: screenState.modelData?.name ?? ""

    property int assertions: 0
    property var input
    property Component inputComponent: Component {
        TestCase {
            when: false
        }
    }

    WindowsFonts {
        id: windowsFonts
    }

    ScreenState {
        id: screenState

        modelData: Quickshell.screens[0] ?? null
        session: true
    }

    FloatingWindow {
        id: win

        visible: true
        implicitWidth: 420
        implicitHeight: 760
        color: "transparent"

        SessionDrawer.Content {
            id: content

            width: 360
            screenState: screenState
        }
    }

    function check(condition, message): void {
        assertions++;
        if (!condition)
            throw new Error(message);
    }

    function equal(actual, expected, message): void {
        check(actual === expected,
            message + ": " + JSON.stringify(actual) + " != " + JSON.stringify(expected));
    }

    function item(name): var {
        return CUtils.findChildren(content, name)[0];
    }

    readonly property var order: ["logoutButton", "shutdownButton", "hibernateButton",
        "rebootButton", "switchBackButton", "autostartToggle"]

    function focused(): string {
        for (const name of order) {
            const control = item(name);
            if (control && control.activeFocus)
                return name;
        }
        return "";
    }

    function move(key, modifier, expected, message): void {
        input.keyClick(key, modifier);
        equal(focused(), expected, message);
    }

    function run(): void {
        input = inputComponent.createObject(win.contentItem);
        check(input !== null, "the key input fixture was created");
        check(Config.session.vimKeybinds === true, "vim keybinds are enabled for the drawer");

        for (const name of order)
            check(item(name) !== null, "control exists: " + name);

        const logout = item("logoutButton");
        const autostart = item("autostartToggle");

        // --- Forward vim cycle ------------------------------------------------
        logout.forceActiveFocus();
        equal(focused(), "logoutButton", "focus starts on logout");
        for (const expected of ["shutdownButton", "hibernateButton", "rebootButton",
            "switchBackButton", "autostartToggle", "logoutButton"]) {
            move(Qt.Key_J, Qt.ControlModifier, expected, "Ctrl+J reaches " + expected);
        }
        move(Qt.Key_N, Qt.ControlModifier, "shutdownButton", "Ctrl+N moves down too");

        // --- Reverse vim cycle ------------------------------------------------
        logout.forceActiveFocus();
        for (const expected of ["autostartToggle", "switchBackButton", "rebootButton",
            "hibernateButton", "shutdownButton", "logoutButton"]) {
            move(Qt.Key_K, Qt.ControlModifier, expected, "Ctrl+K reaches " + expected);
        }
        move(Qt.Key_P, Qt.ControlModifier, "autostartToggle", "Ctrl+P moves up too");

        // --- Tab and Shift+Tab stay on the same closed cycle -----------------
        logout.forceActiveFocus();
        input.keyClick(Qt.Key_Tab);
        equal(focused(), "shutdownButton", "Tab moves forward");
        input.keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        equal(focused(), "logoutButton", "Shift+Tab moves back");
        autostart.forceActiveFocus();
        input.keyClick(Qt.Key_Tab);
        equal(focused(), "logoutButton", "Tab from the toggle closes the cycle");
        input.keyClick(Qt.Key_Tab, Qt.ShiftModifier);
        equal(focused(), "autostartToggle", "Shift+Tab from logout returns to the toggle");

        // --- Activation keeps the switch handler from StyledSwitch ----------
        autostart.forceActiveFocus();
        equal(focused(), "autostartToggle", "the toggle takes focus");
        equal(SessionManager.switchBackDisableAutostart, false, "the toggle starts unchecked");
        input.keyClick(Qt.Key_Space);
        equal(SessionManager.switchBackDisableAutostart, true, "Space toggles the row on");
        input.keyClick(Qt.Key_Space);
        equal(SessionManager.switchBackDisableAutostart, false, "Space toggles the row off");
        input.keyClick(Qt.Key_Return);
        equal(SessionManager.switchBackDisableAutostart, true, "Return toggles the row on");
        input.keyClick(Qt.Key_Enter);
        equal(SessionManager.switchBackDisableAutostart, false, "Enter toggles the row off");
        input.keyClick(Qt.Key_Return);
        equal(SessionManager.switchBackDisableAutostart, true, "Return still toggles after vim handling");

        // --- Escape dismisses the drawer ------------------------------------
        check(screenState.session === true, "the drawer is open before Escape");
        input.keyClick(Qt.Key_Escape);
        check(screenState.session === false, "Escape from the toggle dismisses the drawer");
        screenState.session = true;

        // --- Handoff progress and timeout error are visible -----------------
        const backend = SessionManager._nativeLoader.item;
        check(backend !== null, "the native session backend is loaded");
        backend.switchBackPending = true;
        equal(item("switchBackButton").text, "Switching back to Windows...",
            "the pending handoff is acknowledged in the button");
        backend.switchBackPending = false;
        backend.switchBackError = "Fixture handoff failure.";
        check(item("switchBackError").visible, "a handoff error is shown in the drawer");
        backend.switchBackError = "";
        check(!item("switchBackError").visible, "the error row hides when the failure clears");

        console.log("CAELESTIA_SESSION_DRAWER_PASS " + JSON.stringify({assertions: assertions}));
        Qt.quit();
    }

    Component.onCompleted: Qt.callLater(() => {
        try {
            run();
        } catch (error) {
            console.error("CAELESTIA_SESSION_DRAWER_FAIL " + error.message);
            Qt.exit(1);
        }
    })
}
