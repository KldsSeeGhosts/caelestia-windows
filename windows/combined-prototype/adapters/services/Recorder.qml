pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Windows adaptation of the upstream Recorder singleton.
//
// Upstream drives `caelestia record` / gpu-screen-recorder over pidof. Neither
// exists on Windows, so this adapter drives ffmpeg directly:
//
//   * availability is `where ffmpeg` on PATH (probed in Live mode only);
//   * capture is gdigrab's `desktop` input, H.264 in MP4, written to
//     %USERPROFILE%\Videos\Caelestia\recording_<timestamp>.mp4;
//   * stopping writes `q` to ffmpeg's stdin so the MP4 is finalised, with a
//     bounded kill if ffmpeg does not exit.
//
// The upstream contract (running/paused/elapsed/refCount/start/stop/
// togglePause) is preserved for the original utilities card. Region capture,
// audio capture and pause have no ffmpeg route here; they are reported as
// unsupported instead of silently recording something else.
Singleton {
    id: root

    readonly property bool permitted: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    readonly property string outputDir: (Quickshell.env("USERPROFILE") || "") + "\\Videos\\Caelestia"

    // Upstream contract, read by modules/utilities/cards/Record.qml.
    property bool running: false
    property bool paused: false
    property real elapsed: 0
    property int refCount: 0
    property bool stopping: false

    // Availability and diagnostics.
    property bool probed: false
    property bool available: false
    property string ffmpegPath: ""
    property string lastFile: ""
    property string lastError: ""
    property bool pendingStart: false

    readonly property bool canStart: root.permitted && root.available && !root.running && !root.pendingStart

    // One line for the card. The toggle only records when Live controls are on.
    readonly property string status: {
        if (root.running)
            return root.paused ? "Paused" : "Running...";
        if (!root.permitted)
            return Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1" ? "Suppressed during smoke." : "Live controls are off.";
        if (!root.probed)
            return "Checking ffmpeg...";
        if (!root.available)
            return "Unavailable: ffmpeg was not found on PATH.";
        return "Ready";
    }

    function timestamp(date): string {
        const pad = value => String(value).padStart(2, "0");
        return `${date.getFullYear()}${pad(date.getMonth() + 1)}${pad(date.getDate())}_${pad(date.getHours())}-${pad(date.getMinutes())}-${pad(date.getSeconds())}`;
    }

    function start(extraArgs = []): bool {
        if (!root.permitted || !root.available || root.running || root.pendingStart)
            return false;
        if (extraArgs.length > 0) {
            root.lastError = "Region and audio capture are not implemented on the Windows recorder.";
            return false;
        }

        root.lastError = "";
        root.pendingStart = true;
        // ffmpeg does not create parent directories.
        mkdirProcess.command = [
            "powershell", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command",
            "New-Item -ItemType Directory -Force -Path '" + root.outputDir.replace(/'/g, "''") + "' | Out-Null"
        ];
        mkdirProcess.running = true;
        return true;
    }

    function beginCapture(): void {
        root.lastError = "";
        root.lastFile = "";
        root.captureFile = root.outputDir + "\\recording_" + root.timestamp(new Date()) + ".mp4";
        captureProcess.command = [
            root.ffmpegPath, "-hide_banner", "-loglevel", "error", "-y",
            "-f", "gdigrab", "-framerate", "30", "-i", "desktop",
            "-c:v", "libx264", "-preset", "ultrafast", "-crf", "23", "-pix_fmt", "yuv420p",
            root.captureFile
        ];
        captureProcess.running = true;
        root.pendingStart = false;
        root.running = true;
        root.paused = false;
        root.elapsed = 0;
    }

    function stop(): void {
        if (!root.running)
            return;
        if (captureProcess.running) {
            root.stopping = true;
            // `q` makes ffmpeg flush the container instead of leaving a
            // truncated MP4; the timer is only a fallback for a stuck process.
            captureProcess.write("q\n");
            killTimer.restart();
            return;
        }
        root.running = false;
        root.elapsed = 0;
    }

    function togglePause(): void {
        // ffmpeg cannot pause a live capture; the original pause affordance is
        // hidden by the Windows card instead of pretending it worked.
        root.lastError = "Pausing is not implemented on the Windows recorder.";
    }

    property string captureFile

    // Availability probe. It only runs with Live controls, so read-only and
    // smoke runs never launch a process.
    Process {
        id: probeProcess

        running: root.permitted && !root.probed
        command: ["where", "ffmpeg"]

        stdout: StdioCollector {
            onStreamFinished: {
                const lines = text.trim().split(/\r?\n/).filter(line => line.trim().length > 0);
                if (lines.length > 0) {
                    root.ffmpegPath = lines[0].trim();
                    root.available = true;
                }
            }
        }

        stderr: StdioCollector {}

        onExited: code => {
            root.probed = true;
            if (code !== 0 || root.ffmpegPath === "") {
                root.available = false;
                root.ffmpegPath = "";
            }
        }
    }

    Process {
        id: mkdirProcess

        onExited: code => {
            if (!root.pendingStart)
                return;
            if (code !== 0) {
                root.pendingStart = false;
                root.lastError = "Could not create " + root.outputDir + ".";
                return;
            }
            root.beginCapture();
        }
    }

    Process {
        id: captureProcess

        stdinEnabled: true

        stderr: StdioCollector {
            onStreamFinished: {
                const message = text.trim();
                if (message.length > 0)
                    root.lastError = message.split(/\r?\n/)[0];
            }
        }

        onExited: code => {
            killTimer.stop();
            if (root.stopping)
                root.lastFile = root.captureFile;
            if (code !== 0 && code !== 255 && root.lastError === "")
                root.lastError = "ffmpeg exited with code " + code + ".";
            root.running = false;
            root.paused = false;
            root.stopping = false;
            root.pendingStart = false;
            root.elapsed = 0;
        }
    }

    Timer {
        id: killTimer

        interval: 6000
        onTriggered: {
            if (captureProcess.running)
                captureProcess.running = false;
        }
    }

    // Only advance the clock while something is reading it.
    Timer {
        interval: 1000
        running: root.running && !root.paused
        repeat: true
        onTriggered: root.elapsed++
    }
}
