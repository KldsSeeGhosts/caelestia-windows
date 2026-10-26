import QtQuick
import Quickshell
import Caelestia.Config
import qs.components.misc
import qs.services

// Windows adaptation of daemons/Shortcuts.qml.
//
// The original daemon resolves the active screen through Hypr.focusedMonitor.
// The combined Windows host has no Hyprland connection, so it addresses the
// screen selected by the prototype host instead. The shortcut names are
// unchanged; defaults/windows/keybinds.json binds them to the Caelestia
// defaults and remains overridable from the shell configuration directory.
Scope {
    id: root

    readonly property var screenState: {
        const screen = ShellState.shellRoot?.selectedScreen ?? Quickshell.screens[0];
        return screen ? ShellState.forScreen(screen) : null;
    }

    property bool launcherInterrupted

    function logState(name: string): void {
        const state = root.screenState;
        console.log(`CAELESTIA_SHORTCUT name=${name} launcher=${state?.launcher ?? false}`
            + ` dashboard=${state?.dashboard ?? false} session=${state?.session ?? false}`
            + ` sidebar=${state?.sidebar ?? false} utilities=${state?.utilities ?? false}`
            + ` osd=${state?.osd ?? false}`);
    }

    CustomShortcut {
        name: "showall"
        description: "Toggle launcher, dashboard and osd"
        onPressed: {
            const state = root.screenState;
            if (!state)
                return;
            const value = !(state.launcher || state.dashboard || state.osd || state.utilities);
            state.launcher = state.dashboard = state.osd = state.utilities = value;
            root.logState("showall");
        }
    }

    CustomShortcut {
        name: "dashboard"
        description: "Toggle dashboard"
        onPressed: {
            const state = root.screenState;
            if (!state)
                return;
            state.dashboard = !state.dashboard;
            root.logState("dashboard");
        }
    }

    CustomShortcut {
        name: "session"
        description: "Toggle session menu"
        onPressed: {
            const state = root.screenState;
            if (!state)
                return;
            state.session = !state.session;
            root.logState("session");
        }
    }

    CustomShortcut {
        name: "launcher"
        description: "Toggle launcher"
        onPressed: root.launcherInterrupted = false
        onReleased: {
            const state = root.screenState;
            if (!root.launcherInterrupted && state)
                state.launcher = !state.launcher;
            root.launcherInterrupted = false;
            root.logState("launcher");
        }
    }

    CustomShortcut {
        name: "launcherInterrupt"
        description: "Interrupt launcher keybind"
        onPressed: root.launcherInterrupted = true
    }

    CustomShortcut {
        name: "sidebar"
        description: "Toggle sidebar"
        onPressed: {
            const state = root.screenState;
            if (!state || !Config.sidebar.enabled)
                return;
            state.sidebar = !state.sidebar;
            root.logState("sidebar");
        }
    }

    CustomShortcut {
        name: "utilities"
        description: "Toggle utilities"
        onPressed: {
            const state = root.screenState;
            if (!state)
                return;
            state.utilities = !state.utilities;
            root.logState("utilities");
        }
    }
}
