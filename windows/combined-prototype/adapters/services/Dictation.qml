pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import "DictationLogic.js" as Logic

// Windows status-only adapter. No microphone, ASR process, transcript storage,
// Linux command fallback, or cancellation claim.
Singleton {
    id: root

    readonly property bool enabled: Quickshell.env("CAELESTIA_WINDOWS_DICTATION") === "1"
    readonly property string statePath: Quickshell.env("CAELESTIA_DICTATION_STATE")
        || (Quickshell.env("CAELESTIA_RUNTIME_DIR")
            ? Quickshell.env("CAELESTIA_RUNTIME_DIR") + "/dictation-state.json" : "")
    readonly property string idleState: "idle"
    readonly property string listeningState: "listening"
    readonly property string processingState: "processing"
    readonly property string doneState: "done"
    readonly property string errorState: "error"
    readonly property int doneDurationMs: Logic.doneDurationMs
    readonly property int errorDurationMs: Logic.errorDurationMs
    readonly property bool canCancel: false

    property string state: idleState
    property string screenName: ""
    property double startedAt: 0
    property double updatedAt: 0
    property int elapsedSeconds: 0
    readonly property bool active: state !== idleState

    function reset(): void {
        state = idleState;
        screenName = "";
        startedAt = 0;
        updatedAt = 0;
        elapsedSeconds = 0;
        dismissTimer.stop();
    }

    function applyState(data): void {
        if (!enabled) {
            reset();
            return;
        }
        const next = Logic.normalize(data, Date.now());
        state = next.state;
        screenName = next.screenName;
        startedAt = next.startedAt;
        updatedAt = next.updatedAt;
        elapsedSeconds = state === listeningState && startedAt > 0
            ? Math.max(0, Math.floor(Date.now() / 1000 - startedAt)) : 0;
        dismissTimer.stop();
        const duration = Logic.durationMsFor(state);
        if (duration > 0) {
            dismissTimer.interval = Math.max(1,
                Math.ceil(duration - Math.max(0, Date.now() - updatedAt * 1000)));
            dismissTimer.start();
        }
    }

    function refresh(): void {
        if (reader.item)
            reader.item.reload();
    }

    Loader {
        id: reader
        active: root.enabled && root.statePath.length > 0
        sourceComponent: FileView {
            path: root.statePath
            printErrors: false
            watchChanges: true
            onLoaded: {
                try {
                    root.applyState(JSON.parse(text()));
                } catch (_) {
                    root.reset();
                }
            }
            onFileChanged: reload()
            // Every failure clears stale listening, including access denial.
            onLoadFailed: root.reset()
        }
    }

    Timer {
        // Also recovers missing files and atomic replacements on Windows.
        interval: 1000
        repeat: true
        running: root.enabled && root.statePath.length > 0
        onTriggered: {
            root.elapsedSeconds = root.state === root.listeningState && root.startedAt > 0
                ? Math.max(0, Math.floor(Date.now() / 1000 - root.startedAt)) : 0;
            root.refresh();
        }
    }
    Timer {
        id: dismissTimer
        onTriggered: root.reset()
    }

    IpcHandler {
        target: "dictation"
        function refresh(): void { root.refresh(); }
        function getState(): string { return root.state; }
    }
}
