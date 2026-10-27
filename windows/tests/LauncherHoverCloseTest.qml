import QtQuick

Item {
    id: root

    property QtObject config: QtObject {
        property QtObject launcher: QtObject {
            property bool enabled: true
            property bool showOnHover: true
        }
    }
    property QtObject screenState: QtObject {
        property bool launcher: false
    }
    property bool launcherHoverEntered: false
    property bool launcherResizeGuard: false

    // The runner inserts the real Interactions.qml launcher hover policy here.
    // LAUNCHER_HOVER_FUNCTION

    function launcherLeft(): void {
        // The runner inserts the real onContainsMouseChanged tail here.
        // LAUNCHER_LEAVE_BODY
    }

    property int assertions: 0

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Component.onCompleted: {
        try {
            // Super or the start button opens the launcher with the pointer
            // elsewhere. Moving the pointer outside it must not close it.
            screenState.launcher = true;
            updateLauncherHover(false);
            launcherLeft();
            check(screenState.launcher && !launcherHoverEntered, "keybind open stays until entered");

            // Typing to search moves no pointer, so no hover callback runs and
            // the launcher must remain open.
            check(screenState.launcher, "typing keeps the launcher open");

            // Reaching the launcher arms the hover close.
            updateLauncherHover(true);
            check(screenState.launcher && launcherHoverEntered, "pointer entry arms the close");

            // Leaving the open launcher closes it.
            updateLauncherHover(false);
            check(!screenState.launcher, "pointer leave closes an entered launcher");

            // onLauncherChanged resets the entry flag so the next open needs a
            // new pointer entry.
            launcherHoverEntered = false;
            screenState.launcher = true;
            launcherLeft();
            check(screenState.launcher && !launcherHoverEntered, "next open needs a new entry");

            // A hover open already has the pointer on the launcher.
            updateLauncherHover(true);
            check(screenState.launcher && launcherHoverEntered, "hover open arms the close");
            updateLauncherHover(false);
            check(!screenState.launcher, "hover leave closes");

            // Typing shrinks the results under a resting pointer. The mask
            // change reports a leave that must not close the launcher.
            screenState.launcher = true;
            updateLauncherHover(true);
            launcherResizeGuard = true;
            launcherLeft();
            check(screenState.launcher, "resize under a resting pointer keeps it open");

            // The next pointer move clears the guard, so a real leave closes.
            launcherResizeGuard = false;
            launcherLeft();
            check(!screenState.launcher, "leave after the pointer moves closes");

            // Leaving while closed is inert.
            launcherHoverEntered = false;
            updateLauncherHover(false);
            check(!screenState.launcher, "leave while closed is inert");

            // Disabling hover close keeps an entered launcher open on a mask
            // leave.
            screenState.launcher = true;
            launcherHoverEntered = true;
            config.launcher.showOnHover = false;
            launcherLeft();
            check(screenState.launcher, "leave respects showOnHover");
            config.launcher.showOnHover = true;

            // A disabled launcher ignores the leave path as well.
            config.launcher.enabled = false;
            launcherLeft();
            check(screenState.launcher, "leave respects enabled");
            config.launcher.enabled = true;

            // Escape or the Super toggle closes the launcher and the reset
            // makes any later leave inert.
            launcherHoverEntered = false;
            screenState.launcher = false;
            launcherLeft();
            check(!screenState.launcher, "leave after toggle close is inert");

            console.log("CAELESTIA_LAUNCHER_HOVER_PASS " + assertions);
            Qt.quit();
        } catch (error) {
            console.error("CAELESTIA_LAUNCHER_HOVER_FAIL " + error);
            Qt.exit(1);
        }
    }
}
