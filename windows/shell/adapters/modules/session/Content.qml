pragma ComponentBehavior: Bound

import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import Caelestia.Services
import qs.components
import qs.components.controls
import qs.services
import qs.utils

Column {
    id: root

    required property ScreenState screenState

    padding: Tokens.padding.large
    rightPadding: CUtils.clamp(padding - Config.border.thickness, 0, padding)
    spacing: Tokens.spacing.large

    SessionButton {
        id: logout

        icon: Config.session.icons.logout
        command: Config.session.commands.logout
        accessibleName: "Log out"

        KeyNavigation.down: shutdown
        // Windows a11y fix (ERM-615): every button names both Tab neighbours,
        // so traversal is a closed cycle over the four buttons and never falls
        // back to Qt's default chain, which leaves the drawer for the bar.
        KeyNavigation.tab: shutdown
        KeyNavigation.backtab: reboot

        Component.onCompleted: forceActiveFocus()

        Connections {
            function onLauncherChanged(): void {
                if (!root.screenState.launcher)
                    logout.forceActiveFocus();
            }

            target: root.screenState
        }
    }

    SessionButton {
        id: shutdown

        icon: Config.session.icons.shutdown
        command: Config.session.commands.shutdown
        accessibleName: "Shut down"

        KeyNavigation.up: logout
        KeyNavigation.down: hibernate
        KeyNavigation.tab: hibernate
        KeyNavigation.backtab: logout
    }

    Loader {
        active: Config.paths.sessionGif.trim() !== ""

        sourceComponent: AnimatedImage {
            width: Tokens.sizes.session.button
            height: Tokens.sizes.session.button
            sourceSize.width: width * ((QsWindow.window as QsWindow)?.devicePixelRatio ?? 1)

            playing: visible
            asynchronous: true
            speed: Config.general.sessionGifSpeed
            source: Paths.absolutePath(Config.paths.sessionGif)
            fillMode: AnimatedImage.PreserveAspectFit
        }
    }

    SessionButton {
        id: hibernate

        icon: Config.session.icons.hibernate
        command: Config.session.commands.hibernate
        accessibleName: "Hibernate"

        KeyNavigation.up: shutdown
        KeyNavigation.down: reboot
        KeyNavigation.tab: reboot
        KeyNavigation.backtab: shutdown
    }

    SessionButton {
        id: reboot

        icon: Config.session.icons.reboot
        command: Config.session.commands.reboot
        accessibleName: "Reboot"

        KeyNavigation.up: hibernate
        KeyNavigation.tab: logout
        KeyNavigation.backtab: hibernate
    }

    component SessionButton: IconButton {
        id: button

        required property list<string> command
        property string accessibleName

        // A pointer press on a focused button hides the keyboard indicator until
        // focus moves again; clicks never move focus themselves.
        property bool pointerUsed

        readonly property bool focusVisible: activeFocus && !pointerUsed

        onActiveFocusChanged: pointerUsed = false
        onPressedChanged: if (pressed) pointerUsed = true

        // Windows adaptation: the native Linux SessionManager has neither hook,
        // so upstream behavior (enabled buttons and detached fallback when exec
        // declines a command) is preserved. The Windows adapter sets
        // sessionActionGating and allowDetachedFallback=false; unavailable
        // actions then use the existing disabled styling and a declined command
        // can never reach execDetached.
        readonly property var sessionAction: SessionManager.sessionActionGating === true
            && SessionManager.sessionAction ? SessionManager.sessionAction(command) : null

        function exec(): void {
            if (button.disabled)
                return;
            if (SessionManager.exec(command))
                return;
            if (SessionManager.allowDetachedFallback === false)
                return;
            Quickshell.execDetached(command);
        }

        disabled: sessionAction !== null && sessionAction.dispatchable !== true

        implicitWidth: Tokens.sizes.session.button
        implicitHeight: Tokens.sizes.session.button

        inactiveColour: activeFocus ? Colours.palette.m3secondaryContainer : Colours.tPalette.m3surfaceContainer
        inactiveOnColour: activeFocus ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface
        radius: pressed ? Tokens.rounding.medium : activeFocus ? Tokens.rounding.extraLarge : Tokens.rounding.largeIncreased
        font: Tokens.font.icon.builders.large.scale(1.3).build()
        onClicked: exec()

        Accessible.role: Accessible.Button
        Accessible.name: button.accessibleName
        Accessible.onPressAction: button.exec()

        FocusRing {
            showing: button.focusVisible
            radius: button.radius
        }

        Keys.onEnterPressed: exec()
        Keys.onReturnPressed: exec()
        Keys.onEscapePressed: root.screenState.session = false
        Keys.onPressed: event => {
            if (!Config.session.vimKeybinds)
                return;

            if (event.modifiers & Qt.ControlModifier) {
                if ((event.key === Qt.Key_J || event.key === Qt.Key_N) && KeyNavigation.down) {
                    KeyNavigation.down.focus = true;
                    event.accepted = true;
                } else if ((event.key === Qt.Key_K || event.key === Qt.Key_P) && KeyNavigation.up) {
                    KeyNavigation.up.focus = true;
                    event.accepted = true;
                }
            } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                // Windows a11y fix (ERM-615): the vim path uses the same
                // closed tab cycle as the plain path.
                if (KeyNavigation.backtab) {
                    KeyNavigation.backtab.focus = true;
                    event.accepted = true;
                }
            } else if (event.key === Qt.Key_Tab) {
                if (KeyNavigation.tab) {
                    KeyNavigation.tab.focus = true;
                    event.accepted = true;
                }
            }
        }
    }
}
