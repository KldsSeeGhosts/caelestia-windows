import QtQuick
import Quickshell
import Quickshell.Windows as Native
import Caelestia.Config
import Caelestia.State
import Caelestia.Windows
import qs.services
import "IdleLogic.js" as Logic

// Windows adaptation of upstream daemons/IdleMonitors.qml. GetLastInputInfo is
// polled through the native IdlePower facade; Linux dispatch strings are mapped
// only to lock, display-off, suspend and hibernate. Unknown commands never reach
// a process launcher.
Scope {
    id: root

    property bool active: Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property var entries: GlobalConfig.general.idle.timeouts.values
    readonly property bool inhibited: IdleHold.held === true || RuntimeState.inhibitIdle === true
    readonly property bool hasPlayer: Players.list.some(player => player.isPlaying)
    readonly property bool onAcPower: WindowsBattery.onBatteryKnown && !WindowsBattery.onBattery
    property var fired: ({})
    property int previousIdleSeconds: 0

    onEntriesChanged: fired = ({})

    function idleSeconds(): int {
        const provider = Native.IdlePower;
        if (!provider || typeof provider.idleSeconds !== "function")
            return -1;
        const value = Number(provider.idleSeconds());
        return Number.isFinite(value) && value >= 0 ? Math.floor(value) : -1;
    }

    function perform(action): bool {
        if (!action || !root.active)
            return false;
        if (action.kind === "lock")
            return SessionManager.exec(["lock"]);
        if (action.kind === "displayOff")
            return WindowsDisplayPower.off();
        if (action.kind === "displayOn")
            return true; // Windows turns the panel on for the input that ended idle.
        if (action.kind === "session") {
            if (GlobalConfig.general.idle.lockBeforeSleep)
                SessionManager.exec(["lock"]);
            return SessionManager.exec([action.action]);
        }
        return false;
    }

    function poll(): void {
        if (!root.active)
            return;
        const seconds = idleSeconds();
        if (seconds < 0)
            return;
        const result = Logic.transitions(entries, fired, seconds, inhibited, hasPlayer, onAcPower,
            GlobalConfig.general.idle.inhibitWhenAudio, GlobalConfig.general.idle.inhibitWhenCharging,
            seconds < previousIdleSeconds);
        previousIdleSeconds = seconds;
        fired = result.fired;
        for (let i = 0; i < result.actions.length; ++i)
            perform(result.actions[i].action);
    }

    Timer {
        interval: 1000
        repeat: true
        running: root.active
        onTriggered: root.poll()
    }
}
