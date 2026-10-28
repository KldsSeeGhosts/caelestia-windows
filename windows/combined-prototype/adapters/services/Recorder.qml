pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

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
    property bool pendingStart: false
    property string hostId: ""
    property real eventSequence: 0
    property bool connectionFailed: false
    property bool incompatible: false
    readonly property bool running: ["recording", "paused", "finalizing"].indexOf(state) !== -1
    readonly property bool paused: state === "paused"
    readonly property bool stopping: state === "finalizing"
    readonly property bool canStart: permitted && available && !incompatible && state === "idle" && !pendingStart
    readonly property string status: {
        if (!permitted)
            return Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1" ? "Suppressed during smoke." : "Live controls are off.";
        if (lastError)
            return lastError;
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
        lastError = message;
    }

    function normalize(path): string {
        return path.replace(/\\/g, "/").toLowerCase();
    }

    function owns(path): bool {
        return finishedFiles.indexOf(normalize(path)) !== -1;
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
        path: root.permitted ? Quickshell.stateDir.replace(/\\/g, "/") + "/caelestia/recordings.json" : ""
        atomicWrites: true
        printErrors: false
        onLoaded: {
            try {
                const saved = JSON.parse(text());
                if (Array.isArray(saved))
                    root.finishedFiles = [...new Set([...saved.filter(p => typeof p === "string"), ...root.finishedFiles])].slice(-500);
            } catch (_) {} // corrupt: start over from what Glazier reports
            restored = true;
            if (root.finishedFiles.length)
                setText(JSON.stringify(root.finishedFiles));
        }
        onLoadFailed: restored = true // no file yet
    }

    function applyResponse(text): bool {
        // A killed or crashed client finishes with no output: a transient
        // disconnect, not an incompatible host.
        if (!text.trim()) {
            disconnected("Glazier is not responding.");
            return false;
        }
        let data;
        try {
            data = JSON.parse(text.trim());
        } catch (_) {
            available = false;
            incompatible = true;
            disconnected("Glazier is incompatible: control protocol v1 is required.");
            return false;
        }
        if (data.version !== 1 || typeof data.ok !== "boolean") {
            available = false;
            incompatible = true;
            disconnected("Glazier is incompatible: control protocol v1 is required.");
            return false;
        }
        if (!data.ok && !data.host_id) {
            // A cold host may take a moment to create its pipe after detached
            // launch. Keep the pending start until it responds or times out.
            if (!pendingStart)
                disconnected("Glazier is not running (Start launches it).");
            return false;
        }
        if (["idle", "selecting", "ready", "recording", "paused", "finalizing"].indexOf(data.state) < 0
                || !Number.isFinite(data.elapsed_ms) || data.elapsed_ms < 0
                || typeof data.host_id !== "string" || typeof data.output_directory !== "string"
                || !Array.isArray(data.events)) {
            available = false;
            incompatible = true;
            disconnected("Glazier returned an invalid recorder state.");
            return false;
        }
        available = true;
        if (connectionFailed)
            lastError = "";
        connectionFailed = false;
        state = data.state;
        elapsed = data.elapsed_ms / 1000;
        outputDir = data.output_directory.replace(/\\/g, "/");
        // The first response from a host is its baseline: that journal predates
        // this shell, so only note finished files and keep old errors quiet.
        const replay = hostId !== data.host_id;
        if (replay) {
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

    Process {
        id: probe
        running: root.permitted && !root.probed
        command: ["powershell.exe", "-NoProfile", "-NonInteractive", "-WindowStyle", "Hidden", "-Command",
            "$override=$env:CAELESTIA_GLAZIER_EXE; if ($override) { if (Test-Path -LiteralPath $override -PathType Leaf) { $override }; exit }; "
            + "$installed=Join-Path $env:LOCALAPPDATA 'Programs\\Glazier\\glazier.exe'; "
            + "if (Test-Path -LiteralPath $installed -PathType Leaf) { $installed } "
            + "else { $cmd=Get-Command glazier.exe -ErrorAction SilentlyContinue; if ($cmd) { $cmd.Source } }"]
        stdout: StdioCollector {
            onStreamFinished: {
                root.executable = text.trim();
                root.available = root.executable !== "";
            }
        }
        onExited: code => {
            root.probed = true;
            if (code !== 0 || root.executable === "") {
                root.available = false;
                root.lastError = "Glazier was not found. Install Glazier with control protocol v1.";
            } else {
                root.lastError = "";
                root.poll();
            }
        }
    }

    function poll(): void {
        if (permitted && executable && !incompatible && !statusProcess.running && !commandProcess.running)
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
    // Fast only while something is happening or the card is open.
    Timer {
        interval: root.pendingStart || (!root.connectionFailed && (root.state !== "idle" || root.refCount > 0)) ? 500 : 5000
        running: root.permitted && root.executable !== ""
        repeat: true
        onTriggered: root.poll()
    }

    // Notice a Glazier installed while the shell is running.
    Timer {
        interval: 30000
        running: root.permitted && root.probed && root.executable === ""
        repeat: true
        onTriggered: root.probed = false
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
            if (root.pendingStart)
                root.disconnected("Glazier did not start recording. Check Glazier and its control protocol version.");
        }
    }
}
