import QtQuick
import Quickshell
import Caelestia
import Caelestia.Config
import qs.services
import qs.modules.areapicker

// Offscreen and fake providers only. Never starts the helper or a capture.
ShellRoot {
    id: root
    Tokens.screen: Quickshell.screens[0]?.name ?? ""
    property int assertions: 0
    property QtObject dismissal: QtObject {
        property int hiddenTimeout: 100
        function dismiss() {}
        function surfacesHidden() { return true; }
    }
    property QtObject picker: QtObject {
        property bool interactionEnabled: true
        property bool opened: false
        property bool mode: false
        property bool sound: false
        function open(recording, systemSound) { opened = true; mode = recording; sound = systemSound; }
    }
    property QtObject recorder: QtObject {
        property string state: "idle"
        property real elapsed: 0
        property bool mic: false
        property bool sound: false
        property bool running: ["recording", "paused", "finalizing"].indexOf(state) !== -1
        property var shellRegion: null
        property string lastCommand: ""
        property var startArgs: []
        function startRegion(region, args) { shellRegion = region; startArgs = args; state = "recording"; return true; }
        function togglePause() { lastCommand = state === "paused" ? "--resume" : "--pause"; state = state === "paused" ? "recording" : "paused"; }
        function stop() { lastCommand = "--stop"; state = "finalizing"; }
        function discard() { lastCommand = "--discard"; state = "finalizing"; }
        function toggleMic() { mic = !mic; }
        function toggleSound() { sound = !sound; }
    }
    AreaPicker {
        history: null
        id: area
        interactionEnabled: false
        recorder: root.recorder
    }
    Item {
        RecordingBar { id: bar; recorder: root.recorder }
    }
    RecordingOverlay { id: overlay; recorder: root.recorder }
    property double overlayDeadline
    Timer {
        id: verifyOverlay
        interval: 25
        repeat: true
        onTriggered: {
            const ready = overlay.active && overlay.displays.length === Quickshell.screens.length
                && overlay.displays[0]?.borderWindow && overlay.displays[0]?.controlsWindow;
            if (!ready && Date.now() < root.overlayDeadline)
                return;
            stop();
            try {
                check(ready, "overlay restores from helper status");
                const display = overlay.displays[0];
                check(display.borderWindow.excludeFromCapture && display.controlsWindow.excludeFromCapture, "both windows excluded");
                check(display.borderWindow.mask !== null && display.controlsWindow.mask !== null, "desktop input masks");
                recorder.state = "idle";
                check(!overlay.active, "stopped recording removes overlays");
                CaptureUi.picker = null;
                CaptureUi.glazierProvider = Glazier;
                console.log("CAELESTIA_CAPTURE_RECORDING_PASS " + assertions);
                Qt.quit();
            } catch (e) {
                console.error("CAELESTIA_CAPTURE_RECORDING_FAIL " + e);
                Qt.exit(1);
            }
        }
    }
    function check(value, message) {
        assertions++;
        if (!value) throw new Error(message);
    }
    Component.onCompleted: Qt.callLater(() => {
        try {
            CaptureUi.glazierProvider = dismissal;
            CaptureUi.picker = picker;
            GlobalConfig.windows = { capture: { ui: "classic" } };
            check(CaptureUi.record() && picker.opened && picker.mode && !picker.sound, "saved classic setting still uses the shell picker");
            picker.opened = false;
            check(CaptureUi.record(true) && picker.opened && picker.mode && picker.sound, "region recording carries the audio choice");
            area.recordingMode = true;
            area.recordingSound = picker.sound;
            const screen = { x: -2560, y: 120, width: 1600, height: 900 };
            area.acceptSelection({ geometry: screen, dpr: 1.5 }, { logical: { x: 10, y: 20, width: 101, height: 61 } });
            check(recorder.shellRegion.x === -2545 && recorder.shellRegion.y === 150, "physical monitor offset");
            check(recorder.shellRegion.w === 152 && recorder.shellRegion.h === 92, "even physical dimensions");
            check(recorder.startArgs.join(" ").includes("--no-ui --mic off --system-sound on"), "helper starts without its own UI and with sound");
            check(!area.editing && !area.opened, "record does not open the editor");
            check(bar.primaryAction === "pause" && recorder.state === "recording", "recording controls");
            recorder.elapsed = 69.8;
            check(bar.timerText === "01:09", "MM:SS timer");
            bar.perform("pause");
            check(recorder.state === "paused" && recorder.lastCommand === "--pause" && bar.primaryAction === "resume", "pause");
            check(bar.timerText === "01:09", "paused time stays");
            bar.perform("resume");
            check(recorder.state === "recording" && recorder.lastCommand === "--resume", "resume");
            bar.perform("mic");
            bar.perform("sound");
            check(recorder.mic && recorder.sound, "audio on");
            bar.perform("mic");
            bar.perform("sound");
            check(!recorder.mic && !recorder.sound, "audio off");
            bar.perform("stop");
            check(recorder.state === "finalizing" && recorder.lastCommand === "--stop", "stop");
            recorder.state = "idle";
            check(!recorder.running, "stopped");
            recorder.state = "recording";
            bar.perform("discard");
            check(recorder.lastCommand === "--discard" && recorder.state === "finalizing", "discard");
            recorder.state = "idle";
            check(!recorder.running, "discarded");
            recorder.elapsed = 3600;
            check(bar.timerText === "60:00", "timer beyond an hour");
            const s = Quickshell.screens[0];
            check(s !== undefined, "the fixture has an offscreen display");
            recorder.shellRegion = { x: s.x + 10, y: s.y + 10, w: 100, h: 100 };
            recorder.state = "recording";
            overlayDeadline = Date.now() + 5000;
            verifyOverlay.start();
        } catch (e) {
            console.error("CAELESTIA_CAPTURE_RECORDING_FAIL " + e);
            Qt.exit(1);
        }
    })
}
