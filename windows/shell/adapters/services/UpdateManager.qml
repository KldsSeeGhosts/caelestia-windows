pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Keep an accepted request alive when the Nexus page/window closes.
QtObject {
    id: root
    property bool submitted: false
    property bool failed: false
    property string operationId: ""

    function request(command: var): void {
        if (submitted || process.running || Quickshell.env("CAELESTIA_SHELL_SMOKE") === "1")
            return;
        failed = false;
        submitted = true;
        operationId = "";
        process.command = command;
        process.running = true;
    }

    function loadOperation(): void {
        try {
            const data = JSON.parse(operationFile.text());
            if (data.schema === 1 && data.operationId === operationId && data.phase === "failed") {
                submitted = false;
                failed = true;
            }
        } catch (error) { }
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
            root.submitted = false;
            root.failed = true;
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
            root.submitted = false;
            root.failed = true;
        }
    }
}
