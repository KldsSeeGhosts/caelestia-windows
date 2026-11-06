pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Keep an accepted request alive when the Nexus page/window closes.
QtObject {
    id: root
    // A missing acknowledgement/journal is uncertainty, not evidence that
    // rollback failed or cannot still run. Never offer a duplicate request.
    property string operationState: "idle" // idle | waiting | unconfirmed | failed | complete
    readonly property bool submitted: operationState === "waiting"
    readonly property bool failed: operationState === "failed"
    readonly property bool unconfirmed: operationState === "unconfirmed"
    readonly property bool complete: operationState === "complete"
    property string operationId: ""

    function request(command: var): void {
        if (submitted || unconfirmed || complete || process.running || Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1")
            return;
        operationState = "waiting";
        operationId = "";
        deadline.restart();
        process.command = command;
        process.running = true;
    }

    function loadOperation(): void {
        if (!operationId || failed || complete)
            return;
        try {
            const data = JSON.parse(operationFile.text());
            if (data.schema === 1 && data.operationId === operationId && (data.phase === "failed" || data.phase === "complete")) {
                deadline.stop();
                operationState = data.phase;
            }
        } catch (error) { }
    }

    // Includes queue startup, not only the period after an ID is returned.
    // The default maintenance worker/watchdog bounds fit within ten minutes.
    // This timer changes only local UI state; it neither cancels the worker
    // nor writes a journal through another transaction's prefix lock.
    property Timer deadline: Timer {
        id: deadline
        interval: 600000
        onTriggered: {
            if (root.submitted)
                root.operationState = "unconfirmed";
        }
    }

    property Process process: Process {
        id: process
        stdout: StdioCollector { id: output }
        onExited: code => {
            if (code === 0) {
                try {
                    const data = JSON.parse(output.text.trim());
                    if (typeof data.operationId === "string" && /^[a-f0-9]{32}$/.test(data.operationId)) {
                        root.operationId = data.operationId;
                        return;
                    }
                } catch (error) { }
            }
            deadline.stop();
            root.operationState = "failed";
            console.warn(`CAELESTIA_UPDATES_ROLLBACK_FAIL exit=${code}`);
        }
    }
    property FileView operationFile: FileView {
        id: operationFile
        path: root.operationId !== ""
            ? `${Quickshell.env("CAELESTIA_PROFILE_ROOT")}/state/update-operation.json` : ""
        watchChanges: true
        printErrors: false
        onLoaded: root.loadOperation()
        onFileChanged: reload()
        onLoadFailed: {
            if (root.operationId && !root.failed && !root.complete) {
                deadline.stop();
                root.operationState = "unconfirmed";
            }
        }
    }
}
