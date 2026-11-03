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

    readonly property bool liveSession: Quickshell.env("CAELESTIA_SHELL_LIVE") === "1"
    readonly property bool confirming: liveSession && SessionManager.confirmationPending

    // The button whose exec() opened the confirmation. Cancel and confirm both
    // return keyboard focus there, so it never lands nowhere.
    property Item confirmOrigin

    padding: Tokens.padding.large
    rightPadding: CUtils.clamp(padding - Config.border.thickness, 0, padding)
    spacing: Tokens.spacing.large

    SessionButton {
        id: logout

        icon: Config.session.icons.logout
        command: Config.session.commands.logout
        accessibleName: "Log out"

        KeyNavigation.down: shutdown

        Component.onCompleted: forceActiveFocus()

        Connections {
            function onLauncherChanged(): void {
                if (!root.screenState.launcher)
                    (root.confirming ? cancel : logout).forceActiveFocus();
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
    }

    SessionButton {
        id: reboot

        icon: Config.session.icons.reboot
        command: Config.session.commands.reboot
        accessibleName: "Reboot"

        KeyNavigation.up: hibernate
    }

    // Production has no preview control window. Keep explicit confirmation
    // inside the original session drawer; closing it cancels the pending action.
    Column {
        visible: root.confirming
        spacing: Tokens.spacing.small

        // A confirmation armed before the drawer opened is already visible on
        // creation, so onVisibleChanged never runs for it.
        Component.onCompleted: if (visible) cancel.forceActiveFocus()

        onVisibleChanged: {
            if (visible) {
                cancel.forceActiveFocus();
                return;
            }
            const origin = root.confirmOrigin ?? logout;
            root.confirmOrigin = null;
            if (root.screenState?.session)
                origin.forceActiveFocus();
        }

        StyledText { text: "Confirm Windows " + SessionManager.pendingAction + "?" }
        Row {
            spacing: Tokens.spacing.small

            ConfirmButton {
                id: cancel

                text: "Cancel"
                accessibleName: "Cancel"

                KeyNavigation.left: confirm
                KeyNavigation.right: confirm
                KeyNavigation.up: confirm
                KeyNavigation.down: confirm
                onClicked: SessionManager.cancelConfirmation()
            }

            ConfirmButton {
                id: confirm

                text: "Confirm"
                accessibleName: "Confirm " + SessionManager.pendingAction

                KeyNavigation.left: cancel
                KeyNavigation.right: cancel
                KeyNavigation.up: cancel
                KeyNavigation.down: cancel
                onClicked: SessionManager.confirm()
            }
        }
    }

    Connections {
        target: root.screenState
        function onSessionChanged(): void {
            if (!root.screenState.session && root.liveSession)
                SessionManager.cancelConfirmation();
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
            if (SessionManager.exec(command)) {
                if (SessionManager.confirmationPending)
                    root.confirmOrigin = button;
                return;
            }
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
            } else if (event.key === Qt.Key_Tab && KeyNavigation.down) {
                KeyNavigation.down.focus = true;
                event.accepted = true;
            } else if (event.key === Qt.Key_Backtab || (event.key === Qt.Key_Tab && (event.modifiers & Qt.ShiftModifier))) {
                if (KeyNavigation.up) {
                    KeyNavigation.up.focus = true;
                    event.accepted = true;
                }
            }
        }
    }

    component ConfirmButton: TextButton {
        id: button

        property string accessibleName
        property bool pointerUsed

        readonly property bool focusVisible: activeFocus && !pointerUsed

        onActiveFocusChanged: pointerUsed = false
        onPressedChanged: if (pressed) pointerUsed = true

        Accessible.role: Accessible.Button
        Accessible.name: button.accessibleName
        Accessible.onPressAction: button.clicked()

        FocusRing {
            showing: button.focusVisible
            radius: button.radius
        }

        Keys.onPressed: event => {
            if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter || event.key === Qt.Key_Space) {
                event.accepted = true;
                if (!event.isAutoRepeat)
                    button.clicked();
            }
        }
        Keys.onEscapePressed: event => {
            event.accepted = true;
            SessionManager.cancelConfirmation();
        }
    }
}
