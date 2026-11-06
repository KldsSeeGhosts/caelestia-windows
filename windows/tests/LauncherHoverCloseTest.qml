import QtQuick
import Quickshell
import Caelestia.Config
import qs.modules.drawers

ShellRoot {
    id: root

    property ContentWindow content: ContentWindow {
        screen: Quickshell.screens[0]
        visible: false
        interactionEnabled: false
    }
    readonly property var interactions: content.interactionWrapper
    readonly property var screenState: content.screenState
    readonly property var config: GlobalConfig

    function launcherLeft(): void {
        // Offscreen the pointer is outside. Emit the real MouseArea signal so
        // the production leave handler, including its gates, is exercised.
        interactions.hoveredChanged();
    }

    property int assertions: 0

    function check(value, description): void {
        assertions++;
        if (!value)
            throw new Error(description);
    }

    Component.onCompleted: Qt.callLater(run)
    function run(): void {
        try {
            config.launcher.enabled = true;
            config.launcher.showOnHover = true;
            // Super or the start button opens the launcher with the pointer
            // elsewhere. Moving the pointer outside it must not close it.
            screenState.launcher = true;
            interactions.updateLauncherHover(false);
            launcherLeft();
            check(screenState.launcher && !interactions.launcherHoverEntered, "keybind open stays until entered");

            // Typing to search moves no pointer, so no hover callback runs and
            // the launcher must remain open.
            check(screenState.launcher, "typing keeps the launcher open");

            // Reaching the launcher arms the hover close.
            interactions.updateLauncherHover(true);
            check(screenState.launcher && interactions.launcherHoverEntered, "pointer entry arms the close");

            // Leaving the open launcher closes it.
            interactions.updateLauncherHover(false);
            check(!screenState.launcher, "pointer leave closes an entered launcher");

            // onLauncherChanged resets the entry flag so the next open needs a
            // new pointer entry.
            screenState.launcher = true;
            launcherLeft();
            check(screenState.launcher && !interactions.launcherHoverEntered, "next open needs a new entry");

            // A hover open already has the pointer on the launcher.
            interactions.updateLauncherHover(true);
            check(screenState.launcher && interactions.launcherHoverEntered, "hover open arms the close");
            interactions.updateLauncherHover(false);
            check(!screenState.launcher, "hover leave closes");

            // Typing shrinks the results under a resting pointer. The mask
            // change reports a leave that must not close the launcher.
            screenState.launcher = true;
            interactions.updateLauncherHover(true);
            interactions.panels.launcher.height += 10;
            check(interactions.launcherResizeGuard, "real height signal arms the resize guard");
            launcherLeft();
            check(screenState.launcher, "resize under a resting pointer keeps it open");

            // The next pointer move clears the guard, so a real leave closes.
            interactions.launcherResizeGuard = false;
            launcherLeft();
            check(!screenState.launcher, "leave after the pointer moves closes");

            // Leaving while closed is inert.
            interactions.launcherHoverEntered = false;
            interactions.updateLauncherHover(false);
            check(!screenState.launcher, "leave while closed is inert");

            // Disabling hover close keeps an entered launcher open on a mask
            // leave.
            screenState.launcher = true;
            interactions.launcherHoverEntered = true;
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
            interactions.launcherHoverEntered = false;
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
