pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io
import Quickshell.Windows as Native

// Windows: Glazier owns capture, audio, timing and MP4 finalization. Never infer
// a successful recording from the lifetime of the short-lived command client.
Singleton {
    id: root

    readonly property bool permitted: Quickshell.env("CAELESTIA_COMBINED_LIVE") === "1"
        && Quickshell.env("CAELESTIA_SHELL_SMOKE") !== "1"
    property int refCount: 0
    property string executable: ""
    property bool probed: false
    property bool available: false
    property string state: "idle"
    property real elapsed: 0
    property string outputDir: ""
    // Exclude Glazier's unpublished .glazier-*.mp4 files, including on Windows.
    readonly property var nameFilters: ["[!.]*.mp4"]
    property string lastFile: ""
    // Normalized paths Glazier reported as finished (newest 500, persisted); the
    // only files Delete may remove.
    property var finishedFiles: []
    property string lastError: ""
    property string connectionError: ""
    property bool pendingStart: false
    // Only the shell's initial observation can contain pre-restart errors.
    property bool baselinePending: true
    property string hostId: ""
    property real eventSequence: 0
    property bool connectionFailed: false
    property bool incompatible: false
    readonly property bool running: ["recording", "paused", "finalizing"].indexOf(state) !== -1
    readonly property bool paused: state === "paused"
    readonly property bool stopping: state === "finalizing"
    // Fast only while healthy and something is happening or the card is open;
    // a failed host retries slowly and a quiet shell polls occasionally.
    readonly property bool pollFast: pendingStart || (!connectionFailed && (state !== "idle" || refCount > 0))
    // Observe the initial journal (or stopped host) before accepting Start;
    // protocol v1 cannot distinguish old errors from a pre-baseline attempt.
    readonly property bool canStart: permitted && available && !incompatible && !baselinePending && state === "idle" && !pendingStart
    readonly property string status: {
        if (!permitted)
            return Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1" ? "Suppressed during smoke." : "Live controls are off.";
        if (lastError)
            return lastError;
        if (connectionError)
            return connectionError;
        if (!probed)
            return "Checking Glazier...";
        if (!available)
            return "Unavailable: install Glazier with control protocol v1.";
        if (pendingStart)
            return "Starting Glazier...";
        return ({ idle: "Ready", selecting: "Select a region in Glazier", ready: "Ready in Glazier",
            recording: "Running...", paused: "Paused", finalizing: "Saving recording..." })[state];
    }

    function disconnected(message): void {
        connectionFailed = true;
        state = "idle";
        elapsed = 0;
        pendingStart = false;
        connectionError = message;
    }

    function normalize(path): string {
        return path.replace(/\\/g, "/").toLowerCase();
    }

    function owns(path): bool {
        return typeof path === "string" && finishedFiles.indexOf(normalize(path)) !== -1;
    }

    function remember(path): void {
        if (owns(path))
            return;
        finishedFiles = [...finishedFiles, normalize(path)].slice(-500);
        if (store.restored)
            store.setText(JSON.stringify(finishedFiles));
    }

    FileView {
        id: store
        property bool restored
        function finish(): void {
            restored = true;
            if (root.finishedFiles.length)
                setText(JSON.stringify(root.finishedFiles));
        }
        path: root.permitted ? Quickshell.stateDir.replace(/\\/g, "/") + "/caelestia/recordings.json" : ""
        atomicWrites: true
        printErrors: false
        onLoaded: {
            try {
                const saved = JSON.parse(text());
                if (Array.isArray(saved))
                    root.finishedFiles = [...new Set([...saved.filter(p => typeof p === "string"), ...root.finishedFiles])].slice(-500);
            } catch (_) {} // corrupt: start over from what Glazier reports
            finish();
        }
        onLoadFailed: finish() // no file yet; keep what finished before the read failed
    }

    function applyResponse(text): bool {
        // Empty, partial or malformed output (for example from a client killed
        // by the watchdog) is a transient poll failure, not a protocol
        // mismatch, so it must not disable the recorder until reload.
        if (!text.trim()) {
            disconnected("Glazier is not responding.");
            return false;
        }
        let data;
        try {
            data = JSON.parse(text.trim());
        } catch (_) {
            disconnected("Glazier returned an unreadable status response.");
            return false;
        }
        if (data === null || typeof data !== "object" || Array.isArray(data)) {
            disconnected("Glazier returned an unreadable status response.");
            return false;
        }
        if (typeof data.version === "number" && data.version !== 1) {
            // A parsed status that names another protocol version is explicit
            // incompatibility; a valid compatible response clears it.
            available = false;
            incompatible = true;
            disconnected("Glazier is incompatible: control protocol v1 is required.");
            return false;
        }
        if (data.version !== 1 || typeof data.ok !== "boolean") {
            disconnected("Glazier returned an incomplete status response.");
            return false;
        }
        if (!data.ok && !data.host_id) {
            // A v1 offline response still proves the CLI binary speaks the
            // supported protocol, so clear any prior incompatibility and allow
            // Start to launch Glazier. Keep pendingStart until it responds.
            incompatible = false;
            available = Boolean(executable);
            baselinePending = false; // a future host starts during this shell session
            if (!pendingStart)
                disconnected("Glazier stopped");
            return false;
        }
        if (["idle", "selecting", "ready", "recording", "paused", "finalizing"].indexOf(data.state) < 0
                || !Number.isFinite(data.elapsed_ms) || data.elapsed_ms < 0
                || typeof data.host_id !== "string" || typeof data.output_directory !== "string"
                || !Array.isArray(data.events)) {
            disconnected("Glazier returned an invalid recorder state.");
            return false;
        }
        available = true;
        incompatible = false;
        connectionError = "";
        connectionFailed = false;
        state = data.state;
        elapsed = data.elapsed_ms / 1000;
        outputDir = data.output_directory.replace(/\\/g, "/");
        // A confirmed recording also recovers a failed Start if its started
        // event has already rolled out of Glazier's bounded journal.
        if (running)
            lastError = "";
        // Baseline once on shell startup, not on every host change. After an
        // offline observation, a new host's errors are fresh.
        const replay = baselinePending;
        baselinePending = false;
        if (hostId !== data.host_id) {
            hostId = data.host_id;
            eventSequence = 0;
        }
        for (const event of data.events) {
            if (event.sequence <= eventSequence)
                continue;
            eventSequence = event.sequence;
            if (event.type === "finished" && typeof event.output_path === "string") {
                remember(event.output_path);
                if (!replay)
                    lastFile = event.output_path;
            }
            if (replay)
                continue;
            if (event.type === "error")
                lastError = event.message || "Glazier recording failed.";
            else if (event.type === "started")
                lastError = "";
            if (state === "idle" && ["finished", "cancelled", "error"].indexOf(event.type) !== -1) {
                pendingStart = false;
                startTimeout.stop();
            }
        }
        if (!data.ok)
            lastError = data.error || "Glazier command failed.";
        if (state !== "idle") {
            pendingStart = false;
            startTimeout.stop();
        }
        return true;
    }

    function start(extraArgs = []): bool {
        if (!canStart)
            return false;
        let region = false;
        let sound = false;
        for (const arg of extraArgs) {
            if (!/^-[sr]+$/.test(arg)) {
                lastError = "Unsupported recording option: " + arg;
                return false;
            }
            region = region || arg.indexOf("r") !== -1;
            sound = sound || arg.indexOf("s") !== -1;
        }
        const args = [executable, "--record", "--system-sound", sound ? "on" : "off", "--mic", "off"];
        if (!region)
            args.push("--fullscreen");
        lastError = "";
        connectionError = "";
        lastFile = "";
        pendingStart = true;
        // #81: the backend detached path redirects all stdio to NUL and disowns
        // handles. Do not host the long-lived tray app in a QML Process.
        // Start in Glazier's own folder so it never holds the shell's (install prefix) cwd.
        Quickshell.execDetached({ command: args, workingDirectory: executable.replace(/[\\/][^\\/]*$/, "") });
        startTimeout.restart();
        return true;
    }

    function send(command): void {
        if (!permitted || !available || commandProcess.running)
            return;
        commandProcess.command = [executable, command];
        commandProcess.running = true;
    }

    function stop(): void {
        if (running || state === "selecting" || state === "ready")
            send("--stop");
    }

    function togglePause(): void {
        if (state === "recording" || paused)
            send(paused ? "--resume" : "--pause");
    }

    // Resolve with native path checks instead of a PowerShell child: a missing
    // Glazier is re-probed every 30 s, and that periodic probe must not spawn a
    // process (or a 30-80 MB interpreter) each time.
    function probe(): void {
        if (!permitted)
            return;
        const override = Quickshell.env("CAELESTIA_GLAZIER_EXE") || "";
        let found = "";
        if (override) {
            found = Native.FsUtils.classify(override) === "file" ? override : "";
        } else {
            const installed = (Quickshell.env("LOCALAPPDATA") || "") + "/Programs/Glazier/glazier.exe";
            found = Native.FsUtils.classify(installed) === "file" ? installed
                : Native.FsUtils.findExecutable("glazier.exe");
        }
        executable = found;
        available = found !== "";
        probed = true;
        if (found) {
            lastError = "";
            poll();
        } else {
            lastError = "Glazier was not found. Install Glazier with control protocol v1.";
        }
    }

    Component.onCompleted: probe()

    function poll(): void {
        if (permitted && executable && !statusProcess.running && !commandProcess.running)
            statusProcess.running = true;
    }

    Process {
        id: statusProcess
        command: [root.executable, "--status"]
        stdout: StdioCollector { onStreamFinished: root.applyResponse(text) }
    }

    Process {
        id: commandProcess
        stdout: StdioCollector { onStreamFinished: root.applyResponse(text) }
    }

    // Poll even when the card is closed: tray/hotkey actions must be reflected.
    // Fast only when active or open; retry a failed host at 5 s, idle at 15 s.
    // 1 s is plenty for Glazier's seconds-granularity state changes and halves
    // the status-client spawn rate while recording.
    Timer {
        interval: root.pollFast ? 1000 : root.connectionFailed ? 5000 : 15000
        running: root.permitted && root.executable !== ""
        repeat: true
        onTriggered: root.poll()
    }

    // Notice a Glazier installed while the shell is running. The probe is a
    // native path check, so a 30 s re-check costs no process creation.
    Timer {
        interval: 30000
        running: root.permitted && root.probed && root.executable === ""
        repeat: true
        onTriggered: root.probe()
    }

    Timer {
        interval: 16000
        running: statusProcess.running || commandProcess.running
        onTriggered: {
            statusProcess.running = false;
            commandProcess.running = false;
            root.disconnected("Glazier control timed out.");
        }
    }

    Timer {
        id: startTimeout
        interval: 15000
        onTriggered: {
            if (root.pendingStart) {
                root.pendingStart = false;
                // A healthy idle reply is not a successful Start. Keep this
                // failure until a new attempt or a started event, like errors
                // reported by Glazier itself.
                root.lastError = "Glazier did not start recording. Check Glazier and its control protocol version.";
            }
        }
    }
}
