import QtQuick
import Quickshell
import Caelestia.Config
import qs.components.misc
import qs.services
import qs.modules.nexus

// Windows adaptation of daemons/Shortcuts.qml.
//
// The original daemon resolves the active screen through Hypr.focusedMonitor.
// The combined Windows host has no Hyprland connection, so it addresses the
// screen selected by the prototype host instead. The shortcut names are
// unchanged; defaults/windows/keybinds.json binds them to the Caelestia
// defaults and remains overridable from the shell configuration directory.
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

    readonly property var screenState: {
        const screen = ShellState.shellRoot?.selectedScreen
            ?? Quickshell.screens.find(s => Hypr.monitorFor(s) === Hypr.focusedMonitor)
            ?? Quickshell.screens[0];
        return screen ? ShellState.forScreen(screen) : null;
    }

    property bool launcherInterrupted
    readonly property alias screenshotShortcut: screenshotShortcut
    readonly property alias recordShortcut: recordShortcut

    CustomShortcut {
        id: screenshotShortcut
        name: "screenshot"
        description: "Screenshot with Glazier"
        onPressed: CaptureUi.screenshot("open")
    }
    // Windows: the upstream picker variants all open Glazier's frozen editor on
    // the classic path. With windows.capture.ui set to "shell", CaptureUi opens
    // the QML picker, which clips for the Clip variants.
    CustomShortcut {
        name: "screenshotFreeze"
        description: "Screenshot with Glazier"
        onPressed: CaptureUi.screenshot("openFreeze")
    }
    CustomShortcut {
        name: "screenshotClip"
        description: "Screenshot with Glazier"
        onPressed: CaptureUi.screenshot("openClip")
    }
    CustomShortcut {
        name: "screenshotFreezeClip"
        description: "Screenshot with Glazier"
        onPressed: CaptureUi.screenshot("openFreezeClip")
    }
    // Glazier's own recording hotkey toggles; the shell owns the chord and
    // forwards the same explicit capture/record commands.
    CustomShortcut {
        id: recordShortcut
        name: "record"
        description: "Record the screen with Glazier"
        onPressed: {
            if (Recorder.running || Recorder.state === "selecting" || Recorder.state === "ready")
                Recorder.stop();
            else
                CaptureUi.record();
        }
    }

    function logState(name: string): void {
        const state = root.screenState;
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
