import QtQuick
import Quickshell
import Quickshell.Io
import Caelestia
import Caelestia.Windows
import qs.services
import qs.daemons
import qs.modules.launcher
import qs.modules.launcher.services

// Offscreen dismissal contract. Panels are QML objects, so closing them emits
// the real visibleChanged signal; Glazier must wait for that signal and must
// never launch a capture while a surface is still visible.
ShellRoot {
    id: root

    property int ticks: 0
    property bool invoked: false
    property bool hiding: false
    property bool ipcDone: false
    property bool earlyChecked: false
    property bool timeoutChecked: false
    // Only the shell surface visibility is simulated; dismiss() still writes
    // the real ScreenState flags.
    property var states: [
        {bar: true, osd: true, session: true, launcher: true, dashboard: true, quota: true, utilities: true, sidebar: true},
        {bar: true, osd: true, session: true, launcher: true, dashboard: true, quota: true, utilities: true, sidebar: true}
    ]
    property var bars: [{closed: false, closeTray: function() { this.closed = true; }},
                        {closed: false, closeTray: function() { this.closed = true; }}]
    property var screens: ({screens: [0, 1]})
    property var provider: ({
        forScreen: function(screen) { return root.states[screen]; },
        componentsFor: function(screen) { return {panels: root.panels[screen], bar: root.bars[screen]}; }
    })
    property var panels: [panelA, panelB]
    property string route: Quickshell.env("GLAZIER_ROUTE") || ""
    property string stubOutput: Quickshell.env("GLAZIER_STUB_OUTPUT") || ""
    property real hiddenTimeout: Number(Quickshell.env("GLAZIER_HIDDEN_TIMEOUT") || 2000)

    component Surface: QtObject {
        property bool visible: true
    }
    component Panel: QtObject {
        property Surface osd: Surface {}
        property Surface session: Surface {}
        property Surface launcher: Surface {}
        property Surface dashboard: Surface {}
        property Surface quota: Surface {}
        property Surface utilities: Surface {}
        property Surface sidebar: Surface {}
        property Surface popoutsWrapper: Surface {}
        property QtObject popouts: QtObject {
            property bool closed: false
            function close(): void { closed = true; }
        }
    }

    Panel { id: panelA }
    Panel { id: panelB }

    function fail(message): void {
        console.error("GLAZIER_TEST_FAIL " + message);
        Qt.exit(1);
    }
    function allDismissed(): bool {
        // The bar stays as it was; hiding it would reflow tiled windows.
        return states.every((s, i) => Object.keys(s).every(key => key === "bar" ? s[key] : !s[key])
            && panels[i].popouts.closed && bars[i].closed);
    }
    function stopIfRunning(): void {
        if (Recorder.running || Recorder.state === "selecting" || Recorder.state === "ready")
            Recorder.stop();
    }

    Shortcuts { id: shortcuts }
    AppList { id: appList; screenState: root.states[0] }
    FileView {
        id: marker
        path: Quickshell.env("GLAZIER_DISMISS_MARKER")
        printErrors: false
        onSaved: {
            // The closing animation's end: this is the only event Glazier may
            // launch from.
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
                root.fail("IPC " + code);
                return;
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
        id: earlyCheck
        interval: Math.max(1, root.hiddenTimeout - 100)
        onTriggered: {
            if (!Glazier.pendingPath) {
                root.fail("dismissal launched before the surfaces reported hidden");
                return;
            }
            root.earlyChecked = true;
        }
    }
    Timer {
        id: timeoutCheck
        interval: root.hiddenTimeout + 150
        onTriggered: {
            if (Glazier.pendingPath) {
                root.fail("timeout did not clear the pending capture");
                return;
            }
            if (WindowsFiles.isFile(root.stubOutput)) {
                root.fail("timeout captured anyway");
                return;
            }
            if (!Array.from(Toaster.toasts).some(t => t.message === "Glazier is not ready. The shell is still on screen.")) {
                root.fail("timeout did not report not ready");
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
            if (++root.ticks > 250) {
                root.fail("timeout route=" + root.route + " pending=" + Glazier.pendingPath);
                return;
            }
            if (!Glazier.ready)
                return;
            if (!root.invoked) {
                Glazier.hiddenTimeout = root.hiddenTimeout;
                Glazier.screenProvider = root.screens;
                Glazier.stateProvider = root.provider;
                root.invoked = true;
                if (root.route === "launcher" || root.route === "recordAction") {
                    const name = root.route === "launcher" ? "Screenshot" : "Record screen";
                    const action = Actions.list.find(item => item.name === name);
                    if (!action) {
                        root.fail("launcher action missing: " + name);
                        return;
                    }
                    action.onClicked(appList);
                } else if (root.route === "shortcut") {
                    shortcuts.screenshotShortcut.pressed();
                } else if (root.route === "record") {
                    root.stopIfRunning();
                    shortcuts.recordShortcut.pressed();
                } else if (root.route === "ipc") {
                    ipc.running = true;
                } else {
                    if (!Glazier.capture()) {
                        root.fail("capture refused");
                        return;
                    }
                    earlyCheck.start();
                    timeoutCheck.start();
                }
                return;
            }
            if (!root.hiding && root.allDismissed()) {
                root.hiding = true;
                if (root.route !== "timeout")
                    hideTimer.start();
            }
            if (root.route === "timeout") {
                if (root.hiding && root.earlyChecked && root.timeoutChecked) {
                    console.log("GLAZIER_TEST_PASS");
                    Qt.quit();
                }
                return;
            }
            if (root.hiding && !Glazier.pendingPath && WindowsFiles.isFile(root.stubOutput)
                    && (root.route !== "ipc" || root.ipcDone)) {
                console.log("GLAZIER_TEST_PASS");
                Qt.quit();
            }
        }
    }
}
