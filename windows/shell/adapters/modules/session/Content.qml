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
import qs.modules.nexus.common

Column {
    id: root

    required property ScreenState screenState

    // Windows adaptation: the same allowlisted command and gate the four native
    // session buttons use. The action is present even while unavailable so the
    // user can see why, with the existing disabled styling.
    readonly property var switchBackAction: SessionManager.sessionActionGating === true
        && SessionManager.sessionAction ? SessionManager.sessionAction(["switch-back"]) : null
    readonly property bool switchBackAvailable: switchBackAction !== null
        && switchBackAction.dispatchable === true

    function switchBack(): void {
        if (!root.switchBackAvailable)
            return;
        // The service backend starts Start-Caelestia.ps1 as a detached
        // process; that existing launcher owns Quit and the supervisor's
        // desktop restore after this shell exits.
        SessionManager.switchBackDisableAutostart = autostart.checked;
        SessionManager.exec(["switch-back"]);
    }

    padding: Tokens.padding.large
    rightPadding: CUtils.clamp(padding - Config.border.thickness, 0, padding)
    spacing: Tokens.spacing.large

    SessionButton {
        id: logout

        icon: Config.session.icons.logout
        command: Config.session.commands.logout
        accessibleName: "Log out"

        KeyNavigation.up: autostart.visible ? autostart : switchBackButton
        KeyNavigation.down: shutdown
        // Windows a11y fix: every control names both Tab neighbours, so
        // traversal is a closed cycle over the session drawer and never falls
        // back to Qt's default chain, which leaves the drawer for the bar.
        KeyNavigation.tab: shutdown
        KeyNavigation.backtab: autostart.visible ? autostart : switchBackButton

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
        KeyNavigation.down: switchBackButton
        KeyNavigation.tab: switchBackButton
        KeyNavigation.backtab: hibernate
    }

    // Clearly labelled because this action leaves Windows instead of acting on
    // the current session. It uses the same focus indicator and keyboard paths
    // as the icon buttons above.
    IconTextButton {
        id: switchBackButton

        property bool pointerUsed
        readonly property bool focusVisible: activeFocus && !pointerUsed

        onActiveFocusChanged: pointerUsed = false
        onPressedChanged: if (pressed) pointerUsed = true

        icon: "desktop_windows"
        text: "Switch back to Windows"
        type: TextButton.Filled
        font: Tokens.font.body.small
        disabled: !root.switchBackAvailable

        inactiveColour: switchBackButton.activeFocus ? Colours.palette.m3secondaryContainer : Colours.tPalette.m3surfaceContainer
        inactiveOnColour: switchBackButton.activeFocus ? Colours.palette.m3onSecondaryContainer : Colours.palette.m3onSurface

        KeyNavigation.up: reboot
        KeyNavigation.down: autostart.visible ? autostart : logout
        KeyNavigation.tab: autostart.visible ? autostart : logout
        KeyNavigation.backtab: reboot

        Accessible.role: Accessible.Button
        Accessible.name: "Switch back to Windows"
        Accessible.description: root.switchBackAvailable
            ? "Quit Caelestia and restore the Windows taskbar and desktop."
            : String(root.switchBackAction?.reason ?? "Switching back to Windows is unavailable.")
        Accessible.onPressAction: root.switchBack()

        onClicked: root.switchBack()

        FocusRing {
            showing: switchBackButton.focusVisible
            radius: switchBackButton.radius
        }

        Keys.onEnterPressed: root.switchBack()
        Keys.onReturnPressed: root.switchBack()
        Keys.onSpacePressed: root.switchBack()
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

    // The choice is offered here, before the shell leaves. Off by default so
    // switching back does not silently change a sign-in preference; the
    // installed launcher removes only this installation's own Run entry.
    ToggleRow {
        id: autostart

        visible: root.switchBackAvailable
        text: "Turn off autostart"
        subtext: "When switching back to Windows"
        checked: SessionManager.switchBackDisableAutostart
        onToggled: SessionManager.switchBackDisableAutostart = checked

        KeyNavigation.up: switchBackButton
        KeyNavigation.down: logout
        KeyNavigation.tab: logout
        KeyNavigation.backtab: switchBackButton

        Accessible.name: "Turn off autostart when switching back to Windows"

        Keys.onEscapePressed: root.screenState.session = false
        Keys.onTabPressed: {
            if (KeyNavigation.tab)
                KeyNavigation.tab.focus = true;
        }
        Keys.onBacktabPressed: {
            if (KeyNavigation.backtab)
                KeyNavigation.backtab.focus = true;
        }
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
                // Windows a11y fix: the vim path uses the same
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
