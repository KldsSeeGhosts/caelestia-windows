// Count-only offscreen host. No production entry, windows or capture host.
import QtQuick
import Quickshell
import Quickshell.Io
import qs.services

ShellRoot {
    id: root
    settings.watchFiles: false
    property bool measuring: false
    property real begin: 0
    property int ticks: 0
    property int plantedTicks: 0
    property int assertions: 0
    readonly property bool testing: Quickshell.env("CAELESTIA_IDLE_TEST") === "1"
    readonly property bool plant: Quickshell.env("CAELESTIA_IDLE_PLANT") === "1"
    function check(ok, message) {
        if (!ok) {
            console.error("CAELESTIA_IDLE_FAIL " + message);
            Qt.quit();
        }
        assertions++;
    }
    Connections {
        target: Time
        function onDateChanged() { if (root.measuring) root.ticks++; }
    }
    Component.onCompleted: {
        // Instantiate only these services, with all paths in the disposable stage.
        console.log("CAELESTIA_IDLE_INIT " + Recorder.outputDir + Time.timeStr);
    }
    Timer {
        interval: 2000
        running: true
        onTriggered: {
            root.check(!Recorder.baselinePending && Recorder.state === "idle", "startup baseline");
            root.check(Recorder.outputDir === "C:/synthetic/recordings", "output directory");
            if (root.testing) {
                root.check(!Recorder.statusNeeded, "idle status must sleep");
                root.check(Time.secondsConsumers === 0 && Time.seconds === 0, "minute default");
                Time.retainSeconds();
                Time.retainSeconds();
                root.check(Time.secondsConsumers === 2, "two consumers");
                Time.releaseSeconds();
                root.check(Time.secondsConsumers === 1, "one consumer remains");
                Time.releaseSeconds();
                root.check(Time.secondsConsumers === 0 && Time.seconds === 0, "minute restored");
                Recorder.refCount++;
                root.check(Recorder.statusNeeded, "open card");
                Recorder.refCount--;
                root.check(!Recorder.statusNeeded, "closed card");
                Recorder.pendingStart = true;
                root.check(Recorder.statusNeeded, "starting");
                Recorder.pendingStart = false;
                Recorder.state = "recording";
                root.check(Recorder.statusNeeded, "active recovery");
                Recorder.disconnected("synthetic");
                root.check(Recorder.recovering && Recorder.statusNeeded, "disconnected active recovery");
                Recorder.applyResponse(JSON.stringify({version: 1, ok: true, host_id: "synthetic",
                    state: "idle", elapsed_ms: 0, output_directory: "C:/synthetic/recordings", events: []}));
                root.check(!Recorder.statusNeeded, "healthy idle ends recovery");
            }
            if (root.testing) {
                root.ticks = 0;
                root.measuring = true;
                Time.retainSeconds();
                Time.retainSeconds();
                Time.releaseSeconds();
                secondsCheck.start();
            } else {
                settle.start();
            }
        }
    }
    Timer {
        id: secondsCheck
        interval: 2200
        onTriggered: {
            root.check(root.ticks >= 2, "remaining seconds consumer keeps second precision");
            Time.releaseSeconds();
            root.measuring = false;
            root.ticks = 0;
            settle.start();
        }
    }
    Timer {
        id: settle
        interval: 1000
        onTriggered: {
            root.begin = Date.now();
            root.measuring = true;
            finish.start();
        }
    }
    Timer {
        interval: 1000
        running: root.measuring && root.plant
        repeat: true
        onTriggered: root.plantedTicks++
    }
    Process {
        id: plantedProcess
        command: [Recorder.executable, "--status"]
    }
    Timer {
        interval: 15000
        running: root.measuring && root.plant
        repeat: true
        onTriggered: plantedProcess.running = true
    }
    Timer {
        id: finish
        interval: Number(Quickshell.env("CAELESTIA_IDLE_SECONDS")) * 1000 + 250
        onTriggered: {
            root.measuring = false;
            console.log("CAELESTIA_IDLE_RESULT " + JSON.stringify({
                assertions: root.assertions, begin: root.begin, end: Date.now(),
                clockWakeups: root.ticks, plantedWakeups: root.plantedTicks
            }));
            Qt.quit();
        }
    }
}
