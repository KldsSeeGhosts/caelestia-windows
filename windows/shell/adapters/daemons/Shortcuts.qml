import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia.Config
import qs.components.misc
import qs.services
import qs.modules.nexus

// Windows adaptation of daemons/Shortcuts.qml.
//
// Resolve a shortcut's screen at dispatch time, like the Windows tiler.
//
// `caelestia:nexus` is registered exactly as upstream registers it: a detached
// Nexus FloatingWindow through modules/nexus/WindowFactory.qml. The Windows
// build stages that module, so the handler is the upstream one. No default key
// is shipped for it (windows/docs/KEYBINDS.md), so it stays unbound until the
// user adds a bind.
Scope {
    id: root

    // Windows: instantiate the picker IPC adapter even before the launcher opens.
    readonly property bool glazierAvailable: Glazier.available

    function screenState(): var {
        const screens = Quickshell.screens;
        const cursor = Native.Input.cursorScreenForFocus();
        const focused = Hypr.focusedMonitor;
        const screen = (cursor ? screens.find(s => s.name === cursor) : null)
            ?? (focused ? screens.find(s => Hypr.monitorFor(s) === focused) : null)
            ?? screens[0];
        return screen ? ShellState.forScreen(screen) : null;
    }

    property bool launcherInterrupted
    readonly property alias screenshotShortcut: screenshotShortcut
    readonly property alias recordShortcut: recordShortcut

    CustomShortcut {
        id: screenshotShortcut
        name: "screenshot"
        description: "Open screenshot picker"
        onPressed: CaptureUi.screenshot("open")
    }
    // Windows: the upstream picker variants all open the shell's frozen picker.
    CustomShortcut {
        name: "screenshotFreeze"
        description: "Open screenshot picker"
        onPressed: CaptureUi.screenshot("openFreeze")
    }
    CustomShortcut {
        name: "screenshotClip"
        description: "Open screenshot picker"
        onPressed: CaptureUi.screenshot("openClip")
    }
    CustomShortcut {
        name: "screenshotFreezeClip"
        description: "Open screenshot picker"
        onPressed: CaptureUi.screenshot("openFreezeClip")
    }
    // Toggle between the region picker and stopping an active recording.
    CustomShortcut {
        id: recordShortcut
        name: "record"
        description: "Record the screen"
        onPressed: {
            if (Recorder.running || Recorder.state === "selecting" || Recorder.state === "ready")
                Recorder.stop();
            else
                CaptureUi.record();
        }
    }

    function logState(name: string, state): void {
        console.log(`CAELESTIA_SHORTCUT name=${name} launcher=${state?.launcher ?? false}`
            + ` dashboard=${state?.dashboard ?? false} session=${state?.session ?? false}`
            + ` sidebar=${state?.sidebar ?? false} utilities=${state?.utilities ?? false}`
            + ` osd=${state?.osd ?? false}`);
    }

    CustomShortcut {
        name: "nexus"
        description: "Open the Nexus settings window"
        onPressed: {
            WindowFactory.create();
            console.log("CAELESTIA_SHORTCUT name=nexus");
        }
    }

    CustomShortcut {
        name: "showall"
        description: "Toggle launcher, dashboard and osd"
        onPressed: {
            const state = root.screenState();
            if (!state)
                return;
            const value = !(state.launcher || state.dashboard || state.osd || state.utilities);
            state.launcher = state.dashboard = state.osd = state.utilities = value;
            root.logState("showall", state);
        }
    }

    CustomShortcut {
        name: "dashboard"
        description: "Toggle dashboard"
        onPressed: {
            const state = root.screenState();
            if (!state)
                return;
            state.dashboard = !state.dashboard;
            root.logState("dashboard", state);
        }
    }

    CustomShortcut {
        name: "session"
        description: "Toggle session menu"
        onPressed: {
            const state = root.screenState();
            if (!state)
                return;
            state.session = !state.session;
            root.logState("session", state);
        }
    }

    CustomShortcut {
        name: "launcher"
        description: "Toggle launcher"
        onPressed: root.launcherInterrupted = false
        onReleased: {
            const state = root.screenState();
            if (!root.launcherInterrupted && state)
                state.launcher = !state.launcher;
            root.launcherInterrupted = false;
            root.logState("launcher", state);
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
            const state = root.screenState();
            if (!state || !Config.sidebar.enabled)
                return;
            state.sidebar = !state.sidebar;
            root.logState("sidebar", state);
        }
    }

    CustomShortcut {
        name: "utilities"
        description: "Toggle utilities"
        onPressed: {
            const state = root.screenState();
            if (!state)
                return;
            state.utilities = !state.utilities;
            root.logState("utilities", state);
        }
    }
}
