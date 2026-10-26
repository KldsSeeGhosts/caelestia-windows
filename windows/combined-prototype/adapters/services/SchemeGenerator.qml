pragma Singleton

import QtQuick
import Quickshell
import Quickshell.Io

// Windows adaptation: runs the profile-local scheme bridge, which uses the
// upstream caelestia CLI's own material generator and writes the scheme JSON
// that Colours.qml watches. The launcher's scheme/variant rows, the wallpaper
// picker and the light/dark actions all call this singleton.
//
// The bridge is provisioned by Install-SchemeRuntime.ps1 under the isolated
// combined profile. When it is absent every call is a reported no-op, so the
// shell keeps its fixed palette instead of failing to start.
Singleton {
    id: root

    readonly property string python: String(Quickshell.env("CAELESTIA_SCHEME_PYTHON") ?? "")
    readonly property string helper: String(Quickshell.env("CAELESTIA_SCHEME_HELPER") ?? "")
    readonly property bool available: python !== "" && helper !== ""

    property var schemes: ({})
    property string currentName: ""
    property string currentFlavour: ""
    property string currentMode: "dark"
    property string currentVariant: ""
    // idle | working | ready | error | unavailable
    property string status: available ? "idle" : "unavailable"
    property string lastError: ""
    property string operation: ""
    property var pending: []

    signal schemeListChanged()
    signal schemeChanged()
    signal failed(string message)

    readonly property string currentLabel: {
        if (!available)
            return "Fixed Windows palette";
        if (currentName === "")
            return "No scheme loaded";
        return `${currentName} ${currentFlavour}`;
    }

    function cloneArgs(args): var {
        return [...args];
    }

    function enqueue(kind: string, args): void {
        if (!available) {
            status = "unavailable";
            return;
        }
        pending.push({
            kind: kind,
            args: cloneArgs(args)
        });
        pump();
    }

    function pump(): void {
        if (proc.running || pending.length === 0)
            return;
        const job = pending.shift();
        operation = job.kind;
        status = "working";
        proc.command = [root.python, root.helper, ...job.args];
        proc.running = true;
    }

    function updateCurrent(data): void {
        if (!data)
            return;
        currentName = String(data.name ?? currentName);
        currentFlavour = String(data.flavour ?? currentFlavour);
        currentMode = String(data.mode ?? currentMode);
        currentVariant = String(data.variant ?? currentVariant);
    }

    function finish(code: int, text: string): void {
        const kind = operation;
        operation = "";
        let data = null;
        if (text.trim().length > 0) {
            try {
                data = JSON.parse(text.trim());
            } catch (error) {
                data = null;
            }
        }
        if (code !== 0 || !data || data.ok !== true) {
            status = "error";
            lastError = String(data?.error ?? (text.trim() || `scheme generator exited ${code}`));
            console.warn(`CAELESTIA_SCHEME_FAIL ${kind}: ${lastError}`);
            failed(lastError);
        } else if (kind === "list") {
            schemes = data.schemes ?? {};
            updateCurrent(data.current ?? null);
            status = "ready";
            lastError = "";
            schemeListChanged();
        } else {
            updateCurrent(data);
            status = "ready";
            lastError = "";
            console.log(`CAELESTIA_SCHEME_APPLIED name=${currentName} flavour=${currentFlavour} mode=${currentMode} variant=${currentVariant}`);
            schemeChanged();
        }
        Qt.callLater(root.pump);
    }

    // Generate a dynamic scheme from an image (the wallpaper picker path).
    function applyWallpaper(path: string, smart: bool): void {
        enqueue("apply", ["apply-wallpaper", "--image", String(path), "--smart", smart ? "1" : "0"]);
    }

    function withImage(args: var, image: string): var {
        if (image && image.length > 0)
            args.push("--image", String(image));
        return args;
    }

    // Select a named scheme/flavour from the launcher row. The current Windows
    // wallpaper lets the dynamic row work before the picker has run.
    function setScheme(name: string, flavour: string, image: string): void {
        enqueue("set", withImage(["set", "--name", String(name), "--flavour", String(flavour)], image));
    }

    function setVariant(variant: string, image: string): void {
        enqueue("set", withImage(["set-variant", "--variant", String(variant)], image));
    }

    function setMode(mode: string, image: string): void {
        enqueue("set", withImage(["set-mode", "--mode", String(mode)], image));
    }

    function refresh(): void {
        if (!available)
            return;
        // The bundled scheme list is static; one successful load is enough.
        if (Object.keys(schemes).length > 0 && status !== "error")
            return;
        if (proc.running && operation === "list")
            return;
        for (const job of pending) {
            if (job.kind === "list")
                return;
        }
        enqueue("list", ["list"]);
    }

    Process {
        id: proc

        command: []

        stdout: StdioCollector {
            id: stdoutCollector
        }

        stderr: StdioCollector {
            id: stderrCollector
        }

        onExited: code => {
            if (code !== 0 && stderrCollector.text.trim().length > 0)
                console.warn("CAELESTIA_SCHEME_STDERR " + stderrCollector.text.trim());
            root.finish(code, stdoutCollector.text);
        }
    }
}
