import QtQuick
import Quickshell
import Quickshell.Io
import qs.services
import qs.daemons
import qs.modules.launcher
import qs.modules.launcher.services

ShellRoot {
    id: root
    property int ticks: 0
    property bool invoked: false
    property bool hiding: false
    property bool ipcDone: false
    property bool timeoutChecked: false
    property var states: [
        {bar: true, osd: true, session: true, launcher: true, dashboard: true, quota: true, utilities: true, sidebar: true},
        {bar: true, osd: true, session: true, launcher: true, dashboard: true, quota: true, utilities: true, sidebar: true}
    ]
    property var panels: [makePanel(), makePanel()]
    property var bars: [{closed: false, closeTray: function() { this.closed = true; }},
                        {closed: false, closeTray: function() { this.closed = true; }}]
    property var screens: ({screens: [0, 1]})
    property var provider: ({
        forScreen: function(screen) { return root.states[screen]; },
        componentsFor: function(screen) { return {panels: root.panels[screen], bar: root.bars[screen]}; }
    })

    function makePanel(): var {
        return {
            osd: {visible: true}, session: {visible: true}, launcher: {visible: true},
            dashboard: {visible: true}, quota: {visible: true}, utilities: {visible: true},
            sidebar: {visible: true}, popoutsWrapper: {visible: true},
            popouts: {closed: false, close: function() { this.closed = true; }}
        };
    }
    function allDismissed(): bool {
        return states.every((s, i) => Object.keys(s).every(key => !s[key])
            && panels[i].popouts.closed && bars[i].closed);
    }

    Shortcuts { id: shortcuts }
    AppList { id: appList; screenState: root.states[0] }
    FileView {
        id: marker
        path: Quickshell.env("GLAZIER_DISMISS_MARKER")
        printErrors: false
        onSaved: {
            for (const panel of root.panels)
                for (const key of ["osd", "session", "launcher", "dashboard", "quota", "utilities", "sidebar", "popoutsWrapper"])
                    panel[key].visible = false;
        }
    }
    Process {
        id: ipc
        command: [Quickshell.env("GLAZIER_QS"), "ipc", "--pid", String(Quickshell.processId),
            "call", "screenshot", "capture"]
        onExited: code => {
            if (code !== 0) {
                console.error("GLAZIER_TEST_FAIL IPC " + code);
                Qt.exit(1);
            }
            root.ipcDone = true;
        }
    }
    Timer {
        id: hideTimer
        interval: 120
        onTriggered: marker.setText("hidden")
    }
    Timer {
        id: timeoutCheck
        interval: 220
        onTriggered: {
            if (!Glazier.pendingPath) {
                console.error("GLAZIER_TEST_FAIL timeout launched early");
                Qt.exit(1);
                return;
            }
            root.timeoutChecked = true;
        }
    }
    Timer {
        interval: 20
        repeat: true
        running: true
        onTriggered: {
            if (++root.ticks > 150) {
                console.error("GLAZIER_TEST_FAIL timeout");
                Qt.exit(1);
                return;
            }
            if (!Glazier.ready)
                return;
            if (!root.invoked) {
                Glazier.screenProvider = root.screens;
                Glazier.stateProvider = root.provider;
                root.invoked = true;
                const route = Quickshell.env("GLAZIER_ROUTE");
                if (route === "launcher") {
                    const action = Actions.list.find(item => item.name === "Screenshot");
                    if (!action) {
                        console.error("GLAZIER_TEST_FAIL launcher action missing");
                        Qt.exit(1);
                        return;
                    }
                    action.onClicked(appList);
                } else if (route === "shortcut") {
                    shortcuts.screenshotShortcut.pressed();
                } else if (route === "ipc") {
                    ipc.running = true;
                } else {
                    Glazier.capture();
                    timeoutCheck.start();
                }
            }
            if (!root.hiding && root.allDismissed()) {
                root.hiding = true;
                if (Quickshell.env("GLAZIER_ROUTE") !== "timeout")
                    hideTimer.start();
            }
            if (root.hiding && !Glazier.pendingPath && root.ticks > 35
                    && (Quickshell.env("GLAZIER_ROUTE") !== "ipc" || root.ipcDone)
                    && (Quickshell.env("GLAZIER_ROUTE") !== "timeout" || root.timeoutChecked)) {
                console.log("GLAZIER_TEST_PASS");
                Qt.quit();
            }
        }
    }
}
